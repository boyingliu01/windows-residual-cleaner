# tests/unit/rollback-exec.Tests.ps1
# S4 恢复执行层 — REQ-008/009/021/024/030/031。
# 断言必须在 PS 5.1 与 pwsh 7 下都成立（本项目基线仍是 5.1）。
#
# 分层：
#   - 纯函数（target 拆解 / 键路径归一 / 结构签名 / PATH 整作用域推导 / 四种对外判定映射）
#   - 真实 HKCU 自建模组的探测与回灌（只碰测试自建 guid 键，不依赖主仓遗留状态）
#   - Invoke-RollbackRestore 的**两阶段协议**（REQ-024 迹象 (ii) 的硬要求）
#     与 PATH 接缝（-MachinePathOverride / -SetPathScript，绝不改动本机 PATH）

BeforeAll {
    $script:Root = Join-Path $PSScriptRoot '..\..\references\scripts'
    . (Join-Path $script:Root 'rollback-journal.ps1')
    . (Join-Path $script:Root 'rollback-backup.ps1')
    . (Join-Path $script:Root 'rollback-verdicts.ps1')
    . (Join-Path $script:Root 'rollback-recovery.ps1')
    . (Join-Path $script:Root 'rollback-exec.ps1')
}

Describe 'Split-StartupTarget (DD-003 composite target)' {
    It '<Target> -> Key=<Key> Value=<ValueName>' -TestCases @(
        @{ Target = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run|DeadApp'
           Key    = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
           Value  = 'DeadApp' }
        @{ Target = ' "HKCU\...\Run|X" '; Key = 'HKCU\...\Run'; Value = 'X' }
        @{ Target = 'HKCU\Run|A|B'; Key = 'HKCU\Run|A'; Value = 'B' }
    ) {
        param($Target, $Key, $Value)
        $r = Split-StartupTarget -Target $Target
        $r.Key | Should -Be $Key
        $r.ValueName | Should -Be $Value
    }

    It '无法拆解（无 | / 半边为空）时 ValueName 为 null，调用方 fail-closed' -TestCases @(
        @{ Target = 'HKCU\Software\Run' }
        @{ Target = 'HKCU\Software\Run|' }
        @{ Target = '|DeadApp' }
    ) {
        param($Target)
        ($null -eq (Split-StartupTarget -Target $Target).ValueName) | Should -BeTrue
    }
}

Describe 'Get-NormalizedRegKeyPath (base layer: rollback-journal.ps1)' {
    It '短别名 / 长名 / PS 提供程序形态归一到同一串' {
        $a = Get-NormalizedRegKeyPath -Path 'HKCU\Software\Foo'
        $a | Should -Be (Get-NormalizedRegKeyPath -Path 'HKEY_CURRENT_USER\Software\Foo')
        $a | Should -Be (Get-NormalizedRegKeyPath -Path 'HKCU:\Software\Foo')
        $a | Should -Be 'hkey_current_user\software\foo'
    }

    It '尾随反斜杠与连续反斜杠不参与比较' {
        (Get-NormalizedRegKeyPath -Path 'HKCU\Software\Foo\\') | Should -Be 'hkey_current_user\software\foo'
        (Get-NormalizedRegKeyPath -Path 'HKCU\Software\\Foo') | Should -Be 'hkey_current_user\software\foo'
    }

    It '未知 hive 原样小写；空白入参得到空串' {
        (Get-NormalizedRegKeyPath -Path 'FOO\Bar') | Should -Be 'foo\bar'
        (Get-NormalizedRegKeyPath -Path '  ') | Should -Be ''
    }
}

Describe 'Get-TrimmedRegExport 的父键提示对 hive 写法不敏感（真实 reg.exe 形态）' {
    It 'reg export 写出的长 hive 块头必须能被短别名 HKCU 提示命中' {
        # 写入端拿到的键路径通常是短别名，而 reg.exe 导出的块头是长名。
        # 两者不做归一，DD-003 的裁剪在真实机器上恒判 value_not_found。
        $src = @'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run]
"GoodApp"="C:\\Good\\app.exe"
"DeadApp"="C:\\gone\\dead.exe"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'DeadApp' `
            -ParentKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
        $r.Ok | Should -BeTrue ($r.Reason)
        $r.Content | Should -Match 'DeadApp'
        $r.Content | Should -Not -Match 'GoodApp'
    }

    It '父键提示指向另一个键时不得命中（歧义即拒绝）' {
        $src = @'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Other]
"DeadApp"="C:\\other.exe"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'DeadApp' -ParentKey 'HKCU\Software\Run'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'export_failed(value_not_found)'
    }
}

Describe 'ConvertTo-CanonicalRegKeyPath' {
    It '<In> -> <Out>' -TestCases @(
        @{ In = 'HKLM\SOFTWARE\Foo';              Out = 'HKLM:\SOFTWARE\Foo' }
        @{ In = 'HKEY_LOCAL_MACHINE\SOFTWARE\Foo'; Out = 'HKLM:\SOFTWARE\Foo' }
        @{ In = 'HKCU:\Software\Foo';             Out = 'HKCU:\Software\Foo' }
        @{ In = 'HKEY_CURRENT_USER\Software';     Out = 'HKCU:\Software' }
        @{ In = 'WEIRD\Thing';                    Out = 'WEIRD\Thing' }
        @{ In = '';                               Out = '' }
    ) {
        param($In, $Out)
        ConvertTo-CanonicalRegKeyPath -Path $In | Should -Be $Out
    }
}

Describe 'Get-RegExportStructure / Test-RegStructureIdentical (REQ-024 比较口径)' {
    BeforeAll {
        function script:New-ExecRegText {
            param([string]$Body)
            return "Windows Registry Editor Version 5.00`r`n`r`n$Body`r`n"
        }
    }

    It '版本头、空行与键行书写形态不参与比较' {
        $a = New-ExecRegText @'
[HKEY_CURRENT_USER\Software\WRC]
"v"="1"
'@
        $b = New-ExecRegText @'
[HKCU\software\wrc]
"v"="1"
'@
        (Test-RegStructureIdentical -BackupText $a -CurrentText $b).Identical | Should -BeTrue
    }

    It 'value 数据不同 -> 不一致，且差异方向可辨' {
        $a = New-ExecRegText @'
[HKCU\Software\WRC]
"v"="1"
'@
        $b = New-ExecRegText @'
[HKCU\Software\WRC]
"v"="2"
'@
        $r = Test-RegStructureIdentical -BackupText $a -CurrentText $b
        $r.Identical | Should -BeFalse
        # 签名里的 type=data 段逐字保留，所以字符串值带引号：`...|v|"1"`
        @($r.Differences | Where-Object { $_ -like 'missing_in_current:value|*' -and $_ -like '*|"1"' }).Count | Should -Be 1
        @($r.Differences | Where-Object { $_ -like 'added_in_current:value|*' -and $_ -like '*|"2"' }).Count | Should -Be 1
    }

    It '导出范围内新增子键 -> 不一致（外部写入必须被看见）' {
        $a = New-ExecRegText @'
[HKCU\Software\WRC]
"v"="1"
'@
        $b = New-ExecRegText @'
[HKCU\Software\WRC]
"v"="1"

[HKCU\Software\WRC\AddedBySomeoneElse]
'@
        $r = Test-RegStructureIdentical -BackupText $a -CurrentText $b
        $r.Identical | Should -BeFalse
        @($r.Differences | Where-Object { $_ -like 'added_in_current:key|*' }).Count | Should -Be 1
    }

    It 'ValueNameFilter 把比较范围收窄到目标 value 本身（DD-003）' {
        $a = New-ExecRegText @'
[HKCU\...\Run]
"AppA"="C:\\a.exe"
'@
        $b = New-ExecRegText @'
[HKCU\...\Run]
"AppA"="C:\\a.exe"
"AppB"="C:\\b.exe"
'@
        # 不设过滤时兄弟 value 会算差异；按 DD-003 的比较范围则应一致
        (Test-RegStructureIdentical -BackupText $a -CurrentText $b).Identical | Should -BeFalse
        (Test-RegStructureIdentical -BackupText $a -CurrentText $b -ValueNameFilter 'AppA').Identical | Should -BeTrue
    }

    It '长值折行必须折回同一条目，不得拆成两条签名' {
        $folded = New-ExecRegText @'
[HKCU\Software\WRC]
"long"="str:this is a very long value tha\
  t continues here"
'@
        $sig = @(Get-RegExportStructure -RegText $folded)
        @($sig | Where-Object { $_ -like 'value|*' }).Count | Should -Be 1
        ($sig | Where-Object { $_ -like 'value|*' }) | Should -Match 'continues here'
    }

    It '空文本 -> empty_structure，绝不判为一致' {
        $r = Test-RegStructureIdentical -BackupText '' -CurrentText ''
        $r.Identical | Should -BeFalse
        $r.Differences | Should -Contain 'empty_structure'
    }
}

Describe 'Get-RestoredMachinePath (REQ-021 整作用域)' {
    It '原值为 null -> $null（证据缺失，调用方 fail-closed）' {
        ($null -eq (Get-RestoredMachinePath -OriginalPath $null)) | Should -BeTrue
    }

    It '只移除「本轮删除但不恢复」的段，其余逐字保留' {
        $orig = 'C:\Windows;C:\Program Files\App;C:\Other'
        (Get-RestoredMachinePath -OriginalPath $orig -RemovedEntries @()) | Should -Be $orig
        (Get-RestoredMachinePath -OriginalPath $orig -RemovedEntries @('c:\other\')) | Should -Be 'C:\Windows;C:\Program Files\App'
    }

    It '分段语义与 Get-ExpectedPathAfterCleanup 一致（空段不丢，恢复结果必须曾是真实 PATH）' {
        $orig = 'C:\Windows;;C:\Other'
        $e = Get-ExpectedPathAfterCleanup -OriginalPath $orig -RemovedEntries @()
        (Get-RestoredMachinePath -OriginalPath $orig -RemovedEntries @()) | Should -Be $e
    }

    It '整段匹配：C:\App 不得误删 C:\AppData' {
        $orig = 'C:\App;C:\AppData'
        (Get-RestoredMachinePath -OriginalPath $orig -RemovedEntries @('C:\App')) | Should -Be 'C:\AppData'
    }
}

Describe 'Get-ReportedRollbackVerdict (REQ-009 四种对外判定)' {
    BeforeAll {
        function script:New-InternalVerdict {
            param([string]$Verdict, [string]$Reason = '')
            return @{
                ItemId             = 'registry_key:hkcu\software\wrc'
                Id                 = 'reg_001'
                Kind               = 'registry_key'
                Target             = 'HKCU\Software\WRC'
                Verdict            = $Verdict
                Reason             = $Reason
                EvidenceIncomplete = $false
            }
        }
    }

    It 'restore + 执行成功 -> restored，原因清空' {
        $r = Get-ReportedRollbackVerdict -Verdict (New-InternalVerdict 'restore' 'decision_rule_3') `
            -Executed $true
        $r.Verdict | Should -Be 'restored'
        $r.Reason | Should -Be ''
    }

    It 'restore + 执行失败 -> restore_failed 并保留执行原因' {
        $r = Get-ReportedRollbackVerdict -Verdict (New-InternalVerdict 'restore' 'decision_rule_3') `
            -Executed $false -ExecReason 'import_failed(reg_exit_1)'
        $r.Verdict | Should -Be 'restore_failed'
        $r.Reason | Should -Be 'restore_failed(import_failed(reg_exit_1))'
    }

    It 'already_present / not_restorable 原样对外' -TestCases @(
        @{ V = 'already_present'; Out = 'already_present' }
        @{ V = 'not_restorable';  Out = 'not_restorable' }
    ) {
        param($V, $Out)
        (Get-ReportedRollbackVerdict -Verdict (New-InternalVerdict $V 'r')).Verdict | Should -Be $Out
    }

    It 'conflict 归入 restore_failed 且保留原因（不得出现第五种判定）' {
        $r = Get-ReportedRollbackVerdict -Verdict (New-InternalVerdict 'conflict' 'external_change_sign_ii')
        $r.Verdict | Should -Be 'restore_failed'
        $r.Reason | Should -Be 'conflict(external_change_sign_ii)'
    }

    It '证据不完整标记必须透传（AC-075a 的逐条目容错）' {
        $v = New-InternalVerdict 'restore' 'decision_rule_3'
        $v['EvidenceIncomplete'] = $true
        (Get-ReportedRollbackVerdict -Verdict $v -Executed $true).EvidenceIncomplete | Should -BeTrue
    }
}

Describe 'Get-RollbackEntryProbe + Restore-RegistryBackupFile (integration, real HKCU)' {
    BeforeAll {
        $script:exDir = Join-Path $env:TEMP ('wrc-exec-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:exDir -Force | Out-Null
        $script:exRaw = 'HKCU\Software\WRC-Exec-Test-' + [guid]::NewGuid().ToString('N')
        $script:exPs = $script:exRaw -replace '^HKCU\\', 'HKCU:\'
        New-Item -Path $script:exPs -Force | Out-Null
        New-ItemProperty -Path $script:exPs -Name 'V' -Value 'data-1' -Force | Out-Null
    }

    AfterAll {
        Invoke-RegExe -Arguments @('delete', $script:exRaw, '/f') | Out-Null
        Remove-Item -LiteralPath $script:exDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'present + 与备份一致 -> present_match' {
        $bk = Export-RegistryKeyBackup -Key $script:exRaw -BackupDir $script:exDir -Id 'pm1'
        $bk.Ok | Should -BeTrue ($bk.Reason)
        $entry = @{ kind = 'registry_key'; target = $script:exRaw; backup_file = $bk.Path }
        $p = Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir
        $p.Ok | Should -BeTrue ($p.Reason)
        $p.TargetState | Should -Be 'present_match'
    }

    It 'present + 内容被外部改动 -> present_mismatch（迹象 (i)，绝不覆盖）' {
        $bk = Export-RegistryKeyBackup -Key $script:exRaw -BackupDir $script:exDir -Id 'pm2'
        New-ItemProperty -Path $script:exPs -Name 'V' -Value 'tampered' -Force | Out-Null
        $entry = @{ kind = 'registry_key'; target = $script:exRaw; backup_file = $bk.Path }
        $p = Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir
        $p.TargetState | Should -Be 'present_mismatch'
        New-ItemProperty -Path $script:exPs -Name 'V' -Value 'data-1' -Force | Out-Null
    }

    It 'absent -> absent；回灌后目标真的回来，再探测回到 present_match' {
        $bk = Export-RegistryKeyBackup -Key $script:exRaw -BackupDir $script:exDir -Id 'rs1'
        $bk.Ok | Should -BeTrue ($bk.Reason)
        Invoke-RegExe -Arguments @('delete', $script:exRaw, '/f') | Out-Null
        (Test-Path -LiteralPath $script:exPs) | Should -BeFalse

        $entry = @{ kind = 'registry_key'; target = $script:exRaw; backup_file = $bk.Path }
        (Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir).TargetState | Should -Be 'absent'

        $rs = Restore-RegistryBackupFile -BackupFile $bk.Path -VerifyPath $script:exRaw
        $rs.Ok | Should -BeTrue ($rs.Reason)
        (Test-Path -LiteralPath $script:exPs) | Should -BeTrue
        (Get-ItemProperty -Path $script:exPs -Name 'V').V | Should -Be 'data-1'
        (Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir).TargetState | Should -Be 'present_match'
    }

    It '备份文件缺失 -> 探测失败（fail-closed，绝不当作 absent 去恢复）' {
        $entry = @{ kind = 'registry_key'; target = $script:exRaw; backup_file = (Join-Path $script:exDir 'no-such.reg') }
        $p = Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir
        $p.Ok | Should -BeFalse
        ($null -eq $p.TargetState -or $p.TargetState -eq '') | Should -BeTrue
    }

    It 'backup_file 为空 -> 探测失败并给出原因' {
        $entry = @{ kind = 'registry_key'; target = $script:exRaw; backup_file = '' }
        $p = Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir
        $p.Ok | Should -BeFalse
        $p.Reason | Should -Be 'backup_file_missing'
    }

    It 'path_entry：段仍在 PATH -> present_match；已消失 -> absent' {
        $entry = @{ kind = 'path_entry'; target = 'C:\WRC-Not-Installed' }
        (Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir -MachinePath 'C:\Windows;C:\Other').TargetState | Should -Be 'absent'
        (Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir -MachinePath 'C:\Windows;C:\wrc-not-installed').TargetState | Should -Be 'present_match'
        # 读不到 Machine PATH 时不得臆断为 present（探测不了 -> absent 分支仍需因果证据）
        ($null -eq (Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir -MachinePath $null).TargetState) | Should -BeFalse
    }

    It '不可恢复类（service/task/path_deleted）不参与系统比较，由判定层按 kind 短路' {
        foreach ($k in @('service', 'task', 'path_deleted')) {
            $entry = @{ kind = $k; target = 'whatever'; backup_file = '' }
            (Get-RollbackEntryProbe -Entry $entry -BackupDir $script:exDir).TargetState | Should -Be 'absent'
        }
    }

    It '回灌复查失败时报 verify_absent，而不是静默成功' {
        $reg = @'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\WRC-Exec-Verify-Nope]
'@
        $f = Write-RegUnicodeFile -Path (Join-Path $script:exDir 'verify-nope.reg') -Content $reg
        $f.Ok | Should -BeTrue ($f.Reason)
        $r = Restore-RegistryBackupFile -BackupFile $f.Path -VerifyPath 'HKCU\Software\WRC-Exec-Verify-Nope'
        # 该键确实会被 import 建立；这里断言「不存在的路径」会被判失败
        $bad = Restore-RegistryBackupFile -BackupFile $f.Path -VerifyPath 'HKCU\Software\WRC-Exec-Verify-Absent'
        $bad.Ok | Should -BeFalse
        $bad.Reason | Should -Be 'import_failed(verify_absent)'
        $r.Ok | Should -BeTrue ($r.Reason)
        Invoke-RegExe -Arguments @('delete', 'HKCU\Software\WRC-Exec-Verify-Nope', '/f') | Out-Null
    }
}

Describe 'Invoke-RollbackRestore (REQ-024 两阶段 + REQ-021 PATH + REQ-030/031 落盘)' {
    BeforeAll {
        $script:rrRoot = Join-Path $env:TEMP ('wrc-rr-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:rrRoot -Force | Out-Null
        $script:rrBackup = Join-Path $script:rrRoot 'backup-run'
        New-Item -ItemType Directory -Path $script:rrBackup -Force | Out-Null
        # 同一父键下两个子键：用于证明「先全量判定，再逐个执行」
        $script:rrParent = 'HKCU\Software\WRC-RR-' + [guid]::NewGuid().ToString('N')
        $script:rrParentPs = $script:rrParent -replace '^HKCU\\', 'HKCU:\'
        $script:rrA = $script:rrParent + '\SubA'
        $script:rrB = $script:rrParent + '\SubB'
        foreach ($k in @($script:rrA, $script:rrB)) {
            $ps = $k -replace '^HKCU\\', 'HKCU:\'
            New-Item -Path $ps -Force | Out-Null
            New-ItemProperty -Path $ps -Name 'V' -Value ("data-" + (Split-Path $k -Leaf)) -Force | Out-Null
        }
        $script:rrNow = (Get-Date).ToUniversalTime()

        # 用例之间会互相删除 fixture（恢复类用例把键写回来、冲突类用例把它删掉），
        # 所以每条用例导出备份前先自行把键恢复到已知状态，而不是依赖上一条用例的余荫。
        function script:Ensure-RrKey {
            param([string]$Raw, [string]$Id)
            $ps = $Raw -replace '^HKCU\\', 'HKCU:\'
            if (-not (Test-Path -LiteralPath $ps)) {
                New-Item -Path $ps -Force | Out-Null
                New-ItemProperty -Path $ps -Name 'V' -Value ('data-' + (Split-Path $Raw -Leaf)) -Force | Out-Null
            }
            $bk = Export-RegistryKeyBackup -Key $Raw -BackupDir $script:rrBackup -Id $Id
            if (-not [bool]$bk.Ok) { throw "fixture export failed for $Raw : $($bk.Reason)" }
            return $bk
        }
    }

    AfterAll {
        Invoke-RegExe -Arguments @('delete', $script:rrParent, '/f') | Out-Null
        Remove-Item -LiteralPath $script:rrRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '窗口内 + 三项目标齐备 + 无迹象 -> 同一父键下多条目全部恢复（判定先于执行）' {
        $bkA = Ensure-RrKey -Raw $script:rrA -Id 'rra'
        $bkB = Ensure-RrKey -Raw $script:rrB -Id 'rrb'
        $bkA.Ok | Should -BeTrue ($bkA.Reason)
        Invoke-RegExe -Arguments @('delete', $script:rrA, '/f') | Out-Null
        Invoke-RegExe -Arguments @('delete', $script:rrB, '/f') | Out-Null
        # 基线 = 本轮对该父键的最后一次操作时刻（写入侧用 Get-ParentBaselineSnapshot）。
        # 若边判定边写，恢复 SubA 会把父键时间戳推进到基线之后，SubB 会被误判为外部变更。
        $baseline = Get-ParentBaselineSnapshot -Key $script:rrParent
        $baseline | Should -Not -BeNullOrEmpty

        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) `
            -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'reg_001' -Kind 'registry_key' -Target $script:rrA `
                -BackupFile $bkA.Path -BackupFileSha256 $bkA.Sha256 -PreExisting $true `
                -AbsentConfirmedAfterMutation $true -ParentBaseline $baseline -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'reg_002' -Kind 'registry_key' -Target $script:rrB `
                -BackupFile $bkB.Path -BackupFileSha256 $bkB.Sha256 -PreExisting $true `
                -AbsentConfirmedAfterMutation $true -ParentBaseline $baseline -State 'mutation_succeeded')
        )

        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot -Now $script:rrNow
        $r.Counts.restored | Should -Be 2
        $r.Counts.restore_failed | Should -Be 0
        (Test-Path -LiteralPath ($script:rrA -replace '^HKCU\\', 'HKCU:\')) | Should -BeTrue
        (Test-Path -LiteralPath ($script:rrB -replace '^HKCU\\', 'HKCU:\')) | Should -BeTrue
        $r.Unrepaired.Count | Should -Be 0
        $r.ResultPath | Should -Not -BeNullOrEmpty
        (Test-Path -LiteralPath $r.ResultPath) | Should -BeTrue
    }

    It '超窗（created_at 距今 >= 24h）-> 一条都不恢复，降级 conflict' {
        $bk = Ensure-RrKey -Raw $script:rrA -Id 'rr-out'
        Invoke-RegExe -Arguments @('delete', $script:rrA, '/f') | Out-Null
        $old = $script:rrNow.AddHours(-25)
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $old) -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'reg_010' -Kind 'registry_key' -Target $script:rrA `
                -BackupFile $bk.Path -BackupFileSha256 $bk.Sha256 -PreExisting $true `
                -AbsentConfirmedAfterMutation $true `
                -ParentBaseline (Format-IsoUtc -Value $old.AddMinutes(-5)) -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot -Now $script:rrNow
        $r.WithinWindow | Should -BeFalse
        $r.Counts.restored | Should -Be 0
        $r.Counts.restore_failed | Should -Be 1
        (Test-Path -LiteralPath ($script:rrA -replace '^HKCU\\', 'HKCU:\')) | Should -BeFalse
        $r.Unrepaired.Count | Should -Be 1
        (Test-Path -LiteralPath $r.UnrepairedPath) | Should -BeTrue
    }

    It 'already_present 是可重入的：重复执行不写系统、不算失败' {
        $bk = Ensure-RrKey -Raw $script:rrB -Id 'rr-re'
        if (-not (Test-Path -LiteralPath ($script:rrB -replace '^HKCU\\', 'HKCU:\'))) {
            $null = Restore-RegistryBackupFile -BackupFile $bk.Path -VerifyPath $script:rrB
        }
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'reg_020' -Kind 'registry_key' -Target $script:rrB `
                -BackupFile $bk.Path -BackupFileSha256 $bk.Sha256 -PreExisting $true `
                -AbsentConfirmedAfterMutation $true -ParentBaseline (Format-IsoUtc -Value $script:rrNow) `
                -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot -Now $script:rrNow
        $r.Counts.already_present | Should -Be 1
        $r.Counts.restored | Should -Be 0
        $r.Counts.restore_failed | Should -Be 0
    }

    It '不可恢复类如实告知 not_restorable，不进未修复清单（REQ-030：那是告知不是失败）' {
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'fs_001' -Kind 'path_deleted' -Target 'C:\gone' -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'svc_001' -Kind 'service' -Target 'WRC-Ghost' -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot -Now $script:rrNow
        $r.Counts.not_restorable | Should -Be 2
        $r.Unrepaired.Count | Should -Be 0
        (@($r.Report) -join "`n") | Should -Match 'CANNOT be recovered'
    }

    It 'PATH 漂移（迹象 iii）是作用域级判定：待写回的条目整批降级 conflict，一次都不写' {
        $orig = 'C:\Windows;C:\WRC-AppA;C:\WRC-AppB'
        $script:rrWrites = [System.Collections.Generic.List[string]]::new()
        $seam = {
            param($p)
            $script:rrWrites.Add($p)
            return $p
        }

        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test' `
            -MachinePathOriginal $orig -MachinePathScope 'Machine'
        $eA = ConvertTo-RollbackJournalEntry -Id 'path_001' -Kind 'path_entry' -Target 'C:\WRC-AppA' `
            -PreExisting $true -AbsentConfirmedAfterMutation $true -State 'mutation_succeeded'
        $eB = ConvertTo-RollbackJournalEntry -Id 'path_002' -Kind 'path_entry' -Target 'C:\WRC-AppB' `
            -PreExisting $true -AbsentConfirmedAfterMutation $true -State 'mutation_succeeded'
        # AppB 被外部加回 -> 当前整串 != 预期整串。AppA 仍缺失、需要写回，但整作用域
        # 一旦判为漂移就不能再写；AppB 的目标状态本来就已在 PATH 里 -> already_present
        # （REQ-024 规则 1 优先于迹象 iii，它不需要任何写入）。
        $j['entries'] = @($eA, $eB)
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot `
            -Now $script:rrNow -MachinePathOverride 'C:\Windows;C:\WRC-AppB' -SetPathScript $seam

        $script:rrWrites.Count | Should -Be 0
        $r.Counts.restored | Should -Be 0
        $r.Counts.restore_failed | Should -Be 1
        $r.Counts.already_present | Should -Be 1
        $vA = @($r.Verdicts | Where-Object { $_.Id -eq 'path_001' })[0]
        $vA.Reason | Should -Be 'conflict(external_change_sign_iii)'
        # 2026-10-07（drill5 复盘）：冲突分支必须把比较双方带出判定层 ——
        # 只剩 reason token 时「漂移到底是什么」永久不可复盘。
        $vA.PathCompare | Should -Be 'mismatch'
        $vA.ExpectedPath | Should -Be 'C:\Windows'
        $vA.PathCurrent | Should -Be 'C:\Windows;C:\WRC-AppB'
        # 证据必须穿过 Get-ReportedRollbackVerdict 的投影进入 rollback-result.json。
        $doc = Get-Content -LiteralPath $r.ResultPath -Raw | ConvertFrom-Json
        $jvA = @($doc.verdicts | Where-Object { $_.Id -eq 'path_001' })[0]
        $jvA.PathCompare | Should -Be 'mismatch'
        $jvA.ExpectedPath | Should -Be 'C:\Windows'
        $jvA.PathCurrent | Should -Be 'C:\Windows;C:\WRC-AppB'
        @($r.Verdicts | Where-Object { $_.Id -eq 'path_002' })[0].Verdict | Should -Be 'already_present'
    }

    It 'PATH 无漂移 -> 整作用域一次写回，逐字回到原值（REQ-021）' {
        $orig = 'C:\Windows;C:\WRC-AppA;C:\WRC-AppB'
        $script:rrWrites2 = [System.Collections.Generic.List[string]]::new()
        $seam = {
            param($p)
            $script:rrWrites2.Add($p)
            return $p
        }
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test' `
            -MachinePathOriginal $orig -MachinePathScope 'Machine'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'path_001' -Kind 'path_entry' -Target 'C:\WRC-AppA' `
                -PreExisting $true -AbsentConfirmedAfterMutation $true -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'path_002' -Kind 'path_entry' -Target 'C:\WRC-AppB' `
                -PreExisting $true -AbsentConfirmedAfterMutation $true -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot `
            -Now $script:rrNow -MachinePathOverride 'C:\Windows' -SetPathScript $seam
        $script:rrWrites2[0] | Should -Be $orig
        $r.Counts.restored | Should -Be 2
    }

    It '缺少 machine_path_original 时不得凭空造 PATH（fail-closed，不写系统）' {
        $script:rrWrites3 = [System.Collections.Generic.List[string]]::new()
        $seam = {
            param($p)
            $script:rrWrites3.Add($p)
            return $p
        }
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'path_003' -Kind 'path_entry' -Target 'C:\WRC-AppC' `
                -PreExisting $true -AbsentConfirmedAfterMutation $true -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot `
            -Now $script:rrNow -MachinePathOverride 'C:\Windows' -SetPathScript $seam
        $script:rrWrites3.Count | Should -Be 0
        $r.Counts.restore_failed | Should -Be 1
    }

    It '迹象 (ii)：父键在基线之后被外部写入 -> 整批降级 conflict，一条都不写' {
        $bk = Ensure-RrKey -Raw $script:rrA -Id 'rr-ii'
        Invoke-RegExe -Arguments @('delete', $script:rrA, '/f') | Out-Null
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['entries'] = @(
            # 基线「早于」父键当前时间戳 = 本轮之后父键又被外部写过
            (ConvertTo-RollbackJournalEntry -Id 'reg_030' -Kind 'registry_key' -Target $script:rrA `
                -BackupFile $bk.Path -BackupFileSha256 $bk.Sha256 -PreExisting $true `
                -AbsentConfirmedAfterMutation $true `
                -ParentBaseline (Format-IsoUtc -Value $script:rrNow.AddHours(-2)) `
                -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot -Now $script:rrNow
        $r.Counts.restore_failed | Should -Be 1
        @($r.Verdicts)[0].Reason | Should -Be 'conflict(external_change_sign_ii)'
        (Test-Path -LiteralPath ($script:rrA -replace '^HKCU\\', 'HKCU:\')) | Should -BeFalse
    }

    It '基线全为 null（崩溃在首次基线写入之前）-> 跳过迹象 (ii) 但标注证据不完整' {
        $bk = Ensure-RrKey -Raw $script:rrA -Id 'rr-nb'
        Invoke-RegExe -Arguments @('delete', $script:rrA, '/f') | Out-Null
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'reg_040' -Kind 'registry_key' -Target $script:rrA `
                -BackupFile $bk.Path -BackupFileSha256 $bk.Sha256 -PreExisting $true `
                -AbsentConfirmedAfterMutation $true -ParentBaseline $null -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot -Now $script:rrNow
        $r.Counts.restored | Should -Be 1
        @($r.Verdicts)[0].EvidenceIncomplete | Should -BeTrue
        (@($r.Report) -join "`n") | Should -Match 'evidence-incomplete'
    }

    It 'created_at 缺失 -> 判为无法确认时间，降级 conflict（不得抛异常炸掉整轮）' {
        $bk = Ensure-RrKey -Raw $script:rrB -Id 'rr-na'
        Invoke-RegExe -Arguments @('delete', $script:rrB, '/f') | Out-Null
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['created_at'] = $null
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'svc_010' -Kind 'service' -Target 'WRC-Ghost' -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'reg_050' -Kind 'registry_key' -Target $script:rrB `
                -BackupFile $bk.Path -BackupFileSha256 $bk.Sha256 -PreExisting $true `
                -AbsentConfirmedAfterMutation $true `
                -ParentBaseline (Get-ParentBaselineSnapshot -Key $script:rrParent) -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot -Now $script:rrNow
        $r.WithinWindow | Should -BeFalse
        $r.WindowReason | Should -Be 'created_at_missing'
        @($r.Verdicts | Where-Object { $_.Kind -eq 'registry_key' })[0].Reason | Should -Be 'conflict(window_exceeded)'
        (Test-Path -LiteralPath ($script:rrB -replace '^HKCU\\', 'HKCU:\')) | Should -BeFalse
        $r.Counts.not_restorable | Should -Be 1
    }

    It '落盘产物：rollback-result.json 汇总四种判定，未修复清单落在 output/（REQ-030/031）' {
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test' -RunId ([guid]::NewGuid().ToString())
        # 两条都因缺备份文件而 restore_failed：多条才能暴露「清单被套成两层数组」的缺陷。
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'reg_060' -Kind 'registry_key' -Target 'HKCU\Software\WRC-Missing-Backup' `
                -BackupFile '' -PreExisting $true -AbsentConfirmedAfterMutation $true `
                -ParentBaseline (Format-IsoUtc -Value $script:rrNow) -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'reg_061' -Kind 'registry_key' -Target 'HKCU\Software\WRC-Missing-Backup-2' `
                -BackupFile '' -PreExisting $true -AbsentConfirmedAfterMutation $true `
                -ParentBaseline (Format-IsoUtc -Value $script:rrNow) -State 'mutation_succeeded')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot -Now $script:rrNow
        $r.PersistenceError | Should -BeFalse
        $doc = Get-Content -LiteralPath $r.ResultPath -Raw | ConvertFrom-Json
        $doc.run_id | Should -Be $r.RunId
        $doc.counts.restore_failed | Should -Be 2
        (@($doc.verdicts)).Count | Should -Be 2
        $r.UnrepairedPath | Should -Match 'rollback-unrepaired-'
        (Split-Path -Leaf (Split-Path -Parent $r.UnrepairedPath)) | Should -Be 'output'
        $raw = Get-Content -LiteralPath $r.UnrepairedPath -Raw
        $u = $raw | ConvertFrom-Json
        # REQ-030 键名是 unrepaired[]；items 是修复前的错误键名。
        $raw | Should -Match '"unrepaired":\s*\['
        $raw | Should -Not -Match '"items":'
        @($u.unrepaired).Count | Should -Be 2
        # 回归（@(Add-UnrepairedItem ...) 双层包裹）：每项必须是条目对象本身，
        # 不能是数组，顶层也不能出现 @() 包裹产生的 value/Count 信封。
        (@($u.unrepaired)[0].PSObject.Properties.Name) -contains 'item_id' | Should -BeTrue
        (@($u.unrepaired)[0].kind) | Should -Be 'registry_key'
        # item_id 用 REQ-027 的唯一权威算法 `<kind>:<规范化 target>`（注册表路径统一小写），
        # 不是日志条目短 Id（reg_061）——清单必须能直接回指到日志条目。
        (@($u.unrepaired)[1].item_id) | Should -Be 'registry_key:hkcu\software\wrc-missing-backup-2'
        (@($u.unrepaired)[1].item_id) | Should -Not -Be (@($u.unrepaired)[0].item_id)
        (@($u.unrepaired)[1].target) | Should -Be 'HKCU\Software\WRC-Missing-Backup-2'
        $u.PSObject.Properties.Name | Should -Not -Contain 'value'
        $u.PSObject.Properties.Name | Should -Not -Contain 'Count'
        $u.backup_dir | Should -Be $script:rrBackup
    }

    It '-AcknowledgeConflicts 只回传标记，不改变判定（REQ-030 逃生口不是覆盖开关）' {
        $bk = Ensure-RrKey -Raw $script:rrA -Id 'rr-ack'
        Invoke-RegExe -Arguments @('delete', $script:rrA, '/f') | Out-Null
        $j = ConvertTo-RollbackJournal -CreatedAt (Format-IsoUtc -Value $script:rrNow) -BackupDir $script:rrBackup -MachineFingerprint 'test'
        $j['entries'] = @(
            # 目标确实缺失，但因果证据不足（仅 planned，未确认删除）-> 规则 4：绝不自动恢复
            (ConvertTo-RollbackJournalEntry -Id 'reg_070' -Kind 'registry_key' -Target $script:rrA `
                -BackupFile $bk.Path -BackupFileSha256 $bk.Sha256 -PreExisting $false `
                -AbsentConfirmedAfterMutation $false `
                -ParentBaseline (Get-ParentBaselineSnapshot -Key $script:rrParent) -State 'planned')
        )
        $r = Invoke-RollbackRestore -Journal $j -BackupDir $script:rrBackup -ProjectRoot $script:rrRoot `
            -Now $script:rrNow -AcknowledgeConflicts
        $r.Acknowledged | Should -BeTrue
        @($r.Verdicts)[0].Verdict | Should -Be 'restore_failed'
        @($r.Verdicts)[0].Reason | Should -Be 'conflict(causal_flags_incomplete)'
        (Test-Path -LiteralPath ($script:rrA -replace '^HKCU\\', 'HKCU:\')) | Should -BeFalse
    }
}

Describe '父键作用域：Get-RollbackEntryParentKey / Get-ParentBaselineMaxByParent / Get-ParentBaselineSnapshot' {
    It '注册表键条目的父键是上一段；启动项条目的父键是复合串的键部分' {
        (Get-RollbackEntryParentKey -Entry @{ kind = 'registry_key'; target = 'HKCU\Software\WRC\Sub' }) `
            | Should -Be 'HKCU\Software\WRC'
        (Get-RollbackEntryParentKey -Entry @{ kind = 'startup_value'; target = 'HKCU\...\Run|App' }) `
            | Should -Be 'HKCU\...\Run'
    }

    It '聚合基线按**父键**取 MAX，不得用全日志一个最大值（REQ-024 迹象 ii）' {
        $j = ConvertTo-RollbackJournal -BackupDir 'x' -MachineFingerprint 'f'
        $late = '2026-10-01T10:00:00Z'
        $early = '2026-10-01T08:00:00Z'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'reg_001' -Kind 'registry_key' -Target 'HKCU\Software\P1\A' `
                -ParentBaseline $early -State 'mutation_succeeded'),
            # 同一父键的第二次操作：必须把该父键的基线推进到 MAX
            (ConvertTo-RollbackJournalEntry -Id 'reg_002' -Kind 'registry_key' -Target 'HKCU\Software\P1\B' `
                -ParentBaseline $late -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'reg_003' -Kind 'registry_key' -Target 'HKCU\Software\P2\A' `
                -ParentBaseline $early -State 'mutation_succeeded'),
            # 长短 hive 写法是同一个父键
            (ConvertTo-RollbackJournalEntry -Id 'reg_004' -Kind 'registry_key' -Target 'HKEY_CURRENT_USER\software\p1\C' `
                -ParentBaseline $early -State 'mutation_succeeded'),
            # 非注册表类没有「父键」语义，恒不参与聚合
            (ConvertTo-RollbackJournalEntry -Id 'path_001' -Kind 'path_entry' -Target 'C:\X' `
                -ParentBaseline $null -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'sv_001' -Kind 'startup_value' -Target 'HKCU\Software\P3\Run|App' `
                -ParentBaseline $early -State 'mutation_succeeded')
        )
        $map = Get-ParentBaselineMaxByParent -Journal $j
        # 三个父键：P1（三条，含长短 hive 混写）、P2、P3\Run（startup_value 的键部分）
        $map.Count | Should -Be 3
        $map[(Get-NormalizedRegKeyPath -Path 'HKCU\Software\P1')].ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be $late
        $map[(Get-NormalizedRegKeyPath -Path 'HKCU\Software\P2')].ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be $early
        $map.ContainsKey((Get-NormalizedRegKeyPath -Path 'HKCU\Software\P1\A')) | Should -BeFalse
        # 聚合必须是**每父键**的：P1 的 MAX 晚、P2 的 MAX 早。
        # 若按全日志一个最大值（下面这行），P2 在 08:00 之后、10:00 之前的外部写入会被漏检。
        (Get-ParentBaselineMax -Journal $j).ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be $late
    }

    It '基线为 null / 不可解析的条目跳过；整父键全缺 -> 该父键不进 map' {
        $j = ConvertTo-RollbackJournal -BackupDir 'x' -MachineFingerprint 'f'
        $j['entries'] = @(
            (ConvertTo-RollbackJournalEntry -Id 'reg_001' -Kind 'registry_key' -Target 'HKCU\Software\P9\A' `
                -ParentBaseline $null -State 'mutation_succeeded'),
            (ConvertTo-RollbackJournalEntry -Id 'reg_002' -Kind 'registry_key' -Target 'HKCU\Software\P9\B' `
                -ParentBaseline 'not-a-timestamp' -State 'mutation_succeeded')
        )
        $map = Get-ParentBaselineMaxByParent -Journal $j
        $map.Count | Should -Be 0
    }

    It 'Get-ParentBaselineSnapshot -> 秒精度且**不早于**父键真实 LastWriteTime' {
        $raw = 'HKCU\Software\WRC-Base-' + [guid]::NewGuid().ToString('N')
        $ps = $raw -replace '^HKCU\\', 'HKCU:\'
        New-Item -Path $ps -Force | Out-Null
        try {
            New-Item -Path "$ps\Child" -Force | Out-Null
            $snap = Get-ParentBaselineSnapshot -Key $raw
            $snap | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            $hkey = Open-RegistryKeyForRead -Path $raw
            $lw = Get-RegistryKeyLastWriteTime -Key $hkey
            $hkey.Close()
            # 记下的基线必须能覆盖刚发生的这次自身操作（秒截断会把基线压到操作之前，
            # 那会让恢复端把本工具的删除误判为外部变更）
            ($lw.ToUniversalTime() -le (ConvertFrom-IsoUtc -Text $snap)) | Should -BeTrue
        } finally {
            Invoke-RegExe -Arguments @('delete', $raw, '/f') | Out-Null
        }
    }

    It '父键不存在 / 无法解析 -> $null（基线缺失走证据不完整，不得凭空造时间）' {
        ($null -eq (Get-ParentBaselineSnapshot -Key 'HKCU\Software\WRC-Definitely-Missing-9f3a2b')) | Should -BeTrue
        ($null -eq (Get-ParentBaselineSnapshot -Key '')) | Should -BeTrue
    }

    It 'startup_value 条目：父键不存在 -> absent；target 不可拆解 -> fail-closed（不碰真实 Run 键）' {
        $guidN = [guid]::NewGuid().ToString('N')
        $parentOnly = 'HKCU\Software\WRC-NoParent-' + $guidN
        $raw = $parentOnly + '|GhostApp'
        $bk = Join-Path $env:TEMP ('wrc-nope-' + $guidN + '.reg')
        $entry = @{ kind = 'startup_value'; target = $raw; backup_file = $bk }
        $p = Get-RollbackEntryProbe -Entry $entry -BackupDir $env:TEMP
        $p.Ok | Should -BeFalse
        $p.Reason | Should -Match 'backup_unreadable'

        $crlf = "`r`n"
        $body = 'Windows Registry Editor Version 5.00' + $crlf + $crlf +
            '[' + $parentOnly + ']' + $crlf + '"GhostApp"="C:\\gone.exe"' + $crlf
        $ok = Write-RegUnicodeFile -Path $bk -Content $body
        $ok.Ok | Should -BeTrue ($ok.Reason)
        try {
            $p2 = Get-RollbackEntryProbe -Entry $entry -BackupDir $env:TEMP
            $p2.Ok | Should -BeTrue ($p2.Reason)
            $p2.TargetState | Should -Be 'absent'

            $bad = Get-RollbackEntryProbe -Entry @{ kind = 'startup_value'; target = 'HKCU\no_pipe'; backup_file = $bk } -BackupDir $env:TEMP
            $bad.Ok | Should -BeFalse
            $bad.Reason | Should -Be 'target_not_decomposable'
        } finally {
            Remove-Item -LiteralPath $bk -Force -ErrorAction SilentlyContinue
        }
    }

    It '迹象 (ii) 输入：父键打不开 -> Undecidable（不得静默当作无外部变更）' {
        # 目标的**父键**必须不存在：若父键是 HKCU\Software 这种恒存在的键，
        # 迹象 (ii) 是可判定的（no_external_change），那就不是本用例要断言的分支。
        $missingParent = 'HKCU\Software\WRC-NoParent-' + [guid]::NewGuid().ToString('N')
        $ii = Get-SignIiInputForEntry -Entry @{ kind = 'registry_key'; target = ($missingParent + '\Sub') } `
            -BaselineMax (Get-Date).ToUniversalTime()
        $ii.SignIiDetected | Should -BeFalse
        $ii.SignIiUndecidable | Should -BeTrue
        $ii.SignIiReason | Should -Be 'parent_key_unreadable'
    }

    It '迹象 (ii) 输入：无基线 -> Undecidable(no_baseline)' {
        $ii = Get-SignIiInputForEntry -Entry @{ kind = 'registry_key'; target = 'HKCU\Software\Classes\x' } `
            -BaselineMax $null
        $ii.SignIiUndecidable | Should -BeTrue
        $ii.SignIiReason | Should -Be 'no_baseline'
    }
}

Describe 'Get-CurrentRegSnapshot (read-only probe channel)' {
    BeforeAll {
        $script:snapDir = Join-Path $env:TEMP ('wrc-snap-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:snapDir -Force | Out-Null
        $script:snapRaw = 'HKCU\Software\WRC-Snap-' + [guid]::NewGuid().ToString('N')
        $script:snapPs = $script:snapRaw -replace '^HKCU\\', 'HKCU:\'
        New-Item -Path $script:snapPs -Force | Out-Null
        New-ItemProperty -Path $script:snapPs -Name 'V' -Value 'snap-1' -Force | Out-Null
    }

    AfterAll {
        Invoke-RegExe -Arguments @('delete', $script:snapRaw, '/f') | Out-Null
        Remove-Item -LiteralPath $script:snapDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '导出的当前态可被 Read-RegUnicodeFile 解出，且不留临时快照文件' {
        $before = @(Get-ChildItem -LiteralPath $script:snapDir -File).Count
        $s = Get-CurrentRegSnapshot -Key $script:snapRaw -BackupDir $script:snapDir
        $s.Ok | Should -BeTrue ($s.Reason)
        $s.Absent | Should -BeFalse
        $s.Text | Should -Match 'snap-1'
        (Get-ChildItem -LiteralPath $script:snapDir -File).Count | Should -Be $before
    }

    It '键不存在 -> Absent=$true（不当成异常，也不当成「存在」）' {
        $s = Get-CurrentRegSnapshot -Key 'HKCU\Software\WRC-Definitely-Missing-9f3a2b' -BackupDir $script:snapDir
        $s.Ok | Should -BeFalse
        $s.Absent | Should -BeTrue
    }

    It '备份目录不存在 -> 既非 Ok 也非 Absent（探测不了必须 fail-closed）' {
        $s = Get-CurrentRegSnapshot -Key $script:snapRaw -BackupDir (Join-Path $script:snapDir 'no-such-dir')
        $s.Ok | Should -BeFalse
        $s.Absent | Should -BeFalse
    }
}
