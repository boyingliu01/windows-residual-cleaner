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

# 定位环节已抽到 rollback-recovery.ps1 的 Get-RecoveryJournalTarget：-Auto 与启动期 T3
# 读同一份日志，必须共用同一套「谁是候选 / 谁歧义」的判据（漂移的两个方向都是事故）。
Describe 'Get-RecoveryJournalTarget（共享日志定位，REQ-019 Step 1）' {
    BeforeEach { Reset-AutoProject }

    It '显式 -JournalPath 指向不存在的文件 → journal_path_not_found（不是臆造候选）' {
        $r = Get-RecoveryJournalTarget -ProjectRoot $script:proj -JournalPath (Join-Path $script:proj 'nope.json')
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'journal_path_not_found'
    }

    It '显式 -JournalPath 不可解析 → journal_unreadable' {
        $dir = New-AutoBackupDir -Name 'backup-corrupt'
        $jp = Join-Path $dir 'rollback-journal.json'
        [IO.File]::WriteAllText($jp, '{ this is not json')
        $r = Get-RecoveryJournalTarget -ProjectRoot $script:proj -JournalPath $jp
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'journal_unreadable'
    }

    It '没有 -JournalPath 时只取未完成候选；已完成的目录不参与' {
        $done = New-AutoBackupDir -Name 'backup-aadone'
        $now = Format-IsoUtc -Value (Get-Date).ToUniversalTime()
        $null = New-AutoJournal -Dir $done -CreatedAt $now -CompletedAt $now
        $r = Get-RecoveryJournalTarget -ProjectRoot $script:proj
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'no_candidate'
    }

    It '两份 created_at 可区分的未完成日志 → 取**最新**的一份，其余作为较旧候选（AC-046 前半）' {
        # 回归钉桩：Sort-Object -Property 走标准对象适配，**不认 hashtable 的键**，
        # 旧写法 `-Property Created` 会把所有元素当作相等，-Descending 于是退化成原序反转，
        # 选中的是**最旧**那份日志（实测）。方向选反 = 恢复陈旧日志，可能把用户后来
        # 主动删掉的东西装回去（REQ-019/AC-046）。
        $now = (Get-Date).ToUniversalTime()
        $older = New-AutoBackupDir -Name 'backup-pick-older'
        $newest = New-AutoBackupDir -Name 'backup-pick-newest'
        $null = New-AutoJournal -Dir $older -CreatedAt (Format-IsoUtc -Value $now.AddMinutes(-45))
        $null = New-AutoJournal -Dir $newest -CreatedAt (Format-IsoUtc -Value $now)

        $t = Get-RecoveryJournalTarget -ProjectRoot $script:proj
        $t.Ok | Should -BeTrue
        (Get-Item -LiteralPath $t.BackupDir).FullName | Should -Be (Get-Item -LiteralPath $newest).FullName
        @($t.Candidates).Count | Should -Be 1
        (Get-Item -LiteralPath ([string]$t.Candidates[0].BackupDir)).FullName | Should -Be (Get-Item -LiteralPath $older).FullName
    }

    It '三份可区分时同样取最新，较旧候选按份数交回（排序稳定性）' {
        $now = (Get-Date).ToUniversalTime()
        $a = New-AutoBackupDir -Name 'backup-sort-a'
        $b = New-AutoBackupDir -Name 'backup-sort-b'
        $c = New-AutoBackupDir -Name 'backup-sort-c'
        $null = New-AutoJournal -Dir $a -CreatedAt (Format-IsoUtc -Value $now.AddMinutes(-90))
        $null = New-AutoJournal -Dir $b -CreatedAt (Format-IsoUtc -Value $now.AddMinutes(-5))
        $null = New-AutoJournal -Dir $c -CreatedAt (Format-IsoUtc -Value $now.AddMinutes(-60))
        $sel = Select-RecoveryCandidate -Candidates (Get-RecoveryCandidateSet -ProjectRoot $script:proj)
        (Get-Item -LiteralPath $sel.Selected.BackupDir).FullName | Should -Be (Get-Item -LiteralPath $b).FullName
        @($sel.Others).Count | Should -Be 2
    }

    It '两份 created_at 相同的未完成日志 → 判为歧义并原样交回候选清单' {
        $same = (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        foreach ($n in @('backup-b1', 'backup-b2')) {
            $d = New-AutoBackupDir -Name $n
            $null = New-AutoJournal -Dir $d -CreatedAt $same
        }
        $r = Get-RecoveryJournalTarget -ProjectRoot $script:proj
        $r.Ok | Should -BeFalse
        $r.Ambiguous | Should -BeTrue
        @($r.Candidates).Count | Should -Be 2
    }
}

Describe 'Get-AutoRollbackExitCode（Outcome → -Auto 退出码）' {
    # 纯映射表：消费协议只说「发生了什么」，各自的码由调用方决定。
    # 逐条钉住，新增 Outcome 时这里会立刻缺一块，而不是静默落到 default。
    # 必须用 -ForEach：Describe 体内的循环变量在 Pester 5 的 Run 阶段已不在作用域，
    # 直接闭包引用会得到空串（实测踩过）。
    It '<O> → <E>' -ForEach @(
        @{ O = 'no_journal'; E = 12 },
        @{ O = 'input_error'; E = 1 },
        @{ O = 'unreadable'; E = 12 },
        @{ O = 'ambiguous'; E = 14 },
        @{ O = 'needs_acknowledgement'; E = 14 },
        @{ O = 'rejected'; E = 14 },
        @{ O = 'consumed_with_skipped'; E = 14 },
        @{ O = 'partial_restore'; E = 11 },
        @{ O = 'persistence_failed'; E = 15 },
        @{ O = 'already_completed'; E = 0 },
        @{ O = 'suppressed'; E = 0 },
        @{ O = 'acknowledged_without_restore'; E = 0 },
        @{ O = 'consumed'; E = 0 },
        @{ O = 'dry_run_reported'; E = 0 }
    ) {
        Get-AutoRollbackExitCode -Outcome $O | Should -Be $E
    }

    It '未知 Outcome 兜到 14，而不是 0（漏填映射表不得假装成功）' {
        Get-AutoRollbackExitCode -Outcome 'brand_new_outcome' | Should -Be 14
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

# ─────────────────────────────────────────────────────────────────────────────
# 消费协议本体（REQ-019 Step 1..5）。上面的 -Auto 用例是从退出码侧看它，这一组直接
# 驱动 Invoke-RollbackJournalConsumption —— 启动期 T3 走的是同一个函数，所以协议契约
# 必须钉在这里，而不是钉在某个调用方的码表上。
# 一律断言落盘产物（日志字段 / output 清单 / 旁路标记），不断言打印。
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Invoke-RollbackJournalConsumption（共享消费协议：AC-046/047/048/060/078/079/091）' {
    BeforeEach {
        Reset-AutoProject
        Mock-AutoRestoreSuccess
    }

    It '恢复成功 → completed_at 与 consumed_by_run_id 一并落盘；紧接着的第二次运行不会重复消费（AC-047）' {
        $dir = New-AutoBackupDir -Name 'backup-ac047'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-ac047.json') -Failed 2
        $ownRunId = [string]$f.Journal['run_id']

        $r = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj
        $r.Outcome | Should -Be 'consumed'

        $after = Read-AutoJournalFile -Dir $dir
        $after['completed_at'] | Should -Not -BeNullOrEmpty
        # consumed_by_run_id 记的是**消费方**：写成被消费日志自己的 run_id 等于没写追溯信息。
        $g = [guid]::Empty
        [guid]::TryParse([string]$after['consumed_by_run_id'], [ref]$g) | Should -BeTrue
        ([string]$after['consumed_by_run_id'] -ne $ownRunId) | Should -BeTrue

        # 不重复消费有两条路径都要成立：扫描（Step 1 剔除已完成者）与显式指定日志。
        $rescan = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj
        $rescan.Outcome | Should -Be 'no_journal'
        $explicit = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj -JournalPath $f.Path
        $explicit.Outcome | Should -Be 'already_completed'
        Should -Invoke Invoke-RollbackRestore -Times 1 -Exactly
    }

    It '两份未完成日志：只恢复最新的，较旧那份先写清单再打标记且 reason 恒为 skipped_older_journal（AC-046/079/091）' {
        $now = (Get-Date).ToUniversalTime()
        $oldCreated = Format-IsoUtc -Value $now.AddMinutes(-30)
        $old = New-AutoBackupDir -Name 'backup-step4a-old'
        $new = New-AutoBackupDir -Name 'backup-step4a-new'

        $fOld = New-AutoJournal -Dir $old -CreatedAt $oldCreated
        # 较旧那份带真实条目：清单必须逐条展开，不能只留一个候选级信封。
        $fOld.Journal['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'reg_100' -Kind 'registry_key' `
                -Target 'HKCU\Software\WRC-Consumption-Old-1' -BackupFile '' `
                -PreExisting $true -AbsentConfirmedAfterMutation $true `
                -ParentBaseline $oldCreated -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'reg_101' -Kind 'registry_key' `
                -Target 'HKCU\Software\WRC-Consumption-Old-2' -BackupFile '' `
                -PreExisting $true -AbsentConfirmedAfterMutation $true `
                -ParentBaseline $oldCreated -State 'mutation_succeeded')
        )
        $null = Write-RollbackJournal -BackupDir $old -Journal $fOld.Journal

        # 最新那份必须「真的需要恢复」（清理日志 summary.failed > 0），否则协议走抑制分支，
        # 根本到不了 Step 4a。绑定要经磁盘重写，因为判定读的是盘上那份。
        $fNew = New-AutoJournal -Dir $new -CreatedAt (Format-IsoUtc -Value $now)
        Bind-AutoCleanupLog -Journal $fNew.Journal -Path (Join-Path $script:proj 'cleanup-log-step4a.json') -Failed 4

        $r = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj
        $r.Outcome | Should -Be 'consumed_with_skipped'
        $r.Summary | Should -Be 'restored_with_skipped_older_journals'

        # 清单文件名用的是较旧候选自己的 run_id
        $oldRunId = [string]$fOld.Journal['run_id']
        $listPath = Join-Path (Join-Path $script:proj 'output') ('rollback-unrepaired-' + $oldRunId + '.json')
        (Test-Path -LiteralPath $listPath) | Should -BeTrue
        $raw = Get-Content -LiteralPath $listPath -Raw
        $l = $raw | ConvertFrom-Json
        $l.reason | Should -Be 'skipped_older_journal'
        $l.candidate_unparseable | Should -BeFalse
        (Get-Item -LiteralPath $l.backup_dir).FullName | Should -Be (Get-Item -LiteralPath $old).FullName
        @($l.unrepaired).Count | Should -Be 2
        # AC-091：条目级 reason 也一样，不得混入 conflict/not_restorable。
        @(@($l.unrepaired) | ForEach-Object { $_.reason } | Select-Object -Unique) | Should -Be @('skipped_older_journal')
        # item_id 用 Get-ItemId 的权威形态（kind + 小写 target；hive 别名不展开成长名）
        (@($l.unrepaired)[0].item_id) | Should -Be 'registry_key:hkcu\software\wrc-consumption-old-1'

        # 清单成功之后才有标记：较旧日志被写成 completed_at + consumed_with_failure + 旁路文件
        (Read-AutoJournalFile -Dir $old)['completed_at'] | Should -Not -BeNullOrEmpty
        (Read-AutoJournalFile -Dir $old)['consumed_with_failure'] | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $old 'rollback-consumed.failed.json')) | Should -BeTrue
        # 最新一份正常消费
        (Read-AutoJournalFile -Dir $new)['completed_at'] | Should -Not -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $new 'rollback-consumed.json')) | Should -BeTrue
    }

    It '较旧候选的标记写入失败 → 清单已在盘上、日志仍未完成，整体按 persistence_failed 收口（AC-079 的顺序是承重的）' {
        $now = (Get-Date).ToUniversalTime()
        $old = New-AutoBackupDir -Name 'backup-step4a-markfail-old'
        $new = New-AutoBackupDir -Name 'backup-step4a-markfail-new'
        $null = New-AutoJournal -Dir $old -CreatedAt (Format-IsoUtc -Value $now.AddMinutes(-10))
        $fNew = New-AutoJournal -Dir $new -CreatedAt (Format-IsoUtc -Value $now)
        Bind-AutoCleanupLog -Journal $fNew.Journal -Path (Join-Path $script:proj 'cleanup-log-markfail.json') -Failed 1

        Mock Complete-RollbackJournal { throw 'disk full' }

        $r = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj
        $r.Outcome | Should -Be 'persistence_failed'
        $r.Summary | Should -Be 'older_journal_marker_failed'

        # 顺序证据：清单写成功在前（所以它必须存在），标记在后（所以它必须不存在）。
        $oldFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:proj 'output') -Filter 'rollback-unrepaired-*.json')
        $oldFiles.Count | Should -Be 1
        (Read-AutoJournalFile -Dir $old)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $old 'rollback-consumed.failed.json')) | Should -BeFalse
        # 「不得宣告恢复完成」也适用于本轮成功恢复的那一份：标记没写成就不算完成。
        (Read-AutoJournalFile -Dir $new)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $new 'rollback-consumed.json')) | Should -BeFalse
    }

    It '-AcknowledgeConflicts 下清单写入失败 → 一份标记都不写，返回 persistence_failed（AC-078 禁止「已确认但清单丢失」）' {
        $same = Format-IsoUtc -Value (Get-Date).ToUniversalTime()
        $dirs = @()
        foreach ($n in @('backup-ac078-h1', 'backup-ac078-h2')) {
            $d = New-AutoBackupDir -Name $n
            $null = New-AutoJournal -Dir $d -CreatedAt $same
            $dirs += $d
        }

        Mock Write-UnrepairedList { throw 'disk full' }

        $r = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj -AcknowledgeConflicts $true
        $r.Outcome | Should -Be 'persistence_failed'
        $r.Summary | Should -Be 'acknowledgement_marker_write_failed'
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly

        foreach ($d in $dirs) {
            (Read-AutoJournalFile -Dir $d)['completed_at'] | Should -BeNullOrEmpty
            # 内存里置过 true，但盘上必须仍是 false：清单没写成就不算被确认。
            (Read-AutoJournalFile -Dir $d)['consumed_with_failure'] | Should -BeFalse
            (Test-Path -LiteralPath (Join-Path $d 'rollback-consumed.failed.json')) | Should -BeFalse
        }
        (Test-Path -LiteralPath (Join-Path $script:proj 'output')) | Should -BeFalse
    }

    It 'run_id 不合法的候选：只写候选级清单（candidate_unparseable=true + unrepaired 空数组），不写任何标记（AC-060）' {
        $dir = New-AutoBackupDir -Name 'backup-ac060'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $f.Journal['run_id'] = 'not-a-guid'
        $null = Write-RollbackJournal -BackupDir $dir -Journal $f.Journal

        $r = Set-JournalConsumedWithoutRestore -Candidate @{ Journal = $f.Journal; BackupDir = $dir } `
            -ProjectRoot $script:proj -Reason 'acknowledged_without_restore'
        $r.Ok | Should -BeFalse
        $r.Stage | Should -Be 'unmarkable'
        $r.Detail | Should -Be 'invalid_run_id'

        # 清单文件名里的 run_id 先验合法性：不合法就退回备份目录名，
        # 绝不把外部可控的字符串直接拼进路径。
        $r.ListPath | Should -Be (Join-Path (Join-Path $script:proj 'output') 'rollback-unrepaired-backup-ac060.json')
        $raw = Get-Content -LiteralPath $r.ListPath -Raw
        # 断言**原始 JSON 文本**的空数组形态：ConvertFrom-Json 之后 5.1 与 pwsh 7 形状不同。
        # 5.1 的 ConvertTo-Json 会把空数组折成跨行形式，所以 \s* 必须能跨行。
        $raw | Should -Match '(?s)"unrepaired":\s*\[\s*\]'
        $raw | Should -Match '"candidate_unparseable":\s*true'
        $l = $raw | ConvertFrom-Json
        $l.reason | Should -Be 'acknowledged_without_restore'
        $l.backup_dir | Should -Be $dir

        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.failed.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.json')) | Should -BeFalse
    }

    It '条目全为 not_restorable 不算失败：继续消费并返回 consumed（AC-048：结果不是 14）' {
        Mock Invoke-RollbackRestore {
            return @{
                Report           = @('all entries not_restorable')
                Counts           = @{ restored = 0; already_present = 0; not_restorable = 3; restore_failed = 0 }
                PersistenceError = $false
                ResultPath       = 'mock-rollback-result.json'
                UnrepairedPath   = ''
                Unrepaired       = @()
            }
        }
        $dir = New-AutoBackupDir -Name 'backup-ac048'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-ac048.json') -Failed 3

        $r = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj
        $r.Outcome | Should -Be 'consumed'
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -Not -BeNullOrEmpty
    }

    It '同时存在较旧候选时：Step 4a 的结论优先，not_restorable 不把它降回成功（AC-048 优先级句）' {
        Mock Invoke-RollbackRestore {
            return @{
                Report           = @()
                Counts           = @{ restored = 0; already_present = 0; not_restorable = 1; restore_failed = 0 }
                PersistenceError = $false
                ResultPath       = 'mock-rollback-result.json'
                UnrepairedPath   = ''
                Unrepaired       = @()
            }
        }
        $now = (Get-Date).ToUniversalTime()
        $null = New-AutoBackupDir -Name 'backup-ac048-old'
        $null = New-AutoJournal -Dir (Join-Path $script:proj 'backup-ac048-old') -CreatedAt (Format-IsoUtc -Value $now.AddMinutes(-5))
        $new = New-AutoBackupDir -Name 'backup-ac048-new'
        $fNew = New-AutoJournal -Dir $new -CreatedAt (Format-IsoUtc -Value $now)
        Bind-AutoCleanupLog -Journal $fNew.Journal -Path (Join-Path $script:proj 'cleanup-log-ac048b.json') -Failed 1

        $r = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj
        $r.Outcome | Should -Be 'consumed_with_skipped'
    }

    It '-DryRun 只报告：不消费、不恢复、一个字节都不写（AC-010 / AC-033 的协议侧）' {
        $dir = New-AutoBackupDir -Name 'backup-dryrun'
        $f = New-AutoJournal -Dir $dir -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        Bind-AutoCleanupLog -Journal $f.Journal -Path (Join-Path $script:proj 'cleanup-log-dryrun.json') -Failed 2

        $r = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj -DryRun
        $r.Outcome | Should -Be 'dry_run_reported'
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly
        (Read-AutoJournalFile -Dir $dir)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $dir 'rollback-consumed.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:proj 'output')) | Should -BeFalse
    }

    It '-DryRun 下平局如实报告候选份数，不要求确认也不标记（AC-010 + exit 14(c) 的预览）' {
        $same = Format-IsoUtc -Value (Get-Date).ToUniversalTime()
        foreach ($n in @('backup-drytie1', 'backup-drytie2')) {
            $d = New-AutoBackupDir -Name $n
            $null = New-AutoJournal -Dir $d -CreatedAt $same
        }
        $r = Invoke-RollbackJournalConsumption -ProjectRoot $script:proj -DryRun
        $r.Outcome | Should -Be 'dry_run_reported'
        $r.Summary | Should -Be 'dry_run_ambiguous(2)'
        @($r.Candidates).Count | Should -Be 2
        Should -Invoke Invoke-RollbackRestore -Times 0 -Exactly
        foreach ($n in @('backup-drytie1', 'backup-drytie2')) {
            (Read-AutoJournalFile -Dir (Join-Path $script:proj $n))['completed_at'] | Should -BeNullOrEmpty
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
