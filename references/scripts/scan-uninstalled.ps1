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
            $installLocation = $sub.GetValue('InstallLocation')
            $installPathMissing = ($installLocation -and -not [System.IO.Directory]::Exists($installLocation))

            # 判断逻辑 3: UninstallString 指向的可执行文件不存在
            $uninstallString = $sub.GetValue('UninstallString')
            $uninstallPathMissing = $false
            if ($uninstallString -and $uninstallString -match '^"(.+\.exe)"|^(.+\.exe)') {
                $exePath = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                $uninstallPathMissing = -not [System.IO.File]::Exists($exePath)
            }

            $isResidual = $notInIndex -or $installPathMissing -or $uninstallPathMissing
            if ($isResidual) {
                $uninstalledEntries.Add([PSCustomObject]@{
                    name = $displayName
                    registry_key = "$($rp.Hive)\$subKeyPath\$name"
                    install_location = $installLocation
                    uninstall_string = $uninstallString
                    evidence = @(if ($notInIndex) {"not in installed index"};
                                 if ($installPathMissing) {"InstallLocation path missing"};
                                 if ($uninstallPathMissing) {"UninstallString exe missing"}) -join '; '
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
