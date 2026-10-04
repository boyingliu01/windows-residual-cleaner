# rollback-journal.ps1
# 自动回滚日志（rollback-journal.json）的读写核心。
# REQ-005 / REQ-027 / REQ-032 / REQ-034 / REQ-035
#
# 本文件只放**顶层纯函数/可测函数**，不含 Main、不含 exit（ADR-001）。
# 被其它脚本 dot-source 使用。

# ─────────────────────────────────────────────────────────────────────────────
# 平台/引擎辅助
# ─────────────────────────────────────────────────────────────────────────────

function Get-RegistryKeyLastWriteTime {
    <#
    .SYNOPSIS
        取注册表键的 LastWriteTime（REQ-034 / REQ-024 迹象 (ii)）。
    .DESCRIPTION
        受管 API 不暴露该值：[Microsoft.Win32.RegistryKey] 只有
        SubKeyCount/View/Handle/ValueCount/Name，PS 5.1 与 pwsh 7 均无 LastWriteTime，
        Get-Item HKCU:\... 同样没有（已实测）。因此必须 P/Invoke RegQueryInfoKey。

        两个实测踩过的坑：
        (a) $key.Handle 返回 SafeRegistryHandle 而非 IntPtr，直接传会抛
            MethodArgumentConversionInvalidCastArgument，必须 .DangerousGetHandle()；
        (b) PS 5.1 的 C# 编译器不接受 ref 返回成员，故辅助方法签名里不得出现 ref return。

        取不到时**返回 $null**（调用方按「证据不完整」跳过迹象 (ii)），不抛异常——
        否则一台受限机器上将无法回滚任何条目。
    #>
    param(
        [Parameter(Mandatory)]
        [Microsoft.Win32.RegistryKey]$Key
    )

    if (-not ('WrcRegTime' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32;

public static class WrcRegTime
{
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegQueryInfoKey(
        IntPtr hKey, IntPtr lpClass, IntPtr lpcchClass, IntPtr lpReserved,
        out uint lpcSubKeys, out uint lpcbMaxSubKeyLen, out uint lpcbMaxClassLen,
        out uint lpcValues, out uint lpcbMaxValueNameLen, out uint lpcbMaxValueLen,
        out uint lpcbSecurityDescriptor, out long lpftLastWriteTime);

    public static DateTime GetLastWriteTimeUtc(RegistryKey key)
    {
        uint a, b, c, d, e, f, g;
        long fileTime;
        int rc = RegQueryInfoKey(
            key.Handle.DangerousGetHandle(), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
            out a, out b, out c, out d, out e, out f, out g, out fileTime);
        if (rc != 0)
        {
            throw new System.ComponentModel.Win32Exception(rc);
        }
        return DateTime.FromFileTimeUtc(fileTime);
    }
}
'@ -ErrorAction Stop
    }

    try {
        return [WrcRegTime]::GetLastWriteTimeUtc($Key)
    } catch {
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# JSON 读写（PS 5.1 陷阱安全）
# ─────────────────────────────────────────────────────────────────────────────

function ConvertFrom-RollbackJournalText {
    <#
    .SYNOPSIS
        把日志文本解析为 hashtable；失败返回 $null（不抛）。
    .DESCRIPTION
        PS 5.1 陷阱防护：
        - ConvertFrom-Json 不展开顶层数组 → 先赋值再 @() 规整（此处是对象，非数组）
        - @($null) 的 Count 是 1 → 条目为空时必须显式判 $null
        解析失败返回 $null，由调用方决定「视为不存在」还是「自证失败」。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    try {
        $doc = $Text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }

    if ($null -eq $doc) { return $null }

    # 规整为 hashtable，避免调用方依赖 PSCustomObject 的行为差异
    $journal = @{}
    foreach ($p in $doc.PSObject.Properties) {
        $journal[$p.Name] = $p.Value
    }
    return $journal
}

function Get-RollbackJournalEntryList {
    <#
    .SYNOPSIS
        从日志 hashtable 里取出条目列表，永远是数组（可能是空数组）。
    .DESCRIPTION
        @($null) 的 Count 是 1，所以必须先判 $null 再规整，
        否则「0 个条目」会被读成「1 个条目」（PS 5.1 与 pwsh 7 都是这个坑）。
    #>
    param([Parameter(Mandatory)][hashtable]$Journal)

    if (-not $Journal.ContainsKey('entries')) { return @() }
    $raw = $Journal['entries']
    if ($null -eq $raw) { return @() }

    # 注意：不要写 foreach ($e in @($raw)) —— 在 PS 5.1 下 @($raw) 对已是数组的 $raw
    # 会因管道展开语义产生嵌套，且 $e.PSObject.Properties 在数组上取到的是数组自身的属性，
    # 于是条目字段全空（kind/state 读成空串）。必须逐个元素显式判类型。
    $items = @()
    if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string]) -and -not ($raw -is [hashtable])) {
        foreach ($e in $raw) { $items += , $e }
    } else {
        $items += , $raw
    }

    $out = @()
    foreach ($e in $items) {
        if ($null -eq $e) { continue }
        $h = @{}
        if ($e -is [hashtable]) {
            foreach ($key in $e.Keys) { $h[$key] = $e[$key] }
        } else {
            foreach ($p in $e.PSObject.Properties) { $h[$p.Name] = $p.Value }
        }
        $out += , $h
    }
    return , $out
}

function Get-ItemId {
    <#
    .SYNOPSIS
        item_id 的唯一权威生成规则（REQ-027）。REQ-030 的清单必须复用，不得另立。
    .DESCRIPTION
        item_id = "<kind>:<规范化后的 target>"
        规范化 = 去除首尾空白与引号、路径去掉尾随反斜杠、注册表路径统一小写。
        注册表路径统一小写是因为 Windows 注册表路径大小写不敏感，
        同一键的不同大小写写法必须产生同一个 item_id。
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target
    )

    $t = $Target.Trim()
    $t = $t.Trim('"')
    $t = $t.Trim()
    # 去掉尾随反斜杠（但不把 'C:\' 变成 'C:'）
    if ($t.Length -gt 3 -and $t.EndsWith('\')) {
        $t = $t.TrimEnd('\')
    }
    if ($Kind -eq 'registry_key' -or $Kind -eq 'startup_value') {
        $t = $t.ToLowerInvariant()
    }
    return '{0}:{1}' -f $Kind, $t
}

function Get-Sha256Hex {
    <#
    .SYNOPSIS
        文件 SHA-256 十六进制串；文件不存在返回 $null。
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 原子写（REQ-005）
# ─────────────────────────────────────────────────────────────────────────────

function Write-FileAtomic {
    <#
    .SYNOPSIS
        原子地把 $Content 写到 $TargetPath，并保留上一代副本 .prev（REQ-005 / AC-071）。
    .DESCRIPTION
        两条路径（均已实测）：
        - 首次写入（目标不存在）：File.Move（单次原子重命名，目标存在即失败）。
          必须与目标**同卷同目录**，否则跨卷会退化为复制+删除而失去原子性。
        - 后续写入：File.Replace(tmp, target, prev)。
          该原语在**同一次原子操作内**把旧目标保存为 .prev，因此禁止手工
          「先复制再替换」——那会多出一次非原子拷贝，且可能把 .prev 写成半新内容。
          实测：.prev 已存在时反复 Replace 仍正常（gen2..gen6 全部成功，只保留一个 .prev）；
          Replace(tmp, target, $null) 会抛 "The path is not of a legal form"，
          因此备份路径必须显式命名。
        绝不原地重写 JSON：崩溃在写入中途会留下畸形日志，而自证会拒绝畸形日志，
        反而使 T3 恢复不可用。
    #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$BackupPath
    )

    $dir = Split-Path -Parent $TargetPath
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ([string]::IsNullOrEmpty($BackupPath)) {
        $BackupPath = "$TargetPath.prev"
    }

    # 临时文件必须与目标同目录（同卷），否则失去原子性
    $tmp = Join-Path (Split-Path -Parent $TargetPath) ([System.IO.Path]::GetRandomFileName())
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $Content, $utf8NoBom)

    try {
        if (Test-Path -LiteralPath $TargetPath) {
            [System.IO.File]::Replace($tmp, $TargetPath, $BackupPath)
        } else {
            [System.IO.File]::Move($tmp, $TargetPath)
        }
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Write-RollbackJournal {
    <#
    .SYNOPSIS
        把日志 hashtable 序列化并原子写入（REQ-005 / REQ-032）。
    .DESCRIPTION
        日志落在 $BackupDir 下的 rollback-journal.json；上一代落在 .prev.json。
        目录名约定为 backup-<run_id>（REQ-032）。
    #>
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][hashtable]$Journal
    )

    $target = Join-Path $BackupDir 'rollback-journal.json'
    $prev = Join-Path $BackupDir 'rollback-journal.prev.json'
    $json = $Journal | ConvertTo-Json -Depth 12
    Write-FileAtomic -TargetPath $target -Content $json -BackupPath $prev
    return $target
}

function Read-RollbackJournal {
    <#
    .SYNOPSIS
        读日志：主文件不可解析时回退读 .prev.json（回退深度固定为 1）。
    .DESCRIPTION
        返回 hashtable，或 $null（视为无日志）。**不抛异常**——回滚指引不应因
        一个损坏的文件而完全不可用（rollback.ps1 的既有契约）。
        回退时在结果里标记 journal_recovered_from_prev = $true，使报告能如实说明。
    #>
    param([Parameter(Mandatory)][string]$BackupDir)

    $target = Join-Path $BackupDir 'rollback-journal.json'
    if (Test-Path -LiteralPath $target) {
        # 契约：不抛异常。ACL/共享冲突/瞬时 IO 失败都要吞掉并回退，否则损坏文件会让
        # 回滚指引整体不可用（评审修复：ReadAllText 必须在 try 内）。
        try {
            $txt = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
            $j = ConvertFrom-RollbackJournalText -Text $txt
            if ($null -ne $j) { return $j }
        } catch { $j = $null }   # 契约：不抛；读失败按「此文件不可用」处理，继续回退
    }

    $prev = Join-Path $BackupDir 'rollback-journal.prev.json'
    if (Test-Path -LiteralPath $prev) {
        try {
            $txt = [System.IO.File]::ReadAllText($prev, [System.Text.Encoding]::UTF8)
            $j = ConvertFrom-RollbackJournalText -Text $txt
            if ($null -ne $j) {
                $j['journal_recovered_from_prev'] = $true
                return $j
            }
        } catch { $j = $null }   # 同上：回退也读不动则最终返回 $null
    }

    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# 日志构造与自证（REQ-027）
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-RollbackJournal {
    <#
    .SYNOPSIS
        构造一份合法的空日志（REQ-027 顶层字段齐备）。
    .DESCRIPTION
        created_at 语义固定为**日志创建时刻**（= 本轮清理开始时刻），
        是 REQ-024 的 24h 窗口起点；不是「清理结束时刻」——两者可能相差数十分钟。
        run_id 必须是 guid：它用于日志↔清理日志绑定、重复 run_id 自证与跨轮唯一性；
        用时间戳会在同一秒启动的两轮里冲突并静默破坏这三项。
    #>
    param(
        [string]$RunId,
        [string]$CreatedAt,
        [string]$CleanupLogPath,
        [string]$BackupDir,
        [string]$MachinePathOriginal,
        [string]$MachineFingerprint,
        [string]$FingerprintSource = 'machine_guid'
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString() }
    if ([string]::IsNullOrWhiteSpace($CreatedAt)) {
        $CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if ([string]::IsNullOrWhiteSpace($BackupDir)) { $BackupDir = "backup-$RunId" }

    # 陷阱：param 上的 [string] 会把 $null 强转成空串 ''，而 REQ-027/AC-083 要求
    # cleanup_log_* 三字段「同 null 或同非 null」。空串不是 null，会让自证永远失败。
    # 因此这里显式把空串归一化回 $null。
    $clPath = $CleanupLogPath
    if ([string]::IsNullOrWhiteSpace($clPath)) { $clPath = $null }
    $mpOriginal = $MachinePathOriginal
    if ([string]::IsNullOrWhiteSpace($mpOriginal)) { $mpOriginal = $null }

    return @{
        journal_version          = 1
        run_id                   = $RunId
        created_at               = $CreatedAt
        completed_at             = $null
        machine_fingerprint      = $MachineFingerprint
        fingerprint_source       = $FingerprintSource
        machine_path_original    = $mpOriginal
        cleanup_log_path         = $clPath
        cleanup_log_timestamp    = $null
        cleanup_log_sha256       = $null
        backup_dir               = $BackupDir
        entries                  = @()
    }
}

function ConvertTo-RollbackJournalEntry {
    <#
    .SYNOPSIS
        构造一个日志条目，state 初始为 planned（REQ-018）。
    .DESCRIPTION
        字段名是 **state**（不是 status），初值是 **planned**（不是 pending）。
        kind 六种取值之一；path_deleted（文件/目录删除，不可恢复）与
        path_entry（PATH 环境变量条目移除，可恢复）必须区分。
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('registry_key', 'startup_value', 'path_entry', 'path_deleted', 'service', 'task')][string]$Kind,
        [Parameter(Mandatory)][string]$Target,
        [string]$BackupFile,
        [string]$BackupFileSha256,
        [bool]$PreExisting = $false,
        [bool]$AbsentConfirmedAfterMutation = $false,
        $ParentBaseline = $null,
        [string]$State = 'planned'
    )

    return @{
        id                              = $Id
        item_id                         = (Get-ItemId -Kind $Kind -Target $Target)
        kind                            = $Kind
        target                          = $Target
        backup_file                     = $BackupFile
        backup_file_sha256              = $BackupFileSha256
        pre_existing                    = $PreExisting
        absent_confirmed_after_mutation = $AbsentConfirmedAfterMutation
        parent_baseline                 = $ParentBaseline
        state                           = $State
    }
}

function Test-RollbackJournalSelfValid {
    <#
    .SYNOPSIS
        日志自证（REQ-027）。返回 @{ Valid = bool; Reasons = string[] }。
    .DESCRIPTION
        自证通过需**同时**满足：
        - journal_version 受支持
        - run_id 是合法 guid
        - created_at 可解析
        - machine_fingerprint 存在、fingerprint_source 取值合法且与本机一致
        - backup_dir 存在
        - 每个非 null 的 backup_file 存在且 SHA-256 与记录一致
        - cleanup_log_path / cleanup_log_timestamp / cleanup_log_sha256
          **同 null 或同非 null**（AC-083）；三者同时非 null 时校验哈希与时间戳
        - 每个条目的 kind 在枚举内、state 合法
        这里返回原因列表而不是抛异常，便于测试逐项定位。
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [string]$MachineFingerprint,
        [int]$CleanupLogTimestampToleranceSeconds = 2
    )

    $reasons = @()

    $ver = $Journal['journal_version']
    $verInt = 0
    if ($null -eq $ver -or -not [int]::TryParse([string]$ver, [ref]$verInt) -or $verInt -ne 1) {
        # 非数字的 journal_version（外部畸形 JSON）不得抛异常中断自证，按不支持处理。
        $reasons += "journal_version 不受支持: $ver"
    }

    $runId = [string]$Journal['run_id']
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParse($runId, [ref]$parsedGuid)) {
        $reasons += "run_id 不是合法 guid: $runId"
    }

    $created = [string]$Journal['created_at']
    if ([string]::IsNullOrWhiteSpace($created)) {
        $reasons += "created_at 缺失"
    } elseif ($null -eq (ConvertFrom-IsoUtc -Text $created)) {
        $reasons += "created_at 不可解析: $created"
    }

    if ([string]::IsNullOrWhiteSpace([string]$Journal['machine_fingerprint'])) {
        $reasons += "machine_fingerprint 缺失"
    }

    $src = [string]$Journal['fingerprint_source']
    if ($src -ne 'machine_guid' -and $src -ne 'hostname_fallback') {
        $reasons += "fingerprint_source 取值非法: $src"
    }

    if (-not [string]::IsNullOrWhiteSpace($MachineFingerprint)) {
        if ([string]$Journal['machine_fingerprint'] -ne $MachineFingerprint) {
            $reasons += "machine_fingerprint 与本机不一致"
        }
    }

    $backupDir = [string]$Journal['backup_dir']
    if ([string]::IsNullOrWhiteSpace($backupDir)) {
        $reasons += "backup_dir 缺失"
    } elseif (-not (Test-Path -LiteralPath $backupDir)) {
        $reasons += "backup_dir 不存在: $backupDir"
    }

    # 清理日志三字段：同 null 或同非 null（REQ-027 / AC-083）
    # 注意陷阱 #3：@($null,$null,$null) 的 Count 是 1 而不是 3（$null 会被过滤掉），
    # 所以必须逐个字段显式判 $null，不能靠数组计数。
    $clp = $Journal['cleanup_log_path']
    $clt = $Journal['cleanup_log_timestamp']
    $cls = $Journal['cleanup_log_sha256']
    $nullCount = 0
    if ($null -eq $clp) { $nullCount++ }
    if ($null -eq $clt) { $nullCount++ }
    if ($null -eq $cls) { $nullCount++ }
    if ($nullCount -ne 0 -and $nullCount -ne 3) {
        $reasons += "cleanup_log_path/timestamp/sha256 必须同 null 或同非 null"
    } elseif ($nullCount -eq 0) {
        $p = [string]$clp
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            # REQ-027 容忍：清理日志已不存在时不据此拒绝（可能是 T3），继续自证
            # 但报告证据缺失，由调用方决定。
        } else {
            $actual = Get-Sha256Hex -Path $p
            if ($null -eq $actual) {
                # 文件存在却读不出哈希（ACL/占用/IO）：不得当作「已校验通过」，
                # 否则未经验证的内容会被信任（评审修复）。
                $reasons += "cleanup_log 存在但无法计算哈希，证据不完整: $p"
            } elseif ($actual -ne [string]$cls) {
                $reasons += "cleanup_log_sha256 不匹配"
            }
            $tTol = $CleanupLogTimestampToleranceSeconds
            $want = [string]$clt
            if ([string]::IsNullOrWhiteSpace($want)) {
                # 三字段同为非 null 是 AC-083 的硬约束；此处 timestamp 却是空白 → 证据不一致。
                $reasons += "cleanup_log_timestamp 为空但其余 cleanup_log_* 非空"
            } else {
                $wd = ConvertFrom-IsoUtc -Text $want
                if ($null -eq $wd) {
                    # 非 null 但不可解析的时间戳不得被静默忽略（评审修复：AC-083 一致性）。
                    $reasons += "cleanup_log_timestamp 不可解析: $want"
                } else {
                    $lw = (Get-Item -LiteralPath $p).LastWriteTimeUtc
                    if ([math]::Abs(($lw - $wd).TotalSeconds) -gt $tTol) {
                        $reasons += "cleanup_log 最后写入时间与记录相差超过 ${tTol} 秒"
                    }
                }
            }
        }
    }

    $validKinds = @('registry_key', 'startup_value', 'path_entry', 'path_deleted', 'service', 'task')
    $validStates = @('planned', 'backup_created', 'mutation_succeeded', 'mutation_failed', 'not_restorable')
    $entries = Get-RollbackJournalEntryList -Journal $Journal
    foreach ($e in $entries) {
        $k = [string]$e['kind']
        if ($validKinds -notcontains $k) { $reasons += "条目 kind 非法: $k" }
        $st = [string]$e['state']
        if ($validStates -notcontains $st) { $reasons += "条目 state 非法: $st" }
        $bf = $e['backup_file']
        if ($null -ne $bf -and -not [string]::IsNullOrWhiteSpace([string]$bf)) {
            $bfPath = [string]$bf
            if (-not [System.IO.Path]::IsPathRooted($bfPath) -and -not [string]::IsNullOrWhiteSpace($backupDir)) {
                $bfPath = Join-Path $backupDir $bfPath
            }
            if (-not (Test-Path -LiteralPath $bfPath -PathType Leaf)) {
                $reasons += "条目 backup_file 不存在: $bfPath"
            } else {
                $wantHash = $e['backup_file_sha256']
                if (-not [string]::IsNullOrWhiteSpace([string]$wantHash)) {
                    $a = Get-Sha256Hex -Path $bfPath
                    if ($null -eq $a) {
                        # 备份文件存在却读不出哈希：视为证据不完整，不得默认通过（评审修复）。
                        $reasons += "条目 backup_file 存在但无法计算哈希: $bfPath"
                    } elseif ($a -ne [string]$wantHash) {
                        $reasons += "条目 backup_file 哈希不匹配: $bfPath"
                    }
                }
            }
        }
    }

    return @{ Valid = ($reasons.Count -eq 0); Reasons = $reasons }
}

function Get-MachineFingerprint {
    <#
    .SYNOPSIS
        本机指纹（REQ-027）：首选 MachineGuid，退化则 hostname + 系统卷序列号。
    .DESCRIPTION
        诚实说明：克隆的虚拟机共享 MachineGuid，退化来源同样不唯一，
        因此 hostname_fallback 下**不保证**能识别克隆机/同机副本。
        规格不承诺做不到的事。返回 @{ Value = ...; Source = ... }。
    #>
    param()

    try {
        $mg = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
        if (-not [string]::IsNullOrWhiteSpace($mg)) {
            return @{ Value = $mg; Source = 'machine_guid' }
        }
    } catch {
        Write-Verbose "MachineGuid 不可读，退化到 hostname_fallback: $($_.Exception.Message)"
    }

    $hn = $env:COMPUTERNAME
    $serial = ''
    try {
        $serial = (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop).VolumeSerialNumber
    } catch {
        $serial = ''
    }
    return @{ Value = "$hn-$serial"; Source = 'hostname_fallback' }
}

function Format-IsoUtc {
    <#
    .SYNOPSIS
        ISO 8601 UTC 秒精度字符串（去掉小数秒，避免跨引擎序列化差异）。
    #>
    param([Parameter(Mandatory)][datetime]$Value)
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertFrom-IsoUtc {
    <#
    .SYNOPSIS
        解析带 Z 的 ISO 8601 UTC 串为 Kind=Utc 的 [datetime]；不可解析返回 $null。
    .DESCRIPTION
        必须用 InvariantCulture + RoundtripKind：裸 [datetime]::TryParse 在非 en-US
        locale 下会把尾部 Z 当作本地时间处理，得到 Kind=Local，随后 ToUniversalTime()
        套用本地偏移——跨机/跨时区时会把 created_at 判偏几个小时，误伤 24h 窗口判定
        （评审修复：读侧与写侧 Format-IsoUtc 对齐）。
    #>
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParse(
        $Text,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$dt)
    if (-not $ok) { return $null }
    return $dt.ToUniversalTime()
}
