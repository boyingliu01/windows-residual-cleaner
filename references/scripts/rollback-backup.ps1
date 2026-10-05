# rollback-backup.ps1
# S3 写入端的逐项备份原语（REQ-006 / REQ-007 / DD-003 / REQ-035）。
#
# 逐项 fail-closed：备份不可用 = 删除不发生。导出的 .reg 是 REQ-024 恢复的
# 唯一物料，也是自证（REQ-027 备份哈希）的校验对象。
# 本文件不含 Main、不含 exit（ADR-001）。

function Get-RegistryParentPath {
    <#
    .SYNOPSIS
        注册表键路径的父键（纯解析）。根键（无子级）返回 $null。
    #>
    param([AllowEmptyString()][string]$Key)

    # 'HKCU\' 与 'HKCU' 都表示根键：先去掉尾部分隔符，否则会把根键的「父」算成根键本身。
    $k = $Key.Trim().Trim('"').Trim().TrimEnd('\')
    $idx = $k.LastIndexOf('\')
    if ($idx -lt 0) { return $null }
    $parent = $k.Substring(0, $idx)
    if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
    return $parent
}

function Test-RegContinuation {
    <#
    .SYNOPSIS
        一行 .reg 文本是否为「续行中」（行尾是单个反斜杠，不是值里的 \\）。
    #>
    param([AllowNull()][string]$Line)
    if ($null -eq $Line) { return $false }
    $t = $Line.TrimEnd()
    if (-not $t.EndsWith('\')) { return $false }
    if ($t.EndsWith('\\')) { return $false }
    return $true
}

function Get-TrimmedRegExport {
    <#
    .SYNOPSIS
        DD-003：把「父键整键导出」裁剪为只含目标 value 的最小 .reg。
    .DESCRIPTION
        共享 Run/RunOnce 键绝不能整键回写（会复活其它程序的自启动项），
        因此备份与恢复的粒度都被裁剪锁定为**单个 value**。
        硬约束（REQ-007）：
          - 输出必须**恰好一个**值定义 —— 0 个说明目标本就不存在
            （export_failed(value_not_found)），>1 个说明匹配有歧义
            （export_failed(trim_multivalue)），两者都不得产出备份；
          - 保留版本头与 [键路径] 行（reg import 的最低要求）；
          - 键路径与 value 名大小写不敏感（注册表语义）；
          - 同名 value 出现在多个键块时，只有 ParentKey 命中的键块保留
            （无 ParentKey 提示时取第一个命中块）。
        输入是 reg export 的文本（调用方负责按 Unicode 读，REQ-035）。
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RegText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ValueName,
        [AllowEmptyString()][string]$ParentKey = ''
    )

    $fail = { param($why) @{ Ok = $false; Content = ''; Reason = "export_failed($why)" } }

    # PS 5.1 会把 Mandatory + AllowEmptyString + 实参 '' 判为「缺少参数」而抛绑定异常，
    # 所以 ValueName 不声明 Mandatory，空/缺失统一在下面返回结构化失败（自证契约：不抛）。
    if ([string]::IsNullOrWhiteSpace($ValueName)) { return & $fail 'empty_value_name' }

    $lines = @($RegText -split "\r?\n")
    if ($lines.Count -eq 0) { return & $fail 'empty_input' }

    $header = $lines[0]
    if ($header -notmatch '^\s*Windows Registry Editor Version') {
        return & $fail 'missing_header'
    }

    # 切块：[path] 行开启一个块；块外的散落行不属于任何键，忽略。
    $blocks = @()
    $cur = $null
    foreach ($i in 1..($lines.Count - 1)) {
        $line = $lines[$i]
        if ($line -match '^\s*\[(.+)\]\s*$') {
            if ($null -ne $cur) { $blocks += , $cur }
            $cur = @{ Path = $Matches[1]; Lines = @() }
            continue
        }
        if ($null -ne $cur) { $cur.Lines += , $line }
    }
    if ($null -ne $cur) { $blocks += , $cur }

    $needle = $ValueName.Trim().ToLowerInvariant()
    $parentNeedle = $null
    if (-not [string]::IsNullOrWhiteSpace($ParentKey)) {
        # 必须走 Get-NormalizedRegKeyPath：reg.exe 写出的块头是长 hive 名
        # （HKEY_CURRENT_USER\...），而调用方手里的键路径通常是短别名（HKCU\...）。
        # 直接 ToLower 比较会让 DD-003 的裁剪在真实机器上恒判 value_not_found。
        $parentNeedle = Get-NormalizedRegKeyPath -Path $ParentKey
    }

    $matchedBlock = $null
    $keptLines = @()
    foreach ($b in $blocks) {
        $bPath = [string]$b.Path
        $pathOk = ($null -eq $parentNeedle) -or ((Get-NormalizedRegKeyPath -Path $bPath) -eq $parentNeedle)
        if (-not $pathOk) { continue }
        # 逐条目解析：长值（reg export 用行尾 '\' 折行）必须整体归属同一条目，
        # 否则裁剪会把一条值截成两半，导入时得到损坏值（评审修复）。
        $entries = @()
        $cur = $null
        foreach ($raw in $b.Lines) {
            $l = [string]$raw
            if ($null -ne $cur) {
                # 空行只结束条目，不并入内容（否则裁剪结果带上无谓的尾随空行）
                if ([string]::IsNullOrWhiteSpace($l)) {
                    $entries += , $cur
                    $cur = $null
                    continue
                }
                $cur.Text = $cur.Text + "`r`n" + $l
                if (-not (Test-RegContinuation -Line $l)) {
                    $entries += , $cur
                    $cur = $null
                }
                continue
            }
            $m = [regex]::Match($l, '^\s*"((?:[^"\\]|\\.)*)"\s*=')
            if (-not $m.Success) { continue }
            $e = @{ Name = $m.Groups[1].Value; Text = $l }
            if (Test-RegContinuation -Line $l) { $cur = $e } else { $entries += , $e }
        }
        if ($null -ne $cur) { $entries += , $cur }

        $valueLines = @()
        foreach ($e in $entries) {
            if (([string]$e.Name).ToLowerInvariant() -eq $needle) { $valueLines += , ([string]$e.Text) }
        }
        if ($valueLines.Count -gt 0) {
            if ($null -ne $matchedBlock) {
                # 同名 value 在另一个（同样匹配 ParentKey 的）块再次出现：歧义
                return & $fail 'trim_multivalue'
            }
            $matchedBlock = $b
            $keptLines = $valueLines
        }
    }

    if ($null -eq $matchedBlock) { return & $fail 'value_not_found' }
    if ($keptLines.Count -ne 1) { return & $fail 'trim_multivalue' }

    $out = @()
    $out += $header
    $out += ''
    $out += ('[{0}]' -f $matchedBlock.Path)
    $out += $keptLines[0]
    $out += ''
    return @{ Ok = $true; Content = (($out -join "`r`n") + "`r`n"); Reason = '' }
}

function Read-RegUnicodeFile {
    <#
    .SYNOPSIS
        按 BOM 识别 .reg 编码并读出文本（REQ-035）；不抛。
    .DESCRIPTION
        reg.exe 导出的文件在不同宿主/版本下可能是 UTF-16LE 或 UTF-8，两者都带
        BOM。调用方不得自己猜编码：猜错会得到「每条之间夹 NUL」的文本，
        裁剪后导入即失败。返回 @{ Ok; Content; Reason }。
    #>
    param([Parameter(Mandatory)][string]$Path)

    $fail = { param($why) @{ Ok = $false; Content = ''; Reason = "read_failed($why)" } }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return & $fail 'not_found' }
    $bytes = $null
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return & $fail 'unreadable' }
    if ($null -eq $bytes -or $bytes.Length -lt 2) { return & $fail 'too_short' }
    $enc = $null
    if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = [System.Text.Encoding]::Unicode
    } elseif ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes.Length -ge 3 -and $bytes[2] -eq 0xBF) {
        $enc = [System.Text.Encoding]::UTF8
    } else {
        return & $fail 'no_bom'
    }
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($Path, $enc) } catch { return & $fail 'unreadable' }
    if ([string]::IsNullOrWhiteSpace($text)) { return & $fail 'empty' }
    return @{ Ok = $true; Content = $text; Reason = '' }
}

function Write-RegUnicodeFile {
    <#
    .SYNOPSIS
        把 .reg 文本以 UTF-16LE + BOM 落盘（REQ-035），并回读自证。
    .DESCRIPTION
        reg.exe 只接受「以 FF FE 开头 + 首行版本头」的注册表文件：
        [Text.Encoding]::Unicode 的 GetBytes 不带前导 BOM，必须走
        WriteAllText(path, text, encoding) 才会写入 preamble。
        写入端（DD-003 裁剪后的启动项备份）与恢复端（导入物料）共用本原语，
        失败一律回报 Ok=$false，不抛。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $fail = { param($why) @{ Ok = $false; Path = $Path; Reason = "write_failed($why)" } }

    try {
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::Unicode)
    } catch {
        return & $fail ((($_.Exception.Message) -replace '[^\w.-]', '_'))
    }
    $bytes = $null
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { $bytes = $null }
    if ($null -eq $bytes) { return & $fail 'unreadable_after_write' }
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0xFF -or $bytes[1] -ne 0xFE) {
        return & $fail 'not_utf16le_bom'
    }
    $back = $null
    try { $back = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::Unicode) } catch { $back = $null }
    if ($null -eq $back -or -not $back.StartsWith('Windows Registry Editor')) {
        return & $fail 'header_lost'
    }
    return @{ Ok = $true; Path = $Path; Reason = '' }
}

function Invoke-RegExe {
    <#
    .SYNOPSIS
        可靠地调用 reg.exe：双流重定向拿真实退出码（同 Invoke-ScExe 的教训）。
        返回 @{ ok; exit_code; stdout; stderr; error }；不抛。
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    $regPath = Join-Path $env:SystemRoot 'System32\reg.exe'
    if (-not (Test-Path $regPath)) {
        return @{ ok = $false; exit_code = $null; stdout = ''; stderr = ''; error = "reg.exe not found at $regPath" }
    }

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $regPath -ArgumentList $Arguments `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        $stdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) {
            return @{ ok = $false; exit_code = $null; stdout = $stdout; stderr = $stderr; error = "reg.exe returned no exit code" }
        }
        return @{ ok = ($exitCode -eq 0); exit_code = $exitCode; stdout = $stdout; stderr = $stderr; error = if ($exitCode -eq 0) { '' } else { "$stdout $stderr" } }
    } catch {
        return @{ ok = $false; exit_code = $null; stdout = ''; stderr = ''; error = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Export-RegistryKeyBackup {
    <#
    .SYNOPSIS
        删除前对**该精确键**做 reg export（REQ-006），逐项 fail-closed。
    .DESCRIPTION
        导出成功且文件非空才算备份成立；任何一步失败都返回 Ok=$false +
        reason（export_failed(...)），调用方必须跳过删除。
        不存在的键由 reg.exe 直接失败（这同时挡住「导出半截成功」的形态）。
        返回 @{ Ok; Path; Sha256; Reason }。
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$Id
    )

    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = 'export_failed(backup_dir_missing)' }
    }
    $safeId = ($Id -replace '[^\w.-]', '_')
    $target = Join-Path $BackupDir ("reg-$safeId.reg")
    # 防串写：同名旧文件先删除，否则上次残留会被当作本次备份（哈希对不上是自证
    # 的事，但删除时刻的窗口必须关在这里）。
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $target) {
            return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = 'export_failed(stale_target_undeletable)' }
        }
    }

    $r = Invoke-RegExe -Arguments @('export', $Key, $target, '/y')
    if (-not $r.ok) {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = "export_failed(reg_exit_$($r.exit_code))" }
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = 'export_failed(file_absent_after_success)' }
    }
    $len = 0
    try { $len = (Get-Item -LiteralPath $target).Length } catch { $len = 0 }
    if ($len -le 0) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = 'export_failed(empty_file)' }
    }
    $hash = Get-Sha256Hex -Path $target
    if ([string]::IsNullOrWhiteSpace($hash)) {
        return @{ Ok = $false; Path = $target; Sha256 = $null; Reason = 'export_failed(hash_unreadable)' }
    }
    return @{ Ok = $true; Path = $target; Sha256 = $hash; Reason = '' }
}

function Export-StartupValueBackup {
    <#
    .SYNOPSIS
        DD-003 / REQ-007：启动项 value 的备份 = 「导出父键 → 裁剪为只含目标 value」。
    .DESCRIPTION
        共享的 Run/RunOnce 键绝不能整键回写（会复活其它程序的自启动项），所以备份粒度
        被裁剪锁定为单个 value。四道 fail-closed 关卡，任一失败都不得删除：
          1. reg export 父键到**备份目录内**的临时文件（跨卷会让 REQ-005 的原子写退化）；
          2. 按 BOM 读回（REQ-035：reg export 产出 UTF-16LE + BOM，按 ANSI 读会得到
             每条之间夹 NUL 的文本，裁剪后导入必失败）；
          3. Get-TrimmedRegExport 裁剪 —— 它自身保证「恰好一个值定义」，
             0 个 => value_not_found（目标本就不存在），>1 个 => trim_multivalue（有歧义）；
          4. 写盘后**再读回并重新裁剪一次**（AC-040 的后置校验）：编码或折行在写盘环节
             被破坏时这里就检出，绝不留下一个「看着像备份、导入即失败」的文件。
        临时整键导出文件在任何退出路径下都被删除：它含兄弟程序的自启动项，
        留在备份里既会被误当成可导入物料，也是一份不该持久化的多余副本。
        返回 @{ Ok; Path; Sha256; Reason }；不抛。
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$ValueName,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$Id
    )

    $fail = { param($why) @{ Ok = $false; Path = ''; Sha256 = $null; Reason = "export_failed($why)" } }

    if ([string]::IsNullOrWhiteSpace($ValueName)) { return & $fail 'empty_value_name' }
    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) { return & $fail 'backup_dir_missing' }

    $safeId = ($Id -replace '[^\w.-]', '_')
    $tmp = Join-Path $BackupDir ("tmp-{0}-full.reg" -f $safeId)
    $target = Join-Path $BackupDir ("val-{0}.reg" -f $safeId)
    foreach ($stale in @($tmp, $target)) {
        if (-not (Test-Path -LiteralPath $stale)) { continue }
        Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $stale) { return & $fail 'stale_target_undeletable' }
    }

    try {
        $r = Invoke-RegExe -Arguments @('export', $Key, $tmp, '/y')
        if (-not $r.ok) { return & $fail ("reg_exit_{0}" -f $r.exit_code) }

        $read = Read-RegUnicodeFile -Path $tmp
        if (-not $read.Ok) { return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = $read.Reason } }

        $trim = Get-TrimmedRegExport -RegText $read.Content -ValueName $ValueName -ParentKey $Key
        if (-not $trim.Ok) { return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = $trim.Reason } }

        $w = Write-RegUnicodeFile -Path $target -Content $trim.Content
        if (-not $w.Ok) { return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = $w.Reason } }

        $back = Read-RegUnicodeFile -Path $target
        if (-not $back.Ok) { return @{ Ok = $false; Path = ''; Sha256 = $null; Reason = $back.Reason } }
        $recheck = Get-TrimmedRegExport -RegText $back.Content -ValueName $ValueName -ParentKey $Key
        if (-not $recheck.Ok) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            return & $fail ("trim_postcheck_{0}" -f $recheck.Reason)
        }

        $hash = Get-Sha256Hex -Path $target
        if ([string]::IsNullOrWhiteSpace($hash)) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            return & $fail 'hash_unreadable'
        }
        return @{ Ok = $true; Path = $target; Sha256 = $hash; Reason = '' }
    } finally {
        # 整键导出含兄弟程序的自启动项：无论成功失败都必须清掉。
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Confirm-RegistryTargetAbsent {
    <#
    .SYNOPSIS
        REQ-024 flag 3（absent_confirmed_after_mutation）的注册表侧证据。
    .DESCRIPTION
        接受 'HKCU\Foo' 或 'HKCU:\Foo' 形态。读取异常按「未确认」处理
        （fail-closed：宁可判 absent=$false 让上层复查，不得把读失败
        说成「目标已消失」）。
    #>
    param([Parameter(Mandatory)][string]$Key)

    $psPath = $Key.Trim().Trim('"')
    if ($psPath -notmatch '^\w+\\:') {
        $psPath = $psPath -replace '^(HKLM|HKCU|HKCR|HKU|HKCC):?\\', '$1:\'
    }
    try {
        return @{ Absent = (-not (Test-Path -LiteralPath $psPath)); Path = $psPath }
    } catch {
        return @{ Absent = $false; Path = $psPath; Error = $_.Exception.Message }
    }
}

function Confirm-PathEntryRemoved {
    <#
    .SYNOPSIS
        REQ-024 flag 3 的 PATH 侧证据：给定 PATH 串中是否已无该段。
    #>
    param(
        [AllowNull()][string]$PathList,
        [AllowEmptyString()][string]$Entry
    )
    if ([string]::IsNullOrWhiteSpace($Entry) -or $null -eq $PathList) {
        return @{ Absent = $false }
    }
    $needle = $Entry.Trim().Trim('"').Trim().TrimEnd('\').ToLowerInvariant()
    foreach ($seg in ($PathList -split ';')) {
        if ($seg.Trim().TrimEnd('\').ToLowerInvariant() -eq $needle) { return @{ Absent = $false } }
    }
    return @{ Absent = $true }
}
