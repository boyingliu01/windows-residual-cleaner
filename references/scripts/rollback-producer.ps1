# rollback-producer.ps1
# S3 写入端 —— 回滚日志的「记账」原语（REQ-001 / REQ-003 / REQ-005 / REQ-011 / REQ-015 / REQ-020 / REQ-027 / REQ-031 / REQ-033）。
#
# 本文件**不含 Main、不含 exit**（ADR-001），只做两类事：
#   1) 纯函数：条目的 kind/target 映射、退出码选择、清理日志绑定三元组；
#   2) 极薄的副作用包装：备份目录创建、条目 upsert、原子落盘（把抛异常规约成结构化失败）。
# 真正的系统变更（reg delete / PATH 写 / 服务删除）留在 clean-residuals.ps1 的 Main 里，
# 使「何时变更」与「如何记账」可以在单测里分别断言。
#
# 依赖：必须先 dot-source rollback-journal.ps1（Get-ItemId / ConvertTo-RollbackJournalEntry /
# Write-RollbackJournal / Get-Sha256Hex / Format-IsoUtc）。

function ConvertTo-RollbackJournalTarget {
    <#
    .SYNOPSIS
        把一条 final-report 的 item 映射为该种 kind 的 journal target（纯函数）。
    .DESCRIPTION
        target 的形态必须与恢复端（rollback-exec.ps1 的探针/恢复器）约定一致：
          - startup_value 用复合形式 "<父键>|<value 名>"（恢复端按最后一个 '|' 拆分，
            因为注册表键名不允许含 '|'，而 value 名可以）；
          - 其余 kind 直接用该对象的标识（键路径 / 文件路径 / 服务名 / 任务名 / PATH 段）。
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('registry_key', 'startup_value', 'path_entry', 'path_deleted', 'service', 'task')][string]$Kind,
        [Parameter(Mandatory)]$Item
    )

    switch ($Kind) {
        'startup_value' { return ('{0}|{1}' -f [string]$Item.key, [string]$Item.value_name) }
        'registry_key'  { return [string]$Item.key }
        'path_entry'    { return [string]$Item.path }
        'path_deleted'  { return [string]$Item.path }
        'service'       { return [string]$Item.name }
        'task'          { return [string]$Item.name }
    }
    return ''
}

function Get-ItemMutationKindList {
    <#
    .SYNOPSIS
        一条 item 会触发哪些**破坏性变更**（纯函数，REQ-018 的记账前提）。
    .DESCRIPTION
        条件必须与 clean-residuals.ps1 的 Phase 2 / Phase 3 分支**逐字一致**，
        否则日志会记录从未发生的变更（恢复端据此把没删过的东西装回去）。
        分支对照：
          path_entry     -> `type -eq 'path_entry' -and path`（只改 PATH，绝不删目录）
          path_deleted   -> `path -and type -ne 'path_entry'`
          service        -> `name -and binary_path`
          task           -> `name -and expanded_path -and -not binary_path`
          startup_value  -> `key -and (type -eq 'startup' -or value_name)`（禁止整键删除）
          registry_key   -> `key` 且不属于上一行
        顺序固定为「Phase 2 先、Phase 3 后」，与真实执行顺序一致；同一条 item 可以同时
        命中多类（例如既有安装目录又有注册表键），因此返回**数组**。

        返回值**不得**写成 `return , $kinds`：那样调用方的 `@(Get-ItemMutationKindList …)`
        会多套一层，得到「Count=1、唯一元素为 Object[]」的数组，于是
        `-contains 'path_deleted'` 恒为 $false，所有破坏性分支静默不执行
        （PS 5.1 的同族陷阱见 AGENTS.md 陷阱 6）。这里选择「不防塌」：
        空数组经管道自然塌成 0 元素，调用方一律用 @() 规整后再 -contains。
    #>
    param([Parameter(Mandatory)]$Item)

    $kinds = @()
    $isPathEntry = (([string]$Item.type) -eq 'path_entry')
    if ($Item.path -and -not $isPathEntry) { $kinds += 'path_deleted' }
    if ($Item.name -and $Item.binary_path) { $kinds += 'service' }
    if ($Item.name -and $Item.expanded_path -and -not $Item.binary_path) { $kinds += 'task' }
    if ($isPathEntry -and $Item.path) { $kinds += 'path_entry' }
    if ($Item.key) {
        if (([string]$Item.type) -eq 'startup' -or $Item.value_name) { $kinds += 'startup_value' }
        else { $kinds += 'registry_key' }
    }
    return $kinds
}

function New-RollbackBackupDirectory {
    <#
    .SYNOPSIS
        按 REQ-032 创建本轮备份目录 `backup-<run_id>`（run_id 为 guid）。
    .DESCRIPTION
        目录名即 run_id，使「对不可解析日志写旁路文件」有确定落点、重复 run_id 可直接
        由目录名检出。返回 @{ Ok; RunId; Path; Reason }，**不抛**：调用方据此 fail-closed。
    #>
    # 本库的写入函数一律不带 ShouldProcess：调用方（clean-residuals.ps1）已有 -DryRun
    # 作为 WhatIf 等价物，且它经 UI/管道宿主非交互拉起，提示会挂死整条管道。
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString() }
    $dir = Join-Path $ProjectRoot ("backup-{0}" -f $RunId)
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
        }
        return @{ Ok = $true; RunId = $RunId; Path = $dir; Reason = '' }
    } catch {
        return @{ Ok = $false; RunId = $RunId; Path = $dir; Reason = ("backup_dir_failed({0})" -f $_.Exception.Message) }
    }
}

function Get-JournalBackupFileRelative {
    <#
    .SYNOPSIS
        把导出文件的绝对路径规约为**相对备份目录**的形态（REQ-027 / AC-051）。
    .DESCRIPTION
        自证明确要求 backup_file 落在本候选的备份目录内：绝对路径或 ..\ 穿越一律判为
        「越出备份目录」而整份日志失效（Test-RollbackJournalSelfValid）。
        导出原语返回的是绝对路径，直接写进日志会让一轮**确实有备份**的清理在 T3
        被拒绝恢复——即「备份存在但保护不存在」。因此这里统一规约，越界时返回 $null
        让调用方按「备份不可用」fail-closed 跳过删除，绝不写出一个自证必拒的路径。
    #>
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($BackupDir).TrimEnd('\') + [System.IO.Path]::DirectorySeparatorChar
        $candFull = [System.IO.Path]::GetFullPath($Path)
        if (-not $candFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $candFull.Substring($rootFull.Length)
    } catch {
        return $null
    }
}

function Add-RollbackJournalEntry {
    <#
    .SYNOPSIS
        按 item_id **幂等**地把条目写入内存日志（REQ-005 的「每项处理前后落盘」前提）。
    .DESCRIPTION
        同一 item_id 重复添加时**替换**旧条目而不是追加：状态机推进（planned →
        backup_created → mutation_succeeded）在实现上既可以走 Update-RollbackJournalEntry，
        也可以走「重新构造同一条」；若此处追加，日志里就会出现同一目标的两个互相矛盾的状态，
        恢复端按条目逐条判定会把已删的东西恢复两次。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][hashtable]$Entry
    )

    $iid = [string]$Entry['item_id']
    if ([string]::IsNullOrWhiteSpace($iid)) {
        $iid = Get-ItemId -Kind ([string]$Entry['kind']) -Target ([string]$Entry['target'])
        # 补算出的 id 必须**写回条目**：自证（REQ-027）会重算 item_id 并逐字比对，
        # 空 id 的条目让整份日志判废；Update-RollbackJournalEntry 也按 item_id 匹配，
        # 缺了它状态机永远停在 planned，恢复端据规则 4 直接拒绝恢复。
        $Entry['item_id'] = $iid
    }

    $existing = @($Journal['entries'])
    $out = [System.Collections.Generic.List[object]]::new()
    $replaced = $false
    foreach ($e in $existing) {
        if ($null -eq $e) { continue }
        if (([string]$e['item_id']) -eq $iid) {
            $out.Add($Entry)
            $replaced = $true
        } else {
            $out.Add($e)
        }
    }
    if (-not $replaced) { $out.Add($Entry) }
    $Journal['entries'] = @($out)
    return $Journal['entries']
}

function Update-RollbackJournalEntry {
    <#
    .SYNOPSIS
        只更新内存日志里某条目的若干字段（REQ-018 状态机推进）。
    .DESCRIPTION
        未知 item_id 返回 $false —— 调用方必须能区分「推进失败」与「推进成功」，
        否则状态机会静默停在 planned，恢复端据此拒绝恢复（规则 4）。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ItemId,
        [Parameter(Mandatory)][hashtable]$Fields
    )

    $entries = @($Journal['entries'])
    $found = $false
    foreach ($e in $entries) {
        if ($null -eq $e) { continue }
        if (([string]$e['item_id']) -ne $ItemId) { continue }
        foreach ($k in $Fields.Keys) { $e[$k] = $Fields[$k] }
        $found = $true
    }
    return $found
}

function Write-RollbackJournalSafely {
    <#
    .SYNOPSIS
        把内存日志原子落盘，并把任何异常规约成结构化失败（REQ-005 fail-closed 的判据）。
    .DESCRIPTION
        Write-RollbackJournal 走的是 File.Move / File.Replace，磁盘满、目录被删、
        目标被占用都会抛。写入端**不能**让这种异常冒出去：那会让 Main 的 try/catch
        把它记成一条普通 cleanup_failed，而真实语义是「持久化保护已失效，必须立即停止
        后续破坏性操作」（REQ-017(a) / AC-049 / AC-052，退出码 15）。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][hashtable]$Journal
    )

    try {
        $path = Write-RollbackJournal -BackupDir $BackupDir -Journal $Journal
        return @{ Ok = $true; Path = $path; Reason = '' }
    } catch {
        return @{ Ok = $false; Path = ''; Reason = ("journal_flush_failed({0})" -f $_.Exception.Message) }
    }
}

function Get-CleanupLogJournalBinding {
    <#
    .SYNOPSIS
        计算 cleanup_log_* 三元组（REQ-027 / AC-083：同 null 或同非 null）。
    .DESCRIPTION
        读不到文件、算不出哈希、或取不到 mtime 时**三个都返回 null** —— 宁可让自证
        退化为「无清理日志绑定」（T3 的合法形态），也不能写出「有 path 无 sha256」这种
        模式错误的组合：那会让整份日志永远自证失败，进而让每一轮清理都返回 14。
        时间戳统一为 UTC ISO 8601（与 Format-IsoUtc 同口径），供自证做 ±2s 容差比对。
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    $nullTriple = @{ cleanup_log_path = $null; cleanup_log_timestamp = $null; cleanup_log_sha256 = $null }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $nullTriple }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $nullTriple }

    $sha = Get-Sha256Hex -Path $Path
    if ([string]::IsNullOrWhiteSpace($sha)) { return $nullTriple }
    $mtime = $null
    try { $mtime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc } catch { $mtime = $null }
    if ($null -eq $mtime) { return $nullTriple }

    return @{
        cleanup_log_path      = $Path
        cleanup_log_timestamp = (Format-IsoUtc -Value $mtime)
        cleanup_log_sha256    = $sha
    }
}

function Set-RollbackJournalCleanupBinding {
    <#
    .SYNOPSIS
        把 Get-CleanupLogJournalBinding 的三个字段写回日志（清理日志落盘后回填，REQ-033）。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CleanupLogPath
    )

    $binding = Get-CleanupLogJournalBinding -Path $CleanupLogPath
    $Journal['cleanup_log_path'] = $binding['cleanup_log_path']
    $Journal['cleanup_log_timestamp'] = $binding['cleanup_log_timestamp']
    $Journal['cleanup_log_sha256'] = $binding['cleanup_log_sha256']
    return $binding
}

function Test-JournalHasMutation {
    <#
    .SYNOPSIS
        日志里是否存在 state=mutation_succeeded 的条目（REQ-020 的「本轮确实改过东西」判据）。
    #>
    param([Parameter(Mandatory)][hashtable]$Journal)

    foreach ($e in (Get-RollbackJournalEntryList -Journal $Journal)) {
        if ([string]$e['state'] -eq 'mutation_succeeded') { return $true }
    }
    return $false
}

function Get-CleanupExitCode {
    <#
    .SYNOPSIS
        本轮清理的最终退出码（REQ-015 / REQ-020 / REQ-026 的唯一实现处，纯函数）。
    .DESCRIPTION
        优先级固定，且 15 是**终态**：
          14  上一轮日志未能安全消费（本轮未开始即中止）—— 判定点在本轮任何写入之前
          15  本轮持久化写入失败（日志落盘 / 未修复清单 / 完成或消费标记）
          13  部分失败且 -NoAutoRollback
          12  部分失败但回滚日志缺失/不可读
          1   部分失败但本轮没有任何已变更记录（REQ-020「未执行到回滚即失败」）
          11  部分失败且回滚未完全成功（存在 restore_failed）
          10  部分失败且回滚完全成功
          0   没有失败
        「无已变更记录」排在 11/10 之前：此时恢复端一条都不会动，把 0 条恢复当成
        「回滚完全成功」会虚报保护效果。
        权限(2)/输入(1)/依赖(3) 由调用方在更早的分支直接返回，不进入本表。
    #>
    param(
        [int]$FailedCount = 0,
        [bool]$PriorJournalUnconsumable = $false,
        [bool]$PersistenceError = $false,
        [bool]$NoAutoRollback = $false,
        [bool]$JournalMissing = $false,
        [bool]$HadMutations = $false,
        [int]$RestoreFailedCount = 0
    )

    if ($PriorJournalUnconsumable) { return 14 }
    if ($PersistenceError) { return 15 }
    if ($FailedCount -le 0) { return 0 }
    if ($NoAutoRollback) { return 13 }
    if ($JournalMissing) { return 12 }
    if (-not $HadMutations) { return 1 }
    if ($RestoreFailedCount -gt 0) { return 11 }
    return 10
}

function Get-RollbackFailureKindFromCleanupAction {
    <#
    .SYNOPSIS
        清理动作名 → 回滚条目失败原因（纯函数，供报告与未修复清单复用）。
    .DESCRIPTION
        REQ-002：Tier-4 重命名**不得**再被记成「删除成功」。这里把 Remove-ItemRobust
        回传的真实结果（deleted / renamed:<新名>）翻译成日志里可读的原因。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Outcome)

    $o = [string]$Outcome
    if ($o -eq 'deleted') { return @{ Renamed = $false; NewName = '' } }
    if ($o -like 'renamed:*') {
        return @{ Renamed = $true; NewName = $o.Substring('renamed:'.Length) }
    }
    return @{ Renamed = $false; NewName = '' }
}
