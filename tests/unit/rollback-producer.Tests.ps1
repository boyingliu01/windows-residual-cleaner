# tests/unit/rollback-producer.Tests.ps1
# S3 写入端原语（REQ-001/005/011/015/018/020/026/027/032/033）。
# 断言必须在 PS 5.1 与 pwsh 7 下都成立（pre-commit Gate 5 用 pwsh 7）。

BeforeAll {
    $script:JournalPath  = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-journal.ps1'
    $script:ProducerPath = Join-Path $PSScriptRoot '..\..\references\scripts\rollback-producer.ps1'
    . $script:JournalPath
    . $script:ProducerPath

    $script:ProdRoot = Join-Path $env:TEMP ("wrc-producer-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:ProdRoot -Force | Out-Null
}

AfterAll {
    Remove-Item $script:ProdRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ItemMutationKindList — 与 Phase 2/3 分支逐字一致' {
    It '六种 kind 各自命中且不多记' -TestCases @(
        @{ Item = @{ id='fs_1'; path='C:\App'; type='empty_directory' };               Expected = @('path_deleted') }
        @{ Item = @{ id='p_1';  path='C:\Ghost'; type='path_entry' };                   Expected = @('path_entry') }
        @{ Item = @{ id='svc_1'; name='S'; binary_path='C:\x.exe' };                   Expected = @('service') }
        @{ Item = @{ id='task_1'; name='T'; expanded_path='C:\gone\t.exe' };           Expected = @('task') }
        @{ Item = @{ id='str_1'; key='HKCU\Run'; value_name='A'; type='startup' };     Expected = @('startup_value') }
        @{ Item = @{ id='reg_1'; key='HKCU\Software\Foo'; type='registry_residual' };  Expected = @('registry_key') }
    ) {
        param($Item, $Expected)
        $kinds = @(Get-ItemMutationKindList -Item $Item)
        $kinds | Should -Be $Expected
    }

    It 'path_entry 绝不额外记成 path_deleted（否则会把 PATH 段当目录删掉）' {
        $k = @(Get-ItemMutationKindList -Item @{ id='p_1'; path='C:\Ghost'; type='path_entry' })
        $k | Should -Not -Contain 'path_deleted'
    }

    It '同一条 item 既删目录又删注册表键时返回两类，顺序为 Phase 2 在前' {
        $k = @(Get-ItemMutationKindList -Item @{ id='x_1'; path='C:\App'; key='HKCU\Software\App'; name='AppSvc'; binary_path='C:\App\a.exe' })
        $k | Should -Be @('path_deleted', 'service', 'registry_key')
    }

    It '无破坏性变更的 item 返回空数组（Count=0，不是 $null）' {
        $k = @(Get-ItemMutationKindList -Item @{ id='n_1'; reason='只有元数据' })
        $k.Count | Should -Be 0
    }

    It '回归：调用方 @() 包裹后元素必须是字符串而不是嵌套数组' {
        # `return , $kinds` 会让这里变成「Count=1、唯一元素为 Object[]」，
        # 于是 -contains 恒为 $false、所有破坏性分支静默不执行（AGENTS.md 陷阱 6 同族）。
        $k = @(Get-ItemMutationKindList -Item @{ id='fs_1'; path='C:\App'; type='empty_directory' })
        $k.Count | Should -Be 1
        ($k[0] -is [string]) | Should -BeTrue
        ($k -contains 'path_deleted') | Should -BeTrue
    }
}

Describe 'ConvertTo-RollbackJournalTarget' {
    It 'startup_value 用 "<父键>|<value>" 复合形式（恢复端按最后一个 | 拆分）' {
        ConvertTo-RollbackJournalTarget -Kind 'startup_value' -Item @{ key='HKCU\Run'; value_name='Ghost' } |
            Should -Be 'HKCU\Run|Ghost'
    }

    It '其余 kind 直接取该对象的标识字段' -TestCases @(
        @{ Kind = 'registry_key'; Item = @{ key='HKCU\Software\Foo' }; Expected = 'HKCU\Software\Foo' }
        @{ Kind = 'path_entry';   Item = @{ path='C:\Ghost' };         Expected = 'C:\Ghost' }
        @{ Kind = 'path_deleted'; Item = @{ path='C:\App' };           Expected = 'C:\App' }
        @{ Kind = 'service';      Item = @{ name='SvcA' };             Expected = 'SvcA' }
        @{ Kind = 'task';         Item = @{ name='TaskA' };            Expected = 'TaskA' }
    ) {
        param($Kind, $Item, $Expected)
        ConvertTo-RollbackJournalTarget -Kind $Kind -Item $Item | Should -Be $Expected
    }
}

Describe 'New-RollbackBackupDirectory（REQ-032）' {
    It '目录名即 backup-<run_id>，run_id 是 guid' {
        $r = New-RollbackBackupDirectory -ProjectRoot $script:ProdRoot
        $r.Ok | Should -BeTrue $r.Reason
        $r.RunId | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        (Split-Path $r.Path -Leaf) | Should -Be ("backup-{0}" -f $r.RunId)
        Test-Path -LiteralPath $r.Path | Should -BeTrue
    }

    It '显式 RunId 时不另起 guid（REQ-033 的清理日志↔日志绑定依赖同一个 id）' {
        $gid = [guid]::NewGuid().ToString()
        $r = New-RollbackBackupDirectory -ProjectRoot $script:ProdRoot -RunId $gid
        $r.RunId | Should -Be $gid
    }

    It '同一路径重复创建不报错（幂等）' {
        $gid = [guid]::NewGuid().ToString()
        $a = New-RollbackBackupDirectory -ProjectRoot $script:ProdRoot -RunId $gid
        $b = New-RollbackBackupDirectory -ProjectRoot $script:ProdRoot -RunId $gid
        $a.Ok | Should -BeTrue
        $b.Ok | Should -BeTrue
        $b.Path | Should -Be $a.Path
    }

    It '建不出来时返回 Ok=$false + 原因，绝不抛给调用方（调用方据此 fail-closed）' {
        # 用 Mock 造失败：ProjectRoot 指向文件时 New-Item -Force 实测**不**报错，
        # 而写系统目录既依赖权限又可能真的建出目录，两种都不密闭。
        $gid = [guid]::NewGuid().ToString()
        Mock New-Item { throw 'Access to the path is denied.' } -ParameterFilter { $ItemType -eq 'Directory' }
        $r = New-RollbackBackupDirectory -ProjectRoot $script:ProdRoot -RunId $gid
        $r.Ok | Should -BeFalse
        $r.Reason | Should -BeLike 'backup_dir_failed*Access to the path is denied*'
    }

    It '目录已存在时不再调用 New-Item（幂等且不清空已有备份）' {
        $gid = [guid]::NewGuid().ToString()
        $pre = New-RollbackBackupDirectory -ProjectRoot $script:ProdRoot -RunId $gid
        $marker = Join-Path $pre.Path 'keepme.txt'
        [System.IO.File]::WriteAllText($marker, 'x')
        $again = New-RollbackBackupDirectory -ProjectRoot $script:ProdRoot -RunId $gid
        $again.Ok | Should -BeTrue
        Test-Path -LiteralPath $marker | Should -BeTrue
    }
}

Describe 'Get-JournalBackupFileRelative（REQ-027 / AC-051）' {
    BeforeAll {
        $script:BDir = Join-Path $script:ProdRoot 'backupdir'
        New-Item -ItemType Directory -Path $script:BDir -Force | Out-Null
    }

    It '绝对路径规约为相对备份目录的路径' {
        $f = Join-Path $script:BDir 'HKCU_Foo.reg'
        [System.IO.File]::WriteAllText($f, 'x')
        Get-JournalBackupFileRelative -BackupDir $script:BDir -Path $f | Should -Be 'HKCU_Foo.reg'
    }

    It '子目录里的备份保留相对层级' {
        $sub = Join-Path $script:BDir 'nested'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $f = Join-Path $sub 'a.reg'
        [System.IO.File]::WriteAllText($f, 'x')
        Get-JournalBackupFileRelative -BackupDir $script:BDir -Path $f | Should -BeLike 'nested*a.reg'
    }

    It '根目录大小写不同也认（Windows 路径大小写不敏感）' {
        $upper = $script:BDir.ToUpperInvariant()
        $f = Join-Path $script:BDir 'case.reg'
        [System.IO.File]::WriteAllText($f, 'x')
        Get-JournalBackupFileRelative -BackupDir $upper -Path $f | Should -Be 'case.reg'
    }

    It '越出备份目录（其它盘/其它根）返回 $null，调用方据此跳过删除' {
        (Get-JournalBackupFileRelative -BackupDir $script:BDir -Path 'C:\Windows\reg.txt') | Should -BeNullOrEmpty
    }

    It '..\ 穿越返回 $null（不得写出一个自证必拒的路径）' {
        (Get-JournalBackupFileRelative -BackupDir $script:BDir -Path (Join-Path $script:BDir '..\..\evil.reg')) | Should -BeNullOrEmpty
    }

    It '空/blank 路径返回 $null（区分「无备份」与「备份在根」）' {
        (Get-JournalBackupFileRelative -BackupDir $script:BDir -Path '') | Should -BeNullOrEmpty
        (Get-JournalBackupFileRelative -BackupDir $script:BDir -Path '   ') | Should -BeNullOrEmpty
    }
}

Describe 'Add-RollbackJournalEntry / Update-RollbackJournalEntry（REQ-018 状态机）' {
    BeforeAll {
        function script:New-J { ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) -BackupDir 'backup-x' -MachineFingerprint 'fp' }
        function script:New-E {
            param([string]$Target = 'HKCU\Software\Foo', [string]$State = 'planned')
            ConvertTo-RollbackJournalEntry -Id 'reg_1' -Kind 'registry_key' -Target $Target -PreExisting $true -State $State
        }
    }

    It '同 item_id 重复添加是**替换**而不是追加（否则同一目标有两个矛盾状态）' {
        $j = New-J
        $null = Add-RollbackJournalEntry -Journal $j -Entry (New-E -State 'planned')
        $null = Add-RollbackJournalEntry -Journal $j -Entry (New-E -State 'mutation_succeeded')
        $e = Get-RollbackJournalEntryList -Journal $j
        $e.Count | Should -Be 1
        $e[0]['state'] | Should -Be 'mutation_succeeded'
    }

    It '大小写不同的同一注册表键合并为一条（不同键各自一条）' {
        $j = New-J
        $null = Add-RollbackJournalEntry -Journal $j -Entry (New-E -Target 'HKCU\Software\Foo')
        $null = Add-RollbackJournalEntry -Journal $j -Entry (New-E -Target 'HKCU\Software\Bar')
        $null = Add-RollbackJournalEntry -Journal $j -Entry (New-E -Target 'HKCU\Software\FOO' -State 'mutation_succeeded')
        $e = Get-RollbackJournalEntryList -Journal $j
        $e.Count | Should -Be 2
        $foo = @($e | Where-Object { $_['item_id'] -eq 'registry_key:hkcu\software\foo' })
        $foo.Count | Should -Be 1
        $foo[0]['state'] | Should -Be 'mutation_succeeded' -Because '注册表路径大小写不敏感，同一键的第二次登记必须覆盖而不是追加'
    }

    It '条目缺 item_id 时按 kind:target 补算（REQ-027 唯一权威规则）' {
        $j = New-J
        $entry = New-E
        $entry.Remove('item_id')
        $null = Add-RollbackJournalEntry -Journal $j -Entry $entry
        $e = Get-RollbackJournalEntryList -Journal $j
        $e[0]['item_id'] | Should -Be 'registry_key:hkcu\software\foo' -Because '补算出的 id 必须写回条目，否则自证（REQ-027 重算比对）会把整份日志判废'
    }

    It 'Update 未知 item_id 返回 $false（调用方必须能区分推进失败与成功）' {
        $j = New-J
        $null = Add-RollbackJournalEntry -Journal $j -Entry (New-E)
        Update-RollbackJournalEntry -Journal $j -ItemId 'registry_key:hklm\software\nope' -Fields @{ state = 'mutation_failed' } |
            Should -BeFalse
    }

    It 'Update 只改指定字段，其余字段原样保留' {
        $j = New-J
        $null = Add-RollbackJournalEntry -Journal $j -Entry (New-E)
        $ok = Update-RollbackJournalEntry -Journal $j -ItemId 'registry_key:hkcu\software\foo' `
            -Fields @{ state = 'backup_created'; backup_file = 'foo.reg' }
        $ok | Should -BeTrue
        $e = (Get-RollbackJournalEntryList -Journal $j)[0]
        $e['state'] | Should -Be 'backup_created'
        $e['backup_file'] | Should -Be 'foo.reg'
        $e['pre_existing'] | Should -BeTrue
        $e['target'] | Should -Be 'HKCU\Software\Foo'
    }
}

Describe 'Write-RollbackJournalSafely（REQ-005 fail-closed 判据）' {
    It '落盘成功返回 Ok + 路径，且能被 Read-RollbackJournal 原样读回' {
        $dir = Join-Path $script:ProdRoot ('flush-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $j = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) -BackupDir $dir -MachineFingerprint 'fp'
        $r = Write-RollbackJournalSafely -BackupDir $dir -Journal $j
        $r.Ok | Should -BeTrue $r.Reason
        $back = Read-RollbackJournal -BackupDir $dir
        $back | Should -Not -BeNullOrEmpty
        $back['run_id'] | Should -Be $j['run_id']
    }

    It '落盘失败规约成 Ok=$false + journal_flush_failed，绝不把异常抛给调用方' {
        # 「目录不存在」不是失败源：Write-FileAtomic 会自建目录。
        # 用「父级是文件」的路径强制底层 WriteAllText/Move 抛异常。
        $asFile = Join-Path $script:ProdRoot ('blocker-' + [guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllText($asFile, 'x')
        $unusable = Join-Path $asFile 'sub'
        $j = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) -BackupDir $unusable -MachineFingerprint 'fp'
        # 直接调用：本函数的契约就是「不抛、返回结构化失败」，真的抛了用例照样红。
        # （不要写成 `{ $r = ... } | Should -Not -Throw` 再断言 $r —— scriptblock 在子作用域
        #  里赋值，外层 $r 仍是 $null，于是两条断言同时「通过」，用例是假的。）
        $r = Write-RollbackJournalSafely -BackupDir $unusable -Journal $j
        $r | Should -Not -BeNullOrEmpty
        $r.Ok | Should -BeFalse
        $r.Reason | Should -BeLike 'journal_flush_failed*'
        Remove-Item -LiteralPath $asFile -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-CleanupLogJournalBinding / Set-RollbackJournalCleanupBinding（REQ-033 / AC-083）' {
    It '路径为空或文件不存在 → 三个字段全 $null（宁可无绑定，也不写半套）' {
        foreach ($bad in @('', '   ', (Join-Path $script:ProdRoot 'missing.json'))) {
            $b = Get-CleanupLogJournalBinding -Path $bad
            $b['cleanup_log_path'] | Should -BeNullOrEmpty
            $b['cleanup_log_timestamp'] | Should -BeNullOrEmpty
            $b['cleanup_log_sha256'] | Should -BeNullOrEmpty
        }
    }

    It '真实文件 → 三个字段同非 null，且时间戳可被 [datetime]::Parse' {
        $f = Join-Path $script:ProdRoot 'cleanup-log.json'
        [System.IO.File]::WriteAllText($f, '{"entries":[]}')
        $b = Get-CleanupLogJournalBinding -Path $f
        $b['cleanup_log_path'] | Should -Be $f
        $b['cleanup_log_sha256'] | Should -Match '^[0-9a-f]{64}$'
        # 双引擎口径：断言可解析，不断言 ConvertFrom-Json 之后的类型/格式
        { [datetime]::Parse($b['cleanup_log_timestamp']) } | Should -Not -Throw
    }

    It 'Set-* 把三元组写进内存日志并返回同一组值' {
        $f = Join-Path $script:ProdRoot 'bound-log.json'
        [System.IO.File]::WriteAllText($f, '{"x":1}')
        $j = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) -BackupDir 'backup-x' -MachineFingerprint 'fp'
        $b = Set-RollbackJournalCleanupBinding -Journal $j -CleanupLogPath $f
        $j['cleanup_log_path'] | Should -Be $b['cleanup_log_path']
        $j['cleanup_log_sha256'] | Should -Be $b['cleanup_log_sha256']
        $j['cleanup_log_timestamp'] | Should -Be $b['cleanup_log_timestamp']
    }

    It '绑定不存在的文件时把已有绑定清成 $null（不得留旧值——自证会判模式错误）' {
        $f = Join-Path $script:ProdRoot 'stale-log.json'
        [System.IO.File]::WriteAllText($f, '{"x":2}')
        $j = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) -BackupDir 'backup-x' -MachineFingerprint 'fp'
        $null = Set-RollbackJournalCleanupBinding -Journal $j -CleanupLogPath $f
        $null = Set-RollbackJournalCleanupBinding -Journal $j -CleanupLogPath ''
        $j['cleanup_log_path'] | Should -BeNullOrEmpty
        $j['cleanup_log_sha256'] | Should -BeNullOrEmpty
    }
}

Describe 'Test-JournalHasMutation（REQ-020「本轮确实改过东西」）' {
    BeforeAll {
        function script:JWith([string[]]$States) {
            $j = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) -BackupDir 'backup-x' -MachineFingerprint 'fp'
            $i = 0
            $entries = @()
            foreach ($s in $States) {
                $i++
                $entries += , (ConvertTo-RollbackJournalEntry -Id "reg_$i" -Kind 'registry_key' -Target "HKCU\Software\T$i" -State $s)
            }
            $j['entries'] = $entries
            return $j
        }
    }

    It '空日志 / 只有 planned / 只有 mutation_failed → $false' {
        Test-JournalHasMutation -Journal (JWith @()) | Should -BeFalse
        Test-JournalHasMutation -Journal (JWith @('planned')) | Should -BeFalse
        Test-JournalHasMutation -Journal (JWith @('planned', 'mutation_failed')) | Should -BeFalse
    }

    It '存在 mutation_succeeded → $true' {
        Test-JournalHasMutation -Journal (JWith @('planned', 'mutation_succeeded')) | Should -BeTrue
    }
}

Describe 'Get-CleanupExitCode（REQ-026 矩阵唯一实现处）' {
    It '没有失败 → 0' {
        Get-CleanupExitCode -FailedCount 0 | Should -Be 0
    }

    It '上一轮日志未消费（14）优先级最高，压过本轮一切' {
        Get-CleanupExitCode -FailedCount 3 -PriorJournalUnconsumable $true -PersistenceError $true | Should -Be 14
    }

    It '本轮持久化失败（15）压过 13/12/11/10 —— 改了但记录不可靠是终态' {
        Get-CleanupExitCode -FailedCount 2 -PersistenceError $true -NoAutoRollback $true | Should -Be 15
        Get-CleanupExitCode -FailedCount 2 -PersistenceError $true -JournalMissing $true | Should -Be 15
        Get-CleanupExitCode -FailedCount 2 -PersistenceError $true -HadMutations $true -RestoreFailedCount 1 | Should -Be 15
    }

    It '部分失败 + -NoAutoRollback → 13' {
        Get-CleanupExitCode -FailedCount 1 -NoAutoRollback $true | Should -Be 13
    }

    It '部分失败但日志缺失/不可读 → 12' {
        Get-CleanupExitCode -FailedCount 1 -JournalMissing $true | Should -Be 12
    }

    It '部分失败且本轮没有任何已变更记录 → 1（不得把 0 条恢复说成回滚成功）' {
        Get-CleanupExitCode -FailedCount 1 -HadMutations $false | Should -Be 1
    }

    It '部分失败 + 回滚有未修复项 → 11；完全成功 → 10' {
        Get-CleanupExitCode -FailedCount 1 -HadMutations $true -RestoreFailedCount 2 | Should -Be 11
        Get-CleanupExitCode -FailedCount 1 -HadMutations $true -RestoreFailedCount 0 | Should -Be 10
    }
}

Describe 'Get-RollbackFailureKindFromCleanupAction（REQ-002 / AC-016）' {
    It 'deleted → 非重命名' {
        $r = Get-RollbackFailureKindFromCleanupAction -Outcome 'deleted'
        $r.Renamed | Should -BeFalse
        $r.NewName | Should -Be ''
    }

    It 'renamed:<新名> → 拆出新名（Tier-4 改名不得谎报为删除成功）' {
        $r = Get-RollbackFailureKindFromCleanupAction -Outcome 'renamed:App~.deleted'
        $r.Renamed | Should -BeTrue
        $r.NewName | Should -Be 'App~.deleted'
    }

    It '未知/空串一律按「未重命名」处理，且绝不抛' {
        foreach ($o in @('', 'failed', 'dry_run', 'absent', 'renamed:')) {
            { $null = Get-RollbackFailureKindFromCleanupAction -Outcome $o } | Should -Not -Throw
        }
        (Get-RollbackFailureKindFromCleanupAction -Outcome 'renamed:').NewName | Should -Be ''
    }
}
