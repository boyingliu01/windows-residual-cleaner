# clean-residuals.ps1
# 执行清理：支持四模式确认流程 + 白名单二次校验 + dry-run + Danger 过滤
param(
    [string]$ReportPath = "$PSScriptRoot\..\..\final-report.json",
    [string]$WhitelistPath = "$PSScriptRoot\..\config\whitelist.json",
    [string]$ItemsToClean = "",   # JSON array of IDs, e.g. '["fs_001","svc_001"]'
    [string]$ConfirmFile = "",   # Path to confirmed-ids.json (output of confirm-cleanup.ps1)
    [ValidateSet('A','B','C','D')]
    [string]$Mode = 'D',         # A=Auto-clean Safe, B=Safe auto + Caution confirm, C=Full review, D=Report only
    [switch]$DryRun = $false     # Dry-run mode: log actions without executing
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Robust file deletion with fallback strategies for locked/permission-denied files
function Remove-ItemRobust {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess','')]
    param([string]$Path, [switch]$WhatIf)
    if ($WhatIf) { return $true }
    if (-not (Test-Path $Path)) { return $true }

    # Strategy 1: Standard PowerShell Remove-Item
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        $err1 = $_.Exception.Message
        Write-Warning "  → Standard delete failed: $err1"
    }

    # Strategy 2: Take ownership + grant full access, then retry
    try {
        # takeown /f for files, /r for recursive on directories
        $isDir = (Get-Item $Path).PSIsContainer
        if ($isDir) {
            $takeownArgs = '/r', '/d', 'Y', '/f', $Path
        } else {
            $takeownArgs = '/f', $Path
        }
        $takeown = Start-Process -FilePath 'takeown.exe' -ArgumentList $takeownArgs -Wait -PassThru -WindowStyle Hidden
        if ($takeown.ExitCode -ne 0) {
            Write-Warning "  → takeown.exe failed with exit code $($takeown.ExitCode)"
        }

        # icacls grant Administrators full control
        if ($isDir) {
            $icaclsArgs = $Path, '/grant', 'Administrators:F', '/T', '/C'
        } else {
            $icaclsArgs = $Path, '/grant', 'Administrators:F', '/C'
        }
        $icacls = Start-Process -FilePath 'icacls.exe' -ArgumentList $icaclsArgs -Wait -PassThru -WindowStyle Hidden
        if ($icacls.ExitCode -ne 0) {
            Write-Warning "  → icacls.exe failed with exit code $($icacls.ExitCode)"
        }

        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        $err2 = $_.Exception.Message
        Write-Warning "  → Takeown+ACL delete failed: $err2"
    }

    # Strategy 3: cmd rd /s /q (sometimes works where PS fails)
    try {
        $isDir = (Get-Item $Path).PSIsContainer
        if ($isDir) {
            cmd /c "rd /s /q `"$Path`"" 2>&1
            if ($LASTEXITCODE -eq 0 -and -not (Test-Path $Path)) { return $true }
        } else {
            cmd /c "del /f /q `"$Path`"" 2>&1
            if ($LASTEXITCODE -eq 0 -and -not (Test-Path $Path)) { return $true }
        }
    } catch {
        Write-Warning "  → cmd delete failed: $($_.Exception.Message)"
    }

    # Strategy 4: Rename the file/directory (if deletion is blocked by handle)
    try {
        $isDir = (Get-Item $Path).PSIsContainer
        $parent = Split-Path $Path -Parent
        $leaf = Split-Path $Path -Leaf
        $renamed = Join-Path $parent "~$leaf.deleted"
        $counter = 0
        while (Test-Path $renamed) {
            $counter++
            $renamed = Join-Path $parent "~$leaf.deleted$counter"
        }
        Rename-Item -Path $Path -NewName $renamed -Force -ErrorAction Stop
        Write-Output "  → Renamed to $(Split-Path $renamed -Leaf) (deferred delete - may be in use)"

        # If it's a file, try to schedule it for deletion on next reboot using MoveFileEx
        if (-not $isDir) {
            try {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Delete {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    public const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;
}
"@ -ErrorAction SilentlyContinue
                [Win32Delete]::MoveFileEx($renamed, $null, [Win32Delete]::MOVEFILE_DELAY_UNTIL_REBOOT) | Out-Null
            } catch { Write-Verbose "MoveFileEx delayed-delete failed for $renamed" }
        }
        return $true
    } catch {
        Write-Warning "  → Rename fallback also failed: $($_.Exception.Message)"
    }

    return $false
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

# 点源守卫：当脚本被 dot-source（如单元测试加载函数）时，只加载函数定义，
# 跳过所有副作用代码（还原点检查/白名单加载/清理执行），使 dot-source 完全无副作用。
# 正常执行（& script 或 -File script）时 $MyInvocation.InvocationName != '.', 继续执行。
# 必须位于所有函数定义之后、任何可执行副作用语句之前。
if ($MyInvocation.InvocationName -eq '.') {
    return
}

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
# 如果指定了 ConfirmFile，则跳过 Mode 筛选，直接使用用户确认的 ID 列表
# 注意：变量名必须用 $cleanupItems 而非 $itemsToClean，因为参数 $ItemsToClean
# 是 [string] 类型，PS 变量不区分大小写，会导致类型约束冲突
if ($ConfirmFile -ne '') {
    # ConfirmFile 模式：用户已通过 confirm-cleanup.ps1 交互确认，跳过 Mode 筛选
    $cleanupItems = @()
    foreach ($item in $allItems) {
        if ($item.risk -ne 'danger') {
            $cleanupItems += $item
        }
    }
} else {
    switch ($Mode) {
        'A' { $cleanupItems = @($allItems | Where-Object { $_.risk -eq 'safe' }) }
        'B' { $cleanupItems = @($allItems | Where-Object { $_.risk -eq 'safe' }) }
        'C' { $cleanupItems = @($allItems | Where-Object { $_.risk -ne 'danger' }) }
        'D' { Write-Output "Report-only mode. No cleanup performed."; return }
    }
}

# 如果指定了 ConfirmFile（来自 confirm-cleanup.ps1），则以此为筛选依据
if ($ConfirmFile -and (Test-Path $ConfirmFile)) {
    try {
        $confirmedIds = Get-Content $ConfirmFile -Raw | ConvertFrom-Json
        $cleanupItems = @($cleanupItems | Where-Object { $confirmedIds -contains $_.id })
        Write-Output "Loaded $($confirmedIds.Count) confirmed IDs from $ConfirmFile, matched $($cleanupItems.Count) items"
    } catch {
        Write-Warning "Failed to load ConfirmFile: $_"
    }
} elseif ($ConfirmFile) {
    Write-Warning "ConfirmFile not found: $ConfirmFile"
}

# 如果指定了具体 ID，则进一步过滤（B-m3 修复：try/catch）
if ($ItemsToClean) {
    try {
        $ids = $ItemsToClean | ConvertFrom-Json
        $cleanupItems = @($cleanupItems | Where-Object { $ids -contains $_.id })
    } catch {
        Write-Warning "Invalid ItemsToClean JSON format. Ignoring filter."
    }
}

# --- 执行清理 ---
$log = [System.Collections.Generic.List[Hashtable]]::new()

foreach ($item in $cleanupItems) {
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
                    $deleted = Remove-ItemRobust -Path $item.path -WhatIf:$DryRun
                    if (-not $deleted) {
                        throw "Failed to delete path after all fallback strategies"
                    }
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

        # Clean ghost scheduled tasks（修复：新增 ghost_task 处理分支）
        # ghost task 结构: { type='ghost_task'; name; execute; expanded_path; risk; reason; id }
        # 与 service 的区分：service 有 binary_path，task 有 expanded_path
        if ($item.name -and $item.expanded_path -and -not $item.binary_path) {
            Write-Output "$prefix Deleting scheduled task: $($item.name)"
            if (-not $DryRun) {
                # 根据 name 精确删除计划任务（Unregister-ScheduledTask 会同时删除 task + 其所有 action）
                $task = Get-ScheduledTask -TaskName $item.name -ErrorAction SilentlyContinue
                if ($task) {
                    Unregister-ScheduledTask -TaskName $item.name -Confirm:$false -ErrorAction Stop
                    Write-Output "  → Scheduled task deleted: $($item.name)"
                } else {
                    Write-Output "  → Scheduled task not found (already removed), skipping"
                }
            }
            $log.Add(@{ id=$item.id; action='task_deleted'; name=$item.name; success=$true })
        }

        # Clean PATH residuals（修复：新增 path_entry 处理分支）
        # PATH 残留结构: { type='path_entry'; path=<dead dir>; risk; reason; id }
        # 从机器 PATH 环境变量中移除指向不存在目录的条目
        if ($item.type -eq 'path_entry' -and $item.path) {
            Write-Output "$prefix Removing dead PATH entry: $($item.path)"
            if (-not $DryRun) {
                $mp = [Environment]::GetEnvironmentVariable('Path','Machine')
                $target = $item.path.Trim()
                if ($mp -match [regex]::Escape($target)) {
                    $mpItems = $mp -split ';' | Where-Object { $_.Trim() -and $_.Trim() -ne $target }
                    [Environment]::SetEnvironmentVariable('Path', ($mpItems -join ';'), 'Machine')
                    Write-Output "  → Removed from machine PATH: $target"
                } else {
                    Write-Output "  → PATH entry not found (already removed), skipping"
                }
            }
            $log.Add(@{ id=$item.id; action='path_entry_removed'; path=$item.path; success=$true })
        }
    } catch {
        $log.Add(@{ id=$item.id; action='cleanup_failed'; error=$_.Exception.Message; success=$false })
    }
}

$summary = @{
    mode = $Mode
    dry_run = $DryRun.IsPresent
    total_processed = $log.Count
    succeeded = @($log | Where-Object { $_.success -eq $true }).Count
    failed = @($log | Where-Object { $_.success -eq $false -and $_.action -eq 'cleanup_failed' }).Count
    skipped = @($log | Where-Object { $_.action -match 'skipped' }).Count
    timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
}

Write-Output "`nCleanup summary: $($summary.succeeded) succeeded, $($summary.failed) failed, $($summary.skipped) skipped"
if ($DryRun) { Write-Output "(DRY-RUN mode - no changes were made)" }

# 输出日志（UTF-8 without BOM）
$outputPath = "$PSScriptRoot\..\..\cleanup-log.json"
$logJson = @{ summary = $summary; entries = $log } | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($outputPath, $logJson, [System.Text.UTF8Encoding]::new($false))
Write-Output "Cleanup log saved to: $outputPath"
