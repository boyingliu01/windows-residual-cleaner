# tests/unit/rollback-verdicts.Tests.ps1
# S3 — §3.4 缺失纯函数：可恢复性、REQ-024 唯一权威决策表、PATH 作用域/预期值、裁决与报告渲染。
# 断言必须在 PS 5.1 与 pwsh 7 下都成立（pre-commit Gate 5 用 pwsh 7）。
#
# 核心契约：REQ-024 是**唯一**恢复判定规则（REQ-018/REQ-029 一律引用它）。
# 三项目标（pre_existing + mutation_succeeded + absent_confirmed_after_mutation）
# 且窗口内且无外部变更迹象 → restore；其余一切「目标不存在」→ conflict，不自动恢复。

BeforeAll {
    $script:JournalScript = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-journal.ps1'
    $script:RecoveryScript = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-recovery.ps1'
    $script:VerdictsScript = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-verdicts.ps1'
    . $script:JournalScript
    . $script:RecoveryScript
    . $script:VerdictsScript

    # Pester 5：顶层定义的函数只在发现阶段存在，运行阶段不可见 —— 必须放 BeforeAll。
    function New-VerdictEntry {
        param(
            [string]$Kind = 'registry_key',
            [string]$Target = 'HKCU\Software\WRC-Test',
            [string]$State = 'mutation_succeeded',
            [bool]$PreExisting = $true,
            [bool]$AbsentConfirmed = $true
        )
        return @{
            id                              = 'reg_900'
            item_id                         = (Get-ItemId -Kind $Kind -Target $Target)
            kind                            = $Kind
            target                          = $Target
            backup_file                     = $null
            backup_file_sha256              = $null
            pre_existing                    = $PreExisting
            absent_confirmed_after_mutation = $AbsentConfirmed
            parent_baseline                 = $null
            state                           = $State
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-RollbackRestorable（REQ-018 / DD-006）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Test-RollbackRestorable: kind -> restorable + reason' {
    It '<Kind> 可恢复' -TestCases @(
        @{ Kind = 'registry_key' }
        @{ Kind = 'startup_value' }
        @{ Kind = 'path_entry' }
    ) {
        param($Kind)
        $r = Test-RollbackRestorable -Kind $Kind
        $r.Restorable | Should -BeTrue
        [string]::IsNullOrEmpty($r.Reason) | Should -BeTrue
    }

    It '<Kind> 不可恢复且必须给出原因' -TestCases @(
        @{ Kind = 'path_deleted' }
        @{ Kind = 'service' }
        @{ Kind = 'task' }
    ) {
        param($Kind)
        $r = Test-RollbackRestorable -Kind $Kind
        $r.Restorable | Should -BeFalse
        $r.Reason | Should -Not -BeNullOrEmpty
    }

    It '未知 kind 判为不可恢复（fail-closed，不得抛）' {
        $r = Test-RollbackRestorable -Kind 'widget'
        $r.Restorable | Should -BeFalse
        $r.Reason | Should -Not -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve-PathEntryScope
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Resolve-PathEntryScope' {
    It 'Machine-only entry resolves to Machine' {
        $r = Resolve-PathEntryScope -Entry 'C:\Tools\WRC' `
            -MachinePath 'C:\Windows;C:\Tools\WRC' -UserPath 'C:\Users\me\bin'
        $r.Scope | Should -Be 'Machine'
    }

    It 'User-only entry resolves to User' {
        $r = Resolve-PathEntryScope -Entry 'C:\Users\me\bin' `
            -MachinePath 'C:\Windows' -UserPath 'C:\Users\me\bin;C:\Other'
        $r.Scope | Should -Be 'User'
    }

    It 'entry in both scopes is reported as Both, not silently Machine' {
        $r = Resolve-PathEntryScope -Entry 'C:\Shared' `
            -MachinePath 'C:\Shared' -UserPath 'C:\Shared'
        $r.Scope | Should -Be 'Both'
    }

    It 'absent entry resolves to None' {
        $r = Resolve-PathEntryScope -Entry 'C:\Ghost' `
            -MachinePath 'C:\Windows' -UserPath ''
        $r.Scope | Should -Be 'None'
    }

    It 'comparison tolerates case, surrounding whitespace and trailing backslash' {
        $r = Resolve-PathEntryScope -Entry 'c:\tools\wrc\' `
            -MachinePath 'C:\Windows ; C:\Tools\WRC' -UserPath $null
        $r.Scope | Should -Be 'Machine'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-ExpectedPathAfterCleanup（REQ-021 的「清理后预期值」推导）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Get-ExpectedPathAfterCleanup' {
    It '逐字移除成功条目，保留顺序与其它段' {
        $expected = Get-ExpectedPathAfterCleanup -OriginalPath 'A;B;C;D' -RemovedEntries @('B', 'D')
        $expected | Should -Be 'A;C'
    }

    It '移除匹配大小写不敏感，且按整段匹配（不误删前缀相同的段）' {
        $expected = Get-ExpectedPathAfterCleanup -OriginalPath 'C:\App;C:\AppData' -RemovedEntries @('c:\app')
        $expected | Should -Be 'C:\AppData'
    }

    It '无移除项时原值逐字保留（不得重排/丢空段语义）' {
        Get-ExpectedPathAfterCleanup -OriginalPath 'A;B' -RemovedEntries @() | Should -Be 'A;B'
    }

    It 'OriginalPath 为 null 时返回 null（证据缺失，由调用方降级人工）' {
        $r = Get-ExpectedPathAfterCleanup -OriginalPath $null -RemovedEntries @('A')
        ($null -eq $r) | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-RollbackVerdict — REQ-024 唯一权威决策表
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Get-RollbackVerdict: REQ-024 decision table' {
    It '目标存在且与备份一致 -> already_present' {
        $e = New-VerdictEntry
        $v = Get-RollbackVerdict -Entry $e -TargetState 'present_match' -WithinWindow $true
        $v.Verdict | Should -Be 'already_present'
    }

    It '目标存在但与备份不同 -> conflict（迹象 (i)），不覆盖' {
        $e = New-VerdictEntry
        $v = Get-RollbackVerdict -Entry $e -TargetState 'present_mismatch' -WithinWindow $true
        $v.Verdict | Should -Be 'conflict'
        $v.Reason | Should -Be 'external_change_sign_i'
    }

    It '缺失 + 三项目标齐备 + 窗口内 + 无迹象 -> restore' {
        $e = New-VerdictEntry
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true
        $v.Verdict | Should -Be 'restore'
    }

    It '缺失但 state 非 mutation_succeeded -> conflict，不自动恢复' -TestCases @(
        @{ State = 'planned' }
        @{ State = 'backup_created' }
        @{ State = 'mutation_failed' }
    ) {
        param($State)
        $e = New-VerdictEntry -State $State
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true
        $v.Verdict | Should -Be 'conflict'
    }

    It '缺失但 pre_existing=false -> conflict（可能是用户自己从未创建过的东西）' {
        $e = New-VerdictEntry -PreExisting $false
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true
        $v.Verdict | Should -Be 'conflict'
        $v.Reason | Should -Be 'causal_flags_incomplete'
    }

    It '缺失但 absent_confirmed_after_mutation=false -> conflict（REQ-024 第 4 条）' {
        $e = New-VerdictEntry -AbsentConfirmed $false
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true
        $v.Verdict | Should -Be 'conflict'
        $v.Reason | Should -Be 'causal_flags_incomplete'
    }

    It '缺失 + 三项目标齐备但超窗 -> conflict（窗口是安全边界，不可放宽）' {
        $e = New-VerdictEntry
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $false
        $v.Verdict | Should -Be 'conflict'
        $v.Reason | Should -Be 'window_exceeded'
    }

    It '注册表条目命中迹象 (ii) -> conflict' {
        $e = New-VerdictEntry
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true -SignIiDetected $true
        $v.Verdict | Should -Be 'conflict'
        $v.Reason | Should -Be 'external_change_sign_ii'
    }

    It '迹象 (ii) 不可判定不阻断恢复，但必须标注证据不完整（AC-075a）' {
        $e = New-VerdictEntry
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true `
            -SignIiDetected $false -SignIiUndecidable $true
        $v.Verdict | Should -Be 'restore'
        $v.EvidenceIncomplete | Should -BeTrue
    }

    It 'path_entry 命中迹象 (iii)（PATH 漂移）-> conflict（REQ-021 顺序：先窗口后漂移）' {
        $e = New-VerdictEntry -Kind 'path_entry' -Target 'C:\Tools\WRC'
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true `
            -PathExpected 'A;C' -PathCurrent 'A;B;C'
        $v.Verdict | Should -Be 'conflict'
        $v.Reason | Should -Be 'external_change_sign_iii'
    }

    It 'path_entry 冲突必须留下比较证据（2026-10-07 drill5：只写 reason 导致现场不可复盘）' {
        $e = New-VerdictEntry -Kind 'path_entry' -Target 'C:\Tools\WRC'
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true `
            -PathExpected 'A;C' -PathCurrent 'A;B;C'
        $v.PathCompare | Should -Be 'mismatch'
        $v.ExpectedPath | Should -Be 'A;C'
        $v.PathCurrent | Should -Be 'A;B;C'
    }

    It 'path_entry 比较双方任一为 null 时必须与 mismatch 区分（null 是故障，不是漂移）' {
        $e = New-VerdictEntry -Kind 'path_entry' -Target 'C:\Tools\WRC'
        # 传 null 必须靠「省略参数」而非 `-PathCurrent $null`：PS 5.1 和 pwsh 7 都会把
        # [string] 参数的显式 $null 强转成 ''，两种写法无从区分 null 与空串；
        # 实现按 $PSBoundParameters 的绑定存在性判定 null。省略参数同时也是生产路径：
        # Get-RestorableEntry 只注入非 null 的 extras。
        $vCur = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true `
            -PathExpected 'A;C'
        $vCur.Verdict | Should -Be 'conflict'
        $vCur.PathCompare | Should -Be 'current_null'
        $vExp = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true `
            -PathCurrent 'A;C'
        $vExp.Verdict | Should -Be 'conflict'
        $vExp.PathCompare | Should -Be 'expected_null'
    }

    It 'path_entry 窗口内且无漂移 -> restore，且记录整作用域预期值' {
        $e = New-VerdictEntry -Kind 'path_entry' -Target 'C:\Tools\WRC'
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true `
            -PathExpected 'A;C' -PathCurrent 'A;C'
        $v.Verdict | Should -Be 'restore'
        $v.ExpectedPath | Should -Be 'A;C'
        $v.PathCurrent | Should -Be 'A;C'
        $v.PathCompare | Should -Be 'equal'
    }

    It 'path_deleted 条目 -> not_restorable 并给出原因，不参与决策表' {
        $e = New-VerdictEntry -Kind 'path_deleted' -Target 'C:\Old\WRC-App'
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true
        $v.Verdict | Should -Be 'not_restorable'
        $v.Reason | Should -Not -BeNullOrEmpty
    }

    It '裁决记录必须回指 item_id（REQ-030 未修复清单可直接回指）' {
        $e = New-VerdictEntry
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true
        $v.ItemId | Should -Be $e['item_id']
        $v.Kind | Should -Be $e['kind']
        $v.Target | Should -Be $e['target']
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-RestorableEntry — 两阶段（判定 -> 执行）的批量过滤入口
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Get-RestorableEntry' {
    It '仅返回判定为 restore 的条目；conflict/not_restorable/already_present 分流' {
        $eRestore = New-VerdictEntry -Target 'HKCU\Software\A'
        $eConflict = New-VerdictEntry -Target 'HKCU\Software\B' -AbsentConfirmed $false
        $ePresent = New-VerdictEntry -Target 'HKCU\Software\C'
        $eGone = New-VerdictEntry -Kind 'path_deleted' -Target 'C:\Old\A' -PreExisting $true -AbsentConfirmed $true
        # 键必须用 Get-ItemId 生成（注册表 target 统一小写是权威规则）
        $states = @{
            (Get-ItemId -Kind 'registry_key' -Target 'HKCU\Software\A') = 'absent'
            (Get-ItemId -Kind 'registry_key' -Target 'HKCU\Software\B') = 'absent'
            (Get-ItemId -Kind 'registry_key' -Target 'HKCU\Software\C') = 'present_match'
            (Get-ItemId -Kind 'path_deleted' -Target 'C:\Old\A')        = 'absent'
        }
        $r = Get-RestorableEntry -Entries @($eRestore, $eConflict, $ePresent, $eGone) `
            -TargetStates $states -TargetIdMap @{} -WithinWindow $true
        @($r.Restore).Count | Should -Be 1
        @($r.Restore)[0]['item_id'] | Should -Be $eRestore['item_id']
        @($r.Verdicts | Where-Object { $_.Verdict -eq 'conflict' }).Count | Should -Be 1
        @($r.Verdicts | Where-Object { $_.Verdict -eq 'already_present' }).Count | Should -Be 1
        @($r.Verdicts | Where-Object { $_.Verdict -eq 'not_restorable' }).Count | Should -Be 1
    }

    It '超窗时任何条目都不进 Restore（全部降级 conflict/manual）' {
        $e = New-VerdictEntry
        $states = @{ $e['item_id'] = 'absent' }
        $r = Get-RestorableEntry -Entries @($e) -TargetStates $states -TargetIdMap @{} -WithinWindow $false
        @($r.Restore).Count | Should -Be 0
    }

    It '条目缺外部状态时 fail-closed 判 conflict，绝不臆断为 absent 去恢复' {
        $e = New-VerdictEntry
        $r = Get-RestorableEntry -Entries @($e) -TargetStates @{} -TargetIdMap @{} -WithinWindow $true
        @($r.Restore).Count | Should -Be 0
        @($r.Verdicts)[0].Verdict | Should -Be 'conflict'
        @($r.Verdicts)[0].Reason | Should -Be 'missing_target_state'
    }

    It '空条目集返回空结果（不抛）' {
        $r = Get-RestorableEntry -Entries @() -TargetStates @{} -TargetIdMap @{} -WithinWindow $true
        @($r.Restore).Count | Should -Be 0
        @($r.Verdicts).Count | Should -Be 0
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Format-RollbackReport — 诚实渲染（REQ-014 / AC-070）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'Format-RollbackReport' {
    It '渲染逐条裁决：item_id / verdict / reason 都要出现' {
        $e = New-VerdictEntry
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true
        $lines = Format-RollbackReport -Verdicts @($v)
        $text = $lines -join "`n"
        $text | Should -BeLike "*$($e['item_id'])*"
        $text | Should -BeLike '*restore*'
    }

    It '存在 conflict 时必须声明能力边界：不得宣称可无条件恢复' {
        $e = New-VerdictEntry -Target 'HKCU\Software\X'
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $false
        $text = (Format-RollbackReport -Verdicts @($v)) -join "`n"
        # 诚实性关键词：24h 窗口 + 人工介入；不得出现无条件自动恢复承诺
        $text | Should -BeLike '*24*'
        $text | Should -Not -BeLike '*will be restored automatically*'
    }

    It 'path_entry 冲突的报告必须给出比较证据行（compare token + 长度 + 落盘指向）' {
        $e = New-VerdictEntry -Kind 'path_entry' -Target 'C:\Tools\WRC'
        $v = Get-RollbackVerdict -Entry $e -TargetState 'absent' -WithinWindow $true `
            -PathExpected 'A;C' -PathCurrent 'A;B;C'
        $text = (Format-RollbackReport -Verdicts @($v)) -join "`n"
        $text | Should -BeLike '*path evidence: compare=mismatch*'
        $text | Should -BeLike '*expected_len=3*'
        $text | Should -BeLike '*current_len=5*'
        $text | Should -BeLike '*rollback-result.json*'
    }

    It '空裁决集渲染为无操作说明（不抛）' {
        $text = (Format-RollbackReport -Verdicts @()) -join "`n"
        $text | Should -Not -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ConvertTo-RollbackJournal 缺失的 REQ-027 顶层字段
# ─────────────────────────────────────────────────────────────────────────────

Describe 'ConvertTo-RollbackJournal: REQ-027 top-level completeness' {
    It '必须包含 machine_path_scope / consumed_by_run_id / consumed_with_failure' {
        $j = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) -BackupDir 'backup-x'
        $j.ContainsKey('machine_path_scope') | Should -BeTrue
        $j.ContainsKey('consumed_by_run_id') | Should -BeTrue
        $j.ContainsKey('consumed_with_failure') | Should -BeTrue
        $j['consumed_with_failure'] | Should -BeFalse
    }

    It '新增字段不得破坏既有自证（空日志仍自证通过）' {
        $backupDir = Join-Path $env:TEMP ('wrc-jc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        try {
            $fp = Get-MachineFingerprint
            $j = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) `
                -BackupDir $backupDir -MachineFingerprint $fp.Value -FingerprintSource $fp.Source
            $v = Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint $fp.Value
            $v.Valid | Should -BeTrue ($v.Reasons -join '; ')
        } finally {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'machine_path_scope 可注入且随 Write/Read 往返存活' {
        $backupDir = Join-Path $env:TEMP ('wrc-jc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        try {
            $j = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) `
                -BackupDir $backupDir -MachinePathOriginal 'A;B'
            $j['machine_path_scope'] = 'Machine'
            Write-RollbackJournal -BackupDir $backupDir -Journal $j | Out-Null
            $back = Read-RollbackJournal -BackupDir $backupDir
            $back['machine_path_scope'] | Should -Be 'Machine'
            # 未设置时读回 null（而非 false/0 —— hashtable 往返陷阱）
            ($null -eq $back['consumed_by_run_id']) | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
