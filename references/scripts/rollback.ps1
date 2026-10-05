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

function Get-AutoRollbackTarget {
    <#
    .SYNOPSIS
        定位 -Auto 要消费的那一份日志：显式 -JournalPath 优先，否则按 REQ-019
        Step 1 → 选择唯一候选。返回 @{ Ok; BackupDir; Journal; RequiresAcknowledgement; Reason }。
    .DESCRIPTION
        多候选并列/歧义时**不**在这里决定，只把候选清单如实交给调用方打印——
        自动挑一份恢复等于在证据不足时改动系统（REQ-030：出错必须由人拍板）。
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$JournalPath
    )

    if (-not [string]::IsNullOrWhiteSpace($JournalPath)) {
        if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) {
            return @{ Ok = $false; Reason = 'journal_path_not_found'; Journal = $null }
        }
        $j = Read-JsonFileSafe -Path $JournalPath
        if ($null -eq $j) {
            return @{ Ok = $false; Reason = 'journal_unreadable'; Journal = $null }
        }
        return @{
            Ok = $true
            # PS 5.1 下 `Split-Path -LiteralPath X -Parent` 会抛「Parameter set cannot be
            # resolved」（-Parent 只属于 -Path 集）；纯文件系统路径直接用 .NET 解析，
            # 顺带避开通配符（方括号目录名会被 -Path 当模式）。
            BackupDir = [System.IO.Path]::GetDirectoryName($JournalPath)
            Journal = $j
            RequiresAcknowledgement = $false
            Reason = 'explicit_path'
            Candidates = @()
            Ambiguous = $false
        }
    }

    # 必须用普通赋值：Get-RecoveryCandidateSet 以 `return , $out` 保住空数组语义，
    # 再套 @() 会得到「一个元素是数组」的两层嵌套（AGENTS.md 陷阱 6 的同族）。
    $cands = Get-RecoveryCandidateSet -ProjectRoot $ProjectRoot
    $sel = Select-RecoveryCandidate -Candidates $cands
    if ($null -eq $sel.Selected) {
        return @{
            Ok = $false
            Reason = [string]$sel.Reason
            Journal = $null
            Candidates = @($sel.Others)
            Ambiguous = [bool]$sel.Ambiguous
        }
    }
    $c = $sel.Selected
    return @{
        Ok = $true
        BackupDir = [string]$c.BackupDir
        Journal = $c.Journal
        RequiresAcknowledgement = [bool]$c.RequiresAcknowledgement
        Reason = 'candidate'
        Candidates = @($sel.Others)
        Ambiguous = $false
    }
}

function Write-AutoRollbackCandidateList {
    <#
    .SYNOPSIS
        打印候选日志清单（run_id / created_at / 目录），供人工核对后点名消费。
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Candidates)

    Write-Output "--- Unfinished rollback journals found ---"
    foreach ($c in $Candidates) {
        $j = $c.Journal
        Write-Output ("  {0}  run_id={1}  created_at={2}" -f `
            [string]$c.BackupDir, [string]$j['run_id'], [string]$j['created_at'])
    }
}

function Invoke-AutoRollback {
    <#
    .SYNOPSIS
        -Auto 执行端：定位日志 → 消费判定 → 逐项精准恢复 → 人读报告 + 结构化退出码。
    .DESCRIPTION
        退出码沿用 REQ-026 矩阵的语义，调用方（含 UI）不必另学一套：
          0  已恢复／已按判定正确处理（含「日志已完成，零变更」）；
          1  输入错误（-JournalPath 指向的文件不存在）；
          2  权限不足（-Auto 写注册表与 Machine PATH，必须管理员）；
          3  回滚组件缺失；
          11 恢复未完全成功 —— 日志**保持未完成**、未修复清单已落盘，下次启动仍可重试 T3；
          12 没有可消费的记录（无未完成日志，或指定的日志不可解析）；
          14 日志不可安全消费（自证失败，或需人工确认但未给 -AcknowledgeConflicts）。
        **绝不调用 Restore-Computer**（AC-007 / REQ-010）：还原点只作为人工选项列出。
        $Now / $MachinePathOverride / $SetPathScript 透传给 Invoke-RollbackRestore，是测试注入点。
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

    $target = Get-AutoRollbackTarget -ProjectRoot $ProjectRoot -JournalPath $JournalPath
    if (-not $target.Ok) {
        if ([bool]$target.Ambiguous) {
            Write-AutoRollbackCandidateList -Candidates $target.Candidates
            if ($AcknowledgeConflicts) {
                # REQ-030 的确认出口：人拍板后由**工具**代写机械标记，逐份点名，绝不静默选边。
                # 可解析（run_id 是合法 guid）的候选：completed_at + consumed_with_failure 标记；
                # run_id 不合法的就**写不出绑定标记**（Write-RecoveryMarker 会抛），必须如实
                # 报告「未能确认」，不能假装确认过了——非法标记会被 Test-MarkerWellFormed 判废，
                # 反而让候选永久留在集合里。
                $marked = 0
                $unmarkable = @()
                foreach ($c in $target.Candidates) {
                    $rid = [string]$c.Journal['run_id']
                    $g = [guid]::Empty
                    if (-not [guid]::TryParse($rid, [ref]$g)) {
                        $unmarkable += [string]$c.BackupDir
                        continue
                    }
                    try {
                        # 「标记 consumed_with_failure」是日志字段（REQ-019 Step 4a），
                        # 与 completed_at 一起写：人确认后这份日志既不再被 T3 消费，
                        # 也如实记着「确认过但没有真正恢复」。
                        $c.Journal['consumed_with_failure'] = $true
                        $null = Complete-RollbackJournal -BackupDir ([string]$c.BackupDir) -Journal $c.Journal
                        $null = Write-RecoveryMarker -BackupDir ([string]$c.BackupDir) -Kind 'consumed.failed' -RunId $rid
                        $marked++
                    } catch {
                        return @{ ExitCode = 15; Summary = 'acknowledgement_marker_write_failed' }
                    }
                }
                foreach ($u in $unmarkable) {
                    Write-Warning "  无法确认（run_id 不合法，写不出绑定标记）：$u"
                }
                return @{ ExitCode = 0; Summary = ("acknowledged_without_restore({0})" -f $marked) }
            }
            return @{ ExitCode = 14; Summary = 'ambiguous_candidates' }
        }
        $code = 12
        if ([string]$target.Reason -eq 'journal_path_not_found') { $code = 1 }
        return @{ ExitCode = $code; Summary = [string]$target.Reason }
    }

    $journal = $target.Journal
    $backupDir = [string]$target.BackupDir

    $decision = Get-RollbackConsumptionDecision -Journal $journal `
        -RequiresAcknowledgement ([bool]$target.RequiresAcknowledgement) `
        -AcknowledgeConflicts:$AcknowledgeConflicts

    # 用 if/elseif 而不是 switch：switch 块里的 `return` 语义在 PS 5.1 宿主下不够直白，
    # 而这里每个分支都必须立刻返回各自的退出码。
    if ($decision.Action -eq 'already_completed') {
        Write-Output "Rollback journal already completed (run_id=$($journal['run_id'])). No target touched, nothing restored."
        return @{ ExitCode = 0; Summary = 'journal_already_completed' }
    }
    if ($decision.Action -eq 'suppress') {
        Write-Output "Rollback suppressed: cleanup had actually finished (run_id=$($journal['run_id'])). Nothing restored."
        if ($decision.EvidenceMissing) {
            Write-Warning "  抑制依据缺失（清理日志不可读），仅按 completed_at 判定处理。"
        }
        try {
            if ([string]$decision.Reason -eq 'acknowledged_without_restore') {
                # 人确认过 = 「承认它结束了、不要再自动恢复」，如实记 consumed_with_failure，
                # 与歧义候选的确认路径同一语义。
                $journal['consumed_with_failure'] = $true
            }
            $null = Complete-RollbackJournal -BackupDir $backupDir -Journal $journal
        } catch {
            return @{ ExitCode = 15; Summary = 'completion_marker_write_failed' }
        }
        return @{ ExitCode = 0; Summary = ("suppressed({0})" -f [string]$decision.Reason) }
    }
    if ($decision.Action -eq 'reject') {
        Write-Output ("Rollback journal cannot be consumed safely (run_id={0}): {1}" -f `
            [string]$journal['run_id'], [string]$decision.Reason)
        foreach ($r in @($decision.Reasons)) { Write-Output "  - $r" }
        return @{ ExitCode = 14; Summary = [string]$decision.Reason }
    }
    if ($decision.Action -eq 'needs_acknowledgement') {
        Write-Output ("Rollback needs explicit human acknowledgement (run_id={0}): {1}" -f `
            [string]$journal['run_id'], [string]$decision.Reason)
        Write-Output "Re-run with -AcknowledgeConflicts to confirm this journal, or point at it with -JournalPath."
        return @{ ExitCode = 14; Summary = [string]$decision.Reason }
    }

    # ── restore ──
    # 不用 `$args`：那是 PowerShell 自动变量，在此赋值会遮蔽未命名参数集合（同类坑见 AGENTS.md 陷阱 2）。
    $restoreArgs = @{
        Journal                = $journal
        BackupDir              = $backupDir
        ProjectRoot            = $ProjectRoot
        AcknowledgeConflicts   = [bool]$AcknowledgeConflicts
    }
    if ($null -ne $Now) { $restoreArgs['Now'] = $Now }
    if ($null -ne $MachinePathOverride) { $restoreArgs['MachinePathOverride'] = $MachinePathOverride }
    if ($null -ne $SetPathScript) { $restoreArgs['SetPathScript'] = $SetPathScript }
    $res = Invoke-RollbackRestore @restoreArgs

    # Format-RollbackReport 用 `return , $lines` 保住空数组语义，调用方不得再套 @()。
    foreach ($line in $res.Report) { Write-Output $line }

    if ($res.PersistenceError) {
        return @{ ExitCode = 15; Summary = 'persistence_record_write_failed'; Result = $res }
    }

    $failedCount = 0
    if ($null -ne $res.Counts -and $null -ne $res.Counts['restore_failed']) {
        $failedCount = [int]$res.Counts['restore_failed']
    }

    if ($failedCount -gt 0) {
        # REQ-031 / AC-077：系统仍有未修复项，日志必须**保持未完成**，让下次启动继续 T3。
        Write-Output ("Restore incomplete: {0} item(s) failed. Journal left unfinished; unrepaired list: {1}" -f `
            $failedCount, [string]$res.UnrepairedPath)
        return @{ ExitCode = 11; Summary = 'restore_incomplete'; Result = $res }
    }

    try {
        $null = Complete-RollbackJournal -BackupDir $backupDir -Journal $journal
        $null = Write-RecoveryMarker -BackupDir $backupDir -Kind 'consumed' -RunId ([string]$journal['run_id'])
    } catch {
        # 消费标记写失败：日志仍是未完成状态，下次启动会重试 —— 但「重试」不等于「已消费」，
        # 只有两个标记都写失败才必须如实上报（REQ-019 Step 4a / 15(iii)）。
        try {
            $null = Write-RecoveryMarker -BackupDir $backupDir -Kind 'consumed.failed' -RunId ([string]$journal['run_id'])
        } catch {
            return @{ ExitCode = 15; Summary = 'consumption_marker_write_failed'; Result = $res }
        }
    }

    Write-Output ("Rollback result written: {0}" -f [string]$res.ResultPath)
    Write-Output "Restore point (manual option only, this tool never calls Restore-Computer): sysdm.cpl -> System Protection -> System Restore"
    return @{ ExitCode = 0; Summary = 'restored'; Result = $res }
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
