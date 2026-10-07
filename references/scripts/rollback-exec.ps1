# rollback-exec.ps1
# 恢复执行层（REQ-008 / REQ-009 / REQ-021 / REQ-024 / REQ-030 / REQ-031）。
#
# 分工：rollback-verdicts.ps1 是「唯一权威判定」的纯函数层，
# rollback-recovery.ps1 是候选/抑制/标记的规划层，本文件是**副作用执行层**：
# 探测目标当前状态 → 两阶段（先全量判定，再逐个执行）→ 落 rollback-result.json。
# 被 clean-residuals.ps1（T2 进程内 / T3 下次启动）与 rollback.ps1 -Auto 共用，
# 因此这里不含 Main、不含 exit（ADR-001）。
#
# 依赖（调用方按此顺序 dot-source）：
#   rollback-journal.ps1 → rollback-backup.ps1 → rollback-verdicts.ps1 → rollback-recovery.ps1

function Split-StartupTarget {
    <#
    .SYNOPSIS
        拆解 startup_value 条目的 target = "<父键>|<value 名>"。
    .DESCRIPTION
        同一共享 Run 键下可以有多个残留 value，而 item_id 规则是
        Get-ItemId(kind, target)，所以 value 名必须进入 target，否则同一父键下
        两条目的 item_id 相同，REQ-027 的 id 唯一性与逐条因果证据全部失效。
        注册表键名不允许 '|'，因此按**最后一个** '|' 切分是安全的。
        返回 @{ Key; ValueName }；无法拆解时 ValueName = $null（调用方 fail-closed）。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Target)

    $t = $Target.Trim().Trim('"').Trim()
    $idx = $t.LastIndexOf('|')
    if ($idx -lt 0) { return @{ Key = $t; ValueName = $null } }
    $key = $t.Substring(0, $idx).Trim().TrimEnd('\')
    $val = $t.Substring($idx + 1).Trim()
    if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($val)) {
        return @{ Key = $t; ValueName = $null }
    }
    return @{ Key = $key; ValueName = $val }
}

function ConvertTo-CanonicalRegKeyPath {
    <#
    .SYNOPSIS
        把 'HKLM\SOFTWARE\Foo' / 'HKEY_LOCAL_MACHINE\SOFTWARE\Foo' 都转成
        PS 注册表提供程序路径 'HKLM:\SOFTWARE\Foo'。
    .DESCRIPTION
        提供程序只认短 hive 名（HKLM:/HKCU:/...）作为驱动器；直接给长名
        （HKEY_LOCAL_MACHINE:\）Test-Path 一律为假 —— 那会把「存在」误判成
        「不存在」，进而把已存在的目标当成待恢复目标。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $p = $Path.Trim().Trim('"').Trim()
    # 已是 PS 提供程序形态（'HKLM:\SOFTWARE\Foo'）就原样返回；注意判别的是「字母 + :\」
    if ($p -match '^[A-Za-z]+:\\') { return $p }
    $short = @{
        'HKEY_LOCAL_MACHINE' = 'HKLM'; 'HKLM' = 'HKLM'
        'HKEY_CURRENT_USER' = 'HKCU'; 'HKCU' = 'HKCU'
        'HKEY_CLASSES_ROOT' = 'HKCR'; 'HKCR' = 'HKCR'
        'HKEY_USERS' = 'HKU'; 'HKU' = 'HKU'
        'HKEY_CURRENT_CONFIG' = 'HKCC'; 'HKCC' = 'HKCC'
    }
    $i = $p.IndexOf('\')
    if ($i -lt 0) { $hive = $p; $rest = '' } else { $hive = $p.Substring(0, $i); $rest = $p.Substring($i) }
    $drive = $short[$hive.ToUpperInvariant()]
    if ($null -eq $drive) { return $p }
    return ($drive + ':\' + $rest.TrimStart('\'))
}

function Add-RegSignatureLine {
    <#
    .SYNOPSIS
        把一条 value 定义按 REQ-024 的比较口径写入签名列表（纯函数式追加）。
    #>
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$List,
        [Parameter(Mandatory)][AllowEmptyString()][string]$KeyPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ValueName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ValueText,
        [AllowEmptyString()][string]$ValueNameFilter = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ValueNameFilter)) {
        if ($ValueName -ne $ValueNameFilter.ToLowerInvariant()) { return }
    }
    # 调用方传的是「= 之后的原文」（reg export 的 value 行是 "name"=type=data）。
    # 签名只保留 type=data 部分：前导 '=' 是分隔符而非数据，留着它会让差异串读起来
    # 像 `...|v|="1"`，与文档里 `value|<键>|<名>|<type=data>` 的口径不一致。
    $vt = [string]$ValueText
    if ($vt.Length -gt 0 -and $vt[0] -eq '=') { $vt = $vt.Substring(1) }
    $null = $List.Add('value|' + (Get-NormalizedRegKeyPath -Path $KeyPath) + '|' + $ValueName + '|' + $vt)
}

function Get-RegExportStructure {
    <#
    .SYNOPSIS
        把 .reg 文本解析为**可比对的结构签名**（纯函数）。
    .DESCRIPTION
        REQ-024 规定：版本头、父键行的书写形态、空行、时间戳/ACL 元数据一律不参与
        比较；参与比较的是「导出范围内的子键集合」与「所有 value 的 (name, type, data)
        元组」。因此签名为有序字符串集合：
          key|<规范化键路径>
          value|<规范化键路径>|<value 名小写>|<原始 type=data 文本>
        - value 的 type=data 部分逐字保留（reg export 对同一内容是确定性的）；
        - 长值折行（行尾单个 '\'）先拼回同一条目，避免拆断；
        - (默认) 值 "" 的名字按空串参与签名；
        - ValueNameFilter 非空时只保留该 value（DD-003 的启动项比较范围=目标 value 本身）。
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RegText,
        [AllowEmptyString()][string]$ValueNameFilter = ''
    )

    $lines = @($RegText -split "\r?\n")
    $sig = [System.Collections.Generic.List[string]]::new()
    $curKey = ''
    $pending = $null

    foreach ($raw in $lines) {
        $l = [string]$raw

        if ($null -ne $pending) {
            # 正在折行：本行内容并入同一条目，直到出现不以 '\' 结尾的行
            $t = $l.Trim()
            if ($t.StartsWith('\\')) { $t = $t.Substring(1) }
            $pending.Text = $pending.Text + $t
            if (Test-RegContinuation -Line $l) {
                $pending.Text = $pending.Text -replace '\\$', ''
                continue
            }
            Add-RegSignatureLine -List $sig -KeyPath $pending.Key -ValueName $pending.Name `
                -ValueText $pending.Text -ValueNameFilter $ValueNameFilter
            $pending = $null
            continue
        }

        if ($l -match '^\s*\[(.+)\]\s*$') {
            $curKey = $Matches[1]
            $null = $sig.Add('key|' + (Get-NormalizedRegKeyPath -Path $curKey))
            continue
        }

        $m = [regex]::Match($l, '^\s*"((?:[^"\\]|\\.)*)"\s*=(?<rest>.*)$')
        if (-not $m.Success) { continue }
        $text = $m.Groups['rest'].Value.Trim()
        $cont = Test-RegContinuation -Line $l
        if ($cont) { $text = $text -replace '\\$', '' }
        $pending = @{
            Name = $m.Groups[1].Value.ToLowerInvariant()
            Text = $text
            Key  = $curKey
        }
        if (-not $cont) {
            Add-RegSignatureLine -List $sig -KeyPath $pending.Key -ValueName $pending.Name `
                -ValueText $pending.Text -ValueNameFilter $ValueNameFilter
            $pending = $null
        }
    }

    if ($null -ne $pending) {
        Add-RegSignatureLine -List $sig -KeyPath $pending.Key -ValueName $pending.Name `
            -ValueText $pending.Text -ValueNameFilter $ValueNameFilter
    }

    return @($sig | Sort-Object -Unique)
}

function Test-RegStructureIdentical {
    <#
    .SYNOPSIS
        两份 .reg 文本在 REQ-024 的比较口径下是否一致（纯函数）。
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BackupText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentText,
        [AllowEmptyString()][string]$ValueNameFilter = ''
    )

    $a = @(Get-RegExportStructure -RegText $BackupText -ValueNameFilter $ValueNameFilter)
    $b = @(Get-RegExportStructure -RegText $CurrentText -ValueNameFilter $ValueNameFilter)
    if ($a.Count -eq 0 -or $b.Count -eq 0) {
        return @{ Identical = $false; Differences = @('empty_structure'); BackupCount = $a.Count; CurrentCount = $b.Count }
    }
    $diff = @()
    foreach ($x in $a) { if (-not ($b -ccontains $x)) { $diff += ('missing_in_current:' + $x) } }
    foreach ($y in $b) { if (-not ($a -ccontains $y)) { $diff += ('added_in_current:' + $y) } }
    return @{ Identical = ($diff.Count -eq 0); Differences = $diff; BackupCount = $a.Count; CurrentCount = $b.Count }
}

function Open-RegistryKeyForRead {
    <#
    .SYNOPSIS
        以只读方式打开注册表键（'HKLM\SOFTWARE\Foo' 形态）；失败返回 $null，不抛。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $p = $Path.Trim().Trim('"').Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    $i = $p.IndexOf('\')
    if ($i -lt 0) { $hive = $p; $rest = '' } else { $hive = $p.Substring(0, $i); $rest = $p.Substring($i + 1) }
    $map = @{
        'HKLM' = 'LocalMachine'; 'HKEY_LOCAL_MACHINE' = 'LocalMachine'
        'HKCU' = 'CurrentUser'; 'HKEY_CURRENT_USER' = 'CurrentUser'
        'HKU' = 'Users'; 'HKEY_USERS' = 'Users'
        'HKCC' = 'CurrentConfig'; 'HKEY_CURRENT_CONFIG' = 'CurrentConfig'
        'HKCR' = 'ClassesRoot'; 'HKEY_CLASSES_ROOT' = 'ClassesRoot'
    }
    $name = $map[$hive.ToUpperInvariant()]
    if ($null -eq $name) { return $null }
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::$name, [Microsoft.Win32.RegistryView]::Default)
        if ($null -eq $base) { return $null }
        if ([string]::IsNullOrWhiteSpace($rest)) { return $base }
        return $base.OpenSubKey($rest)
    } catch {
        return $null
    }
}

function Get-CurrentRegSnapshot {
    <#
    .SYNOPSIS
        把某注册表键的**当前**内容导出到临时文件并读出文本（只读探测）。
    .DESCRIPTION
        复用 Export-RegistryKeyBackup 的同一条 reg export 通道，因此「当前态」与
        「备份态」的文本形态完全可比。快照文件名带 guid，用完立即删除，不参与日志
        自证（自证只校验条目记录的 backup_file）。键不存在时返回 Absent=$true，
        而不是把 reg.exe 的错误当异常。
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$BackupDir
    )

    $id = 'probe-' + [guid]::NewGuid().ToString('N')
    $r = Export-RegistryKeyBackup -Key $Key -BackupDir $BackupDir -Id $id
    if (-not $r.Ok) {
        if ($r.Reason -like 'export_failed(reg_exit_*') {
            return @{ Ok = $false; Absent = $true; Text = ''; Reason = $r.Reason }
        }
        return @{ Ok = $false; Absent = $false; Text = ''; Reason = $r.Reason }
    }
    $rd = Read-RegUnicodeFile -Path $r.Path
    try { Remove-Item -LiteralPath $r.Path -Force -ErrorAction SilentlyContinue } catch { $null = $r.Path }
    if (-not $rd.Ok) { return @{ Ok = $false; Absent = $true; Text = ''; Reason = $rd.Reason } }
    return @{ Ok = $true; Absent = $false; Text = $rd.Content; Reason = '' }
}

function Get-RollbackEntryProbe {
    <#
    .SYNOPSIS
        单个条目的当前状态探测（返回 TargetState + 结构差异证据）。
    .DESCRIPTION
        - registry_key：键不存在 -> absent；存在 -> 与备份整键结构比较。
        - startup_value：只比较目标 value 本身（REQ-024 比较口径）；父键或该 value
          不存在 -> absent。
        - path_entry：段在 PATH 里 -> present_match；不在 -> absent。
        - 其余（不可恢复类）：不参与系统比较，返回 absent 占位（判定层按 kind 先短路）。
        备份读不出 / 当前态探测失败时返回 @{ Ok = $false }，调用方 fail-closed
        （缺状态 -> Get-RestorableEntry 判 conflict/missing_target_state）——
        **绝不**把「读不动」当成「不存在」去恢复。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [Parameter(Mandatory)][string]$BackupDir,
        [AllowNull()][string]$MachinePath
    )

    $kind = [string]$Entry['kind']
    $target = [string]$Entry['target']

    if ($kind -eq 'path_entry') {
        if ($null -eq $MachinePath) { return @{ Ok = $true; TargetState = 'absent' } }
        $c = Confirm-PathEntryRemoved -PathList $MachinePath -Entry $target
        if ($c.Absent) { return @{ Ok = $true; TargetState = 'absent' } }
        return @{ Ok = $true; TargetState = 'present_match' }
    }
    if ($kind -ne 'registry_key' -and $kind -ne 'startup_value') {
        return @{ Ok = $true; TargetState = 'absent' }
    }

    $bf = [string]$Entry['backup_file']
    if ([string]::IsNullOrWhiteSpace($bf)) { return @{ Ok = $false; TargetState = ''; Reason = 'backup_file_missing' } }
    $bfPath = $bf
    if (-not [System.IO.Path]::IsPathRooted($bfPath)) { $bfPath = Join-Path $BackupDir $bf }
    $bk = Read-RegUnicodeFile -Path $bfPath
    if (-not $bk.Ok) { return @{ Ok = $false; TargetState = ''; Reason = ('backup_unreadable:' + $bk.Reason) } }

    if ($kind -eq 'startup_value') {
        $parts = Split-StartupTarget -Target $target
        if ([string]::IsNullOrWhiteSpace($parts.ValueName)) {
            return @{ Ok = $false; TargetState = ''; Reason = 'target_not_decomposable' }
        }
        # 备份本身必须仍是「恰好一个值定义」：被篡改成多值的备份不得被当作一致
        $bkTrim = Get-TrimmedRegExport -RegText $bk.Content -ValueName $parts.ValueName -ParentKey $parts.Key
        if (-not $bkTrim.Ok) {
            return @{ Ok = $false; TargetState = ''; Reason = ('backup_not_single_value:' + $bkTrim.Reason) }
        }

        $hkey = Open-RegistryKeyForRead -Path $parts.Key
        if ($null -eq $hkey) { return @{ Ok = $true; TargetState = 'absent' } }
        $names = $null
        try { $names = @($hkey.GetValueNames()) } catch { $names = $null }
        try { $hkey.Close() } catch { $null = $hkey }
        if ($null -eq $names) {
            return @{ Ok = $false; TargetState = ''; Reason = 'parent_values_unreadable' }
        }
        if (-not ($names -contains $parts.ValueName)) { return @{ Ok = $true; TargetState = 'absent' } }

        $snap = Get-CurrentRegSnapshot -Key $parts.Key -BackupDir $BackupDir
        if (-not $snap.Ok) {
            return @{ Ok = $false; TargetState = ''; Reason = ('current_export_failed:' + $snap.Reason) }
        }
        $curTrim = Get-TrimmedRegExport -RegText $snap.Text -ValueName $parts.ValueName -ParentKey $parts.Key
        if (-not $curTrim.Ok) {
            # 当前值读不出唯一形态（歧义/缺失）：按不一致处理（conflict），不做猜测
            return @{ Ok = $true; TargetState = 'present_mismatch'; Reason = ('current_trim_failed:' + $curTrim.Reason) }
        }
        $cmp = Test-RegStructureIdentical -BackupText $bkTrim.Content -CurrentText $curTrim.Content `
            -ValueNameFilter $parts.ValueName
        $st = 'present_mismatch'
        if ($cmp.Identical) { $st = 'present_match' }
        return @{ Ok = $true; TargetState = $st; Differences = $cmp.Differences }
    }

    $keyPath = ConvertTo-CanonicalRegKeyPath -Path $target
    if (-not (Test-Path -LiteralPath $keyPath)) { return @{ Ok = $true; TargetState = 'absent' } }
    $snap = Get-CurrentRegSnapshot -Key $target -BackupDir $BackupDir
    if (-not $snap.Ok) {
        if ($snap.Absent) { return @{ Ok = $true; TargetState = 'absent' } }
        return @{ Ok = $false; TargetState = ''; Reason = ('current_export_failed:' + $snap.Reason) }
    }
    $cmp = Test-RegStructureIdentical -BackupText $bk.Content -CurrentText $snap.Text
    $st = 'present_mismatch'
    if ($cmp.Identical) { $st = 'present_match' }
    return @{ Ok = $true; TargetState = $st; Differences = $cmp.Differences }
}

function Get-RollbackEntryParentKey {
    <#
    .SYNOPSIS
        一个注册表类条目所属的**父键**（迹象 (ii) 的作用域）。
    .DESCRIPTION
        startup_value 的 target 是复合串 "<父键>|<value>"，其父键就是 Run/RunOnce 本身
        （删除 value 更新的就是这个键）；registry_key 的父键是键路径的上_one 段。
        解析不出来时返回空串（调用方按证据不完整处理）。
    #>
    param([Parameter(Mandatory)][hashtable]$Entry)

    $kind = [string]$Entry['kind']
    if ($kind -eq 'startup_value') {
        return [string](Split-StartupTarget -Target ([string]$Entry['target'])).Key
    }
    return [string](Get-RegistryParentPath -Key ([string]$Entry['target']))
}

function Get-ParentBaselineMaxByParent {
    <#
    .SYNOPSIS
        按**父键**聚合 MAX(parent_baseline)（REQ-024 迹象 (ii) 的比较对象）。
    .DESCRIPTION
        REQ-024 要的是「该父键下所有条目基线的最大值」，不是全日志一个最大值：
        用全局 MAX 会让「基线很晚的父键」把「基线很早的父键」的外部写入洗掉
        （外部时间落在两者之间时，早期父键的 LWT 仍 <= 全局 MAX，迹象 (ii) 漏检）。
        null / 不可解析的基线跳过；某父键全部条目都缺基线时该父键不进 map，
        调用方据 $null 判「迹象 (ii) 不可判定」并标注证据不完整（AC-075a 对称容错）。
        键一律以 Get-NormalizedRegKeyPath 归一，长短 hive 写法视为同一父键。
    #>
    param([Parameter(Mandatory)][hashtable]$Journal)

    $map = @{}
    foreach ($e in (Get-RollbackJournalEntryList -Journal $Journal)) {
        $kind = [string]$e['kind']
        if ($kind -ne 'registry_key' -and $kind -ne 'startup_value') { continue }
        $pb = $e['parent_baseline']
        if ($null -eq $pb) { continue }
        $dt = ConvertFrom-IsoUtc -Text $pb
        if ($null -eq $dt) { continue }
        $parent = Get-RollbackEntryParentKey -Entry $e
        if ([string]::IsNullOrWhiteSpace($parent)) { continue }
        $pk = Get-NormalizedRegKeyPath -Path $parent
        $cur = $map[$pk]
        if ($null -eq $cur -or $dt -gt $cur) { $map[$pk] = $dt }
    }
    return $map
}

function Get-ParentBaselineSnapshot {
    <#
    .SYNOPSIS
        清理阶段写入侧用：取父键**当前** LastWriteTime 并向上取整到整秒（REQ-027/AC-095）。
    .DESCRIPTION
        两个必须同时成立的事实：
          - 日志里的时间戳是秒精度（Format-IsoUtc 丢掉小数秒），
          - 注册表 LastWriteTime 是 100ns 精度。
        因此「删除后立刻 now」直接记为基线时，秒截断会让基线**早于**刚发生的那次删除，
        恢复端就会把**我们自己的删除**判成外部变更（迹象 (ii) 误报，整批降级人工）。
        向上取整到下一整秒可证明 基线 >= 本次操作时刻，同时不会掩盖真正的外部写入
        （外部写入必然晚于本轮最后一次操作）。
        读不到（键不存在 / P-Invoke 失败）返回 $null —— 基线缺失按证据不完整处理。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Key)

    $hkey = Open-RegistryKeyForRead -Path $Key
    if ($null -eq $hkey) { return $null }
    $lw = $null
    try { $lw = Get-RegistryKeyLastWriteTime -Key $hkey } catch { $lw = $null }
    try { $hkey.Close() } catch { $null = $hkey }
    if ($null -eq $lw) { return $null }

    $t = $lw.ToUniversalTime()
    # [TimeSpan]::TicksPerSecond（写成 TicksSecond 取到的是 $null，取模即除零）
    $truncated = [datetime]::new($t.Ticks - ($t.Ticks % [TimeSpan]::TicksPerSecond), [DateTimeKind]::Utc)
    if ($truncated -ne $t) { $truncated = $truncated.AddSeconds(1) }
    return Format-IsoUtc -Value $truncated
}

function Get-SignIiInputForEntry {
    <#
    .SYNOPSIS
        对一个注册表类条目算出迹象 (ii) 的输入（Detected / Undecidable）。
    .DESCRIPTION
        父键聚合基线由调用方按父键算一次（Get-ParentBaselineMaxByParent），本函数只读取
        「该条目所属父键」的当前时间戳并与该父键的聚合基线比较。父键打不开 / 时间戳取不到
        都归为 Undecidable（证据不完整），**不得**当作「无外部变更」静默通过。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Entry,
        [AllowNull()]$BaselineMax
    )

    $parentKey = Get-RollbackEntryParentKey -Entry $Entry
    if ([string]::IsNullOrWhiteSpace($parentKey)) {
        return @{ SignIiDetected = $false; SignIiUndecidable = $true; SignIiReason = 'parent_key_unresolved' }
    }
    $hkey = Open-RegistryKeyForRead -Path $parentKey
    if ($null -eq $hkey) {
        return @{ SignIiDetected = $false; SignIiUndecidable = $true; SignIiReason = 'parent_key_unreadable' }
    }
    try {
        $r = Test-ExternalChangeSignRegistry -ParentKey $hkey -BaselineMax $BaselineMax
    } catch {
        return @{ SignIiDetected = $false; SignIiUndecidable = $true; SignIiReason = 'probe_threw' }
    } finally {
        # 句柄必须释放：恢复阶段要对同一父键反复开键，泄漏会耗尽句柄并把可用探测
        # 变成「打不开」，进而误判为证据不完整。
        try { $hkey.Close() } catch { $null = $hkey }
    }
    return @{
        SignIiDetected    = [bool]$r.Detected
        SignIiUndecidable = [bool]$r.Undecidable
        SignIiReason      = [string]$r.Reason
    }
}

function Restore-RegistryBackupFile {
    <#
    .SYNOPSIS
        把一个 .reg 备份文件回灌（reg import），并复查目标是否真的回来了。
    .DESCRIPTION
        只 import 调用方给定的受控文件（越界校验在写入端与自证阶段已完成）。
        复查分两种粒度：
          - 注册表键：键路径 Test-Path 回来即算恢复；
          - 启动项 value（DD-003）：父键**本来就一直存在**，只查键会把「value 没回来」
            说成恢复成功，因此必须查 value 名。
        返回 @{ Ok; Reason }；Reason 形如 import_failed(backup_missing) /
        import_failed(reg_exit_N) / import_failed(verify_absent) /
        import_failed(verify_unreadable)。
    #>
    param(
        [Parameter(Mandatory)][string]$BackupFile,
        [Parameter(Mandatory)][AllowEmptyString()][string]$VerifyPath,
        [AllowEmptyString()][string]$VerifyValueName = ''
    )

    if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) {
        return @{ Ok = $false; Reason = 'import_failed(backup_missing)' }
    }
    $r = Invoke-RegExe -Arguments @('import', $BackupFile)
    if (-not $r.ok) {
        if ($null -eq $r.exit_code) {
            return @{ Ok = $false; Reason = 'import_failed(reg_unavailable)' }
        }
        return @{ Ok = $false; Reason = ('import_failed(reg_exit_' + $r.exit_code + ')') }
    }
    if ($VerifyValueName -ne '') {
        $hkey = Open-RegistryKeyForRead -Path $VerifyPath
        if ($null -eq $hkey) { return @{ Ok = $false; Reason = 'import_failed(verify_absent)' } }
        $names = $null
        try { $names = @($hkey.GetValueNames()) } catch { $names = $null }
        try { $hkey.Close() } catch { $null = $hkey }
        if ($null -eq $names) { return @{ Ok = $false; Reason = 'import_failed(verify_unreadable)' } }
        if (-not ($names -contains $VerifyValueName)) {
            return @{ Ok = $false; Reason = 'import_failed(verify_absent)' }
        }
        return @{ Ok = $true; Reason = '' }
    }
    if (-not [string]::IsNullOrWhiteSpace($VerifyPath)) {
        $ps = ConvertTo-CanonicalRegKeyPath -Path $VerifyPath
        if (-not (Test-Path -LiteralPath $ps)) {
            return @{ Ok = $false; Reason = 'import_failed(verify_absent)' }
        }
    }
    return @{ Ok = $true; Reason = '' }
}

function Get-RestoredMachinePath {
    <#
    .SYNOPSIS
        计算 PATH 恢复后的整作用域值（REQ-021：以整作用域为恢复单位）。
    .DESCRIPTION
        起点是 journal 记录的 Machine PATH 原值，然后**移除**那些「本轮删除成功、
        但本次不恢复」的段（判定为 conflict / restore_failed 的 path_entry）。
        于是「全部恢复」= 逐字回到原值，「只恢复一部分」也不会把不恢复的段装回去。
        必须**复用** Get-ExpectedPathAfterCleanup：迹象 (iii) 的「预期当前值」与
        「恢复后写回值」若用两套分段语义（例如一处丢空段、另一处保留），恢复结果
        会是一个从未存在过的 PATH，判定与写入还会互相矛盾。
        纯函数，不做任何写入。原值为 null 时返回 null（调用方 fail-closed）。
    #>
    param(
        [AllowNull()][string]$OriginalPath,
        [AllowEmptyCollection()][string[]]$RemovedEntries = @()
    )

    return Get-ExpectedPathAfterCleanup -OriginalPath $OriginalPath -RemovedEntries $RemovedEntries
}

function Get-ReportedRollbackVerdict {
    <#
    .SYNOPSIS
        把决策表的内部裁决映射为 REQ-009 规定的四种对外判定之一。
    .DESCRIPTION
        对外只有 restored / already_present / not_restorable / restore_failed；
        决策表产出的 conflict（以及执行失败）一律归入 restore_failed 并保留原因，
        「未变更」归入 already_present，**绝不**新增第五种判定。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Verdict,
        [bool]$Executed = $false,
        [AllowEmptyString()][string]$ExecReason = ''
    )

    $v = [string]$Verdict['Verdict']
    $reason = [string]$Verdict['Reason']
    $out = 'restore_failed'

    if ($v -eq 'restore') {
        if ($Executed) {
            $out = 'restored'
            $reason = ''
        } else {
            $out = 'restore_failed'
            $reason = 'restore_failed(' + $ExecReason + ')'
        }
    } elseif ($v -eq 'already_present') {
        $out = 'already_present'
    } elseif ($v -eq 'not_restorable') {
        $out = 'not_restorable'
    } else {
        $out = 'restore_failed'
        $reason = 'conflict(' + $reason + ')'
    }

    return @{
        ItemId             = [string]$Verdict['ItemId']
        Id                 = [string]$Verdict['Id']
        Kind               = [string]$Verdict['Kind']
        Target             = [string]$Verdict['Target']
        Verdict            = $out
        Reason             = $reason
        EvidenceIncomplete = [bool]$Verdict['EvidenceIncomplete']
        # 迹象 (iii) 的比较证据必须穿过投影进入 rollback-result.json：
        # 只留一个 reason token 时，事后审计无法回答「哪个值 vs 哪个值」。
        ExpectedPath       = $Verdict['ExpectedPath']
        PathCurrent        = $Verdict['PathCurrent']
        PathCompare        = [string]$Verdict['PathCompare']
    }
}

function Write-RollbackResult {
    <#
    .SYNOPSIS
        原子写 rollback-result.json 到本轮备份目录（REQ-008 的可审计产出）。
    #>
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][hashtable]$Result
    )

    $target = Join-Path $BackupDir 'rollback-result.json'
    Write-FileAtomic -TargetPath $target -Content ($Result | ConvertTo-Json -Depth 10)
    return $target
}

function Invoke-RollbackRestore {
    <#
    .SYNOPSIS
        消费一份回滚日志，按 REQ-024 两阶段协议逐项精准恢复。
    .DESCRIPTION
        T2（本轮清理部分失败后的进程内回滚）、T3（下次启动消费上轮日志）与
        rollback.ps1 -Auto 共用本函数，因此**不**在这里决定退出码语义：返回结构化
        的判定汇总，由调用方映射 REQ-026 的 10/11/12/13/14/15。
        阶段划分（REQ-024 迹象 (ii) 的硬要求）：
          1. 全部条目只读探测 + 判定（父键聚合基线只比较一次）；
          2. 判定为 restore 的条目才执行；PATH 作为整作用域一次性写回。
        -AcknowledgeConflicts 是**逃生口**（REQ-030）：只影响标记与调用方的后续动作，
        不改变判定本身，也绝不静默覆盖冲突目标。
        $Now / $MachinePathOverride / $SetPathScript 为测试注入点：
        SetPathScript 是「如何写 Machine PATH」的接缝，单测用它断言写回内容，
        而不会真的改动本机 PATH。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$AcknowledgeConflicts,
        [AllowNull()]$Now = $null,
        [AllowNull()][string]$MachinePathOverride,
        [AllowNull()][scriptblock]$SetPathScript
    )

    if ($null -eq $Now) {
        $nowUtc = (Get-Date).ToUniversalTime()
    } else {
        $nowUtc = ([datetime]$Now).ToUniversalTime()
    }
    $nowIso = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $entries = Get-RollbackJournalEntryList -Journal $Journal

    # ── 窗口（REQ-024：原点恒为 created_at，终点为本次恢复尝试时刻） ──
    # created_at 缺失时**不**调用 Test-WithinRecoveryWindow（其 -CreatedAt 是 Mandatory，
    # 绑 null 会抛绑定异常，把整轮恢复炸成未定义行为）；按「无法确认时间」处理：
    # REQ-024 规定无法确认时间一律降级 conflict，不自动恢复。
    if ($null -eq $Journal['created_at'] -or [string]::IsNullOrWhiteSpace([string]$Journal['created_at'])) {
        $win = @{ Within = $false; Reason = 'created_at_missing'; ElapsedHours = $null }
    } else {
        $win = Test-WithinRecoveryWindow -CreatedAt $Journal['created_at'] -Now $nowUtc
    }
    $within = [bool]$win.Within

    # ── PATH：本轮原值与当前值（只读一次，供迹象 (iii) 与整作用域写回） ──
    $mpOriginalText = $null
    $mo = $Journal['machine_path_original']
    if ($null -ne $mo) { $mpOriginalText = [string]$mo }

    $pathEntries = @($entries | Where-Object { [string]$_.kind -eq 'path_entry' })
    $mpCurrent = $null
    $expectedPath = $null
    $removedSegments = @()
    if ($pathEntries.Count -gt 0) {
        if ($null -ne $MachinePathOverride) {
            $mpCurrent = [string]$MachinePathOverride
        } else {
            try { $mpCurrent = [Environment]::GetEnvironmentVariable('Path', 'Machine') } catch { $mpCurrent = $null }
        }
        foreach ($e in $pathEntries) {
            if ([string]$e['state'] -ne 'mutation_succeeded') { continue }
            $removedSegments += ([string]$e['target'])
        }
        $expectedPath = Get-ExpectedPathAfterCleanup -OriginalPath $mpOriginalText -RemovedEntries $removedSegments
    }

    # ── 父键聚合基线（恢复端只读、在任何恢复写入之前只算一次） ──
    $baselineByParent = Get-ParentBaselineMaxByParent -Journal $Journal
    $baselineMax = Get-ParentBaselineMax -Journal $Journal

    # ── 阶段 1：逐条探测 + 判定，绝不写系统 ──
    $targetStates = @{}
    $idMap = @{}
    foreach ($e in $entries) {
        $iid = [string]$e['item_id']
        if ([string]::IsNullOrWhiteSpace($iid)) {
            $iid = Get-ItemId -Kind ([string]$e['kind']) -Target ([string]$e['target'])
        }
        $probe = Get-RollbackEntryProbe -Entry $e -BackupDir $BackupDir -MachinePath $mpCurrent
        if ($probe.Ok) { $targetStates[$iid] = [string]$probe.TargetState }
        # probe 失败时**不**写入状态：Get-RestorableEntry 会 fail-closed 判
        # conflict(missing_target_state)，绝不把「探测不了」当成「目标不存在」。

        $extra = @{}
        $kind = [string]$e['kind']
        if ($kind -eq 'registry_key' -or $kind -eq 'startup_value') {
            $pk = Get-NormalizedRegKeyPath -Path (Get-RollbackEntryParentKey -Entry $e)
            $entryBaseline = $null
            if ($pk -ne '' -and $null -ne $baselineByParent[$pk]) { $entryBaseline = $baselineByParent[$pk] }
            $ii = Get-SignIiInputForEntry -Entry $e -BaselineMax $entryBaseline
            $extra['SignIiDetected'] = [bool]$ii.SignIiDetected
            $extra['SignIiUndecidable'] = [bool]$ii.SignIiUndecidable
        }
        if ($kind -eq 'path_entry') {
            $extra['PathExpected'] = $expectedPath
            $extra['PathCurrent'] = $mpCurrent
        }
        $idMap[$iid] = $extra
    }

    $batch = Get-RestorableEntry -Entries $entries -TargetStates $targetStates `
        -TargetIdMap $idMap -WithinWindow $within

    # ── 阶段 2：仅对判定为 restore 的条目执行 ──
    $execOk = @{}
    $execReason = @{}
    $pathToRestore = @()
    foreach ($e in @($batch.Restore)) {
        $iid = [string]$e['item_id']
        if ([string]::IsNullOrWhiteSpace($iid)) {
            $iid = Get-ItemId -Kind ([string]$e['kind']) -Target ([string]$e['target'])
        }
        $kind = [string]$e['kind']
        if ($kind -eq 'path_entry') { $pathToRestore += $e; continue }

        $bf = [string]$e['backup_file']
        $bfPath = $bf
        if (-not [System.IO.Path]::IsPathRooted($bfPath)) { $bfPath = Join-Path $BackupDir $bf }
        $verify = [string]$e['target']
        $verifyValue = ''
        if ($kind -eq 'startup_value') {
            $sp = Split-StartupTarget -Target $verify
            $verify = $sp.Key
            if ([string]::IsNullOrWhiteSpace($sp.ValueName)) {
                $execOk[$iid] = $false
                $execReason[$iid] = 'import_failed(target_not_decomposable)'
                continue
            }
            $verifyValue = [string]$sp.ValueName
        }
        $rs = Restore-RegistryBackupFile -BackupFile $bfPath -VerifyPath $verify -VerifyValueName $verifyValue
        $execOk[$iid] = [bool]$rs.Ok
        $execReason[$iid] = [string]$rs.Reason
    }

    # PATH：整作用域一次写回。
    # 迹象 (iii) 是**作用域级**判定（当前整串 vs 预期整串），因此同一作用域内的
    # path_entry 条目要么全部判为 restore、要么全部降级 conflict，不存在「只恢复一部分」；
    # 于是写回值就是原值逐字（Get-ExpectedPathAfterCleanup 空移除集 = 原样）。
    if ($pathToRestore.Count -gt 0) {
        $newPath = Get-RestoredMachinePath -OriginalPath $mpOriginalText
        $writeOk = $false
        $why = ''
        if ($null -eq $newPath) {
            $why = 'original_path_missing'
        } else {
            try {
                # $SetPathScript 是「写 Machine PATH 并**回读**出结果」的接缝：
                # 单测注入它即可断言写回内容，而不会改动本机 PATH。
                # 真实路径写后必须重新从注册表读回——SetEnvironmentVariable 静默失败
                # （非管理员 / 策略锁定）时不能把「以为写进去了」当成恢复成功。
                $after = $null
                if ($null -ne $SetPathScript) {
                    $after = & $SetPathScript $newPath
                    if ($null -ne $after) { $after = [string]$after }
                } else {
                    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
                    try { $after = [Environment]::GetEnvironmentVariable('Path', 'Machine') } catch { $after = $null }
                }
                if ([string]::IsNullOrWhiteSpace($after)) {
                    $why = 'path_write_unverified'
                } else {
                    $allBack = $true
                    foreach ($e in $pathToRestore) {
                        $c = Confirm-PathEntryRemoved -PathList $after -Entry ([string]$e['target'])
                        if ($c.Absent) { $allBack = $false; $why = 'path_write_verify_failed' }
                    }
                    if ($allBack) { $writeOk = $true }
                }
            } catch {
                $msg = ($_.Exception.Message -replace '[^\w.-]', '_')
                $why = 'path_write_failed(' + $msg + ')'
            }
        }
        foreach ($e in $pathToRestore) {
            $iid = [string]$e['item_id']
            if ([string]::IsNullOrWhiteSpace($iid)) {
                $iid = Get-ItemId -Kind 'path_entry' -Target ([string]$e['target'])
            }
            $execOk[$iid] = $writeOk
            $execReason[$iid] = $why
        }
    }

    # ── 汇总：内部裁决 -> 四种对外判定 ──
    $reported = @()
    foreach ($v in @($batch.Verdicts)) {
        $iid = [string]$v.ItemId
        if ([string]$v.Verdict -eq 'restore') {
            $exec = $false
            if ($null -ne $execOk[$iid]) { $exec = [bool]$execOk[$iid] }
            $whyExec = ''
            if ($null -ne $execReason[$iid]) { $whyExec = [string]$execReason[$iid] }
            $reported += , (Get-ReportedRollbackVerdict -Verdict $v -Executed $exec -ExecReason $whyExec)
        } else {
            $reported += , (Get-ReportedRollbackVerdict -Verdict $v)
        }
    }

    $counts = @{
        restored        = @($reported | Where-Object { $_.Verdict -eq 'restored' }).Count
        already_present = @($reported | Where-Object { $_.Verdict -eq 'already_present' }).Count
        not_restorable  = @($reported | Where-Object { $_.Verdict -eq 'not_restorable' }).Count
        restore_failed  = @($reported | Where-Object { $_.Verdict -eq 'restore_failed' }).Count
    }

    # 未修复清单（REQ-030/031）：restore_failed 全部入清单；
    # not_restorable 是如实告知（本来就不可能自动恢复），不算待修。
    $unrepaired = @()
    foreach ($r in $reported) {
        if ($r.Verdict -ne 'restore_failed') { continue }
        # Add-UnrepairedItem 以 `return , $new` 保住空数组语义，因此这里**必须**普通赋值：
        # 再套一层 @() 会得到「元素是数组」的两层嵌套，落盘清单变成 [[item], item]。
        $unrepaired = Add-UnrepairedItem -List $unrepaired -ItemId ([string]$r.ItemId) `
            -Reason ([string]$r.Reason) -Kind ([string]$r.Kind) -Target ([string]$r.Target)
    }

    $baselineIso = $null
    if ($null -ne $baselineMax) { $baselineIso = Format-IsoUtc -Value ([datetime]$baselineMax) }

    $persistenceError = $false
    $resultPath = ''
    try {
        $resultPath = Write-RollbackResult -BackupDir $BackupDir -Result @{
            run_id        = [string]$Journal['run_id']
            executed_at   = $nowIso
            within_window = $within
            baseline_max  = $baselineIso
            counts        = $counts
            verdicts      = @($reported)
        }
    } catch { $persistenceError = $true }

    $unrepairedPath = ''
    if ($unrepaired.Count -gt 0) {
        try {
            $unrepairedPath = Write-UnrepairedList -ProjectRoot $ProjectRoot `
                -RunId ([string]$Journal['run_id']) -Items $unrepaired `
                -BackupDir $BackupDir `
                -Reason 'rollback_incomplete' -CreatedAt $nowIso
        } catch { $persistenceError = $true }
    }

    # Format-RollbackReport 用 `return , $lines` 保住空数组语义，因此调用方**不得**
    # 再套 @()——那会得到「一个元素是数组」的两层嵌套，下游 -join 会打印
    # System.Object[]，整份人读报告变成乱码。
    $reportLines = Format-RollbackReport -Verdicts $batch.Verdicts

    return @{
        RunId            = [string]$Journal['run_id']
        Verdicts         = @($reported)
        Counts           = $counts
        WithinWindow     = $within
        WindowReason     = [string]$win.Reason
        ElapsedHours     = $win.ElapsedHours
        BaselineMax      = $baselineMax
        Unrepaired       = @($unrepaired)
        UnrepairedPath   = $unrepairedPath
        ResultPath       = $resultPath
        PersistenceError = $persistenceError
        Acknowledged     = [bool]$AcknowledgeConflicts
        Report           = $reportLines
    }
}

function Set-JournalConsumedWithoutRestore {
    <#
    .SYNOPSIS
        把一份「已承认结束、但不执行恢复」的日志落盘：先未修复清单，成功后才写标记（REQ-030）。
    .DESCRIPTION
        顺序是承重的：REQ-030 禁止「已确认但清单丢失」的状态——那样唯一的证据已经没了，
        用户却以为问题被记录过。所以 (1) 原子写未修复清单（落在项目根 output/，**不在**
        backup 目录内，否则删掉备份目录会连带删掉清单），(2) 只有清单写成功后才写
        completed_at + consumed_with_failure + 旁路标记。清单写失败 → 一份标记都不写
        （AC-078），调用方按 15 处理。

        run_id 不合法（或日志读不出条目）时没有可展开的条目，仍写一份**候选级**清单：
        `unrepaired[]` 为空数组 + `candidate_unparseable=true` + `backup_dir`，
        使 AC-060 的「先清单后标记」顺序对三类 14 情形都成立且可测。
        清单文件名里的 run_id 一律先验合法性：不合法就改用备份目录名，
        绝不把日志里外部可控的字符串直接拼进路径。
    #>
    # 与 rollback-producer.ps1 同一约定：本管道的写入函数一律不带 ShouldProcess。
    # WhatIf 等价物是调用方 `Invoke-RollbackJournalConsumption -DryRun`，它在进入本函数
    # 之前就返回了；而真正的执行者（clean-residuals / rollback -Auto）经 UI 或管道宿主
    # 非交互拉起，交互提示会挂死整条恢复流程——恢复路径挂死比不挂死危险得多。
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param(
        [Parameter(Mandatory)][hashtable]$Candidate,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [ValidateSet('acknowledged_without_restore', 'skipped_older_journal')][string]$Reason,
        [AllowEmptyString()][string]$CompletedAt = ''
    )

    $journal = $Candidate.Journal
    $backupDir = [string]$Candidate.BackupDir
    $runId = [string]$journal['run_id']
    $g = [guid]::Empty
    $runIdOk = [guid]::TryParse($runId, [ref]$g)

    $listRunId = $runId
    if (-not $runIdOk) { $listRunId = [System.IO.Path]::GetFileName($backupDir) }

    $listPath = ''
    try {
        $items = @()
        if ($runIdOk) {
            # 普通赋值：Get-RollbackJournalEntryList 以 `return , $out` 保住空数组语义，
            # 外面再套 @() 会得到「元素是空数组」的一层嵌套，条目字段全读成空串。
            $entries = Get-RollbackJournalEntryList -Journal $journal
            foreach ($e in $entries) {
                if ($null -eq $e) { continue }
                # Add-UnrepairedItem 用 `return , $new`，调用方必须普通赋值（见其文档）。
                $items = Add-UnrepairedItem -List $items -ItemId ([string]$e['item_id']) `
                    -Kind ([string]$e['kind']) -Target ([string]$e['target']) -Reason $Reason
            }
        }
        $listPath = Write-UnrepairedList -ProjectRoot $ProjectRoot -RunId $listRunId `
            -Items $items -BackupDir $backupDir -Reason $Reason `
            -CandidateUnparseable:(-not $runIdOk)
    } catch {
        # 条目缺 item_id 等畸形日志也走这里：清单写不出来，就一份标记都不写。
        return @{ Ok = $false; Stage = 'unrepaired_list'; Detail = $_.Exception.Message; ListPath = '' }
    }

    if (-not $runIdOk) {
        # 合法标记必须绑定合法 run_id（Write-RecoveryMarker 会抛）；绑不出标记的候选
        # 不能谎称「已确认」——它下一轮仍会留在候选集里，如实交回人工。
        return @{ Ok = $false; Stage = 'unmarkable'; Detail = 'invalid_run_id'; ListPath = $listPath }
    }

    try {
        $journal['consumed_with_failure'] = $true
        $null = Complete-RollbackJournal -BackupDir $backupDir -Journal $journal -CompletedAt $CompletedAt
        $null = Write-RecoveryMarker -BackupDir $backupDir -Kind 'consumed.failed' -RunId $runId
    } catch {
        return @{ Ok = $false; Stage = 'marker'; Detail = $_.Exception.Message; ListPath = $listPath }
    }

    return @{ Ok = $true; Stage = ''; Detail = ''; ListPath = $listPath }
}

function Invoke-RollbackJournalConsumption {
    <#
    .SYNOPSIS
        REQ-019 Step 1..5 的**唯一**消费协议实现：定位 → 判定 → 消费/恢复 → 结构化结论。
    .DESCRIPTION
        为什么必须只有一份：`rollback.ps1 -Auto` 与 clean-residuals 的启动期 T3 读同一份日志、
        依据同一套证据。两处各写一遍「能不能恢复、什么时候写标记」迟早会漂移，而漂移的两个
        方向都是事故——该恢复的没恢复，不该恢复的把用户后来主动删掉的东西装回去。
        本函数**不决定退出码**：返回语义化的 Outcome，由调用方映射自己的码
        （-Auto：0/1/11/12/14/15；启动期：继续清理 / 14 / 15）。
        Outcome 取值：
          no_journal / input_error / unreadable / ambiguous / needs_acknowledgement /
          acknowledged_without_restore / already_completed / suppressed / rejected /
          consumed / consumed_with_skipped / partial_restore / persistence_failed /
          dry_run_reported
        -DryRun 是零副作用模式（AC-010）：只报告发现了什么，不消费、不恢复、不改写任何标记。
        $Now / $MachinePathOverride / $SetPathScript 是透传给 Invoke-RollbackRestore 的测试注入点。
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$JournalPath = '',
        [bool]$AcknowledgeConflicts = $false,
        [switch]$DryRun,
        [AllowNull()]$Now = $null,
        [AllowNull()][string]$MachinePathOverride,
        [AllowNull()][scriptblock]$SetPathScript
    )

    $report = @()
    $result = $null

    $target = Get-RecoveryJournalTarget -ProjectRoot $ProjectRoot -JournalPath $JournalPath

    # ── 歧义（created_at 平局 / 混合可解析性）：绝不选边（REQ-019 / exit 14(c)）──
    if (-not $target.Ok) {
        if ([bool]$target.Ambiguous) {
            $report += '--- Unfinished rollback journals found ---'
            foreach ($c in @($target.Candidates)) {
                $report += ('  {0}  run_id={1}  created_at={2}' -f [string]$c.BackupDir,
                    [string]$c.Journal['run_id'], [string]$c.Journal['created_at'])
            }
            $candCount = @($target.Candidates).Count
            if ($DryRun) {
                $report += ("[DRY-RUN] {0} ambiguous candidate(s); nothing consumed, nothing restored." -f $candCount)
                return @{ Outcome = 'dry_run_reported'; Summary = ("dry_run_ambiguous({0})" -f $candCount);
                          Report = $report; Result = $null; Candidates = @($target.Candidates) }
            }
            if (-not $AcknowledgeConflicts) {
                $report += 'Ambiguous candidates: refusing to pick one. Re-run with -AcknowledgeConflicts to confirm.'
                return @{ Outcome = 'ambiguous'; Summary = 'ambiguous_candidates';
                          Report = $report; Result = $null; Candidates = @($target.Candidates) }
            }
            $marked = 0
            foreach ($c in @($target.Candidates)) {
                $r = Set-JournalConsumedWithoutRestore -Candidate $c -ProjectRoot $ProjectRoot `
                    -Reason 'acknowledged_without_restore'
                if ($r.Ok) { $marked++; continue }
                if ([string]$r.Stage -eq 'unmarkable') {
                    $report += ("  无法确认（run_id 不合法，写不出绑定标记）：{0}" -f [string]$c.BackupDir)
                    continue
                }
                $report += ("  确认落盘失败（{0}）：{1}" -f [string]$r.Stage, [string]$r.Detail)
                return @{ Outcome = 'persistence_failed'; Summary = 'acknowledgement_marker_write_failed';
                          Report = $report; Result = $null; Candidates = @($target.Candidates) }
            }
            return @{ Outcome = 'acknowledged_without_restore';
                      Summary = ("acknowledged_without_restore({0})" -f $marked);
                      Report = $report; Result = $null; Candidates = @($target.Candidates) }
        }

        $outcome = 'no_journal'
        if ([string]$target.Reason -eq 'journal_path_not_found') { $outcome = 'input_error' }
        if ([string]$target.Reason -eq 'journal_unreadable') { $outcome = 'unreadable' }
        return @{ Outcome = $outcome; Summary = [string]$target.Reason;
                  Report = $report; Result = $null; Candidates = @($target.Candidates) }
    }

    $journal = $target.Journal
    $backupDir = [string]$target.BackupDir
    $decision = Get-RollbackConsumptionDecision -Journal $journal `
        -RequiresAcknowledgement ([bool]$target.RequiresAcknowledgement) `
        -AcknowledgeConflicts:$AcknowledgeConflicts

    if ([string]$decision.Action -eq 'already_completed') {
        $report += "Rollback journal already completed (run_id=$($journal['run_id'])). No target touched, nothing restored."
        return @{ Outcome = 'already_completed'; Summary = 'journal_already_completed';
                  Report = $report; Result = $null; Candidates = @() }
    }

    if ($DryRun) {
        $report += ("[DRY-RUN] Unfinished rollback journal found (run_id={0}, {1}); nothing consumed, nothing restored." -f `
            [string]$journal['run_id'], [string]$decision.Action)
        $report += '[DRY-RUN] Run once without -DryRun to complete the recovery before any new cleanup.'
        return @{ Outcome = 'dry_run_reported'; Summary = 'dry_run_reported';
                  Report = $report; Result = $null; Candidates = @($target.Candidates) }
    }

    if ([string]$decision.Action -eq 'suppress') {
        $report += "Rollback suppressed: cleanup had actually finished (run_id=$($journal['run_id'])). Nothing restored."
        if ($decision.EvidenceMissing) {
            $report += '  抑制依据缺失（清理日志不可读），仅按 completed_at 判定处理。'
        }
        try {
            if ([string]$decision.Reason -eq 'acknowledged_without_restore') {
                # 人确认过 = 「承认它结束了、不要再自动恢复」，如实记 consumed_with_failure，
                # 与歧义候选的确认路径同一语义。
                $journal['consumed_with_failure'] = $true
            }
            $null = Complete-RollbackJournal -BackupDir $backupDir -Journal $journal
        } catch {
            $report += ("  完成标记写入失败：{0}" -f $_.Exception.Message)
            return @{ Outcome = 'persistence_failed'; Summary = 'completion_marker_write_failed';
                      Report = $report; Result = $null; Candidates = @() }
        }
        return @{ Outcome = 'suppressed'; Summary = ("suppressed({0})" -f [string]$decision.Reason);
                  Report = $report; Result = $null; Candidates = @() }
    }

    if ([string]$decision.Action -eq 'needs_acknowledgement') {
        $report += ("Rollback needs explicit human acknowledgement (run_id={0}): {1}" -f `
            [string]$journal['run_id'], [string]$decision.Reason)
        $report += 'Re-run with -AcknowledgeConflicts to confirm this journal, or point at it with -JournalPath.'
        return @{ Outcome = 'needs_acknowledgement'; Summary = [string]$decision.Reason;
                  Report = $report; Result = $null; Candidates = @() }
    }

    if ([string]$decision.Action -eq 'reject') {
        $report += ("Rollback journal cannot be consumed safely (run_id={0}): {1}" -f `
            [string]$journal['run_id'], [string]$decision.Reason)
        foreach ($r in @($decision.Reasons)) { $report += "  - $r" }
        return @{ Outcome = 'rejected'; Summary = [string]$decision.Reason;
                  Report = $report; Result = $null; Candidates = @() }
    }

    # ── restore（Step 5）──
    # 不用 `$args`：那是 PowerShell 自动变量，在此赋值会遮蔽未命名参数集合（同类坑见 AGENTS.md 陷阱 2）。
    $restoreArgs = @{
        Journal              = $journal
        BackupDir            = $backupDir
        ProjectRoot          = $ProjectRoot
        AcknowledgeConflicts = [bool]$AcknowledgeConflicts
    }
    if ($null -ne $Now) { $restoreArgs['Now'] = $Now }
    if ($null -ne $MachinePathOverride) { $restoreArgs['MachinePathOverride'] = $MachinePathOverride }
    if ($null -ne $SetPathScript) { $restoreArgs['SetPathScript'] = $SetPathScript }
    $result = Invoke-RollbackRestore @restoreArgs

    # Format-RollbackReport 用 `return , $lines` 保住空数组语义，调用方不得再套 @()。
    foreach ($line in $result.Report) { $report += $line }

    if ($result.PersistenceError) {
        return @{ Outcome = 'persistence_failed'; Summary = 'persistence_record_write_failed';
                  Report = $report; Result = $result; Candidates = @() }
    }

    $failedCount = 0
    if ($null -ne $result.Counts -and $null -ne $result.Counts['restore_failed']) {
        $failedCount = [int]$result.Counts['restore_failed']
    }
    if ($failedCount -gt 0) {
        # REQ-031 / AC-077：系统仍有未修复项，日志必须**保持未完成**，让下次启动继续 T3。
        $report += ("Restore incomplete: {0} item(s) failed. Journal left unfinished; unrepaired list: {1}" -f `
            $failedCount, [string]$result.UnrepairedPath)
        return @{ Outcome = 'partial_restore'; Summary = 'restore_incomplete';
                  Report = $report; Result = $result; Candidates = @() }
    }

    # Step 4a：较旧的候选一份都不恢复，但必须「先清单、成功后才标记」，
    # 否则后续运行会回退到更旧的日志，越过「只回滚紧邻上一轮」的非目标。
    $others = @($target.Candidates)
    $skippedFailed = $false
    foreach ($c in $others) {
        $r = Set-JournalConsumedWithoutRestore -Candidate $c -ProjectRoot $ProjectRoot `
            -Reason 'skipped_older_journal'
        if ($r.Ok) { continue }
        $skippedFailed = $true
        $report += ("  较旧候选标记失败（{0}）：{1}" -f [string]$c.BackupDir, [string]$r.Stage)
    }
    if ($skippedFailed) {
        # 清单或标记没写上 = 本轮持久化记录不可靠（15 是终端码，优先级高于 10/11/14）。
        return @{ Outcome = 'persistence_failed'; Summary = 'older_journal_marker_failed';
                  Report = $report; Result = $result; Candidates = $others }
    }
    if ($others.Count -gt 0) {
        $report += ("{0} older unfinished journal(s) marked consumed-without-restore; recovery of the newest one succeeded." -f $others.Count)
    }

    $consumerRunId = [guid]::NewGuid().ToString()
    try {
        $null = Complete-RollbackJournal -BackupDir $backupDir -Journal $journal -ConsumedByRunId $consumerRunId
        $null = Write-RecoveryMarker -BackupDir $backupDir -Kind 'consumed' -RunId ([string]$journal['run_id'])
    } catch {
        # 消费标记写失败：日志仍是未完成状态，下次启动会重试 —— 但「重试」不等于「已消费」，
        # 只有两个标记都写失败才必须如实上报（REQ-019 Step 4a / 15(iii)）。
        try {
            $null = Write-RecoveryMarker -BackupDir $backupDir -Kind 'consumed.failed' -RunId ([string]$journal['run_id'])
        } catch {
            return @{ Outcome = 'persistence_failed'; Summary = 'consumption_marker_write_failed';
                      Report = $report; Result = $result; Candidates = $others }
        }
    }

    $report += ("Rollback result written: {0}" -f [string]$result.ResultPath)
    $outcome = 'consumed'
    $summary = 'restored'
    if ($others.Count -gt 0) {
        # REQ-019 Step 4a：多份未完成日志时即使最新一份恢复成功，也必须返回 14 并告警。
        $outcome = 'consumed_with_skipped'
        $summary = 'restored_with_skipped_older_journals'
    }
    return @{ Outcome = $outcome; Summary = $summary; Report = $report;
              Result = $result; Candidates = $others }
}
