# build-installed-index.ps1
# 构建已安装软件全量索引，输出 installed-software-index.json

param(
    [string]$OutputPath = "$PSScriptRoot\..\..\installed-software-index.json"
)

# dot-source 时把顶层 param 的默认值固化下来，供 Main 的 -OutputPath 参数做默认值。
# 直接用 `$OutputPath` 不行：Main 的参数与顶层参数同名会互相干扰（PS 5.1 变量名大小写不敏感）。
$script:DefaultOutputPath = $OutputPath

# =========================================================
# 包管理器输出解析器（纯函数，便于单测）
#
# 这三个解析器原本内联在 Main 里，且整体被 `Get-Command winget/scoop/choco`
# 守卫包住 —— 机器上没装对应工具时，解析逻辑一行都不会被执行，
# 也就永远无法被单测覆盖。抽成顶层纯函数后，可以用真实输出样本直接测。
# =========================================================

function ConvertFrom-WingetJson {
    <#
    .SYNOPSIS
        解析 `winget list --output json` 的输出。
    .DESCRIPTION
        winget 的 JSON 是顶层数组；PS 5.1 不会被 @() 展开（见 AGENTS.md 陷阱 #6），
        所以此处直接 foreach 可枚举对象。无 Name 的包被跳过。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    $result = @()
    if ([string]::IsNullOrWhiteSpace($Json)) { return $result }
    $data = $Json | ConvertFrom-Json -ErrorAction Stop
    foreach ($pkg in $data) {
        if ($pkg.Name) {
            $result += [PSCustomObject]@{
                name             = $pkg.Name
                version          = $pkg.Version
                publisher        = $pkg.Publisher
                install_location = ''
                uninstall_string = ''
                source           = 'winget'
            }
        }
    }
    return $result
}

function ConvertFrom-WingetText {
    <#
    .SYNOPSIS
        解析 `winget list` 的文本表格（JSON 不可用时的回退路径）。
    .DESCRIPTION
        调用方已用 Select-Object -Skip 3 跳过标题栏，此处按 2+ 空格分列。
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @())

    $result = @()
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\s{2,}'
        if ($parts.Count -ge 1 -and $parts[0] -ne '') {
            $result += [PSCustomObject]@{
                name             = $parts[0].Trim()
                version          = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
                publisher        = ''
                install_location = ''
                uninstall_string = ''
                source           = 'winget'
            }
        }
    }
    return $result
}

function ConvertFrom-ScoopJson {
    <#
    .SYNOPSIS
        解析 `scoop list --json` 的输出。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    $result = @()
    if ([string]::IsNullOrWhiteSpace($Json)) { return $result }
    $data = $Json | ConvertFrom-Json -ErrorAction Stop
    foreach ($app in $data) {
        $result += [PSCustomObject]@{
            name             = $app.Name
            version          = $app.Version
            publisher        = ''
            install_location = ''
            uninstall_string = ''
            source           = 'scoop'
        }
    }
    return $result
}

function ConvertFrom-ScoopText {
    <#
    .SYNOPSIS
        解析 `scoop list` 的文本表格（JSON 不可用时的回退路径）。
    .DESCRIPTION
        调用方已过滤表头（'Installed' 与 '----' 开头行），此处按空白分列。
    #>
    param([AllowEmptyCollection()][string[]]$Lines = @())

    $result = @()
    foreach ($line in $Lines) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -ge 2 -and $parts[0] -ne '') {
            $result += [PSCustomObject]@{
                name             = $parts[0]
                version          = $parts[1]
                publisher        = ''
                install_location = ''
                uninstall_string = ''
                source           = 'scoop'
            }
        }
    }
    return $result
}

function ConvertFrom-ChocoText {
    <#
    .SYNOPSIS
        解析 `choco list --local-only --limit-output` 的输出。
    .DESCRIPTION
        输出格式为每行 `name|version`。缺少分隔符或空行会被跳过。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $result = @()
    if ([string]::IsNullOrEmpty($Text)) { return $result }
    foreach ($line in ($Text -split "`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        $parts = $trimmed -split '\|'
        if ($parts.Count -ge 2) {
            $result += [PSCustomObject]@{
                name             = $parts[0]
                version          = $parts[1]
                publisher        = ''
                install_location = ''
                uninstall_string = ''
                source           = 'chocolatey'
            }
        }
    }
    return $result
}

function Main {
    # 退出码通过 [ref] 回传（ADR-001）：Main 内不得 exit，也不得 `return <数字>`
    #
    # 输出路径不声明为 `$OutputPath` 参数：在 param() 里声明同名变量会被
    # PowerShell **无条件**创建（值为 ''），从而遮蔽调用方作用域的同名变量。
    # 实测：function F { param([string]$P); "$P" }; $P='CALLER'; F  ->  ''（而非 CALLER）。
    # 而既有测试与 main-flow 的写法都是「先在调用方作用域设 $OutputPath，再裸调 Main」。
    # 故此处保留「读作用域变量」的语义，仅当显式传入 -OutputPathOverride 时覆盖。
    param(
        [ref]$ExitCode,
        [string]$OutputPathOverride
    )
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    # 显式传入优先；否则沿用调用方作用域的 $OutputPath（动态作用域查找）；
    # 再否则回落到脚本顶层 param 的默认值。
    if (-not [string]::IsNullOrWhiteSpace($OutputPathOverride)) {
        $OutputPath = $OutputPathOverride
    } elseif ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = $script:DefaultOutputPath
    }

    # 头部配置
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # Admin privilege check (warning only for read-only operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
    }

    # 使用 List[T] 替代 $entries += @()，避免 O(n²) 数组复制开销
    $entries = [System.Collections.Generic.List[PSObject]]::new()

    $totalSources = 6
    $scannedSources = 0

    # =========================================================
    # 源一：Uninstall 注册表键（HKLM + WOW6432Node + HKCU）
    # 使用 switch 替代动态枚举访问（:: 不支持字符串插值）
    # 在 64-bit PowerShell 中，WOW6432Node 通过直接拼接子键路径访问
    # =========================================================
    $scannedSources++
    $regPaths = @(
        [PSCustomObject]@{ Hive='HKLM'; SubKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; WOW6432=$false },
        [PSCustomObject]@{ Hive='HKLM'; SubKey='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; WOW6432=$true },
        [PSCustomObject]@{ Hive='HKCU'; SubKey='Software\Microsoft\Windows\CurrentVersion\Uninstall'; WOW6432=$false }
    )

    foreach ($rp in $regPaths) {
        try {
            $base = if ($rp.Hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
            # WOW6432Node: 64-bit PowerShell on 64-bit OS 下，直接使用 WOW6432Node 路径前缀
            if ($rp.WOW6432) {
                $subKeyPath = "SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
            } else {
                $subKeyPath = $rp.SubKey
            }

            $key = $base.OpenSubKey($subKeyPath)
            if (-not $key) { continue }

            foreach ($name in $key.GetSubKeyNames()) {
                $sub = $key.OpenSubKey($name)
                if (-not $sub) { continue }

                $displayName = $sub.GetValue('DisplayName')
                if (-not $displayName) { continue }

                # 构建 source 标签，区分 64-bit 和 WOW6432 视图
                $sourceLabel = if ($rp.WOW6432) {
                    "registry_$($rp.Hive)_WOW"
                } else {
                    "registry_$($rp.Hive)_64"
                }

                $entries.Add([PSCustomObject]@{
                    name              = $displayName
                    version           = $sub.GetValue('DisplayVersion')
                    publisher         = $sub.GetValue('Publisher')
                    install_location  = $sub.GetValue('InstallLocation')
                    uninstall_string  = $sub.GetValue('UninstallString')
                    source            = $sourceLabel
                })
            }
            $key.Close()
        } catch {
            Write-Warning "Registry scan failed for $($rp.Hive)\$subKeyPath : $_"
        }
    }

    # =========================================================
    # 源二：winget（if available）
    # 优先 JSON 输出，fallback 文本解析
    # =========================================================
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $scannedSources++
        # 优先使用 JSON 输出（winget v1.6+）
        try {
            $wingetJson = winget list --source winget --output json 2>$null | Out-String
            if ($wingetJson -and $wingetJson.Trim() -ne '') {
                foreach ($e in @(ConvertFrom-WingetJson -Json $wingetJson)) { $entries.Add($e) }
            }
        } catch {
            # Fallback: 文本解析
            Write-Warning "winget JSON parse failed, falling back to text: $_"
            try {
                $wingetText = winget list --source winget 2>$null | Select-Object -Skip 3
                foreach ($e in @(ConvertFrom-WingetText -Lines @($wingetText))) { $entries.Add($e) }
            } catch {
                Write-Warning "winget text parse failed: $_"
            }
        }
    } else {
        Write-Warning "winget not found — skipping Source 2"
    }

    # =========================================================
    # 源三：Scoop（if available）
    # 优先 JSON 输出，fallback 文本解析
    # =========================================================
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        $scannedSources++
        try {
            $scoopJson = scoop list --json 2>$null | Out-String
            if ($scoopJson -and $scoopJson.Trim() -ne '') {
                foreach ($e in @(ConvertFrom-ScoopJson -Json $scoopJson)) { $entries.Add($e) }
            }
        } catch {
            # Fallback: 文本解析（跳过表头和分隔线）
            Write-Warning "scoop JSON parse failed, falling back to text: $_"
            try {
                $scoopText = scoop list 2>$null | Where-Object { $_ -notmatch '^(Installed|----|$)' }
                foreach ($e in @(ConvertFrom-ScoopText -Lines @($scoopText))) { $entries.Add($e) }
            } catch {
                Write-Warning "scoop text parse failed: $_"
            }
        }
    } else {
        Write-Warning "scoop not found — skipping Source 3"
    }

    # =========================================================
    # 源四：Chocolatey（if available）
    # choco list --local-only --limit-output 输出格式：name|version
    # =========================================================
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $scannedSources++
        try {
            $chocoOutput = choco list --local-only --limit-output 2>$null
            if ($chocoOutput) {
                foreach ($e in @(ConvertFrom-ChocoText -Text ($chocoOutput -join "`n"))) { $entries.Add($e) }
            }
        } catch {
            Write-Warning "chocolatey scan failed: $_"
        }
    } else {
        Write-Warning "choco not found — skipping Source 4"
    }

    # =========================================================
    # 源五：MSI Installer UserData 注册表
    # 路径：HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products
    # =========================================================
    $scannedSources++
    try {
        $installerBase = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
        $userDataKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($installerBase)
        if ($userDataKey) {
            foreach ($productKey in $userDataKey.GetSubKeyNames()) {
                $propsKeyPath = "$installerBase\$productKey\InstallProperties"
                $propsKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($propsKeyPath)
                if (-not $propsKey) { continue }

                $displayName = $propsKey.GetValue('DisplayName')
                if ($displayName) {
                    $entries.Add([PSCustomObject]@{
                        name              = $displayName
                        version           = $propsKey.GetValue('DisplayVersion')
                        publisher         = $propsKey.GetValue('Publisher')
                        install_location  = $propsKey.GetValue('InstallLocation')
                        uninstall_string  = ''
                        source            = 'msi'
                    })
                }
                $propsKey.Close()
            }
            $userDataKey.Close()
        }
    } catch {
        Write-Warning "MSI installer scan failed: $_"
    }

    # =========================================================
    # 源六：UWP / MSIX（Get-AppxPackage）
    # =========================================================
    $scannedSources++
    try {
        Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name) {
                $entries.Add([PSCustomObject]@{
                    name              = $_.Name
                    version           = $_.Version
                    publisher         = $_.Publisher
                    install_location  = $_.InstallLocation
                    uninstall_string  = ''
                    source            = 'uwp'
                })
            }
        }
    } catch {
        Write-Warning "UWP scan failed: $_"
    }

    Write-Output "Scanned $scannedSources / $totalSources data sources — collected $($entries.Count) raw entries"

    # =========================================================
    # 去重：按 name|version|source 复合键去重（不是 name 单独去重）
    # =========================================================
    $unique = [System.Collections.Generic.List[PSObject]]::new()
    $seen = @{}
    foreach ($e in $entries) {
        $key = "$($e.name)|$($e.version)|$($e.source)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique.Add($e)
        }
    }

    # =========================================================
    # 输出 JSON：UTF-8 WITHOUT BOM → 写入 skill root
    # =========================================================
    # 提前解析绝对路径（$PSScriptRoot 在 .NET WriteAllText 中不生效）
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputDir = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
    if (-not (Test-Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    $jsonContent = $unique | ConvertTo-Json -Depth 2
    [System.IO.File]::WriteAllText(
        $resolvedOutputPath,
        $jsonContent,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Output "Installed software index: $($unique.Count) entries → $resolvedOutputPath"
    & $setRc 0
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
# $MyInvocation.InvocationName is '.' when dot-sourced, empty when run via -File
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
