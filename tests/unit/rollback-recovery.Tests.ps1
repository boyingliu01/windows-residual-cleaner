# tests/unit/rollback-recovery.Tests.ps1
# S2 — T3 崩溃恢复：候选发现、抑制判定、消费与兜底决策（REQ-019 / REQ-031 / REQ-033 / REQ-024）
# 断言必须在 PS 5.1 与 pwsh 7 下都成立（pre-commit Gate 5 用 pwsh 7）。
#
# 核心诚实验证：**崩溃窗口假说**——在「写完清理日志之后、写 completed_at 之前」崩溃，
# 下次启动必须**抑制自动恢复**，绝不把刚删掉的内容装回去。

BeforeAll {
    $script:JournalScript = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-journal.ps1'
    $script:RecoveryScript = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-recovery.ps1'
    . $script:JournalScript
    . $script:RecoveryScript
}

# ─────────────────────────────────────────────────────────────────────────────
# 崩溃窗口假说（REQ-031 / AC-076）：summary.failed == 0 时必须抑制恢复
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 crash-window: cleanup succeeded but completed_at never written' {
    It 'completed_at == null + summary.failed == 0 → Suppress（不得装回已删内容）' {
        $j = @{
            run_id    = [guid]::NewGuid().ToString()
            completed_at = $null
            cleanup_log_path      = 'C:\does\not\matter.json'
            cleanup_log_timestamp = '2026-10-03T10:00:00Z'
            cleanup_log_sha256    = 'deadbeef'
        }
        $logPath = Join-Path $env:TEMP ("wrc-cw-log-" + [guid]::NewGuid().ToString('N') + '.json')
        try {
            # 与生产路径一致：sha256 记录的是清理日志文件的真实哈希（非 null 时必须匹配）
            $logObj = @{ run_id = $j['run_id']; summary = @{ failed = 0 } }
            [System.IO.File]::WriteAllText($logPath, ($logObj | ConvertTo-Json -Depth 6))
            $j['cleanup_log_sha256'] = (Get-FileHash $logPath -Algorithm SHA256).Hash

            $d = Get-UnfinishedJournalFallbackDecision -Journal $j -CleanupLogPathOverride $logPath
            $d.Suppress | Should -BeTrue
            $d.NormalT3 | Should -BeFalse
            $d.Reason | Should -Be 'unfinished_but_cleanup_succeeded'
        } finally {
            if (Test-Path $logPath) { Remove-Item $logPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'completed_at == null + summary.failed > 0 → 不抑制，走正常 T3 恢复' {
        $j = @{
            run_id    = [guid]::NewGuid().ToString()
            completed_at = $null
            cleanup_log_path      = 'C:\does\not\matter.json'
            cleanup_log_timestamp = '2026-10-03T10:00:00Z'
            cleanup_log_sha256    = 'deadbeef'
        }
        $logPath = Join-Path $env:TEMP ("wrc-cw-log-" + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [System.IO.File]::WriteAllText($logPath,
                (@{ run_id = $j['run_id']; summary = @{ failed = 2 } } | ConvertTo-Json -Depth 6))
            $j['cleanup_log_sha256'] = (Get-FileHash $logPath -Algorithm SHA256).Hash

            $d = Get-UnfinishedJournalFallbackDecision -Journal $j -CleanupLogPathOverride $logPath
            $d.Suppress | Should -BeFalse
            $d.NormalT3 | Should -BeTrue
        } finally {
            if (Test-Path $logPath) { Remove-Item $logPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'completed_at 非 null → 本轮已正常结束，既不抑制也不走 T3（NormalT3=false）' {
        $j = @{ run_id = [guid]::NewGuid().ToString(); completed_at = '2026-10-03T10:00:00Z' }
        $d = Get-UnfinishedJournalFallbackDecision -Journal $j
        $d.Suppress | Should -BeFalse
        $d.NormalT3 | Should -BeFalse
        $d.Reason | Should -Be 'journal_completed'
    }

    It '清理日志哈希不匹配 → RejectCandidate=true 且不走自动恢复（评审修复：篡改/损坏日志不得当正常 T3）' {
        $rid = [guid]::NewGuid().ToString()
        $logPath = Join-Path $env:TEMP ("wrc-cw-rej-" + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [System.IO.File]::WriteAllText($logPath,
                (@{ run_id = $rid; summary = @{ failed = 0 } } | ConvertTo-Json -Depth 6))
            $j = @{ run_id = $rid; completed_at = $null; cleanup_log_path = $logPath;
                    cleanup_log_timestamp = '2026-10-03T10:00:00Z'; cleanup_log_sha256 = 'WRONGHASH' }
            $d = Get-UnfinishedJournalFallbackDecision -Journal $j
            $d.RejectCandidate | Should -BeTrue
            $d.NormalT3 | Should -BeFalse
            $d.Suppress | Should -BeFalse
            $d.Reason | Should -Be 'cleanup_log_sha256_mismatch'
        } finally {
            if (Test-Path $logPath) { Remove-Item $logPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-JournalSuppressionVerdict：分级证据与模式检查（REQ-019 Step 2.5 / REQ-031）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 suppression verdict: evidence grading' {
    BeforeEach {
        $script:VerdictDir = Join-Path $env:TEMP ("wrc-verdict-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:VerdictDir -Force | Out-Null
        $script:runId = [guid]::NewGuid().ToString()
        $script:BaseJournal = @{
            run_id    = $script:runId
            completed_at = $null
            cleanup_log_path      = Join-Path $script:VerdictDir 'base.json'
            cleanup_log_timestamp = '2026-10-03T10:00:00Z'
            cleanup_log_sha256    = 'deadbeef'
        }
    }
    AfterEach {
        if (Test-Path $script:VerdictDir) { Remove-Item $script:VerdictDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '三字段同为 null → 无路径可用，EvidenceMissing 且不抑制' {
        $j = $script:BaseJournal.Clone()
        $j['cleanup_log_path'] = $null
        $j['cleanup_log_timestamp'] = $null
        $j['cleanup_log_sha256'] = $null
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeFalse
        $r.EvidenceMissing | Should -BeTrue
        $r.Reason | Should -Be 'no_cleanup_log_path'
    }

    It '三字段部分为 null → 模式非法，直接拒绝（AC-083）' {
        $j = $script:BaseJournal.Clone()
        $j['cleanup_log_path'] = 'C:\x.json'
        $j['cleanup_log_timestamp'] = $null
        $j['cleanup_log_sha256'] = $null
        # 1 非 null + 2 null = 违反「同 null 或同非 null」
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.RejectCandidate | Should -BeTrue
        $r.Reason | Should -Be 'cleanup_log_fields_pattern_invalid'
    }

    It '日志文件已不存在 → EvidenceMissing，不抑制也不拒绝' {
        $j = $script:BaseJournal.Clone()
        $j['cleanup_log_path'] = Join-Path $script:VerdictDir 'gone.json'
        $j['cleanup_log_timestamp'] = '2026-10-03T10:00:00Z'
        $j['cleanup_log_sha256'] = 'deadbeef'
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeFalse
        $r.RejectCandidate | Should -BeFalse
        $r.EvidenceMissing | Should -BeTrue
        $r.Reason | Should -Be 'cleanup_log_missing'
    }

    It '文件存在但不可解析 → EvidenceMissing，不抑制' {
        $j = $script:BaseJournal.Clone()
        $bad = Join-Path $script:VerdictDir 'bad.json'
        [System.IO.File]::WriteAllText($bad, '{ not json')
        $j['cleanup_log_path'] = $bad
        $j['cleanup_log_sha256'] = (Get-FileHash $bad -Algorithm SHA256).Hash   # 哈希匹配才继续到解析判据
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeFalse
        $r.Reason | Should -Be 'cleanup_log_unparsable'
    }

    It '清理日志 run_id 缺失（旧格式）→ 无法证明归属，不得抑制' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'old.json'
        [System.IO.File]::WriteAllText($log, (@{ summary = @{ failed = 0 } } | ConvertTo-Json -Depth 6))
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_sha256'] = (Get-FileHash $log -Algorithm SHA256).Hash
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeFalse
        $r.Reason | Should -Be 'cleanup_log_run_id_absent'
    }

    It '清理日志 run_id 与日志不一致 → 拒绝候选，不抑制' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'other.json'
        [System.IO.File]::WriteAllText($log,
            (@{ run_id = [guid]::NewGuid().ToString(); summary = @{ failed = 0 } } | ConvertTo-Json -Depth 6))
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_sha256'] = (Get-FileHash $log -Algorithm SHA256).Hash
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.RejectCandidate | Should -BeTrue
        $r.Reason | Should -Be 'cleanup_log_run_id_mismatch'
    }

    It 'summary 缺失 → EvidenceMissing，不抑制' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'nosum.json'
        [System.IO.File]::WriteAllText($log, (@{ run_id = $script:runId } | ConvertTo-Json -Depth 6))
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_sha256'] = (Get-FileHash $log -Algorithm SHA256).Hash
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeFalse
        $r.Reason | Should -Be 'summary_absent'
    }

    It 'summary.failed 缺失 → EvidenceMissing，不抑制' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'nofail.json'
        [System.IO.File]::WriteAllText($log,
            (@{ run_id = $script:runId; summary = @{} } | ConvertTo-Json -Depth 6))
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_sha256'] = (Get-FileHash $log -Algorithm SHA256).Hash
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeFalse
        $r.Reason | Should -Be 'summary_failed_absent'
    }

    It 'failed == 0 且 run_id 匹配 → 抑制' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'ok.json'
        [System.IO.File]::WriteAllText($log,
            (@{ run_id = $script:runId; summary = @{ failed = 0 } } | ConvertTo-Json -Depth 6))
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_sha256'] = (Get-FileHash $log -Algorithm SHA256).Hash
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeTrue
        $r.Reason | Should -Be 'cleanup_succeeded_failed_zero'
    }

    It 'failed > 0 → 不抑制，但 EvidenceMissing 为 false（有判据）' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'fail.json'
        [System.IO.File]::WriteAllText($log,
            (@{ run_id = $script:runId; summary = @{ failed = 3 } } | ConvertTo-Json -Depth 6))
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_sha256'] = (Get-FileHash $log -Algorithm SHA256).Hash
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeFalse
        $r.EvidenceMissing | Should -BeFalse
        $r.Reason | Should -Be 'cleanup_had_failures'
    }

    It 'summary.failed 非数字（外部畸形 JSON）→ TryParse 兜底，不抛、按证据缺失处理（评审修复）' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'nonnum.json'
        # 手写文本以绕过 ConvertTo-Json，确保 failed 是字符串 "zero"
        [System.IO.File]::WriteAllText($log, ('{"run_id":"' + $script:runId + '","summary":{"failed":"zero"}}'))
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_sha256'] = (Get-FileHash $log -Algorithm SHA256).Hash
        { Get-JournalSuppressionVerdict -Journal $j } | Should -Not -Throw
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeFalse
        $r.EvidenceMissing | Should -BeTrue
        $r.Reason | Should -Be 'summary_failed_not_numeric'
    }

    It 'sha256 指定但实际不匹配 → 拒绝候选，不抑制' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'hash.json'
        [System.IO.File]::WriteAllText($log,
            (@{ run_id = $script:runId; summary = @{ failed = 0 } } | ConvertTo-Json -Depth 6))
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_timestamp'] = '2026-10-03T10:00:00Z'
        $j['cleanup_log_sha256'] = 'deadbeef'
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.RejectCandidate | Should -BeTrue
        $r.Reason | Should -Be 'cleanup_log_sha256_mismatch'
    }

    It 'sha256 指定且实际匹配 → 通过哈希校验，可按 summary.failed 判定' {
        $j = $script:BaseJournal.Clone()
        $log = Join-Path $script:VerdictDir 'hashi.json'
        $content = @{ run_id = $script:runId; summary = @{ failed = 0 } } | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($log, $content)
        $hash = (Get-FileHash $log -Algorithm SHA256).Hash
        $j['cleanup_log_path'] = $log
        $j['cleanup_log_timestamp'] = '2026-10-03T10:00:00Z'
        $j['cleanup_log_sha256'] = $hash
        $r = Get-JournalSuppressionVerdict -Journal $j
        $r.Suppress | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Read-JsonFileSafe：BOM 容忍 / 不存在 / 空 / 不可解析（REQ-019 前置）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Read-JsonFileSafe' {
    BeforeEach {
        $script:SafeDir = Join-Path $env:TEMP ("wrc-safe-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:SafeDir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:SafeDir) { Remove-Item $script:SafeDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '不存在 → $null（不抛）' {
        Read-JsonFileSafe -Path (Join-Path $script:SafeDir 'missing.json') | Should -BeNullOrEmpty
    }

    It '空文件 → $null' {
        $p = Join-Path $script:SafeDir 'empty.json'
        [System.IO.File]::WriteAllText($p, '')
        Read-JsonFileSafe -Path $p | Should -BeNullOrEmpty
    }

    It '不可解析 → $null（不抛）' {
        $p = Join-Path $script:SafeDir 'bad.json'
        [System.IO.File]::WriteAllText($p, '{ not json')
        Read-JsonFileSafe -Path $p | Should -BeNullOrEmpty
    }

    It '带 BOM 的 UTF-8 JSON 能解析（PS 5.1 陷阱：必须显式 UTF8 读）' {
        $p = Join-Path $script:SafeDir 'bom.json'
        $content = '{"a":1}'
        $bytes = ([System.Text.Encoding]::UTF8.GetPreamble() + [System.Text.Encoding]::UTF8.GetBytes($content))
        [System.IO.File]::WriteAllBytes($p, $bytes)
        $o = Read-JsonFileSafe -Path $p
        $o['a'] | Should -Be 1
    }

    It '合法 JSON 正常返回，字段可读' {
        $p = Join-Path $script:SafeDir 'ok.json'
        [System.IO.File]::WriteAllText($p, '{"run_id":"abc","summary":{"failed":0}}')
        $o = Read-JsonFileSafe -Path $p
        $o['run_id'] | Should -Be 'abc'
        # 嵌套的 summary 是 PSCustomObject：其 ['key'] 索引器恒为 null（本文件
        # Get-JournalSuppressionVerdict 修复的同款坑），断言必须用属性访问。
        $o['summary'].failed | Should -Be 0
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-MarkerWellFormed：run_id 必须是合法 guid（REQ-019 Step 1）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Test-MarkerWellFormed' {
    It '$null → false' { Test-MarkerWellFormed -Marker $null | Should -BeFalse }
    It '无 run_id → false' { Test-MarkerWellFormed -Marker @{} | Should -BeFalse }
    It 'run_id 为 null → false' { Test-MarkerWellFormed -Marker @{ run_id = $null } | Should -BeFalse }
    It 'run_id 非 guid → false' { Test-MarkerWellFormed -Marker @{ run_id = 'not-a-guid' } | Should -BeFalse }
    It 'run_id 合法 guid → true' {
        Test-MarkerWellFormed -Marker @{ run_id = [guid]::NewGuid().ToString() } | Should -BeTrue
    }
    It 'run_id 可转成 guid 的字符串 → true（宽松校验）' {
        Test-MarkerWellFormed -Marker @{ run_id = ([guid]::NewGuid().ToString()) } | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-RecoveryCandidateSet：候选收集与剔除（REQ-019 Step 1）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Get-RecoveryCandidateSet' {
    BeforeAll {
        # Pester 5：Describe 主体只在发现阶段执行，辅助函数必须定义在 BeforeAll 才可见
        function script:New-FakeBackup {
            param([string]$Sub, [hashtable]$Journal, [switch]$WithConsumed, [switch]$WithConsumedFailed, [switch]$WithAck)
            $dir = Join-Path $script:ProjRoot $Sub
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if ($null -ne $Journal) {
                [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-journal.json'), ($Journal | ConvertTo-Json -Depth 8))
            }
            if ($WithConsumed) {
                [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-consumed.json'),
                    (@{ run_id = [guid]::NewGuid().ToString() } | ConvertTo-Json -Depth 4))
            }
            if ($WithConsumedFailed) {
                [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-consumed.failed.json'),
                    (@{ run_id = [guid]::NewGuid().ToString() } | ConvertTo-Json -Depth 4))
            }
            if ($WithAck) {
                [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-acknowledged.json'),
                    (@{ run_id = [guid]::NewGuid().ToString() } | ConvertTo-Json -Depth 4))
            }
            return $dir
        }
    }

    BeforeEach {
        $script:ProjRoot = Join-Path $env:TEMP ("wrc-proj-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ProjRoot -Force | Out-Null
        $script:runId = [guid]::NewGuid().ToString()
    }
    AfterEach {
        if (Test-Path $script:ProjRoot) { Remove-Item $script:ProjRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ProjectRoot 不存在 → 返回空集合' {
        # 函数用 return ,$out 防管道展开，调用方不得再包 @()（会把空数组套成 1 个元素）
        (Get-RecoveryCandidateSet -ProjectRoot (Join-Path $script:ProjRoot 'nope')).Count | Should -Be 0
    }

    It '无任何 backup 目录 → 返回空集合' {
        (Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot).Count | Should -Be 0
    }

    It '未完成日志被收集为候选' {
        New-FakeBackup -Sub 'backup-aa' -Journal @{ run_id = $script:runId; completed_at = $null }
        $set = Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot
        $set.Count | Should -Be 1
        $set[0].Journal['run_id'] | Should -Be $script:runId
        $set[0].JournalSource | Should -Be 'rollback-journal.json'
    }

    It 'completed_at 非空 → 剔除（上一轮正常成功）' {
        New-FakeBackup -Sub 'backup-done' -Journal @{ run_id = $script:runId; completed_at = '2026-10-03T10:00:00Z' }
        (Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot).Count | Should -Be 0
    }

    It '存在合法 consumed 标记 → 剔除' {
        New-FakeBackup -Sub 'backup-cons' -Journal @{ run_id = $script:runId; completed_at = $null } -WithConsumed
        (Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot).Count | Should -Be 0
    }

    It '存在合法 acknowledged 标记 → 剔除' {
        New-FakeBackup -Sub 'backup-ack' -Journal @{ run_id = $script:runId; completed_at = $null } -WithAck
        (Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot).Count | Should -Be 0
    }

    It '存在 consumed.failed 标记 → 候选留下，且 RequiresAcknowledgement=true' {
        New-FakeBackup -Sub 'backup-fail' -Journal @{ run_id = $script:runId; completed_at = $null } -WithConsumedFailed
        $set = Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot
        $set.Count | Should -Be 1
        $set[0].RequiresAcknowledgement | Should -BeTrue
    }

    It 'consumed 标记损坏（非 guid）→ 不被视为合法标记，候选仍被收集' {
        $dir = New-FakeBackup -Sub 'backup-badmarker' -Journal @{ run_id = $script:runId; completed_at = $null }
        [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-consumed.json'), '{"run_id":"nope"}')
        $set = Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot
        $set.Count | Should -Be 1
        $set[0].RequiresAcknowledgement | Should -BeFalse
    }

    It '主文件缺失但 .prev 存在 → 从 .prev 读并标注来源' {
        $dir = New-FakeBackup -Sub 'backup-prev'
        [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-journal.prev.json'),
            (@{ run_id = $script:runId; completed_at = $null } | ConvertTo-Json -Depth 8))
        $set = Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot
        $set.Count | Should -Be 1
        $set[0].JournalSource | Should -Be 'rollback-journal.prev.json'
    }

    It '主文件与 .prev 都缺失 → 不产生候选（跳过）' {
        New-FakeBackup -Sub 'backup-empty'
        (Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot).Count | Should -Be 0
    }

    It '两个未完成候选都被收集' {
        New-FakeBackup -Sub 'backup-x1' -Journal @{ run_id = [guid]::NewGuid().ToString(); completed_at = $null }
        New-FakeBackup -Sub 'backup-x2' -Journal @{ run_id = [guid]::NewGuid().ToString(); completed_at = $null }
        (Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot).Count | Should -Be 2
    }

    It '主文件存在但损坏且 .prev 完好 → 回退读 .prev，但强制需确认（评审修复）' {
        $dir = New-FakeBackup -Sub 'backup-broken-prev' -Journal @{ run_id = $script:runId; completed_at = $null }
        [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-journal.json'), '{ broken')
        [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-journal.prev.json'),
            (@{ run_id = $script:runId; completed_at = $null } | ConvertTo-Json -Depth 8))
        $set = Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot
        $set.Count | Should -Be 1
        $set[0].JournalSource | Should -Be 'rollback-journal.prev.json'
        # 主文件其实存在（只是损坏）→ .prev 可能是陈旧未完成视图，必须要求人工确认，禁止静默自动 T3。
        $set[0].RequiresAcknowledgement | Should -BeTrue
    }

    It '主文件缺失且 .prev 为未完成 → 正常收集且不强制确认（合法的首次写入崩溃形态）' {
        $dir = New-FakeBackup -Sub 'backup-missing-prev' -Journal @{ run_id = $script:runId; completed_at = $null }
        Remove-Item (Join-Path $dir 'rollback-journal.json') -Force
        [System.IO.File]::WriteAllText((Join-Path $dir 'rollback-journal.prev.json'),
            (@{ run_id = $script:runId; completed_at = $null } | ConvertTo-Json -Depth 8))
        $set = Get-RecoveryCandidateSet -ProjectRoot $script:ProjRoot
        $set.Count | Should -Be 1
        $set[0].JournalSource | Should -Be 'rollback-journal.prev.json'
        $set[0].RequiresAcknowledgement | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Select-RecoveryCandidate：唯一消费 + 并列歧义（REQ-019 / exit 14(c)）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Select-RecoveryCandidate' {
    BeforeAll {
        # Pester 5：辅助函数必须定义在 BeforeAll，否则 It 运行时不可见
        function script:New-Cand { param($Id, $CreatedAt)
            @{ Journal = @{ run_id = $Id; created_at = $CreatedAt } }
        }
    }

    It '空候选集 → no_candidate' {
        $r = Select-RecoveryCandidate -Candidates @()
        $r.Selected | Should -BeNullOrEmpty
        $r.Ambiguous | Should -BeFalse
        $r.Reason | Should -Be 'no_candidate'
    }

    It '单个候选 → 选中它' {
        $c = New-Cand 'a' '2026-10-03T10:00:00Z'
        $r = Select-RecoveryCandidate -Candidates @($c)
        $r.Selected | Should -Be $c
        $r.Reason | Should -Be 'ok'
    }

    It '多个候选 → 取 created_at 最新者，其余为 Others' {
        $old = New-Cand 'old' '2026-10-02T10:00:00Z'
        $new = New-Cand 'new' '2026-10-03T10:00:00Z'
        $r = Select-RecoveryCandidate -Candidates @($old, $new)
        $r.Selected.Journal.run_id | Should -Be 'new'
        @($r.Others).Count | Should -Be 1
        $r.Others[0].Journal.run_id | Should -Be 'old'
        $r.Ambiguous | Should -BeFalse
    }

    It 'created_at 并列 → 歧义，不选中任何（exit 14(c)）' {
        $c1 = New-Cand 'tie1' '2026-10-03T10:00:00Z'
        $c2 = New-Cand 'tie2' '2026-10-03T10:00:00Z'
        $r = Select-RecoveryCandidate -Candidates @($c1, $c2)
        $r.Selected | Should -BeNullOrEmpty
        $r.Ambiguous | Should -BeTrue
        $r.Reason | Should -Be 'created_at_tie'
    }

    It 'created_at 全部不可解析 → 不自作主张，Reason=created_at_unparsable' {
        $c1 = New-Cand 'x' 'garbage'
        $c2 = New-Cand 'y' $null
        $r = Select-RecoveryCandidate -Candidates @($c1, $c2)
        $r.Selected | Should -BeNullOrEmpty
        $r.Reason | Should -Be 'created_at_unparsable'
    }

    It '最新者可解析 + 其余不可解析 → 选中最新者，不可解析者进 Others' {
        $new = New-Cand 'new' '2026-10-03T10:00:00Z'
        $bad = New-Cand 'bad' 'garbage'
        $r = Select-RecoveryCandidate -Candidates @($new, $bad)
        $r.Selected.Journal.run_id | Should -Be 'new'
        @($r.Others).Count | Should -Be 1
        $r.Others[0].Journal.run_id | Should -Be 'bad'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-JournalIsStaleOrForeign：外来机器 / 已消费（REQ-019 首段）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Test-JournalIsStaleOrForeign' {
    BeforeEach {
        $script:FBDir = Join-Path $env:TEMP ("wrc-fb-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FBDir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:FBDir) { Remove-Item $script:FBDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '本机指纹一致且未消费 → 无理由' {
        $j = @{ run_id = [guid]::NewGuid().ToString(); machine_fingerprint = 'FP' }
        @(Test-JournalIsStaleOrForeign -Journal $j -BackupDir $script:FBDir -MachineFingerprint 'FP').Count | Should -Be 0
    }

    It '指纹来自其它机器 → 记为 foreign_machine' {
        $j = @{ run_id = [guid]::NewGuid().ToString(); machine_fingerprint = 'OTHER' }
        $r = @(Test-JournalIsStaleOrForeign -Journal $j -BackupDir $script:FBDir -MachineFingerprint 'MINE')
        $r | Should -Contain 'journal_from_foreign_machine'
    }

    It '存在合法 consumed 标记 → 记为 already_consumed' {
        [System.IO.File]::WriteAllText((Join-Path $script:FBDir 'rollback-consumed.json'),
            (@{ run_id = [guid]::NewGuid().ToString() } | ConvertTo-Json -Depth 4))
        $j = @{ run_id = [guid]::NewGuid().ToString() }
        $r = @(Test-JournalIsStaleOrForeign -Journal $j -BackupDir $script:FBDir)
        $r | Should -Contain 'already_consumed'
    }

    It '未传 MachineFingerprint → 不判断指纹（允许）' {
        $j = @{ run_id = [guid]::NewGuid().ToString() }
        @(Test-JournalIsStaleOrForeign -Journal $j -BackupDir $script:FBDir).Count | Should -Be 0
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Write-RecoveryMarker：原子写消费/确认标记（REQ-019 Step 4a）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Write-RecoveryMarker' {
    BeforeEach {
        $script:MarkerDir = Join-Path $env:TEMP ("wrc-marker-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:MarkerDir -Force | Out-Null
        $script:runId = [guid]::NewGuid().ToString()
    }
    AfterEach {
        if (Test-Path $script:MarkerDir) { Remove-Item $script:MarkerDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'consumed 写出 rollback-consumed.json 并带 consumed_at' {
        $p = Write-RecoveryMarker -BackupDir $script:MarkerDir -Kind 'consumed' -RunId $script:runId -Timestamp '2026-10-03T10:00:00Z'
        Test-Path $p | Should -BeTrue
        (Split-Path $p -Leaf) | Should -Be 'rollback-consumed.json'
        # 断言原始 JSON 文本而非 ConvertFrom-Json 后的值：pwsh 7 会把 ISO 串解析成
        # [datetime] 再序列化出小数秒（AGENTS.md 双引擎断言教训）
        $raw = Get-Content $p -Raw
        $raw | Should -Match ('"run_id":\s*"' + [regex]::Escape($script:runId))
        $raw | Should -Match '"consumed_at":\s*"2026-10-03T10:00:00Z"'
        $raw | Should -Not -Match 'failed_at'
    }

    It 'consumed.failed 写出 rollback-consumed.failed.json 并带 failed_at' {
        $p = Write-RecoveryMarker -BackupDir $script:MarkerDir -Kind 'consumed.failed' -RunId $script:runId -Timestamp '2026-10-03T11:00:00Z'
        (Split-Path $p -Leaf) | Should -Be 'rollback-consumed.failed.json'
        $raw = Get-Content $p -Raw
        $raw | Should -Match '"failed_at":\s*"2026-10-03T11:00:00Z"'
        $raw | Should -Not -Match 'consumed_at'
    }

    It 'acknowledged 写出 rollback-acknowledged.json' {
        $p = Write-RecoveryMarker -BackupDir $script:MarkerDir -Kind 'acknowledged' -RunId $script:runId -Timestamp '2026-10-03T12:00:00Z'
        (Split-Path $p -Leaf) | Should -Be 'rollback-acknowledged.json'
    }

    It '未传 Timestamp → 自动生成可解析的 UTC 串' {
        $p = Write-RecoveryMarker -BackupDir $script:MarkerDir -Kind 'consumed' -RunId $script:runId
        $o = Get-Content $p -Raw | ConvertFrom-Json
        $tmp = [datetime]::MinValue
        [datetime]::TryParse([string]$o.consumed_at, [ref]$tmp) | Should -BeTrue
    }

    It 'run_id 非 guid → 抛错（不得写出非法标记）' {
        { Write-RecoveryMarker -BackupDir $script:MarkerDir -Kind 'consumed' -RunId 'not-a-guid' } |
            Should -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Add-UnrepairedItem：累积未修复清单（REQ-031）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Add-UnrepairedItem' {
    It '从空表新增一条' {
        $l = Add-UnrepairedItem -List @() -ItemId 'i1' -Reason 'skipped_older_journal'
        @($l).Count | Should -Be 1
        $l[0]['item_id'] | Should -Be 'i1'
        $l[0]['reason'] | Should -Be 'skipped_older_journal'
    }

    It '追加到已有列表，不原地修改原数组' {
        $base = @(Add-UnrepairedItem -List @() -ItemId 'a' -Reason 'r1')
        $l = Add-UnrepairedItem -List $base -ItemId 'b' -Reason 'r2'
        @($base).Count | Should -Be 1
        @($l).Count | Should -Be 2
        $l[1]['item_id'] | Should -Be 'b'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Write-UnrepairedList：落盘到 output/rollback-unrepaired-<run_id>.json（REQ-031）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Write-UnrepairedList' {
    BeforeEach {
        $script:URRoot = Join-Path $env:TEMP ("wrc-ur-" + [guid]::NewGuid().ToString('N'))
        $script:runId = [guid]::NewGuid().ToString()
    }
    AfterEach {
        if (Test-Path $script:URRoot) { Remove-Item $script:URRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '写出文件于 output 子目录，且字段完整、items 为数组' {
        $items = @(@{ item_id = 'i1'; reason = 'skipped_older_journal' })
        $p = Write-UnrepairedList -ProjectRoot $script:URRoot -RunId $script:runId -Items $items -Reason 'partial' -CreatedAt '2026-10-03T10:00:00Z'
        Test-Path $p | Should -BeTrue
        [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($p)) | Should -Be 'output'
        (Split-Path $p -Leaf) | Should -Be "rollback-unrepaired-$($script:runId).json"
        # 断言原始 JSON 文本：pwsh 7 的 ConvertFrom-Json 会把 ISO 串解析成 [datetime]
        # 再序列化出小数秒（AGENTS.md 双引擎断言教训）
        $raw = Get-Content $p -Raw
        $raw | Should -Match ('"run_id":\s*"' + [regex]::Escape($script:runId))
        $raw | Should -Match '"reason":\s*"partial"'
        $raw | Should -Match '"created_at":\s*"2026-10-03T10:00:00Z"'
        $raw | Should -Match '"item_id":\s*"i1"'
    }

    It 'items 为空数组 → 写出空数组而非空对象（PS 5.1 陷阱）' {
        $p = Write-UnrepairedList -ProjectRoot $script:URRoot -RunId $script:runId -Items @() -Reason 'none' -CreatedAt '2026-10-03T10:00:00Z'
        # 直接断言原始文本里 items 是 []，而不是 {}（空对象）。ConvertFrom-Json 后
        # 空数组在管道中展开为 0 个元素，无法用 -BeOfType 断言。
        $raw = Get-Content $p -Raw
        $raw | Should -Match '"items":\s*\[\s*\]'
    }

    It '未传 CreatedAt → 自动生成可解析 UTC' {
        $p = Write-UnrepairedList -ProjectRoot $script:URRoot -RunId $script:runId -Items @() -Reason 'x'
        $o = Get-Content $p -Raw | ConvertFrom-Json
        $tmp = [datetime]::MinValue
        [datetime]::TryParse([string]$o.created_at, [ref]$tmp) | Should -BeTrue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Complete-RollbackJournal：给日志写 completed_at（REQ-031）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Complete-RollbackJournal' {
    BeforeEach {
        $script:CompDir = Join-Path $env:TEMP ("wrc-comp-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:CompDir -Force | Out-Null
        $script:runId = [guid]::NewGuid().ToString()
    }
    AfterEach {
        if (Test-Path $script:CompDir) { Remove-Item $script:CompDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '正常完成：写回 completed_at 且返回 Path' {
        $j = @{ run_id = $script:runId; completed_at = $null }
        $r = Complete-RollbackJournal -BackupDir $script:CompDir -Journal $j -CompletedAt '2026-10-03T10:00:00Z'
        $r.Written | Should -BeTrue
        $r.CompletedAt | Should -Be '2026-10-03T10:00:00Z'
        Test-Path $r.Path | Should -BeTrue
        # 日志文件已落盘
        Test-Path (Join-Path $script:CompDir 'rollback-journal.json') | Should -BeTrue
    }

    It '-Skip 时不写，返回 Written=false 与原因（exit 11 语义）' {
        $j = @{ run_id = $script:runId; completed_at = $null }
        $r = Complete-RollbackJournal -BackupDir $script:CompDir -Journal $j -Skip -SkipReason 'unrepaired_items'
        $r.Written | Should -BeFalse
        $r.Reason | Should -Be 'unrepaired_items'
        Test-Path (Join-Path $script:CompDir 'rollback-journal.json') | Should -BeFalse
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-WithinRecoveryWindow：24h 窗口判定（REQ-024）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Test-WithinRecoveryWindow' {
    It '24h 内 → within' {
        $now = [datetime]::new(2026, 10, 4, 10, 0, 0, [DateTimeKind]::Utc)
        $r = Test-WithinRecoveryWindow -CreatedAt '2026-10-03T11:00:00Z' -Now $now
        $r.Within | Should -BeTrue
        $r.Reason | Should -Be 'within_window'
        $r.ElapsedHours | Should -BeLessThan 24
    }

    It '恰好 24h → 视为超窗（非 strict-less）' {
        $now = [datetime]::new(2026, 10, 4, 10, 0, 0, [DateTimeKind]::Utc)
        $r = Test-WithinRecoveryWindow -CreatedAt '2026-10-03T10:00:00Z' -Now $now
        $r.Within | Should -BeFalse
        $r.Reason | Should -Be 'window_exceeded'
    }

    It '超过 24h → 超窗' {
        $now = [datetime]::new(2026, 10, 6, 10, 0, 0, [DateTimeKind]::Utc)
        $r = Test-WithinRecoveryWindow -CreatedAt '2026-10-03T10:00:00Z' -Now $now
        $r.Within | Should -BeFalse
    }

    It 'created_at 不可解析 → 超窗（安全保守）' {
        $r = Test-WithinRecoveryWindow -CreatedAt 'garbage' -Now (Get-Date)
        $r.Within | Should -BeFalse
        $r.Reason | Should -Be 'created_at_unparsable'
    }

    It 'created_at 在未来（时钟回拨/篡改）→ 判为不在窗口，不得靠负 elapsed 无限延长（评审修复）' {
        $now = [datetime]::new(2026, 10, 6, 10, 0, 0, [DateTimeKind]::Utc)
        $future = $now.AddHours(5).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $r = Test-WithinRecoveryWindow -CreatedAt $future -Now $now
        $r.Within | Should -BeFalse
        $r.Reason | Should -Be 'created_at_in_future'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-ParentBaselineMax：注册表类条目 parent_baseline 聚合（REQ-024 迹象 ii）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Get-ParentBaselineMax' {
    It '无条目 → $null' {
        Get-ParentBaselineMax -Journal @{} | Should -BeNullOrEmpty
    }

    It '忽略非注册表条目（其 parent_baseline 为 null）' {
        $j = @{ entries = @(
            @{ kind = 'path_deleted'; parent_baseline = $null }
        ) }
        Get-ParentBaselineMax -Journal $j | Should -BeNullOrEmpty
    }

    It '取注册表类条目 parent_baseline 的最大值' {
        $j = @{ entries = @(
            @{ kind = 'registry_key'; parent_baseline = '2026-10-03T10:00:00Z' },
            @{ kind = 'registry_key'; parent_baseline = '2026-10-03T12:00:00Z' },
            @{ kind = 'path_deleted'; parent_baseline = $null },
            @{ kind = 'startup_value'; parent_baseline = '2026-10-03T09:00:00Z' }
        ) }
        $m = Get-ParentBaselineMax -Journal $j
        # 比较 UTC 时刻：Get-ParentBaselineMax 现返回 Kind=Utc（ConvertFrom-IsoUtc），
        # 而 [datetime]'...Z' 字面量会被解析成 Kind=Local，直接 -Be 会因 Kind 差异误判。
        $m.ToUniversalTime() | Should -Be ([datetime]'2026-10-03T12:00:00Z').ToUniversalTime()
    }

    It '跳过不可解析的 parent_baseline，不把它当 0' {
        $j = @{ entries = @(
            @{ kind = 'registry_key'; parent_baseline = 'garbage' }
        ) }
        Get-ParentBaselineMax -Journal $j | Should -BeNullOrEmpty
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Test-ExternalChangeSignRegistry：注册表父键时间戳迹象（REQ-024 迹象 ii）
# ─────────────────────────────────────────────────────────────────────────────

Describe 'S2 Test-ExternalChangeSignRegistry' {
    It '无基线 → Undecidable，不判外部变更' {
        $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software')
        try {
            $r = Test-ExternalChangeSignRegistry -ParentKey $rk -BaselineMax $null
            $r.Detected | Should -BeFalse
            $r.Undecidable | Should -BeTrue
            $r.Reason | Should -Be 'no_baseline'
        } finally { $rk.Close() }
    }

    It '基线在未来（父键时间戳未晚于基线）→ 无外部变更' {
        $probe = 'Software\WRC_RegSign_' + [guid]::NewGuid().ToString('N')
        try {
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($probe)
            $k.SetValue('M', '1'); $k.Close()
            $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($probe)
            $future = (Get-Date).AddYears(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $r = Test-ExternalChangeSignRegistry -ParentKey $rk -BaselineMax $future
            $r.Detected | Should -BeFalse
            $r.Undecidable | Should -BeFalse
        } finally {
            $rk.Close()
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($probe, $false) 2>$null
        }
    }

    It '真实键始终能取到时间戳（P/Invoke 生效），BaselineMax 为过去时检测到变更' {
        $probe = 'Software\WRC_RegSign2_' + [guid]::NewGuid().ToString('N')
        try {
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($probe)
            $k.SetValue('M', '1'); $k.Close()
            $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($probe)
            $past = (Get-Date).AddYears(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            $r = Test-ExternalChangeSignRegistry -ParentKey $rk -BaselineMax $past
            $r.Detected | Should -BeTrue
            $r.Reason | Should -Be 'parent_key_changed_after_baseline'
        } finally {
            $rk.Close()
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($probe, $false) 2>$null
        }
    }
}
