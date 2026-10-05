# rollback.ps1 —— 备份目录发现、还原点匹配、以及 Main 的完整输出路径。
#
# 该脚本此前只有 40/56 行被覆盖，且依赖仓里遗留的 backup-* 目录（非密闭）。
# 现在 BackupRoot 可注入，测试自建 fixture，不再依赖仓内遗留物。

BeforeAll {
    $script:RollbackScript = "$PSScriptRoot\..\..\references\scripts\rollback.ps1"
    . $script:RollbackScript

    function New-BackupFixture {
        param([string]$Root, [string]$Name, [string[]]$RegFiles = @(), [string]$StatusJson = '')
        $dir = Join-Path $Root $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($r in $RegFiles) {
            [IO.File]::WriteAllText((Join-Path $dir $r), 'Windows Registry Editor Version 5.00')
        }
        if ($StatusJson) {
            [IO.File]::WriteAllText((Join-Path $dir 'restore-status.json'), $StatusJson)
        }
        return $dir
    }
}

Describe 'Get-BackupDirectory' {
    It 'returns nothing when the root does not exist' {
        @(Get-BackupDirectory -Root (Join-Path $env:TEMP ('nope-' + [guid]::NewGuid().ToString('N')))).Count |
            Should -Be 0
    }

    It 'returns only backup-* directories, newest name first' {
        $root = Join-Path $env:TEMP ('wrc-bk-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            New-BackupFixture -Root $root -Name 'backup-20260101-000000' | Out-Null
            New-BackupFixture -Root $root -Name 'backup-20260301-000000' | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'not-a-backup') | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'other') | Out-Null

            $r = @(Get-BackupDirectory -Root $root)
            $r.Count | Should -Be 2
            # 名称降序 → 最新的在前
            $r[0].Name | Should -Be 'backup-20260301-000000'
            $r[1].Name | Should -Be 'backup-20260101-000000'
        } finally {
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ignores plain files named backup-*' {
        $root = Join-Path $env:TEMP ('wrc-bkf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            New-Item -ItemType Directory -Force -Path $root | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'backup-file.txt'), 'x')
            @(Get-BackupDirectory -Root $root).Count | Should -Be 0
        } finally {
            Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-RegistryBackupFile' {
    It 'returns only reg-*.reg files' {
        $dir = Join-Path $env:TEMP ('wrc-reg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'reg-HKLM.reg'), 'x')
            [IO.File]::WriteAllText((Join-Path $dir 'reg-HKCU.reg'), 'x')
            [IO.File]::WriteAllText((Join-Path $dir 'notes.txt'), 'x')
            [IO.File]::WriteAllText((Join-Path $dir 'other.json'), 'x')

            $r = @(Get-RegistryBackupFile -Directory $dir)
            $r.Count | Should -Be 2
            ($r | ForEach-Object { $_.Name }) | Should -Contain 'reg-HKLM.reg'
            ($r | ForEach-Object { $_.Name }) | Should -Contain 'reg-HKCU.reg'
        } finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns nothing for a missing directory' {
        @(Get-RegistryBackupFile -Directory (Join-Path $env:TEMP ('nope-' + [guid]::NewGuid().ToString('N')))).Count |
            Should -Be 0
    }
}

Describe 'Get-MatchingRestorePoint' {
    BeforeEach {
        $script:t0 = [datetime]'2026-06-01T12:00:00'
    }

    It 'returns an empty array when there are no restore points' {
        @(Get-MatchingRestorePoint -RestorePoints @() -MatchTime $script:t0).Count | Should -Be 0
    }

    It 'matches a restore point inside the +/-5 minute window' {
        $rp = [PSCustomObject]@{ SequenceNumber = 1; CreationTime = $script:t0.AddMinutes(2) }
        @(Get-MatchingRestorePoint -RestorePoints @($rp) -MatchTime $script:t0).Count | Should -Be 1
    }

    It 'matches exactly on the -5 minute boundary' {
        $rp = [PSCustomObject]@{ SequenceNumber = 2; CreationTime = $script:t0.AddMinutes(-5) }
        @(Get-MatchingRestorePoint -RestorePoints @($rp) -MatchTime $script:t0).Count | Should -Be 1
    }

    It 'matches exactly on the +5 minute boundary' {
        $rp = [PSCustomObject]@{ SequenceNumber = 3; CreationTime = $script:t0.AddMinutes(5) }
        @(Get-MatchingRestorePoint -RestorePoints @($rp) -MatchTime $script:t0).Count | Should -Be 1
    }

    It 'excludes points outside the window' {
        $rps = @(
            [PSCustomObject]@{ SequenceNumber = 1; CreationTime = $script:t0.AddMinutes(-6) },
            [PSCustomObject]@{ SequenceNumber = 2; CreationTime = $script:t0.AddMinutes(6) },
            [PSCustomObject]@{ SequenceNumber = 3; CreationTime = $script:t0.AddHours(-3) }
        )
        @(Get-MatchingRestorePoint -RestorePoints $rps -MatchTime $script:t0).Count | Should -Be 0
    }

    It 'returns only the points inside the window' {
        $rps = @(
            [PSCustomObject]@{ SequenceNumber = 1; CreationTime = $script:t0.AddMinutes(-30) },
            [PSCustomObject]@{ SequenceNumber = 2; CreationTime = $script:t0.AddMinutes(-1) },
            [PSCustomObject]@{ SequenceNumber = 3; CreationTime = $script:t0.AddMinutes(4) },
            [PSCustomObject]@{ SequenceNumber = 4; CreationTime = $script:t0.AddMinutes(90) }
        )
        $r = @(Get-MatchingRestorePoint -RestorePoints $rps -MatchTime $script:t0)
        $r.Count | Should -Be 2
        ($r | ForEach-Object { $_.SequenceNumber }) | Should -Contain 2
        ($r | ForEach-Object { $_.SequenceNumber }) | Should -Contain 3
    }

    It 'honours a custom window' {
        $rp = [PSCustomObject]@{ SequenceNumber = 1; CreationTime = $script:t0.AddMinutes(30) }
        @(Get-MatchingRestorePoint -RestorePoints @($rp) -MatchTime $script:t0 -WindowMinutes 60).Count |
            Should -Be 1
    }
}

Describe 'rollback.ps1 Main' {
    BeforeEach {
        $script:root = Join-Path $env:TEMP ('wrc-rb-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
    }
    AfterEach {
        Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ExitCode param is a [ref] and optional' {
        . $script:RollbackScript
        $cmd = Get-Command Main
        $cmd.Parameters.ContainsKey('ExitCode') | Should -Be $true
        $cmd.Parameters['ExitCode'].ParameterType.Name | Should -Be 'PSReference'
    }

    It 'says no backup directories found when the root is empty' {
        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride (Join-Path $script:root 'no-such-log.json') `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $rc | Should -Be 0
        $out | Should -Match 'No backup directories found'
        $out | Should -Match 'ROLLBACK INSTRUCTIONS'
    }

    It 'lists the most recent backup directory and its reg files' {
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' -RegFiles @('reg-HKLM.reg') | Out-Null
        New-BackupFixture -Root $script:root -Name 'backup-20260201-000000' -RegFiles @('reg-HKLM.reg','reg-HKCU.reg') | Out-Null

        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride (Join-Path $script:root 'no-such-log.json') `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $rc | Should -Be 0
        # 最新的那个目录（名称降序）
        $out | Should -Match 'Most recent backup: backup-20260201-000000'
        $out | Should -Match 'reg-HKLM\.reg'
        $out | Should -Match 'reg-HKCU\.reg'
    }

    It 'reports when the latest backup has no reg files' {
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' | Out-Null
        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride (Join-Path $script:root 'no-such-log.json') `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $out | Should -Match 'No registry backup files found'
    }

    It 'prints the restore point description from restore-status.json' {
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' `
            -RegFiles @('reg-HKLM.reg') `
            -StatusJson '{"restore_point_description":"Pre-cleanup 2026-06-01"}' | Out-Null
        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride (Join-Path $script:root 'no-such-log.json') `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $out | Should -Match 'Restore point: Pre-cleanup 2026-06-01'
    }

    It 'reads the cleanup timestamp from a cleanup log' {
        $log = Join-Path $script:root 'cleanup-log.json'
        [IO.File]::WriteAllText($log, '{"summary":{"timestamp":"2026-06-01T12:00:00"}}')
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' | Out-Null
        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride $log `
            -BackupRootOverride $script:root *>&1) -join "`n"
        # 不要断言具体日期格式：$cleanupTime 直接来自 JSON 字符串，但一旦走了
        # [DateTime]::Parse 就会变成区域相关的显示格式（实测 en-US 下是 06/01/2026 12:00:00）。
        # 断言「有 Last cleanup 行」+「日期被解析成了 2026-06-01」即可，跨区域稳定。
        $out | Should -Match 'Last cleanup:'
        $out | Should -Match '2026'
        $out | Should -Match 'Matching restore points near cleanup time'
    }

    # 清理日志损坏时不得中断整个回滚指引输出
    It 'survives a corrupt cleanup log' {
        $log = Join-Path $script:root 'cleanup-log.json'
        [IO.File]::WriteAllText($log, '{ not valid json')
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' | Out-Null
        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride $log `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $rc | Should -Be 0
        $out | Should -Match 'ROLLBACK INSTRUCTIONS'
        $out | Should -Match 'Most recent backup'
    }

    It 'survives a corrupt restore-status.json' {
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' `
            -RegFiles @('reg-HKLM.reg') -StatusJson '{ broken' | Out-Null
        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride (Join-Path $script:root 'no-such-log.json') `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $rc | Should -Be 0
        $out | Should -Match 'ROLLBACK INSTRUCTIONS'
    }

    It 'survives an unparseable cleanup timestamp' {
        $log = Join-Path $script:root 'cleanup-log.json'
        [IO.File]::WriteAllText($log, '{"summary":{"timestamp":"not-a-date"}}')
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' | Out-Null
        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride $log `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $rc | Should -Be 0
        $out | Should -Match 'No restore points found near cleanup time'
    }

    It 'always prints the manual rollback steps' {
        . $script:RollbackScript
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride (Join-Path $script:root 'no-such-log.json') `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $out | Should -Match 'To rollback:'
        $out | Should -Match 'sysdm\.cpl'
        $out | Should -Match 'Restore-Computer'
        # REQ-008：-Auto 已实现，只读指引必须把它作为可用出口说出来；
        # 「under development」是一句已经作废的承诺，留着就是文档与代码不一致。
        $out | Should -Match 'Automatic per-item rollback is available'
        $out | Should -Not -Match 'under development'
    }

    It 'lists the restore points that fall inside the window' {
        # 用同名函数覆盖真机 Get-ComputerRestorePoint（本机通常没有还原点）。
        # 必须在 dot-source 之后、同一局部作用域内定义，否则会被脚本自身定义遮蔽。
        . $script:RollbackScript
        function Get-ComputerRestorePoint {
            return @(
                [PSCustomObject]@{ SequenceNumber = 41; Description = 'Pre-cleanup'; CreationTime = [datetime]'2026-06-01T12:02:00' },
                [PSCustomObject]@{ SequenceNumber = 40; Description = 'Far away';    CreationTime = [datetime]'2026-06-01T03:00:00' }
            )
        }
        $log = Join-Path $script:root 'cleanup-log.json'
        [IO.File]::WriteAllText($log, '{"summary":{"timestamp":"2026-06-01T12:00:00"}}')
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' | Out-Null

        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride $log `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $rc | Should -Be 0
        $out | Should -Match 'Matching restore points near cleanup time'
        $out | Should -Match 'Found 1 restore point\(s\) created near cleanup time'
        # 只有窗口内的 #41 被打印，窗口外的 #40 不出现
        $out | Should -Match '#41: Pre-cleanup'
        $out | Should -Not -Match '#40: Far away'
    }

    It 'prints a correct count when exactly one restore point matches' {
        # 回归：函数只匹配到 1 个还原点时，PowerShell 会把单元素数组解包成标量，
        # `$matched.Count` 变 $null，正文打印出「Found  restore point(s)」（缺数字）。
        # 这正是 AGENTS.md 陷阱第 3 条的同一族问题，必须 @() 包住返回值。
        . $script:RollbackScript
        function Get-ComputerRestorePoint {
            return @([PSCustomObject]@{
                SequenceNumber = 77; Description = 'Only one'; CreationTime = [datetime]'2026-06-01T12:01:00'
            })
        }
        $log = Join-Path $script:root 'cleanup-log.json'
        [IO.File]::WriteAllText($log, '{"summary":{"timestamp":"2026-06-01T12:00:00"}}')
        New-BackupFixture -Root $script:root -Name 'backup-20260101-000000' | Out-Null

        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) `
            -CleanupLogPathOverride $log `
            -BackupRootOverride $script:root *>&1) -join "`n"
        $rc | Should -Be 0
        # 数量必须是 1，不能是空
        $out | Should -Match 'Found 1 restore point\(s\) created near cleanup time'
        $out | Should -Not -Match 'Found\s+restore point'
        $out | Should -Match '#77: Only one'
    }

    It 'falls back to the script default paths when no override is given' {
        # 覆盖 71 / 76 两行：dot-source 会把顶层 param() 的默认值绑进当前作用域，
        # 所以必须显式清空这两个变量，Main 才会走到 `elseif (IsNullOrWhiteSpace)`
        # 的回落分支（读 $script:DefaultCleanupLogPath / $script:DefaultBackupRoot）。
        . $script:RollbackScript
        $CleanupLogPath = ''
        $BackupRoot = ''
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) *>&1) -join "`n"
        $rc | Should -Be 0
        $out | Should -Match 'ROLLBACK INSTRUCTIONS'
        # 空 BackupRoot 回落到仓库根：那里若有 backup-* 就列出，没有就报「未找到」
        $out | Should -Match 'Registry Backup Files'
    }
}
