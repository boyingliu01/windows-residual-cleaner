# rollback.ps1
# 输出可用还原点和回滚指引（B-m4 增强版）；`-Auto` 消费回滚日志做逐项精准恢复（REQ-008）
param(
    [string]$CleanupLogPath = "$PSScriptRoot\..\..\cleanup-log.json",
    [string]$BackupRoot = "$PSScriptRoot\..\..",
    [switch]$Auto = $false,
    [string]$JournalPath = "",
    [switch]$AcknowledgeConflicts = $false
)

$script:DefaultCleanupLogPath = $CleanupLogPath
$script:DefaultBackupRoot = $BackupRoot

# ─────────────────────────────────────────────────────────────────────────────
# -Auto 的依赖（REQ-008 / REQ-024）：与 clean-residuals.ps1 同一套库、同一顺序。
# 这些库**没有**顶层 param()，dot-source 不会把同名默认值冲进本作用域（AGENTS.md 陷阱 8a）。
# ─────────────────────────────────────────────────────────────────────────────
$rollbackLibOrder = @('rollback-journal.ps1', 'rollback-backup.ps1', 'rollback-verdicts.ps1',
                      'rollback-recovery.ps1', 'rollback-exec.ps1')
$script:RollbackLibsMissing = @()
foreach ($libName in $rollbackLibOrder) {
    $libPath = Join-Path $PSScriptRoot $libName
    if (-not (Test-Path -LiteralPath $libPath)) {
        $script:RollbackLibsMissing += $libName
        continue
    }
    . $libPath
}

function Test-RollbackAdminPrivilege {
    <#
    .SYNOPSIS
        当前进程是否具备管理员权限（-Auto 的硬前置）。
    #>
    param()

    try {
        $me = [Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent())
        return $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-AutoRollbackExitCode {
    <#
    .SYNOPSIS
        把 Invoke-RollbackJournalConsumption 的语义化 Outcome 映射为 -Auto 的退出码。
    .DESCRIPTION
        纯函数，单独可测：消费协议本身与 clean-residuals 的启动期 T3 共用一份实现，
        只有「这个结论对调用方意味着哪个码」是各自的。映射表集中在这里，
        新增 Outcome 时忘了加映射会落到 default 而不是静默返回 0。
    #>
    param([Parameter(Mandatory)][string]$Outcome)

    # 未知 Outcome → 14（交回人工），不是 0：宁可让人看一眼，
    # 也不能因为「表没更新」就宣告自动恢复成功。
    $map = @{
        no_journal                   = 12
        input_error                  = 1
        unreadable                   = 12
        ambiguous                    = 14
        needs_acknowledgement        = 14
        rejected                     = 14
        consumed_with_skipped        = 14
        partial_restore              = 11
        persistence_failed           = 15
        already_completed            = 0
        suppressed                   = 0
        acknowledged_without_restore = 0
        consumed                     = 0
        dry_run_reported             = 0
    }
    if ($map.ContainsKey($Outcome)) { return $map[$Outcome] }
    return 14
}

function Invoke-AutoRollback {
    <#
    .SYNOPSIS
        -Auto 入口：libs/权限前置 → 交给共享消费协议 → 打印报告 → 映射退出码。
    .DESCRIPTION
        这里**没有**恢复逻辑，只有包装。真正的 Step 1..5 在
        Invoke-RollbackJournalConsumption（rollback-exec.ps1），与启动期 T3 同一份实现。
        退出码沿用 REQ-026 矩阵的语义，调用方（含 UI）不必另学一套：
          0  已恢复／已按判定正确处理（含「日志已完成，零变更」）；
          1  输入错误（-JournalPath 指向的文件不存在）；
          2  权限不足（-Auto 写注册表与 Machine PATH，必须管理员）；
          3  回滚组件缺失；
          11 恢复未完全成功 —— 日志**保持未完成**、未修复清单已落盘，下次启动仍可重试 T3；
          12 没有可消费的记录（无未完成日志，或指定的日志不可解析）；
          14 日志不可安全消费（自证失败、歧义，或需人工确认但未给 -AcknowledgeConflicts）；
          15 本轮持久化记录写失败（终端码，优先级高于 11/14）。
        **绝不调用 Restore-Computer**（AC-007 / REQ-010）：还原点只作为人工选项列出。
        $Now / $MachinePathOverride / $SetPathScript 透传给消费协议，是测试注入点。
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$JournalPath = "",
        [bool]$AcknowledgeConflicts = $false,
        [AllowNull()]$Now = $null,
        [AllowNull()][string]$MachinePathOverride,
        [AllowNull()][scriptblock]$SetPathScript
    )

    if (@($script:RollbackLibsMissing).Count -gt 0) {
        return @{ ExitCode = 3; Summary = ("rollback_components_missing({0})" -f ($script:RollbackLibsMissing -join ',')) }
    }
    if (-not (Test-RollbackAdminPrivilege)) {
        return @{ ExitCode = 2; Summary = 'administrator_required' }
    }

    # 不用 `$args`：那是 PowerShell 自动变量，在此赋值会遮蔽未命名参数集合（AGENTS.md 陷阱 2）。
    $consumeArgs = @{
        ProjectRoot          = $ProjectRoot
        JournalPath          = $JournalPath
        AcknowledgeConflicts = [bool]$AcknowledgeConflicts
    }
    if ($null -ne $Now) { $consumeArgs['Now'] = $Now }
    # 只在**调用方真的给了**这个注入点时才转发：`[string]` 参数未传时是空串而不是 null，
    # 用 `$null -ne` 判断会把「未注入」伪装成「注入了空 PATH」，
    # 让消费协议跳过真实注册表读取（AGENTS.md 陷阱 11）。
    if ($PSBoundParameters.ContainsKey('MachinePathOverride')) { $consumeArgs['MachinePathOverride'] = $MachinePathOverride }
    if ($null -ne $SetPathScript) { $consumeArgs['SetPathScript'] = $SetPathScript }
    $o = Invoke-RollbackJournalConsumption @consumeArgs

    # 报告由协议侧统一构造（含候选清单与逐项判定），此处只负责落屏。
    # Format-RollbackReport 用 `return , $lines` 保住空数组语义，故 $o.Report 已是扁平数组。
    foreach ($line in @($o.Report)) { Write-Output $line }

    $code = Get-AutoRollbackExitCode -Outcome ([string]$o.Outcome)
    if ($code -eq 0) {
        Write-Output "Restore point (manual option only, this tool never calls Restore-Computer): sysdm.cpl -> System Protection -> System Restore"
    }
    return @{ ExitCode = $code; Summary = [string]$o.Summary; Outcome = [string]$o.Outcome; Result = $o.Result }
}

function Get-BackupDirectory {

    <#
    .SYNOPSIS
        列出备份目录，最新的在前（按名称降序）。
    .DESCRIPTION
        backup-* 是运行时目录（gitignored）。抽成函数以便用 fixture 单测，
        且让 BackupRoot 可注入 —— 否则测试只能依赖仓里遗留的 backup-*。
    #>
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path $Root)) { return @() }
    return @(
        Get-ChildItem -Path $Root -Filter 'backup-*' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
    )
}

function Get-RegistryBackupFile {
    <#
    .SYNOPSIS
        列出某备份目录下的 reg-*.reg 文件。
    #>
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-Path $Directory)) { return @() }
    return @(Get-ChildItem -Path $Directory -Filter 'reg-*.reg' -ErrorAction SilentlyContinue)
}

function Get-MatchingRestorePoint {
    <#
    .SYNOPSIS
        找出清理时间前后 ±5 分钟内的还原点。
    #>
    param(
        [AllowEmptyCollection()][object[]]$RestorePoints = @(),
        [Parameter(Mandatory)][datetime]$MatchTime,
        [int]$WindowMinutes = 5
    )

    if (-not $RestorePoints) { return @() }
    return @(
        $RestorePoints | Where-Object {
            $_.CreationTime -ge $MatchTime.AddMinutes(-$WindowMinutes) -and
            $_.CreationTime -le $MatchTime.AddMinutes($WindowMinutes)
        }
    )
}

function Main {
    # ADR-001: 用 [ref] 回传退出码；不得 exit（会杀死测试宿主）
    param(
        [ref]$ExitCode,
        [string]$CleanupLogPathOverride,
        [string]$BackupRootOverride
    )
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    if (-not [string]::IsNullOrWhiteSpace($CleanupLogPathOverride)) {
        $CleanupLogPath = $CleanupLogPathOverride
    } elseif ([string]::IsNullOrWhiteSpace($CleanupLogPath)) {
        $CleanupLogPath = $script:DefaultCleanupLogPath
    }
    if (-not [string]::IsNullOrWhiteSpace($BackupRootOverride)) {
        $BackupRoot = $BackupRootOverride
    } elseif ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = $script:DefaultBackupRoot
    }

    # ── -Auto：消费回滚日志、逐项精准恢复（REQ-008）。不带 -Auto 时下面这段一行都不执行，
    #    今天的只读指引输出保持逐字不变（AC-012 的回归要求）。──
    if ($Auto) {
        $autoResult = Invoke-AutoRollback -ProjectRoot $BackupRoot `
            -JournalPath $JournalPath `
            -AcknowledgeConflicts ([bool]$AcknowledgeConflicts)
        Write-Output ("Auto rollback: {0}" -f [string]$autoResult.Summary)
        & $setRc ([int]$autoResult.ExitCode)
        return
    }

    # Admin privilege check (warning only for read-only operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning "Running without admin. Restore points may not be enumerable."
    }

    Write-Output "===== ROLLBACK INSTRUCTIONS ====="
    Write-Output ""

    # 读取清理日志获取时间
    $cleanupTime = $null
    if (Test-Path $CleanupLogPath) {
        try {
            $log = Get-Content $CleanupLogPath -Raw | ConvertFrom-Json
            $cleanupTime = $log.summary.timestamp
            Write-Output "Last cleanup: $cleanupTime"
        } catch { Write-Verbose "Rollback operation skipped: $_" }
    }

    Write-Output ""
    Write-Output "Available Restore Points (most recent 10):"
    $restorePoints = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Select-Object -Last 10
    $restorePoints | Format-Table SequenceNumber, Description, CreationTime -AutoSize

    # 尝试匹配清理时间附近的还原点
    if ($cleanupTime) {
        Write-Output ""
        Write-Output "--- Matching restore points near cleanup time ---"
        try {
            $matchTime = [DateTime]::Parse($cleanupTime)
            # 必须 @(...) 包住返回值：函数只匹配到 1 个还原点时，PowerShell 会把
            # 单元素数组**解包**成标量，`$matched.Count` 于是为 $null，打印出
            # 「Found  restore point(s)」这种缺数字的句子（AGENTS.md 陷阱第 3 条的同一族问题）。
            $matched = @(Get-MatchingRestorePoint -RestorePoints @($restorePoints) -MatchTime $matchTime)
            if ($matched.Count -gt 0) {
                Write-Output "Found $($matched.Count) restore point(s) created near cleanup time:"
                foreach ($m in $matched) {
                    Write-Output "  #$($m.SequenceNumber): $($m.Description) - $($m.CreationTime)"
                }
            } else {
                Write-Output "No restore points found near cleanup time."
            }
        } catch {
            Write-Verbose "Cannot parse cleanup timestamp '$cleanupTime': $_"
            Write-Output "No restore points found near cleanup time."
        }
    }

    Write-Output ""
    Write-Output "To rollback:"
    Write-Output "1. Open System Properties (Win+R → sysdm.cpl → System Protection → System Restore)"
    Write-Output "2. Select the 'Pre-cleanup' restore point"
    Write-Output "3. Follow the wizard (system will reboot)"
    Write-Output ""
    Write-Output "Alternatively, via PowerShell (requires reboot):"
    Write-Output '  Restore-Computer -RestorePoint [SequenceNumber from above]'

    # List registry backup files from most recent backup directory
    Write-Output ""
    Write-Output "=== Registry Backup Files ==="
    $backupDirs = @(Get-BackupDirectory -Root $BackupRoot)
    if ($backupDirs.Count -gt 0) {
        $latestDir = $backupDirs[0]
        Write-Output "Most recent backup: $($latestDir.Name)"
        $regFiles = @(Get-RegistryBackupFile -Directory $latestDir.FullName)
        if ($regFiles.Count -gt 0) {
            foreach ($f in $regFiles) {
                Write-Output "  $($f.Name) ($([math]::Round($f.Length / 1KB, 1)) KB)"
            }
        } else {
            Write-Output "  No registry backup files found."
        }

        # Show restore status if available
        $statusFile = Join-Path $latestDir.FullName "restore-status.json"
        if (Test-Path $statusFile) {
            try {
                $status = Get-Content $statusFile -Raw | ConvertFrom-Json
                Write-Output ""
                Write-Output "Restore point: $($status.restore_point_description)"
            } catch {
                Write-Verbose "Cannot parse restore-status.json: $_"
            }
        }
    } else {
        Write-Output "  No backup directories found."
    }

    Write-Output ""
    Write-Output "Automatic per-item rollback is available: run this script with -Auto"
    Write-Output "  powershell.exe -File rollback.ps1 -Auto          # consumes the newest unfinished rollback journal"
    Write-Output "  powershell.exe -File rollback.ps1 -Auto -JournalPath <path>   # a journal you name explicitly"
    Write-Output "It restores only what this tool deleted and confirmed, and never calls Restore-Computer."
    Write-Output "Recovery window is fixed at 24 hours after the run; beyond that items are reported for manual recovery."
    Write-Output "You can also manually merge .reg files if you only need to restore specific keys."

    & $setRc 0
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
