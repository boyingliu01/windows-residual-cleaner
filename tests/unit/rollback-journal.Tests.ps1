# tests/unit/rollback-journal.Tests.ps1
# S1 — journal 核心：schema、原子写、自证（REQ-005 / REQ-027 / REQ-032 / REQ-034 / REQ-035）
# 断言必须在 PS 5.1 与 pwsh 7 下都成立（pre-commit Gate 5 用 pwsh 7）。

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-journal.ps1'
    . $script:ScriptPath
}

Describe 'rollback-journal: item_id 规范化（REQ-027）' {
    It 'registry_key 路径统一小写并去掉尾随反斜杠' {
        $a = Get-ItemId -Kind 'registry_key' -Target 'HKLM\SOFTWARE\Acme\'
        $b = Get-ItemId -Kind 'registry_key' -Target 'hklm\software\acme'
        $a | Should -Be 'registry_key:hklm\software\acme'
        $b | Should -Be $a -Because '注册表路径大小写不敏感，必须产生同一 item_id'
    }

    It 'path_entry 去掉引号与空白但保留大小写' {
        Get-ItemId -Kind 'path_entry' -Target '  "C:\Program Files\Acme\bin"  ' |
            Should -Be 'path_entry:C:\Program Files\Acme\bin'
    }

    It 'path_deleted 保留大小写且去掉尾随反斜杠' {
        Get-ItemId -Kind 'path_deleted' -Target 'C:\Program Files\Acme\' |
            Should -Be 'path_deleted:C:\Program Files\Acme'
    }

    It '不把盘符根 C:\ 削成 C:' {
        Get-ItemId -Kind 'path_deleted' -Target 'C:\' | Should -Be 'path_deleted:C:\'
    }

    It 'path_deleted 与 path_entry 对同一路径产生不同 item_id（两者语义不同，不得混用）' {
        $d = Get-ItemId -Kind 'path_deleted' -Target 'C:\X'
        $e = Get-ItemId -Kind 'path_entry' -Target 'C:\X'
        $d | Should -Not -Be $e
    }
}

Describe 'rollback-journal: 空条目列表不得被读成 1 条（PS 5.1 陷阱）' {
    It 'entries 为 null 时 Count 为 0' {
        $j = @{ entries = $null }
        (Get-RollbackJournalEntryList -Journal $j).Count | Should -Be 0
    }

    It 'entries 缺失时 Count 为 0' {
        (Get-RollbackJournalEntryList -Journal @{}).Count | Should -Be 0
    }

    It 'entries 为空数组时 Count 为 0' {
        (Get-RollbackJournalEntryList -Journal @{ entries = @() }).Count | Should -Be 0
    }

    It '两条条目时 Count 为 2，且字段被正确读出（不得读成空串）' {
        $j = @{ entries = @(
            @{ kind = 'registry_key'; state = 'planned' },
            @{ kind = 'path_deleted'; state = 'mutation_succeeded' }
        ) }
        $list = Get-RollbackJournalEntryList -Journal $j
        $list.Count | Should -Be 2
        $list[0]['kind'] | Should -Be 'registry_key'
        $list[1]['state'] | Should -Be 'mutation_succeeded'
    }
}

Describe 'rollback-journal: 原子写两条路径（REQ-005 / AC-071）' {
    BeforeEach {
        $script:Dir = Join-Path $env:TEMP ("wrc-rj-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:Dir) { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '首次写入（目标不存在）成功，且不产生 .prev' {
        $target = Join-Path $script:Dir 'a.json'
        Write-FileAtomic -TargetPath $target -Content '{"g":1}'
        Test-Path $target | Should -BeTrue
        Test-Path "$target.prev" | Should -BeFalse
        (Get-Content $target -Raw).Trim() | Should -Be '{"g":1}'
    }

    It '第二次写入保留上一代副本 .prev，且目标是新内容' {
        $target = Join-Path $script:Dir 'b.json'
        Write-FileAtomic -TargetPath $target -Content '{"g":1}'
        Write-FileAtomic -TargetPath $target -Content '{"g":2}'
        (Get-Content $target -Raw).Trim() | Should -Be '{"g":2}'
        (Get-Content "$target.prev" -Raw).Trim() | Should -Be '{"g":1}'
    }

    It '反复写入时 .prev 始终只有一代（不累积）' {
        $target = Join-Path $script:Dir 'c.json'
        foreach ($g in 1..5) { Write-FileAtomic -TargetPath $target -Content "{`"g`":$g}" }
        (Get-Content $target -Raw).Trim() | Should -Be '{"g":5}'
        (Get-Content "$target.prev" -Raw).Trim() | Should -Be '{"g":4}'
        @(Get-ChildItem $script:Dir -Filter '*.prev').Count | Should -Be 1
    }

    It '不使用 Move-Item -Force（结构性断言：该 cmdlet 先删目标再移动，存在缺失窗口）' {
        # 实测结论（重要）：用「轮询探测目标是否存在」**无法可靠验证**原子性。
        # 证据：即使故意写成 delete-then-move 的非原子版本，同进程轮询 300 次也观测不到缺口
        # （缺口太短）；而跨进程 Start-Job 轮询只会测到调度抖动，产生假失败（实测 65 次误报）。
        # 因此这里改为**结构性断言**：直接证明实现没有调用那个已知不安全的 cmdlet，
        # 且确实使用了两个原子原语。这比不可靠的时序断言更诚实，也更能防止回归。
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$null)
        $cmds = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() })

        $cmds | Should -Not -Contain 'Move-Item' -Because 'Move-Item -Force 在 PS 5.1 下是先删后移，不是原子替换'

        $text = [System.IO.File]::ReadAllText($script:ScriptPath)
        $text | Should -Match '\[System\.IO\.File\]::Replace' -Because '后续写入必须是原子替换'
        $text | Should -Match '\[System\.IO\.File\]::Move' -Because '首次写入必须是原子重命名'
    }

    It '替换返回后目标立刻是新内容（Replace 是同步的，无延迟可见性问题）' {
        $target = Join-Path $script:Dir 'sync.json'
        Write-FileAtomic -TargetPath $target -Content '{"g":1}'
        Write-FileAtomic -TargetPath $target -Content '{"g":2}'
        (Get-Content $target -Raw).Trim() | Should -Be '{"g":2}'
        (Get-Content "$target.prev" -Raw).Trim() | Should -Be '{"g":1}'
    }

    It '临时文件写在目标同目录（同卷），不得落到 %TEMP%' {
        $target = Join-Path $script:Dir 'e.json'
        Write-FileAtomic -TargetPath $target -Content '{"g":1}'
        Write-FileAtomic -TargetPath $target -Content '{"g":2}'
        # 同目录内除目标与 .prev 外不应残留临时文件
        $extra = @(Get-ChildItem $script:Dir -File | Where-Object { $_.Name -notin @('e.json', 'e.json.prev') })
        $extra.Count | Should -Be 0
    }
}

Describe 'rollback-journal: 构造与自证（REQ-027）' {
    BeforeEach {
        $script:Dir = Join-Path $env:TEMP ("wrc-rjv-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:Dir) { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'cleanup_log_* 三字段默认为真正的 null（不是空串），自证才能通过' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $null -eq $j['cleanup_log_path'] | Should -BeTrue
        $null -eq $j['cleanup_log_timestamp'] | Should -BeTrue
        $null -eq $j['cleanup_log_sha256'] | Should -BeTrue
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeTrue
    }

    It 'run_id 默认是合法 guid' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        ([guid]::TryParse([string]$j['run_id'], [ref]([guid]::Empty))) | Should -BeTrue
    }

    It 'backup_dir 默认为 backup-<run_id>（REQ-032，不是时间戳）' {
        $j = ConvertTo-RollbackJournal -BackupDir '' -MachineFingerprint 'FP'
        $j['backup_dir'] | Should -Be ("backup-" + $j['run_id'])
    }

    It '条目 state 初值为 planned（不是 pending）' {
        $e = ConvertTo-RollbackJournalEntry -Id 'e1' -Kind 'registry_key' -Target 'HKLM\X'
        $e['state'] | Should -Be 'planned'
        $e.ContainsKey('status') | Should -BeFalse -Because '字段名是 state，不是 status'
    }

    It 'kind 枚举拒绝非法取值（六种之外）' {
        { ConvertTo-RollbackJournalEntry -Id 'e' -Kind 'file_path' -Target 'C:\X' } |
            Should -Throw -Because 'file_path 不是合法 kind；文件删除应为 path_deleted'
    }

    It '六种 kind 全部被接受' {
        foreach ($k in 'registry_key', 'startup_value', 'path_entry', 'path_deleted', 'service', 'task') {
            { ConvertTo-RollbackJournalEntry -Id 'e' -Kind $k -Target 'T' } | Should -Not -Throw
        }
    }

    It '非 guid 的 run_id 自证失败' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['run_id'] = '2026-10-02T14:31:07'
        $r = Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP'
        $r.Valid | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'guid'
    }

    It 'cleanup_log_* 部分为 null 时自证失败（AC-083）' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['cleanup_log_sha256'] = 'deadbeef'
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It 'fingerprint_source 非法取值自证失败' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP' -FingerprintSource 'bogus'
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It 'fingerprint_source 两种合法取值都通过' {
        foreach ($s in 'machine_guid', 'hostname_fallback') {
            $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP' -FingerprintSource $s
            (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid |
                Should -BeTrue -Because "$s 是合法来源"
        }
    }

    It '机器指纹不一致时自证失败' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'OTHER'
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'MINE').Valid | Should -BeFalse
    }

    It 'backup_dir 不存在时自证失败' {
        $j = ConvertTo-RollbackJournal -BackupDir (Join-Path $script:Dir 'nope') -MachineFingerprint 'FP'
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It '条目 kind 非法时自证失败' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['entries'] = @(@{ kind = 'file_path'; state = 'planned' })
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It '条目 state 非法时自证失败' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['entries'] = @(@{ kind = 'registry_key'; state = 'pending' })
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It 'backup_file 存在且哈希匹配时通过；哈希不匹配时失败' {
        $bf = Join-Path $script:Dir 'reg-x.reg'
        [System.IO.File]::WriteAllText($bf, 'Windows Registry Editor Version 5.00')
        $hash = (Get-FileHash $bf -Algorithm SHA256).Hash

        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['entries'] = @(ConvertTo-RollbackJournalEntry -Id 'e1' -Kind 'registry_key' -Target 'HKLM\Software\X' `
            -State 'mutation_succeeded' -BackupFile 'reg-x.reg' -BackupFileSha256 $hash)
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeTrue

        $j['entries'][0]['backup_file_sha256'] = 'deadbeef'
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It 'backup_file 不存在时自证失败' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['entries'] = @(ConvertTo-RollbackJournalEntry -Id 'e1' -Kind 'registry_key' -Target 'HKLM\Software\X' -BackupFile 'missing.reg')
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It '条目缺 id / item_id / target → 自证失败（评审修复：恢复依赖这些字段）' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['entries'] = @(@{ kind = 'registry_key'; state = 'planned' })   # 裸条目，无 id/item_id/target
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It '条目 item_id 与 kind+target 不一致（被篡改）→ 自证失败（评审修复 recompute-and-compare）' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $e = ConvertTo-RollbackJournalEntry -Id 'e1' -Kind 'registry_key' -Target 'HKLM\Software\X'
        $e['item_id'] = 'registry_key:hklm\software\victim'   # 指向不同对象
        $j['entries'] = @($e)
        $r = Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP'
        $r.Valid | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'item_id'
    }

    It 'journal_version 非数字（外部畸形 JSON）→ 判不支持且不抛异常（评审修复）' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['journal_version'] = 'abc'
        { Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP' } | Should -Not -Throw
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It 'cleanup_log_timestamp 非 null 但不可解析 → 自证失败，不静默忽略（评审修复 AC-083）' {
        $clp = Join-Path $script:Dir 'cl.json'
        [System.IO.File]::WriteAllText($clp, '{"summary":{"failed":1}}')
        $hash = (Get-FileHash $clp -Algorithm SHA256).Hash
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['cleanup_log_path'] = $clp
        $j['cleanup_log_timestamp'] = 'not-a-timestamp'
        $j['cleanup_log_sha256'] = $hash
        $r = Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP'
        $r.Valid | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'timestamp'
    }

    It 'completed_at 非空但非合法时间戳（损坏/篡改）→ 自证失败，不永久静默阻断恢复（评审修复）' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['completed_at'] = 'completed'
        $r = Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP'
        $r.Valid | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'completed_at'
    }

    It 'cleanup_log_* 三个都是空串（非 null）→ 等价于「无清理日志证据」，判合法（评审修复：空白≡缺失）' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['cleanup_log_path'] = ''
        $j['cleanup_log_timestamp'] = ''
        $j['cleanup_log_sha256'] = ''
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeTrue
    }

    It 'cleanup_log_* 部分空串部分真实 → 模式不一致判非法（评审修复：空白按缺失计入）' {
        $clp = Join-Path $script:Dir 'mix.json'
        [System.IO.File]::WriteAllText($clp, '{"summary":{"failed":1}}')
        $hash = (Get-FileHash $clp -Algorithm SHA256).Hash
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['cleanup_log_path'] = $clp
        $j['cleanup_log_timestamp'] = ''          # 空串：现按「缺失」计，于是变成 2 缺 1 在 → 不一致
        $j['cleanup_log_sha256'] = $hash
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It 'backup_file 存在但未记录哈希 → 自证失败（内容未绑定，评审修复）' {
        $bf = Join-Path $script:Dir 'nh.reg'
        [System.IO.File]::WriteAllText($bf, 'x')
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $e = ConvertTo-RollbackJournalEntry -Id 'e1' -Kind 'registry_key' -Target 'HKLM\X' -State 'mutation_succeeded'
        $e['backup_file'] = 'nh.reg'   # 无 backup_file_sha256
        $j['entries'] = @($e)
        (Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP').Valid | Should -BeFalse
    }

    It 'backup_file 用 ..\\ 穿越备份目录 → 自证失败（评审修复：越界路径拒绝）' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $e = ConvertTo-RollbackJournalEntry -Id 'e1' -Kind 'registry_key' -Target 'HKLM\X' -State 'mutation_succeeded'
        $e['backup_file'] = '..\outside.reg'
        $e['backup_file_sha256'] = ('A' * 64)
        $j['entries'] = @($e)
        $r = Test-RollbackJournalSelfValid -Journal $j -MachineFingerprint 'FP'
        $r.Valid | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match '越出|不存在'
    }
}

Describe 'rollback-journal: 落盘与回读（REQ-005 / REQ-032）' {
    BeforeEach {
        $script:Dir = Join-Path $env:TEMP ("wrc-rjw-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:Dir) { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '写入后能回读，run_id 与 entries 保持' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        $j['entries'] = @((ConvertTo-RollbackJournalEntry -Id 'e1' -Kind 'registry_key' -Target 'HKLM\X'))
        Write-RollbackJournal -BackupDir $script:Dir -Journal $j | Out-Null

        $back = Read-RollbackJournal -BackupDir $script:Dir
        $back['run_id'] | Should -Be $j['run_id']
        (Get-RollbackJournalEntryList -Journal $back).Count | Should -Be 1
        (Test-RollbackJournalSelfValid -Journal $back -MachineFingerprint 'FP').Valid | Should -BeTrue
    }

    It '主文件损坏时回退读 .prev 并如实标注' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        Write-RollbackJournal -BackupDir $script:Dir -Journal $j | Out-Null
        $j['completed_at'] = '2026-10-03T11:00:00Z'
        Write-RollbackJournal -BackupDir $script:Dir -Journal $j | Out-Null
        # 把主文件写坏
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'rollback-journal.json'), '{ not json')

        $back = Read-RollbackJournal -BackupDir $script:Dir
        $back | Should -Not -BeNullOrEmpty
        $back['journal_recovered_from_prev'] | Should -BeTrue
    }

    It '主文件与 .prev 都不可用/不存在时返回 null（不抛）' {
        Read-RollbackJournal -BackupDir $script:Dir | Should -BeNullOrEmpty
    }

    It '回退深度固定为 1：不递归找更早版本' {
        $j = ConvertTo-RollbackJournal -BackupDir $script:Dir -MachineFingerprint 'FP'
        Write-RollbackJournal -BackupDir $script:Dir -Journal $j | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'rollback-journal.json'), 'broken')
        [System.IO.File]::WriteAllText((Join-Path $script:Dir 'rollback-journal.prev.json'), 'broken too')
        Read-RollbackJournal -BackupDir $script:Dir | Should -BeNullOrEmpty
    }
}

Describe 'rollback-journal: 注册表 LastWriteTime 辅助（REQ-034）' {
    It '受管 API 确实不暴露 LastWriteTime（证明 P/Invoke 是必需的）' {
        $props = [Microsoft.Win32.RegistryKey].GetProperties() | Select-Object -ExpandProperty Name
        $props | Should -Not -Contain 'LastWriteTime'
    }

    It '能取到真实时间戳，且一次 SetValue 后父键时间戳严格变大' {
        $probe = 'Software\WRC_JournalTest_' + [guid]::NewGuid().ToString('N')
        try {
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($probe)
            $k.SetValue('M', '1'); $k.Close()

            $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($probe)
            $t1 = Get-RegistryKeyLastWriteTime -Key $rk
            $rk.Close()
            $t1 | Should -Not -BeNullOrEmpty
            $t1 | Should -BeOfType [datetime]

            Start-Sleep -Milliseconds 1100
            $k2 = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($probe, $true)
            $k2.SetValue('M2', '2'); $k2.Close()

            $rk2 = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($probe)
            $t2 = Get-RegistryKeyLastWriteTime -Key $rk2
            $rk2.Close()

            $t2 | Should -BeGreaterThan $t1 -Because '迹象 (ii) 依赖变更会推进父键时间戳'
        } finally {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($probe, $false) 2>$null
        }
    }

    It '取不到时返回 null 而不抛（受限机器上不得因此无法回滚）' {
        $disposed = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software')
        $disposed.Close()
        { Get-RegistryKeyLastWriteTime -Key $disposed } | Should -Not -Throw
    }
}

Describe 'rollback-journal: 机器指纹（REQ-027）' {
    It '返回 Value 与 Source，且 Source 是两种合法取值之一' {
        $fp = Get-MachineFingerprint
        $fp.Value | Should -Not -BeNullOrEmpty
        $fp.Source | Should -BeIn @('machine_guid', 'hostname_fallback')
    }

    It '同一进程内两次调用结果稳定' {
        $a = Get-MachineFingerprint
        $b = Get-MachineFingerprint
        $a.Value | Should -Be $b.Value
        $a.Source | Should -Be $b.Source
    }
}

Describe 'rollback-journal: ISO 时间格式（避免跨引擎序列化差异）' {
    It 'Format-IsoUtc 产出秒精度 Z 结尾串' {
        $s = Format-IsoUtc -Value ([datetime]::new(2026, 10, 3, 10, 0, 0, [DateTimeKind]::Utc))
        $s | Should -Be '2026-10-03T10:00:00Z'
    }

    It '产出的串可被 [datetime]::Parse 解析（双引擎安全断言）' {
        $s = Format-IsoUtc -Value (Get-Date)
        $tmp = [datetime]::MinValue
        [datetime]::TryParse($s, [ref]$tmp) | Should -BeTrue
    }
}
