# rollback-recovery.ps1
# T3「下次启动时恢复」的候选发现、抑制判定与消费（REQ-016 / REQ-019 / REQ-031 / REQ-033）
#
# 本文件只放顶层可测函数，不含 Main、不含 exit（ADR-001）。

# ─────────────────────────────────────────────────────────────────────────────
# 旁路标记（REQ-019 Step 1）
# ─────────────────────────────────────────────────────────────────────────────

function Read-JsonFileSafe {
    <#
    .SYNOPSIS
        安全读 JSON：不存在或不可解析都返回 $null（不抛）。BOM 容忍。
    .DESCRIPTION
        Delphi 网关/reg export 的经历说明：外部产出的 JSON 常带 BOM，
        PS 5.1 下必须显式按 UTF8 读，否则首字符会变成 U+FEFF 导致解析失败。
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
        return ConvertFrom-RollbackJournalText -Text $txt
    } catch {
        return $null
    }
}

function Test-MarkerWellFormed {
    <#
    .SYNOPSIS
        判定一个旁路标记对象是否「可解析且格式合法」。
    .DESCRIPTION
        REQ-019 Step 1：不存在的、或存在但不可解析/格式非法的旁路文件
        一律**视为不存在**。理由：不能因为一个损坏的旁路文件就跳过本该执行的 T3 恢复
        ——那会把「强制恢复」变成「一个坏文件就能绕过」。
        run_id 字段存在且是合法 guid 才算格式合法。
    #>
    param($Marker)

    if ($null -eq $Marker) { return $false }
    if (-not $Marker.ContainsKey('run_id')) { return $false }
    $rid = $Marker['run_id']
    if ($null -eq $rid) { return $false }
    $g = [guid]::Empty
    if (-not [guid]::TryParse([string]$rid, [ref]$g)) { return $false }
    return $true
}

function Test-MarkerBelongsToJournal {
    <#
    .SYNOPSIS
        旁路标记是否「格式合法」且其 run_id 与这份日志一致（评审修复）。
    .DESCRIPTION
        仅格式合法不足以剔除候选：一份从别处复制来的、或写错目录的合法 GUID 标记，
        会把一个本应恢复的候选永久踢出集合。标记必须绑定到它声称代表的那次运行——
        与清理日志哈希/run_id 绑定同理（未绑定的证据不得用于抑制恢复）。
    #>
    param($Marker, [hashtable]$Journal)

    if (-not (Test-MarkerWellFormed -Marker $Marker)) { return $false }
    $journalRunId = [string]$Journal['run_id']
    $markerRunId = [string]$Marker['run_id']
    if ([string]::IsNullOrWhiteSpace($journalRunId)) { return $false }
    return ($markerRunId -eq $journalRunId)
}

function Get-CompletedAtState {
    <#
    .SYNOPSIS
        把 completed_at 归一为三态之一：'done' / 'unfinished' / 'malformed'。
    .DESCRIPTION
        「唯一未完成判据」要求严格区分三种情形（评审修复）：
          - $null / 键缺失            → 'unfinished'（正常 T3 路径）
          - 可解析的 ISO UTC 时间戳   → 'done'（本轮已正常结束，剔除）
          - 其余（空白串、损坏/篡改值）→ 'malformed'（既非完成也非干净未完成，须上报拒绝，
                                        绝不能被当作完成而静默剔除，也不能被当作未完成而重装内容）
        旧代码用「非空即完成」把后两类混进 'done'，导致损坏的 completed_at 永久阻断恢复；
        另一处又把空白串当未完成，可能触发对已完成运行的重装。
    #>
    param($CompletedAt)

    if ($null -eq $CompletedAt) { return 'unfinished' }
    # 传原始对象给 ConvertFrom-IsoUtc：pwsh7 下 completed_at 可能是 [DateTime]（ConvertFrom-Json
    # 解析所致），[string] 化会丢 Z 被误判 malformed。仅对字符串才做空白判定。
    if ($CompletedAt -isnot [datetime] -and [string]::IsNullOrWhiteSpace([string]$CompletedAt)) { return 'malformed' }
    if ($null -ne (ConvertFrom-IsoUtc -Text $CompletedAt)) { return 'done' }
    return 'malformed'
}

function Get-RecoveryCandidateSet {
    <#
    .SYNOPSIS
        Step 1：扫描 backup-* 目录，收集候选并剔除已完成者（REQ-019）。
    .DESCRIPTION
        固定顺序中的 Step 1。剔除条件是「已完成」：
          - completed_at 非空；或
          - 存在可解析且格式合法的 rollback-consumed.json；或
          - 存在可解析且格式合法的 rollback-acknowledged.json。
        关键的第二个闸门：若存在可解析且格式合法的 rollback-consumed.failed.json，
        该候选仍留在集合里，但被标记 RequiresAcknowledgement = $true —— 它**不得**
        自动消费，必须由调用方拿到 -AcknowledgeConflicts 显式确认后才继续。
        没有这道闸门，下次运行会直接重新消费它，AC-053/AC-089 的断言就不成立。

        为什么必须先剔除已完成者：否则上一轮**正常成功**留下的日志会被当成候选，
        在 Step 3 因 completed_at 非空而自证失败，使 Step 4b 让此后每一次清理都返回 14,
        整个工具再也无法运行。

        解析失败的旁路文件**只影响是否剔除**，在本函数内**绝不改写或删除**——
        它是取证材料。改写只发生在确实要写标记的那一刻。
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$BackupDirPattern = 'backup-*'
    )

    $out = @()
    if (-not (Test-Path -LiteralPath $ProjectRoot)) { return , $out }

    $dirs = @(Get-ChildItem -LiteralPath $ProjectRoot -Filter $BackupDirPattern -Directory -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        $journalPath = Join-Path $d.FullName 'rollback-journal.json'
        $prevPath = Join-Path $d.FullName 'rollback-journal.prev.json'

        $journal = $null
        $source = 'rollback-journal.json'
        # 主文件存在但不可解析（而非缺失）时，回退读到的 .prev 可能是「上一代未完成」的
        # 陈旧视图——File.Replace 会把完成前的那一代留在 .prev。若主日志其实已完成、只是
        # 当前损坏，直接用陈旧的 .prev 走自动 T3 会把已完成的运行误当未完成而重装内容。
        # 因此：主文件存在却只能靠 .prev 恢复 → 强制 RequiresAcknowledgement，禁止静默自动恢复。
        $primaryCorrupt = $false
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
            $journal = Read-JsonFileSafe -Path $journalPath
            if ($null -eq $journal) { $primaryCorrupt = $true }
        }
        # 主文件缺失，或存在但不可解析（写入过程中崩溃的形态）→ 回退读 .prev。
        # 与 Read-RollbackJournal 的回退语义保持一致：否则一份损坏的主日志会让
        # 本可恢复的候选被永久忽略（评审意见：候选发现必须复用同样的 .prev 回退）。
        if ($null -eq $journal -and (Test-Path -LiteralPath $prevPath -PathType Leaf)) {
            $journal = Read-JsonFileSafe -Path $prevPath
            $source = 'rollback-journal.prev.json'
        }
        if ($null -eq $journal) { continue }

        # 已完成 → 剔除。仅当 completed_at 是合法时间戳才算完成；损坏/空白值不得被当作
        # 「完成」而静默永久剔除（评审修复）——保留为候选并标记需确认，交自证上报拒绝。
        $completedState = Get-CompletedAtState -CompletedAt $journal['completed_at']
        if ($completedState -eq 'done') { continue }
        $completedMalformed = ($completedState -eq 'malformed')

        $consumedMarker = Read-JsonFileSafe -Path (Join-Path $d.FullName 'rollback-consumed.json')
        if (Test-MarkerBelongsToJournal -Marker $consumedMarker -Journal $journal) { continue }

        $ackMarker = Read-JsonFileSafe -Path (Join-Path $d.FullName 'rollback-acknowledged.json')
        if (Test-MarkerBelongsToJournal -Marker $ackMarker -Journal $journal) { continue }

        # 第二道闸门：此前「尝试消费但标记都写失败」。同样必须绑定 run_id（评审修复）。
        $failedMarker = Read-JsonFileSafe -Path (Join-Path $d.FullName 'rollback-consumed.failed.json')

        $out += , @{
            BackupDir              = $d.FullName
            BackupDirName          = $d.Name
            JournalPath            = if ($source -eq 'rollback-journal.json') { $journalPath } else { $prevPath }
            JournalSource          = $source
            Journal                = $journal
            RequiresAcknowledgement = ((Test-MarkerBelongsToJournal -Marker $failedMarker -Journal $journal) -or $primaryCorrupt -or $completedMalformed)
        }
    }

    return , $out
}

function Select-RecoveryCandidate {
    <#
    .SYNOPSIS
        从候选集中选出**唯一**要消费的那一份（REQ-019 / exit 14(c)）。
    .DESCRIPTION
        多个未完成候选时无法安全判断该恢复哪一个：
          - created_at 出现并列（时间戳相同）→ exit 14(c)；
          - 多个未完成日志但 created_at 唯一可排序 → 取**最新**的一份消费，
            其余在 Step 4a 写入未修复清单（reason: skipped_older_journal）后
            标记 consumed_with_failure。
        注意：不能「全都恢复」——多份日志可能对同一目标记录相反的删除意图，
        一起执行结果不确定。
        返回 @{ Selected = <candidate or $null>; Others = @(); Ambiguous = bool; Reason = string }
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Candidates)

    if ($Candidates.Count -eq 0) {
        return @{ Selected = $null; Others = @(); Ambiguous = $false; Reason = 'no_candidate' }
    }

    # 按 created_at 解析排序；不可解析的排到最后（不能静默当作最新）
    $sortable = @()
    $unparsable = @()
    foreach ($c in $Candidates) {
        $dt = ConvertFrom-IsoUtc -Text $c.Journal['created_at']
        if ($null -ne $dt) {
            $sortable += , @{ Cand = $c; Created = $dt }
        } else {
            $unparsable += , $c
        }
    }

    if ($sortable.Count -eq 0) {
        # 全部不可解析：交给 Step 3 自证拒绝，不在这里臆断
        return @{ Selected = $null; Others = @($Candidates); Ambiguous = $false; Reason = 'created_at_unparsable' }
    }

    # 混合形态（部分可排序、部分 created_at 损坏）：损坏者其实可能是最新的一份，
    # 把它默默排到有效者之后并据有效者恢复，等于在「无法判定谁最新」时贸然改动系统。
    # 与并列同理判为歧义，要求显式确认，绝不静默选边（评审修复）。
    if ($unparsable.Count -gt 0) {
        return @{ Selected = $null; Others = @($Candidates); Ambiguous = $true; Reason = 'created_at_partially_unparsable' }
    }

    # 排序键必须用脚本块取，不能写 `-Property Created`：Sort-Object 的属性解析走标准对象
    # 适配，**不认 hashtable 的键**（实测 PS 5.1：@{ Cand=…; Created=<datetime> } 上
    # `-Property Created` 把所有元素视为相等，于是 -Descending 退化成了「原序反转」，
    # 选出来的是**最旧**的一份日志）。方向选反的后果不是 cosmetic：REQ-019/AC-046 要求
    # 只回滚紧邻的上一轮，恢复陈旧日志会把用户后来主动删掉的内容装回去。
    $sorted = @($sortable | Sort-Object -Property { $_.Created } -Descending)
    $newest = $sorted[0]

    # 并列检测：与最新者 created_at 完全相同的其它候选
    $ties = @($sorted | Where-Object { $_.Created -eq $newest.Created })
    if ($ties.Count -gt 1) {
        return @{ Selected = $null; Others = @($Candidates); Ambiguous = $true; Reason = 'created_at_tie' }
    }

    $others = @()
    foreach ($s in $sorted) { if ($s.Cand -ne $newest.Cand) { $others += , $s.Cand } }
    foreach ($u in $unparsable) { $others += , $u }

    return @{ Selected = $newest.Cand; Others = $others; Ambiguous = $false; Reason = 'ok' }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2.5 抑制判定（REQ-019 / REQ-031）
# ─────────────────────────────────────────────────────────────────────────────

function Get-JournalSuppressionVerdict {
    <#
    .SYNOPSIS
        Step 2.5：只**判定**「本轮清理其实已正常结束」，不写任何标记（REQ-019）。
    .DESCRIPTION
        返回 @{ Suppress = bool; EvidenceMissing = bool; RejectCandidate = bool; Reason = string }

        **抑制 ≠ 消费**：本函数绝不写 completed_at、绝不写任何标记。
        消费只发生在 Step 3 自证通过之后。若在验证前就消费，
        一份自证失败的日志会被永久绕过（REQ-027 的保证失效）。

        必须先做模式检查：cleanup_log_* 三字段若不是「同 null 或同非 null」
        （违反 AC-083），该候选直接交给 Step 3 拒绝，**绝不进入任何抑制分支**——
        否则一份模式非法的日志可能在被 Step 3 拒绝之前先被「抑制」放行。

        分级证据（不要求齐全，否则日志一被删抑制就永不触发，REQ-031 的兜底形同虚设）：
          ① 文件存在且可读 → 校验哈希（非 null 时必须匹配）与 run_id 一致；
             两者都过才可抑制。哈希不匹配 → 拒绝该候选，不进抑制分支。
          ② 文件已不存在 → 一律不拒绝、也不据其抑制。
             **必须明说的后果**：若该日志其实是「清理成功但标记丢失」的路径，
             它不会被抑制，而是交 Step 3 自证；自证通过后按正常 T3 恢复，
             即**可能把刚清理掉的内容装回去**。这是已知且接受的残留风险
             （与 DD-018 同源），换取「不因一个被删的日志就永久拒绝恢复」。
             此时 EvidenceMissing = $true，报告必须如实标注「抑制依据缺失」。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [string]$CleanupLogPathOverride
    )

    $res = @{ Suppress = $false; EvidenceMissing = $false; RejectCandidate = $false; Reason = '' }

    $clp = $Journal['cleanup_log_path']
    $clt = $Journal['cleanup_log_timestamp']
    $cls = $Journal['cleanup_log_sha256']

    # 模式检查（AC-083）：逐字段显式判「缺失」（@($null,$null,$null) 的 Count 是 1，不能用计数）。
    # 「缺失」= $null 或全空白：下游哈希/时间戳校验都用 IsNullOrWhiteSpace 判定是否可校验，
    # 若此处只认 $null，则 cleanup_log_sha256='' 会被当作「已存在」通过模式检查、却在哈希校验里
    # 被跳过，导致仅凭 run_id 抑制恢复——即未绑定证据抑制了本应执行的恢复（评审修复）。
    $missingCount = 0
    if ($null -eq $clp -or [string]::IsNullOrWhiteSpace([string]$clp)) { $missingCount++ }
    if ($null -eq $clt -or [string]::IsNullOrWhiteSpace([string]$clt)) { $missingCount++ }
    if ($null -eq $cls -or [string]::IsNullOrWhiteSpace([string]$cls)) { $missingCount++ }
    if ($missingCount -ne 0 -and $missingCount -ne 3) {
        $res.RejectCandidate = $true
        $res.Reason = 'cleanup_log_fields_pattern_invalid'
        return $res
    }

    $path = $clp
    if (-not [string]::IsNullOrWhiteSpace($CleanupLogPathOverride)) { $path = $CleanupLogPathOverride }

    # 用外部 override 指向的日志、且这份日志本身未记录 cleanup_log_sha256（崩溃发生在写证据之前）：
    # 没有日志侧哈希可绑定，但清理日志仍以 run_id 绑定。此时仍遵循首要安全不变量——
    # 「completed_at 为 null 且清理日志存在且 summary.failed==0 → 抑制」：failed==0 表示恢复并不
    # 需要，据 run_id 绑定的证据抑制是安全的；反之若 failed>0 或判据缺失则不得凭未绑定哈希去抑制
    # 可能需要的恢复。故这里不提前返回，交由下方 run_id + summary.failed 判定决定（评审修复：
    # 修正上一版把该路径一律打成 EvidenceMissing→NormalT3、反而重装刚删内容的问题）。

    # ② 无路径可用 → 读不到日志就没有判据
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        $res.EvidenceMissing = $true
        $res.Reason = 'no_cleanup_log_path'
        return $res
    }

    $p = [string]$path
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        # ② 文件已不存在：不拒绝、不抑制，交 Step 3
        $res.EvidenceMissing = $true
        $res.Reason = 'cleanup_log_missing'
        return $res
    }

    # ① 文件存在且可读：先校验哈希与 run_id，两者都过才可抑制
    $actualHash = Get-Sha256Hex -Path $p
    if ($null -ne $cls -and -not [string]::IsNullOrWhiteSpace([string]$cls)) {
        if ($null -eq $actualHash -or $actualHash -ne [string]$cls) {
            $res.RejectCandidate = $true
            $res.Reason = 'cleanup_log_sha256_mismatch'
            return $res
        }
    }

    $logObj = Read-JsonFileSafe -Path $p
    if ($null -eq $logObj) {
        # 文件在但不可解析：读不到判据，按证据缺失处理（不抑制）
        $res.EvidenceMissing = $true
        $res.Reason = 'cleanup_log_unparsable'
        return $res
    }

    # run_id 绑定：必须确认该清理日志属于这份日志本身（REQ-033）
    $journalRunId = [string]$Journal['run_id']
    $logRunId = $logObj['run_id']
    if ($null -ne $logRunId -and -not [string]::IsNullOrWhiteSpace([string]$logRunId)) {
        if ([string]$logRunId -ne $journalRunId) {
            $res.RejectCandidate = $true
            $res.Reason = 'cleanup_log_run_id_mismatch'
            return $res
        }
    } else {
        # 清理日志没有 run_id（旧格式）：无法证明归属，不得据此抑制
        $res.EvidenceMissing = $true
        $res.Reason = 'cleanup_log_run_id_absent'
        return $res
    }

    # 唯一判据：summary.failed == 0
    $summary = $logObj['summary']
    if ($null -eq $summary) {
        $res.EvidenceMissing = $true
        $res.Reason = 'summary_absent'
        return $res
    }

    # 归一化为 hashtable：ConvertFrom-Json 产出的嵌套 summary 是 PSCustomObject，
    # 其 ['key'] 索引器对 PSCustomObject 恒返回 $null（实测 0 和 2 都返回 null），
    # 若直接 $summary['failed'] 会把 failed 读成 null，导致 [int]$null -eq 0 恒真，
    # 无论 summary.failed 是 0 还是 2 都误判为「清理成功」而抑制恢复（REQ-031 失效）。
    # 与 Get-RollbackJournalEntryList 的条目归一化同理，改为显式读属性。
    if ($summary -is [hashtable]) {
        $failed = $summary['failed']
    } else {
        # 显式取属性对象再判空：直接 .Properties['failed'].Value 在属性缺失时
        # 会对 $null 取 .Value（strict mode 下抛 NullReference）。
        $failedProp = $summary.PSObject.Properties['failed']
        $failed = if ($null -ne $failedProp) { $failedProp.Value } else { $null }
    }
    if ($null -eq $failed) {
        $res.EvidenceMissing = $true
        $res.Reason = 'summary_failed_absent'
        return $res
    }

    # 外部 JSON 的 failed 可能是任意值（如字符串 "zero"）；[int] 强转会抛异常，
    # 使恢复流程被一份畸形清理日志中断。用 TryParse：非整数按「证据不完整」处理，
    # 交 Step 3 自证，而不是崩溃或臆断为成功/失败。
    $failedInt = 0
    if (-not [int]::TryParse([string]$failed, [ref]$failedInt)) {
        $res.EvidenceMissing = $true
        $res.Reason = 'summary_failed_not_numeric'
        return $res
    }

    if ($failedInt -eq 0) {
        $res.Suppress = $true
        $res.Reason = 'cleanup_succeeded_failed_zero'
    } else {
        $res.Reason = 'cleanup_had_failures'
    }
    return $res
}

function Test-JournalIsStaleOrForeign {
    <#
    .SYNOPSIS
        判定日志是否属于上一轮且已消费，或不匹配当前 run（REQ-019 首段）。
    .DESCRIPTION
        - machine_fingerprint 与本机不一致 → 外来日志（从别的机器拷来的）
        - 已消费标记存在（可解析且合法）→ 上一轮且已消费
        两者都不得修改系统状态。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][string]$BackupDir,
        [string]$MachineFingerprint
    )

    $reasons = @()

    if (-not [string]::IsNullOrWhiteSpace($MachineFingerprint)) {
        $mf = [string]$Journal['machine_fingerprint']
        if (-not [string]::IsNullOrWhiteSpace($mf) -and $mf -ne $MachineFingerprint) {
            $reasons += 'journal_from_foreign_machine'
        }
    }

    $consumed = Read-JsonFileSafe -Path (Join-Path $BackupDir 'rollback-consumed.json')
    if (Test-MarkerBelongsToJournal -Marker $consumed -Journal $Journal) { $reasons += 'already_consumed' }

    return $reasons
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4a/4b：消费与未修复清单（REQ-019 / REQ-031）
# ─────────────────────────────────────────────────────────────────────────────

function Write-RecoveryMarker {
    <#
    .SYNOPSIS
        原子写一个消费/确认标记（REQ-019 Step 4a）。
    .DESCRIPTION
        用与日志相同的原子写原语，保证标记文件要么完整存在要么不存在，
        不会出现半截 JSON —— 半截标记会被 Test-MarkerWellFormed 判为非法，
        从而让本该剔除的候选重新进入候选集。
        没有 run_id 时不得写出标记（那会造出一个格式非法的标记）。
    #>
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][ValidateSet('consumed', 'consumed.failed', 'acknowledged')][string]$Kind,
        [Parameter(Mandatory)][string]$RunId,
        [string]$Timestamp
    )

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        $Timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $g = [guid]::Empty
    if (-not [guid]::TryParse($RunId, [ref]$g)) {
        throw "Write-RecoveryMarker: run_id 不是合法 guid: $RunId"
    }

    $name = switch ($Kind) {
        'consumed' { 'rollback-consumed.json' }
        'consumed.failed' { 'rollback-consumed.failed.json' }
        'acknowledged' { 'rollback-acknowledged.json' }
    }
    $target = Join-Path $BackupDir $name

    $payload = @{ run_id = $RunId }
    if ($Kind -eq 'consumed.failed') {
        $payload['failed_at'] = $Timestamp
    } else {
        $payload['consumed_at'] = $Timestamp
    }

    Write-FileAtomic -TargetPath $target -Content ($payload | ConvertTo-Json -Depth 5)
    return $target
}

function Add-UnrepairedItem {
    <#
    .SYNOPSIS
        累积未修复条目（REQ-031 / exit 11 与 14(a) 的落盘内容）。
    .DESCRIPTION
        返回新的数组而不是原地修改 —— 避免调用方共享引用导致的串改。
        条目字段固定为 REQ-030 约定的 `item_id` / `kind` / `target` / `reason`。

        末尾的 `return , $new` 是为了在「新增前为空」时仍返回长度为 0 的数组而不是
        $null。代价是调用方**必须用普通赋值**接结果：再套一层 `@()` 会得到
        「元素是数组」的两层嵌套，落盘清单变成 `[[item], item]` 并多出一层
        value/Count 信封（AGENTS.md 陷阱 6 同族）。
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$List,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$Reason,
        [AllowEmptyString()][string]$Kind = '',
        [AllowEmptyString()][string]$Target = ''
    )

    $new = @($List)
    $new += , @{
        item_id = $ItemId
        kind    = $Kind
        target  = $Target
        reason  = $Reason
    }
    return , $new
}

function Write-UnrepairedList {
    <#
    .SYNOPSIS
        把未修复清单落盘到 <project_root>/output/rollback-unrepaired-<run_id>.json（REQ-031）。
    .DESCRIPTION
        退出码 11 与 14(a) 都必须落盘这份清单，以便下一次启动按 T3 再次尝试恢复
        并向用户报告。原子写，避免出现半截清单被当成完整证据。

        顶层字段按 REQ-030 固定为 `run_id` / `created_at` / `reason` / `backup_dir` /
        `candidate_unparseable` / `unrepaired[]`。清单必须落在项目根目录的 output/ 下、
        **不在**任何 `backup-*` 子目录内——否则删除该备份目录会连带丢掉唯一副本。

        -CandidateUnparseable 对应 Step 4b（候选自证失败/不可解析）：此时没有可读的
        条目列表可展开，`unrepaired[]` 为空数组，但顶层仍记录候选级证据。
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Items,
        [AllowEmptyString()][string]$BackupDir = '',
        [string]$Reason,
        [string]$CreatedAt,
        [switch]$CandidateUnparseable
    )

    $outDir = Join-Path $ProjectRoot 'output'
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($CreatedAt)) {
        $CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $payload = @{
        run_id                = $RunId
        created_at            = $CreatedAt
        reason                = $Reason
        backup_dir            = $BackupDir
        candidate_unparseable = [bool]$CandidateUnparseable
        unrepaired            = @($Items)
    }
    $target = Join-Path $outDir "rollback-unrepaired-$RunId.json"
    Write-FileAtomic -TargetPath $target -Content ($payload | ConvertTo-Json -Depth 8)
    return $target
}

function Complete-RollbackJournal {
    <#
    .SYNOPSIS
        原子地给日志写上 completed_at（REQ-031）。
    .DESCRIPTION
        **唯一例外是退出码 11**：那时系统仍处于未修复状态，日志必须保持未完成，
        以便下一次启动按 T3 再次尝试。因此本函数提供 -Skip 语义由调用方决定，
        但**不允许**静默跳过——跳过时必须给出 reason 供报告使用。
        注意 completed_at 的语义是「本轮清理正常结束」，**不是**「回滚跑过了」。
    #>
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][hashtable]$Journal,
        [switch]$Skip,
        [string]$SkipReason,
        [string]$CompletedAt,
        # 「谁消费了这份日志」。REQ-019 要求恢复成功后与 completed_at 一并写入，
        # 使「消费」可追溯到发起方；不传则保持日志原值（消费前就崩溃的兜底）。
        [AllowEmptyString()][string]$ConsumedByRunId = ''
    )

    if ($Skip) {
        return @{ Written = $false; Reason = $SkipReason }
    }

    if ([string]::IsNullOrWhiteSpace($CompletedAt)) {
        $CompletedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    # 在浅拷贝上写 completed_at，不原地改调用方的 $Journal：若 Write-RollbackJournal
    # 抛异常，调用方内存里的日志不会谎称「已完成」而跳过恢复（评审修复）。
    $copy = @{}
    foreach ($k in $Journal.Keys) { $copy[$k] = $Journal[$k] }
    $copy['completed_at'] = $CompletedAt
    if (-not [string]::IsNullOrWhiteSpace($ConsumedByRunId)) {
        $copy['consumed_by_run_id'] = $ConsumedByRunId
    }
    $path = Write-RollbackJournal -BackupDir $BackupDir -Journal $copy
    return @{ Written = $true; Path = $path; CompletedAt = $CompletedAt }
}

# ─────────────────────────────────────────────────────────────────────────────
# 窗口判定（REQ-024）
# ─────────────────────────────────────────────────────────────────────────────

function Test-WithinRecoveryWindow {
    <#
    .SYNOPSIS
        24h 窗口判定：now - created_at < 24h（恰好 24h 视为超窗）。
    .DESCRIPTION
        窗口值**固定，不可配置**（REQ-024）：不得提供配置项或开关来延长它——
        那会把「安全边界」变成「用户嫌麻烦就关掉的设置」。
        时间原点恒为日志的 created_at；终点为**本次恢复尝试时刻**
        （T3 下即下次启动那一刻，而非崩溃时刻）。
    #>
    param(
        [Parameter(Mandatory)][object]$CreatedAt,
        [datetime]$Now
    )

    # 窗口固定 24h，**不提供参数或开关**（REQ-024）：可配置的安全边界等于没有安全边界。
    $windowHours = 24

    if ($Now -eq [datetime]::MinValue) { $Now = (Get-Date).ToUniversalTime() }
    $created = ConvertFrom-IsoUtc -Text $CreatedAt
    if ($null -eq $created) {
        return @{ Within = $false; Reason = 'created_at_unparsable'; ElapsedHours = $null }
    }

    $elapsed = $Now.ToUniversalTime() - $created.ToUniversalTime()
    # 未来 created_at（时钟回拨/篡改）会得到负的 elapsed，负数 < 24 会被误判为「在窗口内」，
    # 等于无限延长安全边界。安全边界必须要求 elapsed >= 0；未来时间戳按无效证据拒绝。
    if ($elapsed.TotalHours -lt 0) {
        return @{ Within = $false; Reason = 'created_at_in_future'; ElapsedHours = [math]::Round($elapsed.TotalHours, 3) }
    }
    $within = $elapsed.TotalHours -lt $windowHours
    return @{
        Within       = $within
        Reason       = if ($within) { 'within_window' } else { 'window_exceeded' }
        ElapsedHours = [math]::Round($elapsed.TotalHours, 3)
    }
}

function Get-ParentBaselineMax {
    <#
    .SYNOPSIS
        恢复端聚合基线 MAX(parent_baseline)（REQ-024 迹象 (ii)）。
    .DESCRIPTION
        取日志中所有**注册表类**条目 parent_baseline 的最大值。
        path/service/task 条目的 parent_baseline 恒为 null（没有「注册表父键」语义），
        必须跳过——不能把 null 当 0 参与比较，否则任何时间戳都会「严格晚于 0」，
        导致所有非注册表条目全部误判为外部变更。
        返回 $null 表示没有可用基线（此时迹象 (ii) 不可判定，应跳过该项检查）。
    #>
    param([Parameter(Mandatory)][hashtable]$Journal)

    $entries = Get-RollbackJournalEntryList -Journal $Journal
    $max = $null
    foreach ($e in $entries) {
        $kind = [string]$e['kind']
        if ($kind -ne 'registry_key' -and $kind -ne 'startup_value') { continue }
        $pb = $e['parent_baseline']
        if ($null -eq $pb) { continue }
        $dt = ConvertFrom-IsoUtc -Text $pb
        if ($null -eq $dt) { continue }
        if ($null -eq $max -or $dt -gt $max) { $max = $dt }
    }
    return $max
}

function Test-ExternalChangeSignRegistry {
    <#
    .SYNOPSIS
        迹象 (ii)：注册表父键 LastWriteTime 严格晚于 MAX(parent_baseline) → 外部变更。
    .DESCRIPTION
        仅适用于注册表键/value 条目。父键当前时间戳取自 P/Invoke（REQ-034），
        因为受管 API 不暴露 LastWriteTime（已实测）。
        取不到时间戳（$null）时返回 @{ Detected = $false; Undecidable = $true }，
        由调用方如实标注「证据不完整」，**不得**当作「无外部变更」静默通过。
    #>
    param(
        [Parameter(Mandatory)][Microsoft.Win32.RegistryKey]$ParentKey,
        $BaselineMax
    )

    if ($null -eq $BaselineMax) {
        return @{ Detected = $false; Undecidable = $true; Reason = 'no_baseline' }
    }

    $lw = Get-RegistryKeyLastWriteTime -Key $ParentKey
    if ($null -eq $lw) {
        return @{ Detected = $false; Undecidable = $true; Reason = 'timestamp_unavailable' }
    }

    $detected = $lw.ToUniversalTime() -gt ([datetime]$BaselineMax).ToUniversalTime()
    return @{
        Detected    = $detected
        Undecidable = $false
        Reason      = if ($detected) { 'parent_key_changed_after_baseline' } else { 'no_external_change' }
        LastWriteTimeUtc = $lw.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 未完成日志的兜底规则（REQ-031 末段）
# ─────────────────────────────────────────────────────────────────────────────

function Get-UnfinishedJournalFallbackDecision {
    <#
    .SYNOPSIS
        兜底：completed_at 为 null 时，依据清理日志判断该不该做自动恢复（REQ-031）。
    .DESCRIPTION
        规则：
          - completed_at 非 null → 本轮已正常结束，走正常路径（NormalT3 = $false）
          - completed_at 为 null **且** 清理日志存在 **且** summary.failed == 0
            → 抑制自动恢复（Suppress = $true）。这正是「崩溃在写完清理日志之后、
              写 completed_at 之前」的窗口——**必须断言此时不把已删的东西装回去**。
          - completed_at 为 null **且** summary.failed > 0 → 正常 T3 恢复。
        注意本函数是 REQ-019 Step 2.5 的**判定**，不写标记。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [string]$CleanupLogPathOverride
    )

    $completedState = Get-CompletedAtState -CompletedAt $Journal['completed_at']
    if ($completedState -eq 'done') {
        return @{ Suppress = $false; NormalT3 = $false; RejectCandidate = $false; Reason = 'journal_completed' }
    }
    # 损坏/空白的 completed_at：既非完成也非干净未完成，不得当作正常 T3 继续（可能重装已完成的内容）。
    if ($completedState -eq 'malformed') {
        return @{ Suppress = $false; NormalT3 = $false; RejectCandidate = $true; Reason = 'completed_at_malformed' }
    }

    $v = Get-JournalSuppressionVerdict -Journal $Journal -CleanupLogPathOverride $CleanupLogPathOverride
    if ($v.Suppress) {
        return @{ Suppress = $true; NormalT3 = $false; RejectCandidate = $false; Reason = 'unfinished_but_cleanup_succeeded'; EvidenceMissing = $v.EvidenceMissing }
    }

    # 抑制判定明确「拒绝该候选」（哈希/run_id/模式不符）时，绝不能当成正常 T3 继续——
    # 那会把一份被篡改或损坏的日志按普通恢复处理。必须把 RejectCandidate 透传给调用方，
    # 且不走自动恢复（NormalT3=$false），交上层按拒绝路径处理。
    if ($v.RejectCandidate) {
        return @{ Suppress = $false; NormalT3 = $false; RejectCandidate = $true; Reason = $v.Reason; EvidenceMissing = $v.EvidenceMissing }
    }

    return @{
        Suppress  = $false
        NormalT3  = $true
        RejectCandidate = $false
        Reason    = $v.Reason
        EvidenceMissing = $v.EvidenceMissing
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 消费判定（REQ-019 固定顺序 2.5 → 3 → 4；T3 与 rollback.ps1 -Auto 共用）
# ─────────────────────────────────────────────────────────────────────────────

function Get-RollbackConsumptionDecision {
    <#
    .SYNOPSIS
        对**已定位**的一份日志给出消费判定：restore / suppress / already_completed /
        needs_acknowledgement / reject。本函数只读，不写任何标记。
    .DESCRIPTION
        为什么 T3 与 rollback.ps1 -Auto 必须共用：两者读同一份日志、依据同一套证据。
        各自实现「能不能恢复」迟早会漂移，而漂移的两个方向都是事故——该恢复的没恢复，
        不该恢复的把用户后来主动删掉的东西装回去。
        顺序是承重的（REQ-019）：Step 2.5 抑制判定**先于** Step 3 自证，因为抑制针对的
        正是「清理日志已丢、自证必然失败」那种日志；先跑自证就永远进不了抑制分支。
        判定为 reject / needs_acknowledgement 时调用方**不得**写任何标记：被标记消费却
        未通过验证的日志再也无法重试（REQ-030）。
        本函数自身也一律不落笔——抑制 ≠ 消费，写标记由调用方在恢复真正完成后执行。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [bool]$RequiresAcknowledgement = $false,
        [switch]$AcknowledgeConflicts,
        [string]$CleanupLogPathOverride,
        [string]$MachineFingerprint
    )

    $res = @{
        Action          = 'reject'
        Reason          = ''
        Reasons         = @()
        EvidenceMissing = $false
        State           = ''
        Journal         = $Journal
    }

    if ([string]::IsNullOrWhiteSpace($MachineFingerprint)) {
        $MachineFingerprint = [string](Get-MachineFingerprint).Value
    }

    $state = Get-CompletedAtState -CompletedAt $Journal['completed_at']
    $res.State = $state
    if ($state -eq 'done') {
        # 已完成 → 不消费、不恢复、不改动（AC-014 的后半：跨进程第二次调用必须零变更）。
        $res.Action = 'already_completed'
        $res.Reason = 'journal_completed'
        return $res
    }

    # Step 1 闸门的延伸：候选被标记「必须人工确认」（曾尝试消费但标记写失败、只能靠 .prev
    # 读出的日志、completed_at 损坏）。这道判定**必须在自证之前**——那三类日志恰恰常常自证
    # 失败，若先自证就永远返回 reject，人拿着 -AcknowledgeConflicts 也解不开死锁。
    # 确认的语义是「承认这份日志到此为止、不要再自动恢复」，**不是**「授权按坏证据恢复」：
    # 所以确认走 suppress（只补标记、绝不恢复），未确认一律 needs_acknowledgement。
    if ($state -eq 'malformed' -or $RequiresAcknowledgement) {
        if ($AcknowledgeConflicts) {
            $res.Action = 'suppress'
            $res.Reason = 'acknowledged_without_restore'
        } else {
            $res.Action = 'needs_acknowledgement'
            $res.Reason = if ($state -eq 'malformed') { 'completed_at_malformed' } else { 'requires_acknowledgement' }
        }
        return $res
    }

    # Step 2.5 —— 抑制判定
    $fb = Get-UnfinishedJournalFallbackDecision -Journal $Journal -CleanupLogPathOverride $CleanupLogPathOverride
    $res.EvidenceMissing = [bool]$fb.EvidenceMissing

    # Step 3 —— 自证
    $sv = Test-RollbackJournalSelfValid -Journal $Journal -MachineFingerprint $MachineFingerprint
    $res.Reasons = @($sv.Reasons)
    if (-not $sv.Valid) {
        $res.Action = 'reject'
        $res.Reason = 'self_validation_failed'
        return $res
    }

    # 抑制判定的证据本身被判定为「拒绝该候选」（哈希或模式不符）时，绝不恢复。
    if ($fb.RejectCandidate) {
        $res.Action = 'reject'
        $res.Reason = [string]$fb.Reason
        return $res
    }

    # 崩溃在「清理日志写完、completed_at 之前」：抑制自动恢复并如实报告「已完成（标记丢失）」。
    if ($fb.Suppress) {
        $res.Action = 'suppress'
        $res.Reason = [string]$fb.Reason
        return $res
    }

    $res.Action = 'restore'
    $res.Reason = 'unfinished_journal'
    return $res
}

function Get-RecoveryJournalTarget {
    <#
    .SYNOPSIS
        REQ-019 Step 1 的定位环节：显式 -JournalPath 优先，否则扫描 backup-* 后选出唯一候选。
    .DESCRIPTION
        返回 @{ Ok; BackupDir; Journal; RequiresAcknowledgement; Reason; Candidates; Ambiguous }。
        本函数**只定位、不判定**：并列/歧义时不把任何一份当成目标，而是把候选清单原样交回
        调用方打印——证据不足时自动挑一份恢复等于臆断（REQ-030「出错必须由人拍板」）。
        能不能消费一律由 Get-RollbackConsumptionDecision 决定，T3 与 -Auto 共用同一判定。
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$JournalPath = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($JournalPath)) {
        if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) {
            return @{ Ok = $false; Reason = 'journal_path_not_found'; Journal = $null;
                      Candidates = @(); Ambiguous = $false }
        }
        $j = Read-JsonFileSafe -Path $JournalPath
        if ($null -eq $j) {
            return @{ Ok = $false; Reason = 'journal_unreadable'; Journal = $null;
                      Candidates = @(); Ambiguous = $false }
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
