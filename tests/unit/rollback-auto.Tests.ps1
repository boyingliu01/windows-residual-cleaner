# tests/unit/rollback-auto.Tests.ps1
# rollback.ps1 -Auto（REQ-008）与 T3/-Auto 共用的消费判定。
# 断言必须在 PS 5.1 与 pwsh 7 下都成立；涉及副作用的分支一律断言**落盘结果**，
# 不断言「打印了某个字符串」（AGENTS.md 的测试设计教训）。
#
# 密闭性：全部日志写在自建的 wrc-auto-projroot 下，绝不依赖主仓遗留的 backup-*。

BeforeAll {
    $script:libRoot = Join-Path $PSScriptRoot '..\..\references\scripts'
    . (Join-Path $script:libRoot 'rollback-journal.ps1')
    . (Join-Path $script:libRoot 'rollback-backup.ps1')
    . (Join-Path $script:libRoot 'rollback-verdicts.ps1')
    . (Join-Path $script:libRoot 'rollback-recovery.ps1')
    . (Join-Path $script:libRoot 'rollback-exec.ps1')
    $script:AutoScript = Join-Path $script:libRoot 'rollback.ps1'
    . $script:AutoScript

    $script:proj = Join-Path $PSScriptRoot '..\..\wrc-auto-projroot'
    $script:fingerprint = [string](Get-MachineFingerprint).Value

    function script:New-AutoBackupDir {
        param([string]$Name)
        $dir = Join-Path $script:proj $Name
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }

    function script:New-AutoJournal {
        param([string]$Dir, [string]$CreatedAt, $CompletedAt = $null, [int]$Version = 1)
        $j = ConvertTo-RollbackJournal -BackupDir $Dir -MachineFingerprint $script:fingerprint `
            -FingerprintSource 'machine_guid'
        $j['journal_version'] = $Version
        if (-not [string]::IsNullOrWhiteSpace($CreatedAt)) { $j['created_at'] = $CreatedAt }
        $j['completed_at'] = $CompletedAt
        $path = Write-RollbackJournal -BackupDir $Dir -Journal $j
        return @{ Journal = $j; Path = $path; Dir = $Dir }
    }

    # 把一份「已落盘的清理日志」绑定进日志：三字段同非空（AC-083），哈希与 mtime 都取真实值。
    function script:Bind-AutoCleanupLog {
        param([hashtable]$Journal, [string]$Path, [int]$Failed)
        $json = @{ run_id = [string]$Journal['run_id']; summary = @{ failed = $Failed }; entries = @() } | ConvertTo-Json
        [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
        $Journal['cleanup_log_path'] = $Path
        $Journal['cleanup_log_timestamp'] = Format-IsoUtc -Value (Get-Item -LiteralPath $Path).LastWriteTimeUtc
        $Journal['cleanup_log_sha256'] = Get-Sha256Hex -Path $Path
        # 绑定后必须**重写日志文件**：Invoke-AutoRollback 读的是盘上那份，
        # 只改内存 hashtable 会让磁盘日志仍是「三字段同 null」，绑定行为根本没被测到。
        $null = Write-RollbackJournal -BackupDir ([string]$Journal['backup_dir']) -Journal $Journal
    }

    function script:Read-AutoJournalFile {
        param([string]$Dir)
        return Read-JsonFileSafe -Path (Join-Path $Dir 'rollback-journal.json')
    }

    # Pester 5 不允许在 root 写 BeforeEach（"Each test setup is not supported in root"），
    # 所以每个 Describe 各自调用这个复位函数。
    function script:Reset-AutoProject {
        if (Test-Path -LiteralPath $script:proj) { Remove-Item -LiteralPath $script:proj -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $script:proj -Force
    }

    function script:Mock-AutoRestoreSuccess {
        # 默认把恢复引擎换成「全部成功」的形状：需要失败/落盘异常的用例各自覆盖它。
        Mock Invoke-RollbackRestore {
            return @{
                Report           = @('mock report line')
                Counts           = @{ restored = 0; already_present = 0; not_restorable = 0; restore_failed = 0 }
                PersistenceError = $false
                ResultPath       = 'mock-rollback-result.json'
                UnrepairedPath   = ''
                Unrepaired       = @()
            }
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:proj) { Remove-Item -LiteralPath $script:proj -Recurse -Force }
}

Describe 'Get-RollbackConsumptionDecision（REQ-019 固定顺序 2.5 → 3 → 4）' {
    BeforeEach { Reset-AutoProject }

    It 'completed_at 已写好 → already_completed（AC-014 后半：第二次调用零变更）' {
        $dir = New-AutoBackupDir -Name 'backup-done'
        $now = Format-IsoUtc -Value (Get-Date).ToUniversalTime()
        $f = New-AutoJournal -Dir $dir -CreatedAt $now -CompletedAt $now
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint
        $d.Action | Should -Be 'already_completed'
        $d.Reason | Should -Be 'journal_completed'
    }

    It 'completed_at 损坏 → needs_acknowledgement；只有人给了 -AcknowledgeConflicts 才降级为 suppress' {
        $dir = New-AutoBackupDir -Name 'backup-malformed'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime()) `
            -CompletedAt 'not-a-timestamp'
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint
        $d.Action | Should -Be 'needs_acknowledgement'
        $d.Reason | Should -Be 'completed_at_malformed'

        $ack = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint `
            -AcknowledgeConflicts
        $ack.Action | Should -Be 'suppress'
    }

    It '崩溃在「清理日志已写、completed_at 之前」→ suppress，不重装刚删的内容（AC-076）' {
        $dir = New-AutoBackupDir -Name 'backup-suppress'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-0.json') -Failed 0
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint
        $d.Action | Should -Be 'suppress'
        $d.Reason | Should -Be 'unfinished_but_cleanup_succeeded'
        # 抑制 ≠ 消费：判定本身不写任何标记（REQ-019 Step 2.5）
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.json')) | Should -BeFalse
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -BeNullOrEmpty
    }

    It '清理日志 summary.failed > 0 → restore（真需要恢复）' {
        $dir = New-AutoBackupDir -Name 'backup-restore'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-1.json') -Failed 2
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint
        $d.Action | Should -Be 'restore'
    }

    It '自证失败 → reject，并带上可核对的原因（此时绝不消费）' {
        $dir = New-AutoBackupDir -Name 'backup-badversion'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime()) -Version 99
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint
        $d.Action | Should -Be 'reject'
        $d.Reason | Should -Be 'self_validation_failed'
        @($d.Reasons).Count | Should -BeGreaterThan 0
    }

    It '清理日志哈希被篡改 → reject（不得据伪造证据抑制恢复）' {
        $dir = New-AutoBackupDir -Name 'backup-tampered'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-2.json') -Failed 0
        $f.Journal['cleanup_log_sha256'] = ('0' * 64)
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint
        $d.Action | Should -Be 'reject'
    }

    It 'cleanup_log_* 模式非法（只有 path 非空）→ reject，绝不进入抑制分支' {
        $dir = New-AutoBackupDir -Name 'backup-pattern'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $f.Journal['cleanup_log_path'] = (Join-Path $script:proj 'nothing.json')
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint
        $d.Action | Should -Be 'reject'
    }

    It '候选闸门要求确认（曾消费失败 / 只能靠 .prev 读出）时，未确认 needs_acknowledgement、确认后只补标记不恢复' {
        $dir = New-AutoBackupDir -Name 'backup-needsack'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-3.json') -Failed 1
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint `
            -RequiresAcknowledgement $true
        $d.Action | Should -Be 'needs_acknowledgement'
        # 确认的语义是「承认结束、别再自动恢复」，不是「授权按坏证据恢复」→ suppress
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint `
            -RequiresAcknowledgement $true -AcknowledgeConflicts
        $d.Action | Should -Be 'suppress'
        $d.Reason | Should -Be 'acknowledged_without_restore'
    }

    It '确认判定排在自证之前：坏日志坏了也能被人解开，而不是永久 14 死锁' {
        $dir = New-AutoBackupDir -Name 'backup-needsack-bad'
        # journal_version 99 让自证必失败；若先自证，-AcknowledgeConflicts 也永远解不开。
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime()) -Version 99
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint `
            -RequiresAcknowledgement $true -AcknowledgeConflicts
        $d.Action | Should -Be 'suppress'
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint `
            -RequiresAcknowledgement $true
        $d.Action | Should -Be 'needs_acknowledgement'
    }

    It '清理日志已丢失（T3 典型形态）→ 不抑制、如实标 EvidenceMissing' {
        $dir = New-AutoBackupDir -Name 'backup-gonelog'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $logPath = Join-Path $script:proj 'cleanup-log-4.json'
        Bind-AutoCleanupLog -Journal $f.Journal -Path $logPath -Failed 1
        Remove-Item -LiteralPath $logPath -Force
        $d = Get-RollbackConsumptionDecision -Journal $f.Journal -MachineFingerprint $script:fingerprint
        # 自证对「日志已不存在」是容忍的（REQ-027），因此这里进恢复路径，但必须带证据缺失标记
        $d.Action | Should -Be 'restore'
        $d.EvidenceMissing | Should -BeTrue
    }
}

Describe 'Get-AutoRollbackTarget（日志定位）' {
    BeforeEach { Reset-AutoProject }

    It '显式 -JournalPath 指向不存在的文件 → journal_path_not_found（不是臆造候选）' {
        $r = Get-AutoRollbackTarget -ProjectRoot $script:proj -JournalPath (Join-Path $script:proj 'nope.json')
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'journal_path_not_found'
    }

    It '显式 -JournalPath 不可解析 → journal_unreadable' {
        $dir = New-AutoBackupDir -Name 'backup-corrupt'
        $jp = Join-Path $dir 'rollback-journal.json'
        [IO.File]::WriteAllText($jp, '{ this is not json')
        $r = Get-AutoRollbackTarget -ProjectRoot $script:proj -JournalPath $jp
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'journal_unreadable'
    }

    It '没有 -JournalPath 时只取未完成候选；已完成的目录不参与' {
        $done = New-AutoBackupDir -Name 'backup-aadone'
        $now = Format-IsoUtc -Value (Get-Date).ToUniversalTime()
        $null = New-AutoJournal -Dir $done -CreatedAt $now -CompletedAt $now
        $r = Get-AutoRollbackTarget -ProjectRoot $script:proj
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'no_candidate'
    }

    It '两份 created_at 相同的未完成日志 → 判为歧义并原样交回候选清单' {
        $same = (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        foreach ($n in @('backup-b1', 'backup-b2')) {
            $d = New-AutoBackupDir -Name $n
            $null = New-AutoJournal -Dir $d -CreatedAt $same
        }
        $r = Get-AutoRollbackTarget -ProjectRoot $script:proj
        $r.Ok | Should -BeFalse
        $r.Ambiguous | Should -BeTrue
        @($r.Candidates).Count | Should -Be 2
    }
}

Describe 'Invoke-AutoRollback（REQ-008 退出码与落盘副作用）' {
    BeforeEach {
        Reset-AutoProject
        # -Auto 会写注册表与 Machine PATH，测试里一律放行权限；单条用例可覆盖为 $false。
        Mock Test-RollbackAdminPrivilege { return $true }
        Mock-AutoRestoreSuccess
        # AC-007 的记录桩：把真 cmdlet 换成 Mock，-Auto 一旦调用它就会被计数。
        Mock Restore-Computer { return $null }
    }

    # Invoke-AutoRollback 会 Write-Output 人读报告，因此调用点必须从输出流里挑出
    # 那个 hashtable 结果；直接赋值拿到的是「字符串 + hashtable」的 Object[]，
    # $r.ExitCode 恒为 $null，用例就会假绿。
    It '权限不足 → 2，且不碰任何日志' {
        Mock Test-RollbackAdminPrivilege { return $false }
        $dir = New-AutoBackupDir -Name 'backup-perm'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 2
        $r.Summary | Should -Be 'administrator_required'
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -BeNullOrEmpty
    }

    It '回滚组件缺失 → 3（fail-closed，不假装恢复）' {
        $saved = $script:RollbackLibsMissing
        try {
            $script:RollbackLibsMissing = @('rollback-exec.ps1')
            $r = Invoke-AutoRollback -ProjectRoot $script:proj | Where-Object { $_ -is [hashtable] }
            $r.ExitCode | Should -Be 3
            $r.Summary | Should -Match 'rollback_components_missing'
        } finally {
            $script:RollbackLibsMissing = $saved
        }
    }

    It '-JournalPath 不存在 → 1；不可解析 → 12' {
        $missing = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath (Join-Path $script:proj 'none.json') |
            Where-Object { $_ -is [hashtable] }
        $missing.ExitCode | Should -Be 1
        $dir = New-AutoBackupDir -Name 'backup-unreadable'
        $jp = Join-Path $dir 'rollback-journal.json'
        [IO.File]::WriteAllText($jp, 'not json at all')
        $unreadable = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $jp |
            Where-Object { $_ -is [hashtable] }
        $unreadable.ExitCode | Should -Be 12
    }

    It '没有未完成日志 → 12，且从未调用恢复引擎' {
        $r = Invoke-AutoRollback -ProjectRoot $script:proj | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 12
        $r.Summary | Should -Be 'no_candidate'
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly
    }

    It '恢复全部成功 → 0，并落 completed_at + rollback-consumed.json' {
        $dir = New-AutoBackupDir -Name 'backup-ok'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-ok.json') -Failed 3
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Be 'restored'
        # 真实副作用：日志被标记完成、消费标记落盘（AC-014 靠这两件事阻止重复恢复）
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -Not -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.json')) | Should -BeTrue
    }

    It '恢复有失败项 → 11，日志**保持未完成**（AC-077：下次启动仍可 T3）' {
        Mock Invoke-RollbackRestore {
            return @{
                Report           = @('reg_002 restore_failed(conflict)')
                Counts           = @{ restored = 0; already_present = 0; not_restorable = 0; restore_failed = 1 }
                PersistenceError = $false
                ResultPath       = 'mock-rollback-result.json'
                UnrepairedPath   = 'mock-unrepaired.json'
                Unrepaired       = @()
            }
        }
        $dir = New-AutoBackupDir -Name 'backup-partial'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-partial.json') -Failed 1
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 11
        $r.Summary | Should -Be 'restore_incomplete'
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.json')) | Should -BeFalse
    }

    It '落盘失败 → 15（终端码，优先级高于 11）' {
        Mock Invoke-RollbackRestore {
            return @{
                Report = @(); Counts = @{ restore_failed = 2 }
                PersistenceError = $true; ResultPath = ''; UnrepairedPath = ''; Unrepaired = @()
            }
        }
        $dir = New-AutoBackupDir -Name 'backup-persist'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-persist.json') -Failed 1
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 15
    }

    It '已完成的日志 → 0、不调用恢复引擎、不改文件（AC-014 跨进程重复调用）' {
        $now = Format-IsoUtc -Value (Get-Date).ToUniversalTime()
        $dir = New-AutoBackupDir -Name 'backup-rerun'
        $f = New-AutoJournal -Dir $dir -CreatedAt $now -CompletedAt $now
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Be 'journal_already_completed'
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.json')) | Should -BeFalse
    }

    It '抑制路径 → 0、不恢复，但补写 completed_at（崩溃在标记之前）' {
        $dir = New-AutoBackupDir -Name 'backup-suppressed'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-sup.json') -Failed 0
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Match 'suppressed'
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -Not -BeNullOrEmpty
    }

    It '自证失败 → 14，不消费、不写标记' {
        $dir = New-AutoBackupDir -Name 'backup-reject'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime()) -Version 42
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 14
        $r.Summary | Should -Be 'self_validation_failed'
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.json')) | Should -BeFalse
    }

    It '上次消费未确认（consumed.failed 在盘上）→ 14，且绝不重复消费；确认后只补标记' {
        $dir = New-AutoBackupDir -Name 'backup-failedmarker'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-fm.json') -Failed 2
        # 上一轮「尝试消费但没确认成」留下的旁路文件（REQ-019 Step 1 的第二道闸门）
        $null = Write-RecoveryMarker -BackupDir $dir -Kind 'consumed.failed' -RunId ([string]$f.Journal['run_id'])

        $blocked = Invoke-AutoRollback -ProjectRoot $script:proj | Where-Object { $_ -is [hashtable] }
        $blocked.ExitCode | Should -Be 14
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly

        $ok = Invoke-AutoRollback -ProjectRoot $script:proj -AcknowledgeConflicts $true |
            Where-Object { $_ -is [hashtable] }
        $ok.ExitCode | Should -Be 0
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly
        $after = Read-AutoJournalFile -Dir $dir
        $after['completed_at'] | Should -Not -BeNullOrEmpty
        $after['consumed_with_failure'] | Should -BeTrue
    }

    It 'created_at 平局 → 14 且不动系统；加 -AcknowledgeConflicts 才逐份确认' {
        $same = (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $dirs = @()
        foreach ($n in @('backup-tie1', 'backup-tie2')) {
            $d = New-AutoBackupDir -Name $n
            $null = New-AutoJournal -Dir $d -CreatedAt $same
            $dirs += $d
        }
        $blocked = Invoke-AutoRollback -ProjectRoot $script:proj | Where-Object { $_ -is [hashtable] }
        $blocked.ExitCode | Should -Be 14
        $blocked.Summary | Should -Be 'ambiguous_candidates'
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly

        $ok = Invoke-AutoRollback -ProjectRoot $script:proj -AcknowledgeConflicts $true |
            Where-Object { $_ -is [hashtable] }
        $ok.ExitCode | Should -Be 0
        $ok.Summary | Should -Be 'acknowledged_without_restore(2)'
        foreach ($d in $dirs) {
            (Read-AutoJournalFile -Dir $d)['completed_at'] | Should -Not -BeNullOrEmpty
            (Read-AutoJournalFile -Dir $d)['consumed_with_failure'] | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $d 'rollback-consumed.failed.json')) | Should -BeTrue
        }
    }

    It '两个消费标记都写失败 → 15（REQ-019 Step 4a / 15(iii)）' {
        Mock Complete-RollbackJournal { throw 'disk full' }
        Mock Write-RecoveryMarker { throw 'disk full' }
        $dir = New-AutoBackupDir -Name 'backup-marker'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-marker.json') -Failed 5
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 15
        $r.Summary | Should -Be 'consumption_marker_write_failed'
    }

    It 'completed_at 写失败但消费标记写成功 → 仍然 0，并落下 consumed.failed 供下次确认' {
        Mock Complete-RollbackJournal { throw 'atomic replace denied' }
        $dir = New-AutoBackupDir -Name 'backup-marker2'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-marker2.json') -Failed 5
        $r = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path | Where-Object { $_ -is [hashtable] }
        $r.ExitCode | Should -Be 0
        # completed_at 没写成 → 必须以 consumed.failed 记账：下次启动只能把它当成
        # 「需人工确认」的候选，绝不静默重复恢复（REQ-019 Step 4a 的第二道闸门）。
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.failed.json')) | Should -BeTrue
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -BeNullOrEmpty
    }

    It '-Auto 全程不调用 Restore-Computer（AC-007：还原点只是人工选项）' {
        $dir = New-AutoBackupDir -Name 'backup-norestore'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-nr.json') -Failed 1
        $null = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path
        Should -Invoke Restore-Computer -Times 0 -Exactly
    }

    It '透传测试注入点：PATH 接缝与 -Now 必须抵达恢复引擎（否则 24h 窗口无法测）' {
        $dir = New-AutoBackupDir -Name 'backup-inject'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-inject.json') -Failed 1
        $now = [datetime]'2026-10-01T05:00:00Z'
        $null = Invoke-AutoRollback -ProjectRoot $script:proj -JournalPath $f.Path `
            -Now $now -MachinePathOverride 'C:\Injected' -SetPathScript { param($p) $p }
        Should -Invoke Invoke-RollbackRestore -Times 1 -Exactly -ParameterFilter {
            $MachinePathOverride -eq 'C:\Injected' -and $null -ne $SetPathScript
        }
    }
}

Describe 'rollback.ps1 Main 的 -Auto 分派' {
    BeforeEach { Reset-AutoProject }

    It '不带 -Auto 时输出与今天一致，绝不触碰日志（AC-012 回归）' {
        . $script:AutoScript
        $dir = New-AutoBackupDir -Name 'backup-readonly'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        # dot-source 会把顶层 param() 的默认值绑进本作用域（AGENTS.md 陷阱 8a），
        # 所以 $Auto / $JournalPath 必须在 dot-source **之后**赋值。
        $Auto = $false
        $JournalPath = ''
        $AcknowledgeConflicts = $false
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride (Join-Path $script:proj 'no-log.json') `
            -BackupRootOverride $script:proj *>&1) -join "`n"
        $rc | Should -Be 0
        $out | Should -Match 'ROLLBACK INSTRUCTIONS'
        $out | Should -Match 'Automatic per-item rollback is available'
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.json')) | Should -BeFalse
    }

    It '带 -Auto 时把退出码原样回传（不是恒 0，也不得 exit）' {
        . $script:AutoScript
        Mock Test-RollbackAdminPrivilege { return $false }
        $Auto = $true
        $JournalPath = ''
        $AcknowledgeConflicts = $false
        $rc = 0
        $null = (Main -ExitCode ([ref]$rc) -BackupRootOverride $script:proj *>&1)
        $rc | Should -Be 2
    }
}
