# scan-filesystem-residuals.ps1
# 扫描文件系统空目录/孤文件残留（不依赖已卸载软件列表）
param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\config.json",
    [string]$OutputPath = "$PSScriptRoot\..\..\fs-residuals.json"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 加载配置
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$maxFileCount = $config.file_thresholds.max_file_count
$maxSizeMB = $config.file_thresholds.max_size_mb
$excludedFiles = $config.file_thresholds.excluded_files
$targetDirs = $config.target_directories

$residuals = [System.Collections.Generic.List[PSObject]]::new()

# 受保护目录：系统关键目录，永远不标记为残留（即使看起来"空"或文件少）
# 这些目录由系统/其他软件动态管理，绝不能清理
$protectedDirNames = @(
    'WindowsApps','ModifiableWindowsApps','Windows Defender','Microsoft',
    'Windows Defender Advanced Threat Protection','Windows Photo Viewer',
    'WindowsPowerShell','Windows Mail','Windows Security','Internet Explorer'
)

function Get-EffectiveFileCount {
    param([string]$path, [string[]]$excluded)
    # 修复：递归统计文件数，与 Get-DirectorySizeMB 的 AllDirectories 保持一致
    # 原实现用 GetFiles($path) 只数顶层文件，导致"顶层 0 文件但子目录有大量文件"的
    # 活跃程序目录（WindowsApps/Tencent/Google/Office 等）被误判为 0 files 残留
    try {
        $allFiles = [System.IO.Directory]::EnumerateFiles($path, '*', [System.IO.SearchOption]::AllDirectories)
        $count = 0
        foreach ($f in $allFiles) {
            $fname = [System.IO.Path]::GetFileName($f)
            $isExcluded = $false
            foreach ($pattern in $excluded) {
                if ($fname -like $pattern) { $isExcluded = $true; break }
            }
            if (-not $isExcluded) { $count++ }
        }
        return $count
    } catch {
        return 0
    }
}

function Get-DirectorySizeMB {
    param([string]$path)
    # 修复：用 EnumerateFiles + 内联 Length 累加，避免对每个文件调用 Get-Item（极慢）
    # 原实现逐文件 Get-Item，在 WindowsApps 等大目录（数千文件）上导致扫描超时
    try {
        $size = 0L
        foreach ($f in [System.IO.Directory]::EnumerateFiles($path, '*', [System.IO.SearchOption]::AllDirectories)) {
            try {
                $size += (New-Object System.IO.FileInfo $f).Length
            } catch { }
        }
        return [math]::Round($size / 1MB, 2)
    } catch {
        return 0
    }
}

function Test-AllSubdirsEmpty {
    param([string]$path)
    try {
        $subdirs = [System.IO.Directory]::GetDirectories($path)
        if ($subdirs.Count -eq 0) { return $true }
        foreach ($sd in $subdirs) {
            if ([System.IO.Directory]::GetFileSystemEntries($sd).Count -gt 0) { return $false }
        }
        return $true
    } catch {
        return $true
    }
}

foreach ($targetDir in $targetDirs) {
    $expandedDir = [Environment]::ExpandEnvironmentVariables($targetDir)
    if (-not (Test-Path $expandedDir)) { continue }
    try {
        foreach ($subdir in [System.IO.Directory]::GetDirectories($expandedDir)) {
            $dirName = [System.IO.Path]::GetFileName($subdir)

            # 受保护目录直接跳过（系统关键目录，绝不清理）
            if ($protectedDirNames -contains $dirName) {
                continue
            }

            # 单次递归遍历：同时统计文件数、总大小、是否含非空子目录
            # 原实现对每个目录做 3 次独立递归（计数/大小/空判定），大目录上极慢且误报
            $fileCount = 0
            $totalSizeMB = 0.0
            $allSubdirsEmpty = $true
            try {
                $size = 0L
                $hasNonEmptySubdir = $false
                foreach ($f in [System.IO.Directory]::EnumerateFiles($subdir, '*', [System.IO.SearchOption]::AllDirectories)) {
                    $fname = [System.IO.Path]::GetFileName($f)
                    $isExcluded = $false
                    foreach ($pattern in $excludedFiles) {
                        if ($fname -like $pattern) { $isExcluded = $true; break }
                    }
                    if (-not $isExcluded) { $fileCount++ }
                    try { $size += (New-Object System.IO.FileInfo $f).Length } catch { }
                }
                # 若存在任何文件，则说明有非空子目录（递归已包含）
                $totalSizeMB = [math]::Round($size / 1MB, 2)
                $allSubdirsEmpty = ($fileCount -eq 0)
            } catch {
                # 无权限等异常时按保守处理
                $fileCount = 0
                $totalSizeMB = 0.0
                $allSubdirsEmpty = $false
            }

            # 判定风险等级（修复：递归计数后，有实际内容的目录是活跃程序而非残留，跳过）
            $risk = 'skip'
            $reason = ''
            if ($fileCount -eq 0 -and $allSubdirsEmpty) {
                $risk = 'safe'
                $reason = "Empty directory (0 files, no non-empty subdirectories)"
            } elseif ($fileCount -le $maxFileCount -and $totalSizeMB -lt $maxSizeMB) {
                $risk = 'safe'
                $reason = "Minimal residual ($fileCount files, ${totalSizeMB}MB)"
            } elseif ($fileCount -le $maxFileCount -and $totalSizeMB -ge $maxSizeMB) {
                # 文件少但体积大（如残留的模型缓存/日志）：仍需人工确认
                $risk = 'caution'
                $reason = "Few files but notable size ($fileCount files, ${totalSizeMB}MB)"
            } else {
                # 递归计数后文件多 → 活跃程序目录，非残留，跳过（不再误报）
                $risk = 'skip'
                $reason = "Active directory with $fileCount files - not a residual"
            }

            if ($risk -ne 'skip') {
                $residuals.Add([PSCustomObject]@{
                    path = $subdir
                    name = $dirName
                    type = if ($fileCount -eq 0) { 'empty_directory' } else { 'residual_directory' }
                    file_count = $fileCount
                    size_mb = $totalSizeMB
                    risk = $risk
                    reason = $reason
                })
            }
        }
    } catch { Write-Warning "Scan failed for ${expandedDir}: $_" }
}

$jsonContent = $residuals | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($OutputPath, $jsonContent, [System.Text.UTF8Encoding]::new($false))

Write-Output "Filesystem residuals found: $($residuals.Count)"
Write-Output "  Safe: $($residuals | Where-Object { $_.risk -eq 'safe' } | Measure-Object | Select-Object -ExpandProperty Count)"
Write-Output "  Caution: $($residuals | Where-Object { $_.risk -eq 'caution' } | Measure-Object | Select-Object -ExpandProperty Count)"
