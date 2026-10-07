# rollback-verdicts.ps1
# §3.4 的裁决层纯函数：可恢复性判定、REQ-024 唯一权威决策表、PATH 作用域/预期值、
# 逐条裁决记录与诚实报告渲染。
#
# 本文件只放顶层可测纯函数，不含 Main、不含 exit（ADR-001）。
# 副作用（reg import/query、PATH 读写、父键 LastWriteTime 采集）留在调用方，
# 判定所需的外部事实全部以参数注入 —— 这是 REQ-024「唯一权威规则」可被
# 双引擎单测覆盖的前提。
#
# 依赖：rollback-journal.ps1 的 Get-ItemId（item_id 规范化，须先 dot-source）。

function Test-RollbackRestorable {
    <#
    .SYNOPSIS
        kind -> 是否可恢复 + 不可恢复原因（REQ-018 / DD-006）。
    .DESCRIPTION
        registry_key / startup_value 经备份 .reg 恢复；path_entry 经
        machine_path_original 整作用域恢复（REQ-021）。
        path_deleted（文件/目录删除）、service、task 按 DD-006 不可恢复，
        必须给出如实原因——journal 是「完整交代」，不是选择性遗忘。
        未知 kind 一律 fail-closed 判不可恢复，绝不抛异常中断回滚。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Kind)

    switch ($Kind) {
        'registry_key'  { return @{ Restorable = $true; Reason = '' } }
        'startup_value' { return @{ Restorable = $true; Reason = '' } }
        'path_entry'    { return @{ Restorable = $true; Reason = '' } }
        'path_deleted'  { return @{ Restorable = $false; Reason = 'not_restorable_file_content' } }
        'service'       { return @{ Restorable = $false; Reason = 'not_restorable_service' } }
        'task'          { return @{ Restorable = $false; Reason = 'not_restorable_task' } }
        default         { return @{ Restorable = $false; Reason = 'not_restorable_unknown_kind' } }
    }
}

function Resolve-PathEntryScope {
    <#
    .SYNOPSIS
        把一个 PATH 片段映射到它实际所在的作用域（Machine / User / Both / None）。
    .DESCRIPTION
        恢复端必须知道当初删的是哪个作用域的条目才能写回正确的位置。
        整段比较、大小写不敏感、容忍首尾空白与尾随反斜杠；
        同时出现在两个作用域时如实返回 Both —— 让调用方决定，绝不静默择一。
        （生产入口读取的始终是 Machine PATH，见 clean-residuals 的 path_entry 分支。）
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Entry,
        [AllowNull()][string]$MachinePath,
        [AllowNull()][string]$UserPath
    )

    $inMachine = Test-PathSegmentPresent -Entry $Entry -PathList $MachinePath
    $inUser = Test-PathSegmentPresent -Entry $Entry -PathList $UserPath

    $scope = if ($inMachine -and $inUser) { 'Both' }
        elseif ($inMachine) { 'Machine' }
        elseif ($inUser) { 'User' }
        else { 'None' }
    return @{ Scope = $scope; InMachine = $inMachine; InUser = $inUser }
}

function Test-PathSegmentPresent {
    <#
    .SYNOPSIS
        内部原语：PATH 片段是否整段存在于某条 PATH 串（大小写不敏感、容忍尾斜杠）。
    #>
    param(
        [AllowEmptyString()][string]$Entry,
        [AllowNull()][string]$PathList
    )
    if ($null -eq $PathList) { return $false }
    if ([string]::IsNullOrWhiteSpace($Entry)) { return $false }
    $needle = $Entry.Trim().Trim('"').Trim().TrimEnd('\').ToLowerInvariant()
    foreach ($seg in ($PathList -split ';')) {
        $cand = $seg.Trim().TrimEnd('\').ToLowerInvariant()
        if ($cand -ne '' -and $cand -eq $needle) { return $true }
    }
    return $false
}

function Test-RollbackFlagTrue {
    <#
    .SYNOPSIS
        布尔证据字段的跨引擎归一化比较（REQ-027 条目 pre_existing /
        absent_confirmed_after_mutation）。
    .DESCRIPTION
        hashtable 里存的是 [bool]，而 pwsh 7 的 ConvertFrom-Json 同样给 [bool]、
        PS 5.1 经某些序列化路径可能给字符串 'True'。$true -eq 'True' 在 PS 下为
        **False**（StringComparer 不做 bool↔串互转），直接比较会静默判错因果链。
    #>
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value) { return $false }
    return (([string]$Value).Trim().ToLowerInvariant() -eq 'true')
}

function Get-ExpectedPathAfterCleanup {
    <#
    .SYNOPSIS
        推导「清理后预期值」：从捕获原值逐字移除成功移除的条目（REQ-021）。
    .DESCRIPTION
        只移除 RemovedEntries 中出现的段（= state=mutation_succeeded 的 path_entry
        条目，或清理日志中 success=true 的 path_entry_removed 记录）；
        其余段必须**逐字**保留——顺序、大小写、原样空白都不允许被「规范化」改动，
        否则恢复写回的是一个从未存在过的 PATH。
        段匹配大小写不敏感、整段匹配（'C:\App' 不得误删 'C:\AppData'）。
        OriginalPath 为 null/空白 → 返回 $null（证据缺失，调用方必须降级人工）。
    #>
    param(
        [AllowNull()][string]$OriginalPath,
        [AllowEmptyCollection()][string[]]$RemovedEntries = @()
    )

    if ($null -eq $OriginalPath -or [string]::IsNullOrWhiteSpace($OriginalPath)) { return $null }

    $needles = @()
    foreach ($r in @($RemovedEntries)) {
        if ($null -eq $r) { continue }
        $n = ([string]$r).Trim().Trim('"').Trim().TrimEnd('\').ToLowerInvariant()
        if ($n -ne '') { $needles += , $n }
    }

    $kept = @()
    foreach ($seg in ($OriginalPath -split ';')) {
        $cand = $seg.Trim().TrimEnd('\').ToLowerInvariant()
        $drop = ($cand -ne '' -and $needles -contains $cand)
        if (-not $drop) { $kept += , $seg }
    }
    return ($kept -join ';')
}

function Get-RollbackVerdict {
    <#
    .SYNOPSIS
        单个条目的最终裁决 —— REQ-024 四行决策表 + REQ-021 PATH 分支的唯一实现处。
    .DESCRIPTION
        REQ-018/REQ-029 一律引用本表，任何调用方不得另立规则。
        外部事实以参数注入（TargetState / WithinWindow / SignIi* / Path*），
        因此决策表本身可在双引擎下逐行断言，无需真实系统。
        判定顺序（与 REQ-024 一致）：
          1. kind 不可恢复           -> not_restorable（不参与决策表）
          2. present + 与备份一致     -> already_present（不重复恢复）
          3. present + 与备份不同     -> conflict（迹象 (i)，绝不覆盖）
          4. absent：三项目标齐备 -> 窗口 -> 迹象 (ii)/(iii) -> restore
             任何一环不满足 -> conflict，绝不自动恢复。
        迹象 (ii) 不可判定（缺基线/读不到时间戳）**不阻断**恢复，
        但必须在裁决上标注证据不完整（AC-075a 的逐条目容错）。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [Parameter(Mandatory)][ValidateSet('present_match', 'present_mismatch', 'absent')][string]$TargetState,
        [Parameter(Mandatory)][bool]$WithinWindow,
        [bool]$SignIiDetected = $false,
        [bool]$SignIiUndecidable = $false,
        [AllowNull()][string]$PathExpected,
        [AllowNull()][string]$PathCurrent
    )

    $kind = [string]$Entry['kind']
    $base = @{
        ItemId             = [string]$Entry['item_id']
        Id                 = [string]$Entry['id']
        Kind               = $kind
        Target             = [string]$Entry['target']
        Verdict            = ''
        Reason             = ''
        EvidenceIncomplete = $false
        ExpectedPath       = $null
        PathCurrent        = $null
        PathCompare        = ''
    }

    $restorable = Test-RollbackRestorable -Kind $kind
    if (-not $restorable.Restorable) {
        $base.Verdict = 'not_restorable'
        $base.Reason = $restorable.Reason
        return $base
    }

    if ($TargetState -eq 'present_match') {
        $base.Verdict = 'already_present'
        $base.Reason = 'target_present_identical'
        return $base
    }
    if ($TargetState -eq 'present_mismatch') {
        $base.Verdict = 'conflict'
        $base.Reason = 'external_change_sign_i'
        return $base
    }

    # ── absent 分支：REQ-024 规则 3/4 ──
    $stateOk = ([string]$Entry['state'] -eq 'mutation_succeeded')
    # 布尔证据字段必须经 Test-RollbackFlagTrue 归一（$true -eq 'True' 在 PS 下为 False，
    # 直接比较会让因果链判定静默出错）。
    $preOk = Test-RollbackFlagTrue -Value $Entry['pre_existing']
    $absentOk = Test-RollbackFlagTrue -Value $Entry['absent_confirmed_after_mutation']

    if (-not ($stateOk -and $preOk -and $absentOk)) {
        $base.Verdict = 'conflict'
        $base.Reason = 'causal_flags_incomplete'
        return $base
    }
    if (-not $WithinWindow) {
        $base.Verdict = 'conflict'
        $base.Reason = 'window_exceeded'
        return $base
    }

    $isRegistry = ($kind -eq 'registry_key' -or $kind -eq 'startup_value')
    if ($isRegistry) {
        if ($SignIiDetected) {
            $base.Verdict = 'conflict'
            $base.Reason = 'external_change_sign_ii'
            return $base
        }
        if ($SignIiUndecidable) { $base.EvidenceIncomplete = $true }
    }

    if ($kind -eq 'path_entry') {
        # REQ-021：判定顺序固定「先窗口（上面已过），再漂移」；以整作用域为单位恢复。
        # 证据留痕：冲突分支此前只写 reason、丢弃两个比较值，事后无法回答「到底什么漂移」
        # （2026-10-07 drill5 现场因此不可复盘）。判定依赖可变外部值时，证据与结论同等重要，
        # 必须随裁决产出并经 rollback-result.json 落盘。
        # 「null」用绑定存在性判定而非 $null -eq：PS 5.1/pwsh 7 都会把 [string] 参数的
        # 省略或显式 $null 强转成 ''（AGENTS.md 陷阱 9 同族），$null -eq $PathExpected 恒为
        # False，null 与 mismatch 无法区分。Get-RestorableEntry 只注入非 null 的 extras，
        # 因此「未绑定」== 生产路径的 null；显式空串仍如实按值比较。
        $hasExpected = $PSBoundParameters.ContainsKey('PathExpected')
        $hasCurrent = $PSBoundParameters.ContainsKey('PathCurrent')
        if ($hasExpected) { $base.ExpectedPath = $PathExpected }
        if ($hasCurrent) { $base.PathCurrent = $PathCurrent }
        if (-not $hasExpected) { $base.PathCompare = 'expected_null' }
        elseif (-not $hasCurrent) { $base.PathCompare = 'current_null' }
        elseif ($PathExpected -cne $PathCurrent) { $base.PathCompare = 'mismatch' }
        else { $base.PathCompare = 'equal' }

        if ($base.PathCompare -ne 'equal') {
            $base.Verdict = 'conflict'
            $base.Reason = 'external_change_sign_iii'
            return $base
        }
    }

    $base.Verdict = 'restore'
    $base.Reason = 'decision_rule_3'
    return $base
}

function Get-RestorableEntry {
    <#
    .SYNOPSIS
        两阶段协议的第 1 阶段：对全部条目**先判定**，产出 restore 子集与逐条裁决。
    .DESCRIPTION
        REQ-024 明确要求「先对全部条目算出冲突判定，再逐个执行恢复」——
        若边判定边写，同一父键下先恢复的条目会推进父键时间戳，把后面条目
        **我们自己的恢复**误判为外部变更迹象 (ii)。因此本函数**绝不写系统**。
        TargetStates / TargetIdMap 由调用方（Main）以 item_id 为键注入：
          - TargetStates: item_id -> 'present_match'|'present_mismatch'|'absent'
          - TargetIdMap:  item_id -> 该条目的外部迹象输入 hashtable
                          （可含 SignIiDetected / SignIiUndecidable / PathExpected / PathCurrent）
        条目缺外部状态时 fail-closed 判 conflict（missing_target_state），
        绝不臆断为 absent 去恢复。
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Entries,
        [Parameter(Mandatory)][hashtable]$TargetStates,
        [Parameter(Mandatory)][hashtable]$TargetIdMap,
        [Parameter(Mandatory)][bool]$WithinWindow
    )

    $restore = @()
    $verdicts = @()
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $iid = [string]$e['item_id']
        if ([string]::IsNullOrWhiteSpace($iid)) {
            $iid = Get-ItemId -Kind ([string]$e['kind']) -Target ([string]$e['target'])
        }
        $state = $TargetStates[$iid]
        if ($null -eq $state) {
            $v = @{
                ItemId             = $iid
                Id                 = [string]$e['id']
                Kind               = [string]$e['kind']
                Target             = [string]$e['target']
                Verdict            = 'conflict'
                Reason             = 'missing_target_state'
                EvidenceIncomplete = $true
                ExpectedPath       = $null
                PathCurrent        = $null
                PathCompare        = ''
            }
        } else {
            $extra = $TargetIdMap[$iid]
            $vArgs = @{
                Entry        = $e
                TargetState  = [string]$state
                WithinWindow = $WithinWindow
            }
            if ($null -ne $extra) {
                if ($extra.ContainsKey('SignIiDetected'))    { $vArgs['SignIiDetected'] = [bool]$extra['SignIiDetected'] }
                if ($extra.ContainsKey('SignIiUndecidable')) { $vArgs['SignIiUndecidable'] = [bool]$extra['SignIiUndecidable'] }
                if ($null -ne $extra['PathExpected']) { $vArgs['PathExpected'] = [string]$extra['PathExpected'] }
                if ($null -ne $extra['PathCurrent']) { $vArgs['PathCurrent'] = [string]$extra['PathCurrent'] }
            }
            $v = Get-RollbackVerdict @vArgs
        }
        $verdicts += , $v
        if ($v.Verdict -eq 'restore') { $restore += , $e }
    }
    return @{ Restore = $restore; Verdicts = $verdicts }
}

function Format-RollbackReport {
    <#
    .SYNOPSIS
        渲染逐条裁决表 + **诚实的能力边界声明**（REQ-014 / DD-018）。
    .DESCRIPTION
        文案红线：不得出现「任何时刻都能可靠还原」「下次启动会自动恢复」这类
        无条件承诺；存在 conflict 时必须明说 24 小时窗口与人工介入路径。
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Verdicts)

    $lines = @()
    $lines += '===== ROLLBACK VERDICTS ====='
    $vs = @($Verdicts)
    if ($vs.Count -eq 0) {
        $lines += '(no journal entries to evaluate; nothing was changed)'
        return , $lines
    }

    foreach ($v in $vs) {
        $flag = ''
        if ($v.EvidenceIncomplete) { $flag = ' [evidence-incomplete]' }
        $lines += ('{0}  {1}  ->  {2}{3}' -f $v.ItemId, $v.Kind, $v.Verdict, $flag)
        if ($v.Verdict -ne 'restore' -and -not [string]::IsNullOrWhiteSpace($v.Reason)) {
            $lines += ('    reason: {0}' -f $v.Reason)
            # 迹象 (iii) 的冲突必须给出可行动证据：null 与 mismatch 是两种不同故障，
            # 长度对比让「漂移与否」当场可见；完整比较值在 rollback-result.json。
            if ([string]$v.Kind -eq 'path_entry' -and [string]$v.PathCompare -in @('mismatch', 'current_null', 'expected_null')) {
                $el = 'null'; $cl = 'null'
                if ($null -ne $v.ExpectedPath) { $el = [string]([string]$v.ExpectedPath).Length }
                if ($null -ne $v.PathCurrent) { $cl = [string]([string]$v.PathCurrent).Length }
                $lines += ('    path evidence: compare={0}, expected_len={1}, current_len={2} (full values in rollback-result.json)' -f `
                    [string]$v.PathCompare, $el, $cl)
            }
        }
    }

    $counts = @{}
    foreach ($v in $vs) {
        $k = [string]$v.Verdict
        if (-not $counts.ContainsKey($k)) { $counts[$k] = 0 }
        $counts[$k] = $counts[$k] + 1
    }
    $lines += ('summary: ' + (($counts.Keys | Sort-Object | ForEach-Object { "$_=$($counts[$_])" }) -join ', '))

    if ($counts.ContainsKey('conflict')) {
        $lines += ''
        $lines += 'NOTE: automatic restore is BOUNDED, not guaranteed (DD-018).'
        $lines += 'Items above marked conflict require MANUAL recovery: automatic restore'
        $lines += 'applies only within a fixed 24-hour window from journal creation and only'
        $lines += 'when no external-change sign is present. This tool never claims it can'
        $lines += 'always restore reliably.'
    }
    if ($counts.ContainsKey('not_restorable')) {
        $lines += 'NOTE: not_restorable items (files/dirs, services, tasks) were deleted by'
        $lines += 'this run and CANNOT be recovered by this tool - state that plainly.'
    }
    return , $lines
}
