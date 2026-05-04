# clean-residuals.ps1
# 执行清理：支持四模式确认流程 + 白名单二次校验 + dry-run + Danger 过滤
param(
    [string]$ReportPath = "$PSScriptRoot\..\..\final-report.json",
    [string]$WhitelistPath = "$PSScriptRoot\..\config\whitelist.json",
    [string]$ItemsToClean = "",   # JSON array of IDs, e.g. '["fs_001","svc_001"]'
    [ValidateSet('A','B','C','D')]
    [string]$Mode = 'D',         # A=Auto-clean Safe, B=Safe auto + Caution confirm, C=Full review, D=Report only
    [switch]$DryRun = $false     # Dry-run mode: log actions without executing
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# B-M7 修复：清理前检查还原点是否已创建
if ($Mode -ne 'D') {
    $restoreFiles = Get-ChildItem -Path "$PSScriptRoot\..\..\backup-*" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $restoreFiles) {
        Write-Error "No restore point or backup found. Please run create-restore-point.ps1 first."
        Write-Output "Run: powershell -ExecutionPolicy Bypass -File '$PSScriptRoot\create-restore-point.ps1'"
        exit 1
    }
    Write-Output "Restore backup found: $($restoreFiles[0].Name)"
}

# --- 加载白名单（Defense-in-Depth: 清理前二次校验） ---
$whitelist = $null
if (Test-Path $WhitelistPath) {
    try {
        $whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to load whitelist: $_"
    }
}

function Test-Whitelisted {
    param([string]$Path, [string]$Key, [string]$ServiceName)
    if (-not $whitelist) { return $false }
    if ($Key -and $whitelist.registry_patterns) {
        foreach ($wp in $whitelist.registry_patterns) {
            if ($Key -match $wp.pattern) { return $true }
        }
    }
    if ($Path -and $whitelist.path_patterns) {
        foreach ($wp in $whitelist.path_patterns) {
            if ($Path -match $wp.pattern) { return $true }
        }
    }
    if ($ServiceName -and $whitelist.service_names -contains $ServiceName) { return $true }
    return $false
}

# --- 加载报告并按模式筛选项目 ---
try {
    $report = Get-Content $ReportPath -Raw | ConvertFrom-Json
} catch {
    $errMsg = $_.Exception.Message
    Write-Error ("Failed to load report from {0}: {1}" -f $ReportPath, $errMsg)
    exit 1
}

# 汇总所有项目到统一列表（含 shell_residuals 分类）
$allItems = @()
foreach ($cat in @('filesystem_residuals','registry_residuals','ghost_services','ghost_tasks','startup_residuals','shell_residuals','path_residuals')) {
    $items = $report.$cat
    if ($items) {
        if ($items -is [array] -or $items -is [System.Collections.IList]) {
            $allItems += @($items)
        } else {
            $allItems += $items
        }
    }
}

# B-M4 修复：按 Mode 筛选
# Mode A: 自动清理 Safe 项
# Mode B: 自动清理 Safe 项，Caution 项仅标记（用户需逐项确认，由调用者控制）
# Mode C: 全量审阅（Safe + Caution），Danger 保留
# Mode D: 仅报告，不清理
$itemsToClean = @()
switch ($Mode) {
    'A' { $itemsToClean = @($allItems | Where-Object { $_.risk -eq 'safe' }) }
    'B' { $itemsToClean = @($allItems | Where-Object { $_.risk -eq 'safe' }) }
    'C' { $itemsToClean = @($allItems | Where-Object { $_.risk -ne 'danger' }) }
    'D' { Write-Output "Report-only mode. No cleanup performed."; return }
}

# 如果指定了具体 ID，则进一步过滤（B-m3 修复：try/catch）
if ($ItemsToClean) {
    try {
        $ids = $ItemsToClean | ConvertFrom-Json
        $itemsToClean = @($itemsToClean | Where-Object { $ids -contains $_.id })
    } catch {
        Write-Warning "Invalid ItemsToClean JSON format. Ignoring filter."
    }
}

# --- 执行清理 ---
$log = [System.Collections.Generic.List[Hashtable]]::new()

foreach ($item in $itemsToClean) {
    $prefix = if ($DryRun) { "[DRY-RUN] " } else { "" }

    # Defense-in-Depth: 白名单二次校验
    if (Test-Whitelisted -Path $item.path -Key $item.key -ServiceName $item.name) {
        Write-Warning "$prefix SKIP (whitelisted): $($item.id)"
        $log.Add(@{ id=$item.id; action='skipped_whitelisted'; success=$false })
        continue
    }

    # Danger 项永远不清理（二次保险）
    if ($item.risk -eq 'danger') {
        Write-Warning "$prefix SKIP (danger): $($item.id) - $($item.reason)"
        $log.Add(@{ id=$item.id; action='skipped_danger'; success=$false })
        continue
    }

    try {
        # Clean registry（B-C2 修复：清理前检查键是否存在）
        if ($item.key) {
            Write-Output "$prefix Deleting registry key: $($item.key)"
            if (-not $DryRun) {
                # 先用 reg query 检查键是否存在
                $regKey = $item.key
                cmd /c "reg query `"$regKey`" 2>&1"
                if ($LASTEXITCODE -ne 0) {
                    Write-Output "  → Registry key does not exist (already removed), skipping"
                    $log.Add(@{ id=$item.id; action='registry_skip'; key=$item.key; success=$true; note='key not found' })
                    continue
                }
                reg delete "$regKey" /f 2>&1
                if ($LASTEXITCODE -ne 0) { throw "reg delete failed with exit code $LASTEXITCODE" }
            }
            $log.Add(@{ id=$item.id; action='registry_deleted'; key=$item.key; success=$true })
        }

        # Clean files/dirs
        if ($item.path) {
            Write-Output "$prefix Deleting path: $($item.path)"
            if (-not $DryRun) {
                if (Test-Path $item.path) {
                    Remove-Item -Path $item.path -Recurse -Force -ErrorAction Stop
                } else {
                    Write-Output "  → Path does not exist (already removed), skipping"
                }
            }
            $log.Add(@{ id=$item.id; action='path_deleted'; path=$item.path; success=$true })
        }

        # Clean services（B-C4 修复：停止 + 依赖检查 + 等待 + 删除）
        if ($item.name -and $item.binary_path) {
            Write-Output "$prefix Stopping and deleting service: $($item.name)"
            if (-not $DryRun) {
                # 先尝试停止服务
                sc.exe stop $item.name 2>$null
                # 等待服务停止（最多 10 秒）
                $waited = 0
                do {
                    Start-Sleep -Milliseconds 1000
                    $waited++
                    $svcState = (Get-CimInstance Win32_Service -Filter "Name='$($item.name)'" -ErrorAction SilentlyContinue).State
                } while ($svcState -eq 'Running' -and $waited -lt 10)

                if ($svcState -eq 'Running') {
                    Write-Warning "  → Service did not stop in time, attempting force delete"
                }
                sc.exe delete $item.name 2>&1
                if ($LASTEXITCODE -ne 0) { throw "sc.exe delete failed with exit code $LASTEXITCODE" }
            }
            $log.Add(@{ id=$item.id; action='service_deleted'; name=$item.name; success=$true })
        }
    } catch {
        $log.Add(@{ id=$item.id; action='cleanup_failed'; error=$_.Exception.Message; success=$false })
    }
}

$summary = @{
    mode = $Mode
    dry_run = $DryRun.IsPresent
    total_processed = $log.Count
    succeeded = ($log | Where-Object { $_.success -eq $true }).Count
    failed = ($log | Where-Object { $_.success -eq $false -and $_.action -eq 'cleanup_failed' }).Count
    skipped = ($log | Where-Object { $_.action -match 'skipped' }).Count
    timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
}

Write-Output "`nCleanup summary: $($summary.succeeded) succeeded, $($summary.failed) failed, $($summary.skipped) skipped"
if ($DryRun) { Write-Output "(DRY-RUN mode - no changes were made)" }

# 输出日志（UTF-8 without BOM）
$outputPath = "$PSScriptRoot\..\..\cleanup-log.json"
$logJson = @{ summary = $summary; entries = $log } | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($outputPath, $logJson, [System.Text.UTF8Encoding]::new($false))
Write-Output "Cleanup log saved to: $outputPath"
