# tests/unit/rollback-backup.Tests.ps1
# S3 写入端 — DD-003 父键导出裁剪（纯函数）与注册表父键解析。
# 断言必须在 PS 5.1 与 pwsh 7 下都成立。
#
# REQ-007 / DD-003：启动项 value 的备份 = 导出父键后裁剪为「只含目标 value」的
# 最小 .reg；裁剪输出必须**恰好一个值定义**，否则 export_failed(trim_multivalue)。
# REQ-035：reg export 产出 UTF-16LE + BOM，读写必须按 Unicode。

BeforeAll {
    $script:JournalScript  = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-journal.ps1'
    $script:BackupScript   = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-backup.ps1'
    . $script:JournalScript
    . $script:BackupScript
}

Describe 'Get-RegistryParentPath' {
    It '<Key> -> <Parent>' -TestCases @(
        @{ Key = 'HKCU\Software\Foo';        Parent = 'HKCU\Software' }
        @{ Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Parent = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion' }
        @{ Key = 'HKEY_LOCAL_MACHINE\Software\X\Y'; Parent = 'HKEY_LOCAL_MACHINE\Software\X' }
    ) {
        param($Key, $Parent)
        Get-RegistryParentPath -Key $Key | Should -Be $Parent
    }

    It '根键（无父级）返回 $null' {
        ($null -eq (Get-RegistryParentPath -Key 'HKCU')) | Should -BeTrue
        ($null -eq (Get-RegistryParentPath -Key 'HKCU\')) | Should -BeTrue
    }
}

Describe 'Get-TrimmedRegExport (DD-003 / REQ-007)' {
    # 与 reg.exe 实际输出同构：UTF-16LE 段 + [父键\子键] 块。
    # Pester 5：Describe 体内直接定义的函数只存在于 discovery 阶段，
    # 必须放进 BeforeAll 才能在 run 阶段被用例调用。
    BeforeAll {
        function script:New-RegText {
            param([string]$Body)
            return "Windows Registry Editor Version 5.00`r`n`r`n$Body`r`n"
        }
    }

    It '共享 Run 键只保留目标 value，兄弟 value 一律剔除' {
        $src = New-RegText @'
[HKCU\Software\Microsoft\Windows\CurrentVersion\Run]
"GoodApp"="C:\\Good\\app.exe"
"DeadApp"="C:\\gone\\dead.exe"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'DeadApp'
        $r.Ok | Should -BeTrue ($r.Reason)
        $r.Content | Should -BeLike '*"DeadApp"=*'
        $r.Content | Should -Not -BeLike '*GoodApp*'
    }

    It '裁剪结果必须恰好一个值定义（多值时 trim_multivalue 拒绝）' {
        $dup = New-RegText @'
[HKCU\...\Run]
"DeadApp"="C:\\gone\\a.exe"
"DeadApp"="C:\\gone\\b.exe"
'@
        (Get-TrimmedRegExport -RegText $dup -ValueName 'DeadApp').Reason |
            Should -Be 'export_failed(trim_multivalue)'
    }

    It '目标 value 不存在时拒绝（不得产出空备份再删真值）' {
        $src = New-RegText @'
[HKCU\...\Run]
"Other"="x"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'Missing'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'export_failed(value_not_found)'
    }

    It '保留版本头与父键行（reg import 的最低要求）' {
        $src = New-RegText @'
[HKCU\...\Run]
"DeadApp"="C:\\gone\\dead.exe"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'DeadApp'
        $r.Content | Should -Match 'Windows Registry Editor Version 5\.00'
        # 用 -Match 而非 -BeLike：-like 的 [...] 是字符类，键行断言会变成空判定。
        $r.Content | Should -Match '\[HKCU\\[.]{3}\\Run\]'
    }

    It '同名 value 出现在多个键块时只保留目标键块内的定义' {
        $src = New-RegText @'
[HKEY_CURRENT_USER\...\Run]
"Shared"="C:\\keep\\this.exe"

[HKEY_CURRENT_USER\Software\Other]
"Shared"="C:\\must\\not\\appear.exe"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'Shared' -ParentKey 'HKEY_CURRENT_USER\...\Run'
        $r.Ok | Should -BeTrue ($r.Reason)
        $r.Content | Should -BeLike '*keep\\this*'
        $r.Content | Should -Not -BeLike '*must\\not*'
    }

    It '大小写不敏感匹配 value 名与键路径（注册表语义）' {
        $src = New-RegText @'
[hkcu\...\run]
"deadapp"="C:\\gone\\dead.exe"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'DeadApp'
        $r.Ok | Should -BeTrue ($r.Reason)
    }
    It '无版本头 / 空输入都拒绝（不得把任意文本当作 .reg 备份）' {
        (Get-TrimmedRegExport -RegText 'plain text' -ValueName 'X').Reason |
            Should -Be 'export_failed(missing_header)'
        (Get-TrimmedRegExport -RegText '' -ValueName 'X').Reason |
            Should -Be 'export_failed(missing_header)'
    }

    It '长值折行（行尾单个反斜杠）整体归属同一条目，不被拆断' {
        $src = New-RegText @'
[HKCU\...\Run]
"DeadApp"=hex(7):43,00,3a,00,5c,00,67,00,6f,00,6e,00,65,00,5c,00,\
00,00
"Other"="y"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'DeadApp'
        $r.Ok | Should -BeTrue ($r.Reason)
        ($r.Content -split "`r`n" | Where-Object { $_ -match '00,00$' }).Count | Should -Be 1
        $r.Content | Should -Not -BeLike '*"Other"*'
        # 裁剪结果仍必须是「恰好一个值定义」：折行不得被算成两条
        (Get-TrimmedRegExport -RegText $r.Content -ValueName 'DeadApp').Ok | Should -BeTrue
    }

    It '空 value 名直接拒绝（避免与键的 (默认) 值 ""= 混淆）' {
        $src = New-RegText @'
[HKCU\...\Run]
""="C:\\default\\app.exe"
'@
        (Get-TrimmedRegExport -RegText $src -ValueName ' ').Reason |
            Should -Be 'export_failed(empty_value_name)'
        (Get-TrimmedRegExport -RegText $src -ValueName '').Reason |
            Should -Be 'export_failed(empty_value_name)'
    }

    It '目标 value 只存在于其它键块时不得跨块取值' {
        $src = New-RegText @'
[HKEY_CURRENT_USER\Software\Other]
"DeadApp"="C:\\wrong\\block.exe"
'@
        $r = Get-TrimmedRegExport -RegText $src -ValueName 'DeadApp' `
            -ParentKey 'HKEY_CURRENT_USER\...\Run'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'export_failed(value_not_found)'
    }
}

Describe 'Export-RegistryKeyBackup (integration, real reg.exe)' {
    BeforeAll {
        $script:exportDir = Join-Path $env:TEMP ('wrc-exp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:exportDir -Force | Out-Null
        $script:testKey = 'HKCU:\Software\WRC-Backup-Test-' + [guid]::NewGuid().ToString('N')
        New-Item -Path $script:testKey -Force | Out-Null
        New-ItemProperty -Path $script:testKey -Name 'V' -Value 'data-1' -Force | Out-Null
        New-Item -Path "$script:testKey\Sub" -Force | Out-Null
    }
    AfterAll {
        Remove-Item -Path $script:testKey -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:exportDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '导出存在的键：文件落盘、SHA-256 齐备、内容非空' {
        $r = Export-RegistryKeyBackup -Key ($script:testKey -replace '^HKCU:', 'HKCU') `
            -BackupDir $script:exportDir -Id 'reg_t1'
        $r.Ok | Should -BeTrue ($r.Reason)
        Test-Path -LiteralPath $r.Path -PathType Leaf | Should -BeTrue
        $r.Sha256 | Should -Match '^[0-9A-F]{64}$'
    }

    It '导出的 .reg 必须自带 BOM，且可被 Read-RegUnicodeFile 原样解出' {
        $r = Export-RegistryKeyBackup -Key ($script:testKey -replace '^HKCU:', 'HKCU') `
            -BackupDir $script:exportDir -Id 'reg_t2'
        $bytes = [System.IO.File]::ReadAllBytes($r.Path)
        $utf16 = ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
        $utf8bom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        ($utf16 -or $utf8bom) | Should -BeTrue
        $rd = Read-RegUnicodeFile -Path $r.Path
        $rd.Ok | Should -BeTrue ($rd.Reason)
        $rd.Content | Should -Match 'Windows Registry Editor Version 5\.00'
    }

    It '导出不存在的键 -> 失败且不留半截文件（fail-closed）' {
        $r = Export-RegistryKeyBackup -Key 'HKCU\Software\WRC-Definitely-Missing-9f3a2b' `
            -BackupDir $script:exportDir -Id 'reg_t3'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match 'export_failed\(reg_exit_'
        # 失败路径不回报路径（Path 为空），且磁盘上不得留下该名字的残留
        ([string]::IsNullOrWhiteSpace([string]$r.Path)) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:exportDir -Filter 'reg-reg_t3*') | Should -BeNullOrEmpty
    }

    It 'DD-003 闭环：整键导出 -> 裁剪单值 -> 删除 -> 导入裁剪件，只复活目标值' {
        New-ItemProperty -Path $script:testKey -Name 'S' -Value 'sibling' -Force | Out-Null
        $keyRaw = $script:testKey -replace '^HKCU:', 'HKCU'
        $exp = Export-RegistryKeyBackup -Key $keyRaw -BackupDir $script:exportDir -Id 'reg_rt'
        $exp.Ok | Should -BeTrue ($exp.Reason)

        $rd = Read-RegUnicodeFile -Path $exp.Path
        $rd.Ok | Should -BeTrue ($rd.Reason)
        $trim = Get-TrimmedRegExport -RegText $rd.Content -ValueName 'V'
        $trim.Ok | Should -BeTrue ($trim.Reason)
        $trim.Content | Should -Not -BeLike '*"S"*'

        Remove-ItemProperty -Path $script:testKey -Name 'V' -Force
        Remove-ItemProperty -Path $script:testKey -Name 'S' -Force
        @(Get-Item -LiteralPath $script:testKey).GetValueNames() | Should -BeNullOrEmpty

        # REQ-035：裁剪后的 .reg 必须以 UTF-16LE + BOM 落盘，reg import 才认
        $file = Join-Path $script:exportDir 'reg-rt-trimmed.reg'
        $w = Write-RegUnicodeFile -Path $file -Content $trim.Content
        $w.Ok | Should -BeTrue ($w.Reason)
        $lead = [System.IO.File]::ReadAllBytes($file)
        ($lead[0] -eq 0xFF -and $lead[1] -eq 0xFE) | Should -BeTrue

        $imp = Invoke-RegExe -Arguments @('import', $file)
        $imp.ok | Should -BeTrue ($imp.error)
        (Get-ItemProperty -LiteralPath $script:testKey).V | Should -Be 'data-1'
        # 兄弟值没有被整键回写复活 —— 这正是禁止整键导入的原因
        (@(Get-Item -LiteralPath $script:testKey).GetValueNames() -contains 'S') | Should -BeFalse
    }

    It 'Invoke-RegExe 回报真实退出码与非零 error，不抛' {
        $r = Invoke-RegExe -Arguments @('query', 'HKCU\Definitely-Missing-9f3a2b')
        $r.ok | Should -BeFalse
        ($null -ne $r.exit_code) | Should -BeTrue
        ([string]::IsNullOrWhiteSpace($r.error)) | Should -BeFalse
    }
}

Describe 'Write-RegUnicodeFile (REQ-035)' {
    BeforeAll {
        $script:wruDir = Join-Path $env:TEMP ('wrc-reg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:wruDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -LiteralPath $script:wruDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '写入 UTF-16LE + BOM，reg import 可直接消费' {
        $p = Join-Path $script:wruDir 'ok.reg'
        $r = Write-RegUnicodeFile -Path $p -Content "Windows Registry Editor Version 5.00`r`n`r`n"
        $r.Ok | Should -BeTrue ($r.Reason)
        $b = [System.IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) | Should -BeTrue
    }

    It '空内容 = 只有 BOM：判定失败（不得产出 reg 拒收的空备份）' {
        $r = Write-RegUnicodeFile -Path (Join-Path $script:wruDir 'empty.reg') -Content ''
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'write_failed(header_lost)'
    }

    It '目录不存在时回报失败而不抛' {
        $r = Write-RegUnicodeFile -Path (Join-Path $script:wruDir 'no-such-dir\x.reg') -Content 'Windows Registry Editor Version 5.00'
        $r.Ok | Should -BeFalse
        ($r.Reason -like 'write_failed(*') | Should -BeTrue
    }

    It 'UTF-16LE 与 UTF-8+BOM 两种物料都能读回；无 BOM / 缺文件都回报失败' {
        $u8 = Join-Path $script:wruDir 'utf8bom.reg'
        [System.IO.File]::WriteAllText($u8, "Windows Registry Editor Version 5.00`r`n",
            (New-Object System.Text.UTF8Encoding($true)))
        (Read-RegUnicodeFile -Path $u8).Content | Should -Match 'Windows Registry Editor Version 5\.00'

        $raw = Join-Path $script:wruDir 'no-bom.reg'
        [System.IO.File]::WriteAllText($raw, "Windows Registry Editor Version 5.00`r`n",
            (New-Object System.Text.UTF8Encoding($false)))
        (Read-RegUnicodeFile -Path $raw).Reason | Should -Be 'read_failed(no_bom)'

        (Read-RegUnicodeFile -Path (Join-Path $script:wruDir 'absent.reg')).Reason |
            Should -Be 'read_failed(not_found)'
    }
}

Describe 'Confirm-RegistryTargetAbsent / Confirm-PathEntryRemoved (REQ-024 flag 3)' {
    It '不存在的键 -> Absent=$true' {
        $r = Confirm-RegistryTargetAbsent -Key 'HKCU\Software\WRC-Definitely-Missing-9f3a2b'
        $r.Absent | Should -BeTrue
    }

    It '存在的键 -> Absent=$false' {
        $r = Confirm-RegistryTargetAbsent -Key 'HKCU\Software\Microsoft'
        $r.Absent | Should -BeFalse
    }

    It 'PATH 段已移除 -> Absent=$true；仍在 -> Absent=$false（整段、大小写不敏感）' {
        (Confirm-PathEntryRemoved -PathList 'A;C' -Entry 'B').Absent | Should -BeTrue
        (Confirm-PathEntryRemoved -PathList 'A;b' -Entry 'B').Absent | Should -BeFalse
        (Confirm-PathEntryRemoved -PathList 'A;C' -Entry '').Absent | Should -BeFalse
    }
}
