# scan-uninstalled.ps1
# 扫描已卸载软件：与 installed-software-index.json 交叉验证
param(
    [string]$IndexPath = "$PSScriptRoot\..\..\installed-software-index.json",
    [string]$OutputPath = "$PSScriptRoot\..\..\uninstalled-list.json"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 加载已安装软件索引
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
            # 修复：去除引号后再检查路径，避免 "D:\path" 被当作非法路径
            $installLocation = $sub.GetValue('InstallLocation')
            $installPathMissing = $false
            if ($installLocation) {
                $cleanLocation = $installLocation.Trim('"').Trim("'")
                if ($cleanLocation -ne '' -and -not [System.IO.Directory]::Exists($cleanLocation)) {
                    $installPathMissing = $true
                }
            }

            # 判断逻辑 3: UninstallString 指向的可执行文件不存在
            # 修复：跳过 MsiExec.exe / rundll32.exe / regsvr32.exe 等系统卸载器，
            # 这些是 Windows 系统工具，总是存在于 System32，不应作为残留判断依据
            $uninstallString = $sub.GetValue('UninstallString')
            $uninstallPathMissing = $false
            if ($uninstallString -and $uninstallString -notmatch '^\s*(MsiExec|rundll32|regsvr32)\.exe') {
                $exePath = $null
                if ($uninstallString -match '^"(.+?\.exe)"') {
                    $exePath = $Matches[1]
                } elseif ($uninstallString -match '^(.+?\.exe)(?:\s|$)') {
                    $exePath = $Matches[1]
                }
                if ($exePath -and -not [System.IO.File]::Exists($exePath)) {
                    $uninstallPathMissing = $true
                }
            }

            # 三重判断 OR 组合：任一条件满足即判定为残留
            # 逻辑 1（索引缺失）= 主信号
            # 逻辑 2（InstallLocation 丢失）= 安装路径被删除
            # 逻辑 3（UninstallString exe 丢失）= 卸载程序被删除
            $isResidual = $notInIndex -or $installPathMissing -or $uninstallPathMissing
            if ($isResidual) {
                $evidenceParts = @()
                if ($notInIndex) { $evidenceParts += "not in installed index" }
                if ($installPathMissing) { $evidenceParts += "InstallLocation path missing" }
                if ($uninstallPathMissing) { $evidenceParts += "UninstallString exe missing" }

                $uninstalledEntries.Add([PSCustomObject]@{
                    name = $displayName
                    registry_key = "$($rp.Hive)\$subKeyPath\$name"
                    install_location = $installLocation
                    uninstall_string = $uninstallString
                    evidence = $evidenceParts -join '; '
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
            if (-not $installedNames.ContainsKey($dirName) -and $installedNames.Keys -notmatch [regex]::Escape($dirName)) {
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
