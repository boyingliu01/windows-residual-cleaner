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

# 可靠地调用 sc.exe，替代裸 `sc.exe ... 2>$null` 写法。
#
# 背景（PS 5.1 陷阱 #7）: `powershell.exe` 宿主在同时满足「stdout 未重定向」与
# 「stderr 被重定向」时，会抛出
#   StandardOutputEncoding/StandardErrorEncoding is only supported when ... redirected
# 因此 `sc.exe stop X 2>$null` 与 `sc.exe delete X 2>&1` 在本项目基线上**必然抛异常**：
#   - Phase 1 的 stop 永远失败 → 幽灵服务根本不会被停止
#   - Phase 2 的 delete 异常被 catch → 记为 cleanup_failed，且 $LASTEXITCODE 为空
# 干净的 sc.exe 输出不带引号，无法用 `cmd /c "... 2>&1"` 包裹（会在引号处截断参数），
# 故改用 Start-Process 显式重定向两个流：任何流重定向都能规避该 bug。
#
# 注意: Start-Process -Wait 对带 UI 的进程会提前返回，sc.exe 是控制台程序，
# 退出时其子进程已全部结束，因此不需要额外的 Handle 排空逻辑。
function Invoke-ScExe {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    $scPath = Join-Path $env:SystemRoot 'System32\sc.exe'
    if (-not (Test-Path $scPath)) {
        return @{ ok = $false; output = ''; exit_code = $null; error = "sc.exe not found at $scPath" }
    }

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $scPath `
            -ArgumentList $Arguments `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -ErrorAction Stop

        # 文件总是存在（GetTempFileName 已创建），读取仅用于获取进程输出。
        # 用 -ErrorAction SilentlyContinue 而非空 catch 块（PSAvoidUsingEmptyCatchBlock）。
        $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }

        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) {
            return @{ ok = $false; output = $stdout.Trim(); exit_code = $null; error = "sc.exe returned no exit code (timeout ${TimeoutSeconds}s?)" }
        }

        return @{
            ok        = ($exitCode -eq 0)
            output    = $stdout.Trim()
            exit_code = $exitCode
            error     = if ($exitCode -eq 0) { '' } else { (($stdout + "`n" + $stderr).Trim()) }
        }
    } catch {
        # Start-Process 自身失败（如权限不足 / sc.exe 被安全软件拦截）：
        # exit_code 保持 $null 以区别于"sc.exe 正常运行并返回了退出码"，
        # 调用方必须把 $null 视为失败，不能当成 1060（服务不存在）而静默放过。
        return @{ ok = $false; output = ''; exit_code = $null; error = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

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

# Admin privilege check (mandatory for write operations)
function Test-AdminPrivilege {
    [CmdletBinding()]
    param([switch]$Mandatory)
    $isAdmin = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if ($Mandatory) {
            Write-Error "Administrator privileges required. Please run PowerShell as Administrator."
            # 注意：这里**不能** exit。exit 在 Pester 进程内会终止宿主，
            # 导致整份测试套件静默塌掉（见 docs/decisions/ADR-001）。
            # 由调用方检查返回值并决定退出码。
            return $false
        } else {
            Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
        }
    }
    return $isAdmin
}

function Main {
    # ADR-001: Main 通过 [ref] 回传退出码，绝不调用 exit，也绝不 `return <code>`。
    #
    # 为什么不用 `return 1` / `exit (Main)`：
    #   1. `return 1` 会把整数写进**输出流**（PowerShell 函数返回语义），污染调用方
    #      stdout —— 现有测试用 `(Main 2>&1) -join` 断言输出文本，会被数字污染。
    #   2. `exit (Main)` 会让 PowerShell 先求值 `Main`，其输出被吞进 exit 的参数
    #      表达式，宿主随即退出，**此前的 Write-Output 全部丢失**（实测确认）。
    #   3. `exit` 在 dot-source + 进程内调用（测试 / 覆盖率插桩）时会杀死宿主，
    #      使 Pester 收尾崩溃、整份套件静默消失（本 sprint 的 blocker B1）。
    #
    #   `[ref]` 方案：stdout 保持纯净，退出码单独回传，进程内调用完全安全。
    #   注意 AGENTS.md 陷阱 #1（[ref]+[CmdletBinding] 失效）不适用于此：Main 无该注解。
    param([ref]$ExitCode)

    # 设置退出码的便捷脚本块（未传 [ref] 时静默忽略，便于旧调用方兼容）
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    if (-not (Test-AdminPrivilege -Mandatory)) {
        & $setRc 2
        return
    }

    # B-M7 修复：清理前检查还原点是否已创建。
    # 仅在"将真正删除"时强制：非 DryRun 且 (走 ConfirmFile 或 Mode A/B/C)。
    # 注意 UI(/api/cleanup) 通过 ConfirmFile 触发、Mode 保持默认 'D'，旧条件 ($Mode -ne 'D')
    # 会让 UI 的真实删除绕过备份门——故改用"意图删除"判定，堵住该缺口。
    $willDelete = (-not $DryRun) -and ($ConfirmFile -ne '' -or $Mode -ne 'D')
    if ($willDelete) {
        $restoreFiles = Get-ChildItem -Path "$PSScriptRoot\..\..\backup-*" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if (-not $restoreFiles) {
            Write-Error "No restore point or backup found. Please run create-restore-point.ps1 first."
            Write-Output "Run: powershell -ExecutionPolicy Bypass -File '$PSScriptRoot\create-restore-point.ps1'"
            & $setRc 1
            return
        }
        Write-Output "Restore backup found: $($restoreFiles[0].Name)"
    }

    # --- 加载白名单（Defense-in-Depth: 清理前二次校验） ---
    $script:whitelist = $null
    if (Test-Path $WhitelistPath) {
        try {
            $script:whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json
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
        & $setRc 1
         return
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
        # ConfirmFile 模式：ConfirmFile 是唯一删除依据（用户已通过 confirm-cleanup.ps1 确认）。
        # 安全关键（fail-closed）：文件缺失 / 无法解析 / 内容为空时必须立即中止。
        # 否则 cleanupItems 会回退到"全部非 danger"集合，导致越界删除所有残留
        # （历史 Critical 缺陷：调用方传入错误的相对路径 → Test-Path 失败 → 静默全清）。
        if (-not (Test-Path $ConfirmFile)) {
            Write-Error "ConfirmFile not found: '$ConfirmFile'. Aborting to prevent over-deletion. Pass an absolute path."
            & $setRc 1
             return
        }
        try {
            $confirmedIds = Get-Content $ConfirmFile -Raw | ConvertFrom-Json
        } catch {
            Write-Error "Failed to parse ConfirmFile '$ConfirmFile': $_. Aborting."
            & $setRc 1
             return
        }
        if (-not $confirmedIds) {
            Write-Error "ConfirmFile '$ConfirmFile' contains no confirmed IDs. Aborting (nothing to clean)."
            & $setRc 1
             return
        }
        # 以确认 ID 为权威集合，并保留 danger 双层拦截作为纵深防御
        $cleanupItems = @($allItems | Where-Object { $confirmedIds -contains $_.id -and $_.risk -ne 'danger' })
        Write-Output "Loaded $(@($confirmedIds).Count) confirmed IDs from $ConfirmFile, matched $($cleanupItems.Count) items"
    } else {
        switch ($Mode) {
            'A' { $cleanupItems = @($allItems | Where-Object { $_.risk -eq 'safe' }) }
            'B' { $cleanupItems = @($allItems | Where-Object { $_.risk -eq 'safe' }) }
            'C' { $cleanupItems = @($allItems | Where-Object { $_.risk -ne 'danger' }) }
            'D' { Write-Output "Report-only mode. No cleanup performed."; & $setRc 0; return }
        }
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

    # --- Three-phase batch processing ---
    $log = [System.Collections.Generic.List[Hashtable]]::new()
    $prefix = if ($DryRun) { "[DRY-RUN] " } else { "" }

    # Pre-filter: whitelist + danger (applies to all phases)
    # 业务日志用 Write-Output（非 Warning）：Pester 拦截 warning 流导致 2>&1 无法捕获，
    # 且这些消息是正常流程状态而非告警
    $eligibleItems = @()
    foreach ($item in $cleanupItems) {
        if (Test-Whitelisted -Path $item.path -Key $item.key -ServiceName $item.name) {
            Write-Output "$prefix SKIP (whitelisted): $($item.id)"
            $log.Add(@{ id=$item.id; action='skipped_whitelisted'; success=$false })
            continue
        }
        if ($item.risk -eq 'danger') {
            Write-Output "$prefix SKIP (danger): $($item.id) - $($item.reason)"
            $log.Add(@{ id=$item.id; action='skipped_danger'; success=$false })
            continue
        }
        $eligibleItems += $item
    }

    # Phase 1: Stop all services (stop only, no delete)
    Write-Output "$prefix Phase 1: Stopping services..."
    foreach ($item in $eligibleItems) {
        if ($item.name -and $item.binary_path) {
            Write-Output "$prefix   Stopping service: $($item.name)"
            if (-not $DryRun) {
                try {
                    # 经 Invoke-ScExe 调用（不能写裸 `sc.exe stop X 2>$null`：PS 5.1 下必然抛异常）
                    $stopResult = Invoke-ScExe -Arguments @('stop', $item.name)
                    if (-not $stopResult.ok -and $stopResult.exit_code -ne 1060) {
                        # 1060 = ERROR_SERVICE_DOES_NOT_EXIST：服务已不存在，无需停止
                        Write-Warning "  → sc.exe stop $($item.name) failed (exit $($stopResult.exit_code)): $($stopResult.error)"
                    }
                    $waited = 0
                    do {
                        Start-Sleep -Milliseconds 1000
                        $waited++
                        $svcState = (Get-CimInstance Win32_Service -Filter "Name='$($item.name)'" -ErrorAction SilentlyContinue).State
                    } while ($svcState -eq 'Running' -and $waited -lt 10)
                    if ($svcState -eq 'Running') {
                        Write-Warning "  → Service $($item.name) did not stop in time"
                    }
                } catch {
                    Write-Warning "  → Failed to stop service $($item.name): $($_.Exception.Message)"
                }
            }
        }
    }

    # Phase 2: Delete files/directories + delete services
    Write-Output "$prefix Phase 2: Deleting files and services..."
    foreach ($item in $eligibleItems) {
        try {
            # Clean files/dirs
            # path_entry 的 .path 是"指向不存在目录的 PATH 片段"，其清理方式是移除 PATH 条目
            # （见下方 path_entry 分支），绝不能当作文件系统目录去删除，否则会误删同名真实目录并产生虚假日志。
            if ($item.path -and $item.type -ne 'path_entry') {
                Write-Output "$prefix   Deleting path: $($item.path)"
                if (-not $DryRun) {
                    if (Test-Path $item.path) {
                        $deleted = Remove-ItemRobust -Path $item.path
                        if (-not $deleted) {
                            throw "Failed to delete path after all fallback strategies"
                        }
                    } else {
                        Write-Output "  → Path does not exist (already removed), skipping"
                    }
                }
                $log.Add(@{ id=$item.id; action='path_deleted'; path=$item.path; success=$true })
            }

            # Delete services (after files, so binaries are released)
            if ($item.name -and $item.binary_path) {
                Write-Output "$prefix   Deleting service: $($item.name)"
                if (-not $DryRun) {
                    $delResult = Invoke-ScExe -Arguments @('delete', $item.name)
                    # 1060 = ERROR_SERVICE_DOES_NOT_EXIST：已被删除，视为幂等成功
                    if (-not $delResult.ok -and $delResult.exit_code -ne 1060) {
                        throw "sc.exe delete failed with exit code $($delResult.exit_code): $($delResult.error)"
                    }
                }
                $log.Add(@{ id=$item.id; action='service_deleted'; name=$item.name; success=$true })
            }

            # Delete ghost scheduled tasks（master 修复：ghost_task 分支）
            # ghost task 结构: { type='ghost_task'; name; execute; expanded_path; risk; reason; id }
            # 与 service 的区分：service 有 binary_path，task 有 expanded_path
            if ($item.name -and $item.expanded_path -and -not $item.binary_path) {
                Write-Output "$prefix   Deleting scheduled task: $($item.name)"
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

            # Remove dead PATH entries（master 修复：path_entry 分支）
            # PATH 残留结构: { type='path_entry'; path=<dead dir>; risk; reason; id }
            # 从机器 PATH 环境变量中移除指向不存在目录的条目
            if ($item.type -eq 'path_entry' -and $item.path) {
                Write-Output "$prefix   Removing dead PATH entry: $($item.path)"
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

    # Phase 3: Clean registry keys
    Write-Output "$prefix Phase 3: Cleaning registry..."
    foreach ($item in $eligibleItems) {
        try {
            if ($item.key) {
                if ($item.type -eq 'startup' -or $item.value_name) {
                    # 启动项残留：.key 是共享的 Run/RunOnce 父键，真正的残留只是其中一个 VALUE。
                    # 若按整键 reg delete 会连带删除机器上所有程序的自启动项（灾难性 collateral damage），
                    # 因此只能用 /v 精确删除该 value。
                    if (-not $item.value_name) {
                        throw "startup item missing value_name; refuse to delete shared Run key"
                    }
                    Write-Output "$prefix   Deleting startup value: $($item.key) /v $($item.value_name)"
                    if (-not $DryRun) {
                        cmd /c "reg query `"$($item.key)`" /v `"$($item.value_name)`" 2>&1" | Out-Null
                        if ($LASTEXITCODE -ne 0) {
                            Write-Output "  → Startup value not found (already removed), skipping"
                            $log.Add(@{ id=$item.id; action='registry_skip'; key=$item.key; value=$item.value_name; success=$true; note='value not found' })
                            continue
                        }
                        reg delete "$($item.key)" /v "$($item.value_name)" /f 2>&1
                        if ($LASTEXITCODE -ne 0) { throw "reg delete /v failed with exit code $LASTEXITCODE" }
                    }
                    $log.Add(@{ id=$item.id; action='startup_value_deleted'; key=$item.key; value=$item.value_name; success=$true })
                } else {
                    Write-Output "$prefix   Deleting registry key: $($item.key)"
                    if (-not $DryRun) {
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

    & $setRc 0
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
# ADR-001: Main 用 [ref] 回传退出码；Main 内**不得**有 exit，也不得 `return <code>`
# （前者会杀死测试宿主致套件静默塌掉，后者会把整数写进 stdout 污染输出）。
# 注意：不能用 `exit (Main)` —— 那会吞掉 Main 的全部 Write-Output（实测）。
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
