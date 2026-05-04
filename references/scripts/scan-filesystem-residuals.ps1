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

function Get-EffectiveFileCount {
    param([string]$path, [string[]]$excluded)
    try {
        $allFiles = [System.IO.Directory]::GetFiles($path)
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
    try {
        $files = [System.IO.Directory]::GetFiles($path, '*', [System.IO.SearchOption]::AllDirectories)
        $size = 0
        foreach ($f in $files) {
            $fileInfo = Get-Item $f -Force -ErrorAction SilentlyContinue
            if ($fileInfo) { $size += $fileInfo.Length }
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
            $fileCount = Get-EffectiveFileCount -path $subdir -excluded $excludedFiles
            $totalSizeMB = Get-DirectorySizeMB -path $subdir
            $allSubdirsEmpty = Test-AllSubdirsEmpty -path $subdir

            # 判定风险等级
            $risk = 'skip'
            $reason = ''
            if ($fileCount -eq 0 -and $allSubdirsEmpty) {
                $risk = 'safe'
                $reason = "Empty directory (0 files, no non-empty subdirectories)"
            } elseif ($fileCount -le $maxFileCount -and $totalSizeMB -lt $maxSizeMB) {
                $risk = 'safe'
                $reason = "Minimal residual ($fileCount files, ${totalSizeMB}MB)"
            } elseif ($fileCount -le $maxFileCount -and $totalSizeMB -ge $maxSizeMB) {
                $risk = 'caution'
                $reason = "Few files but notable size ($fileCount files, ${totalSizeMB}MB)"
            } elseif ($fileCount -gt $maxFileCount -and $fileCount -le 20) {
                $risk = 'caution'
                $reason = "Moderate file count ($fileCount files, ${totalSizeMB}MB)"
            } else {
                $risk = 'caution'
                $reason = "Substantial content ($fileCount files, ${totalSizeMB}MB) - manual review recommended"
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
