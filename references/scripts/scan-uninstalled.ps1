# scan-uninstalled.ps1
# 扫描已卸载软件：与 installed-software-index.json 交叉验证
param(
    [string]$IndexPath = "$PSScriptRoot\..\..\installed-software-index.json",
    [string]$OutputPath = "$PSScriptRoot\..\..\uninstalled-list.json"
)

# 固化顶层 param 的默认值，供 Main 在调用方未提供时回落
$script:DefaultIndexPath = $IndexPath
$script:DefaultOutputPath = $OutputPath

function Test-PathMissing {
    <#
    .SYNOPSIS
        判断 InstallLocation 指向的目录是否缺失。
    .DESCRIPTION
        含两处历史修复：先 Trim 引号（AGENTS.md 陷阱 #4），再展开环境变量（陷阱 #5）。
        空路径不算缺失。
    #>
    param([AllowEmptyString()][AllowNull()][string]$InstallLocation)

    if (-not $InstallLocation) { return $false }
    $clean = [Environment]::ExpandEnvironmentVariables($InstallLocation.Trim('"').Trim("'"))
    if ([string]::IsNullOrWhiteSpace($clean)) { return $false }
    return -not [System.IO.Directory]::Exists($clean)
}

function Get-UninstallExePath {
    <#
    .SYNOPSIS
        从 UninstallString 中提取 exe 路径；系统卸载器返回 $null。
    .DESCRIPTION
        跳过 MsiExec/rundll32/regsvr32 —— 它们是 Windows 系统工具，总是存在于
        System32，不应作为残留判断依据。支持带引号与不带引号两种形式。
    #>
    param([AllowEmptyString()][AllowNull()][string]$UninstallString)

    if (-not $UninstallString) { return $null }
    if ($UninstallString -match '^\s*(MsiExec|rundll32|regsvr32)\.exe') { return $null }

    $exePath = $null
    if ($UninstallString -match '^"(.+?\.exe)"') {
        $exePath = $Matches[1]
    } elseif ($UninstallString -match '^(.+?\.exe)(?:\s|$)') {
        $exePath = $Matches[1]
    }
    if (-not $exePath) { return $null }
    return [Environment]::ExpandEnvironmentVariables($exePath)
}

function Get-ResidualVerdict {
    <#
    .SYNOPSIS
        两阶段加权残留判定（纯函数）。
    .DESCRIPTION
        阶段 1：不在已安装索引中 → 直接判残留；有路径/卸载器证据则 high，否则 low。
        阶段 2：在索引中 → 必须「路径缺失 AND 卸载器缺失」才判残留（medium）。
        权威信号是索引成员关系；辅助信号不能独立触发（见 AGENTS.md「多条件检测」）。
    #>
    param(
        [bool]$NotInIndex,
        [bool]$InstallPathMissing,
        [bool]$UninstallPathMissing
    )

    if ($NotInIndex) {
        $confidence = if ($InstallPathMissing -or $UninstallPathMissing) { 'high' } else { 'low' }
        return @{ is_residual = $true; confidence = $confidence }
    }
    if ($InstallPathMissing -and $UninstallPathMissing) {
        return @{ is_residual = $true; confidence = 'medium' }
    }
    return @{ is_residual = $false; confidence = 'high' }
}

function Get-ResidualEvidence {
    <#
    .SYNOPSIS
        把三路判定信号拼成人类可读的证据串。
    #>
    param(
        [bool]$NotInIndex,
        [bool]$InstallPathMissing,
        [bool]$UninstallPathMissing
    )

    $parts = @()
    if ($NotInIndex) { $parts += 'not in installed index' }
    if ($InstallPathMissing) { $parts += 'InstallLocation path missing' }
    if ($UninstallPathMissing) { $parts += 'UninstallString exe missing' }
    return ($parts -join '; ')
}

function Main {
    # ADR-001: 用 [ref] 回传退出码；不得 exit（会杀死测试宿主），也不得 `return <code>`
    #
    # 路径不声明为 `$IndexPath`/`$OutputPath` 参数：在 param() 里声明同名变量会被
    # PowerShell 无条件创建（值为 ''），遮蔽调用方作用域的同名变量（实测）。
    # 既有调用契约是「在作用域内设 $IndexPath/$OutputPath 后调用 Main」，
    # 故保留该语义，并提供 -IndexPathOverride/-OutputPathOverride 显式覆盖。
    param(
        [ref]$ExitCode,
        [string]$IndexPathOverride,
        [string]$OutputPathOverride
    )
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    if (-not [string]::IsNullOrWhiteSpace($IndexPathOverride)) {
        $IndexPath = $IndexPathOverride
    } elseif ([string]::IsNullOrWhiteSpace($IndexPath)) {
        $IndexPath = $script:DefaultIndexPath
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPathOverride)) {
        $OutputPath = $OutputPathOverride
    } elseif ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = $script:DefaultOutputPath
    }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # Admin privilege check (warning only for read-only operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
    }

    # 加载已安装软件索引
    if (-not (Test-Path $IndexPath)) {
        Write-Error "Installed software index not found: $IndexPath"
        & $setRc 3
        return
    }
    $installedIndex = Get-Content $IndexPath -Raw | ConvertFrom-Json
    $installedNames = @{}
    foreach ($i in $installedIndex) { $installedNames[$i.name] = $true }

    $uninstalledEntries = [System.Collections.Generic.List[PSObject]]::new()
    $uninstalledDirs = [System.Collections.Generic.List[PSObject]]::new()

    # 遍历 Uninstall 注册表键
    $regPaths = @(
        @{ Hive='HKLM'; SubKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; WOW6432=$false },
        @{ Hive='HKLM'; SubKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; WOW6432=$true },
        @{ Hive='HKCU'; SubKey='Software\Microsoft\Windows\CurrentVersion\Uninstall'; WOW6432=$false }
    )

    foreach ($rp in $regPaths) {
        try {
            $base = if ($rp.Hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
            $subKeyPath = if ($rp.WOW6432) { "SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" } else { $rp.SubKey }
            $key = $base.OpenSubKey($subKeyPath)
            if (-not $key) { continue }
            foreach ($name in $key.GetSubKeyNames()) {
                $sub = $key.OpenSubKey($name)
                if (-not $sub) { continue }
                $displayName = $sub.GetValue('DisplayName')
                if (-not $displayName) { continue }

                # 判断逻辑 1: 卸载键存在但索引中无匹配 → 已卸载残留
                $notInIndex = -not $installedNames.ContainsKey($displayName)

                # 判断逻辑 2: InstallLocation 指向的路径不存在
                # （Trim 引号 + 展开环境变量，见 Test-PathMissing）
                $installLocation = $sub.GetValue('InstallLocation')
                $installPathMissing = Test-PathMissing -InstallLocation $installLocation

                # 判断逻辑 3: UninstallString 指向的可执行文件不存在
                # （跳过 MsiExec/rundll32/regsvr32 系统卸载器，见 Get-UninstallExePath）
                $uninstallString = $sub.GetValue('UninstallString')
                $uninstallPathMissing = $false
                $exePath = Get-UninstallExePath -UninstallString $uninstallString
                if ($exePath -and -not [System.IO.File]::Exists($exePath)) {
                    $uninstallPathMissing = $true
                }

                # 两阶段加权判断 (Task 3a fix) — 权威信号 gate 辅助信号
                $verdict = Get-ResidualVerdict `
                    -NotInIndex $notInIndex `
                    -InstallPathMissing $installPathMissing `
                    -UninstallPathMissing $uninstallPathMissing

                if ($verdict.is_residual) {
                    $evidence = Get-ResidualEvidence `
                        -NotInIndex $notInIndex `
                        -InstallPathMissing $installPathMissing `
                        -UninstallPathMissing $uninstallPathMissing

                    $uninstalledEntries.Add([PSCustomObject]@{
                        name = $displayName
                        registry_key = "$($rp.Hive)\$subKeyPath\$name"
                        install_location = $installLocation
                        uninstall_string = $uninstallString
                        evidence = $evidence
                        confidence = $verdict.confidence
                        source = $rp.Hive
                    })
                }
            }
        } catch { Write-Warning "Scan failed for $($rp.Hive): $_" }
    }

    # A-M1 修复：文件系统反查 (来源三)
    # 扫描 Program Files / AppData / ProgramData 中的子目录，反查注册表
    $scanDirs = @(
        [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('ProgramFilesX86'),
        [Environment]::GetFolderPath('ApplicationData'),
        [Environment]::GetFolderPath('LocalApplicationData'),
        [Environment]::GetFolderPath('CommonApplicationData')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($dir in $scanDirs) {
        try {
            foreach ($subdir in [System.IO.Directory]::GetDirectories($dir)) {
                $dirName = [System.IO.Path]::GetFileName($subdir)
                $matchedNames = @($installedNames.Keys | Where-Object { $_ -match [regex]::Escape($dirName) })
                if (-not $installedNames.ContainsKey($dirName) -and $matchedNames.Count -eq 0) {
                    $uninstalledDirs.Add([PSCustomObject]@{
                        name = $dirName
                        path = $subdir
                        evidence = "directory present but no matching installed software in index"
                    })
                }
            }
        } catch { Write-Warning "Filesystem scan failed for ${dir}: $_" }
    }

    # 输出
    $report = @{
        uninstalled_software = $uninstalledEntries
        candidate_directories = $uninstalledDirs
    }
    $jsonContent = $report | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($OutputPath, $jsonContent, [System.Text.UTF8Encoding]::new($false))

    Write-Output "Uninstalled entries: $($uninstalledEntries.Count) | Candidate directories: $($uninstalledDirs.Count)"
    & $setRc 0
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
# $MyInvocation.InvocationName is '.' when dot-sourced, empty when run via -File
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
