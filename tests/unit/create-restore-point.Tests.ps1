# create-restore-point.ps1 —— 系统还原检测 + 注册表备份的完整分支覆盖。
#
# 这些分支此前完全未覆盖：它们都需要管理员权限或真实的还原点状态。
# ADR-001 之后可在进程内调用 Main，于是用同一作用域的替身驱动各条分支
# （替身必须在 dot-source **之后**定义，否则会被脚本自身定义遮蔽）。
#
# 注意：Main 现在有 -SkipRestorePoint 与 -BackupRootOverride，可在不触碰真机
# 还原点的前提下测试注册表备份与状态 JSON 输出。

BeforeAll {
    $script:RestoreScript = "$PSScriptRoot\..\..\references\scripts\create-restore-point.ps1"
}

Describe 'create-restore-point.ps1 registry backup branch' {
    BeforeEach {
        $script:root = Join-Path $env:TEMP ('wrc-crp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
    }
    AfterEach {
        Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes a valid restore-status.json describing the backup' {
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        # 跳过真实还原点创建，只验证注册表备份 + 状态落盘
        $rc = 0
        Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root -SkipRestorePoint *>&1 | Out-Null
        $rc | Should -Be 0

        $status = Join-Path $script:root 'backup-*'
        $dirs = @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory)
        $dirs.Count | Should -Be 1

        $statusFile = Join-Path $dirs[0].FullName 'restore-status.json'
        Test-Path $statusFile | Should -Be $true
        $doc = Get-Content $statusFile -Raw | ConvertFrom-Json
        $doc.backup_dir | Should -Be $dirs[0].FullName
        # 不要断言精确到秒的格式：PS 5.1 的 ConvertFrom-Json 把 timestamp 保持为字符串，
        # 而 PS 7 会把它解析成 [datetime]，再 -join 时带上小数秒（实测
        # "2026-10-02T21:39:42.0000000"）。pre-commit 门禁用的是 pwsh 7，
        # 所以这里必须只断言「是一个 parseable 的日期时间」。
        { [datetime]::Parse([string]$doc.timestamp) } | Should -Not -Throw
        ([datetime]::Parse([string]$doc.timestamp)).Year | Should -BeGreaterThan 2000
        # 原始 JSON 文本里必须是 ISO-8601 形态（秒级）
        (Get-Content $statusFile -Raw) | Should -Match '"timestamp"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        # restore_point_enabled 必为布尔
        $doc.restore_point_enabled | Should -BeOfType [bool]
    }

    It 'creates the backup directory when BackupRoot does not exist yet' {
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        $fresh = Join-Path $script:root 'not-yet-created'
        $rc = 0
        Main -ExitCode ([ref]$rc) -BackupRootOverride $fresh -SkipRestorePoint *>&1 | Out-Null
        $rc | Should -Be 0
        Test-Path $fresh | Should -Be $true
    }

    It 'records at least one registry export entry' {
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        $rc = 0
        Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root -SkipRestorePoint *>&1 | Out-Null

        $dir = @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory)[0]
        $statusFile = Join-Path $dir.FullName 'restore-status.json'
        $doc = Get-Content $statusFile -Raw | ConvertFrom-Json
        # HKCU 的 Uninstall 键在任何会话下都可导出，因此至少 1 条
        @($doc.backup_files).Count | Should -BeGreaterThan 0
        # 每条必须有 key/file/size/valid 四字段
        foreach ($f in @($doc.backup_files)) {
            $f.key | Should -Not -BeNullOrEmpty
            $f.file | Should -Not -BeNullOrEmpty
            $f.PSObject.Properties.Name | Should -Contain 'valid'
        }
    }

    It 'skips restore point creation but still backs up the registry' {
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        # 本机 System Restore 实测为启用（RPSessionInterval=1），所以这条**只有**在
        # -SkipRestorePoint 真被消费时才不会碰到还原点。旧实现声明了这个开关却从不读取，
        # 于是这里的 Checkpoint-Computer 替身被调用、抛出的信息又被产品的 catch 吞成
        # 「失败」，测试仍然全绿——断言「没崩」证明不了「没调用」（AGENTS.md 测试设计教训）。
        # 现在改为断言可观测副作用：替身里记账，状态文件里如实落盘。
        $script:checkpointCalled = $false
        function Checkpoint-Computer {
            param([string]$Description, [string]$RestorePointType)
            $script:checkpointCalled = $true
        }
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root -SkipRestorePoint *>&1) -join "`n"
        $rc | Should -Be 0
        $script:checkpointCalled | Should -BeFalse
        $out | Should -Match 'Restore point creation skipped by request'

        # 仍然产出了备份目录
        @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory).Count | Should -Be 1
        # 状态文件必须如实说明「没试过、未建立」，而不是留下一个看起来像成功的空档
        $statusFile = Join-Path @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory)[0].FullName 'restore-status.json'
        $doc = Get-Content $statusFile -Raw | ConvertFrom-Json
        $doc.restore_point_attempted | Should -BeFalse
        $doc.restore_point_enabled | Should -BeFalse
    }
}

Describe 'create-restore-point.ps1 restore point branches' {
    BeforeEach {
        $script:root = Join-Path $env:TEMP ('wrc-crp2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null
    }
    AfterEach {
        Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates a restore point when System Restore is reported enabled' {
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        # 检测接缝直接给「已启用」：本机注册表状态不该决定这条分支能不能跑
        function Test-SystemRestoreEnabled { return $true }
        $script:checkpointCalled = $false
        function Checkpoint-Computer {
            param([string]$Description, [string]$RestorePointType)
            $script:checkpointCalled = $true
            $script:checkpointDesc = $Description
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root *>&1 | Out-Null
        $rc | Should -Be 0
        $script:checkpointCalled | Should -Be $true
        $script:checkpointDesc | Should -Match '^Pre-cleanup '
    }

    It 'warns and still proceeds when Checkpoint-Computer fails' {
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        function Test-SystemRestoreEnabled { return $true }
        function Checkpoint-Computer { throw 'simulated checkpoint failure' }
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root *>&1) -join "`n"
        # 还原点失败不得让整个备份流程失败，仍应写出状态文件——但**不得**冒充成功
        # （REQ-004 / AC-018：可区分的非零码 + 如实的 restore_point_enabled）
        $rc | Should -Be 4
        @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory).Count | Should -Be 1
        $out | Should -Match 'Failed to create restore point'
        $statusFile = Join-Path @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory)[0].FullName 'restore-status.json'
        $doc = Get-Content $statusFile -Raw | ConvertFrom-Json
        $doc.restore_point_attempted | Should -BeTrue
        $doc.restore_point_enabled | Should -BeFalse
    }

    It 'honours the real registry state on this machine (enabled -> no Enable call)' {
        # 本机 HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\RPSessionInterval
        # 实测为 1，因此「方法 1: 检查注册表」先判定为**已启用**，
        # Get-CimInstance 的返回值不再影响结论，Enable-ComputerRestore 不应被调用。
        # 这条断言把当前真机行为固定下来；若将来该键变为 0，这条会失败并提示需重测。
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        $script:enableCalled = $false
        function Enable-ComputerRestore {
            param([string]$Drive, [object]$ErrorAction)
            $script:enableCalled = $true
        }
        function Get-CimInstance {
            param([string]$ClassName, [string]$Namespace, [object]$Filter)
            return [PSCustomObject]@{ RPSessionInterval = 0 }
        }
        function Checkpoint-Computer { param([string]$Description, [string]$RestorePointType) }

        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore')
        $interval = if ($key) { $key.GetValue('RPSessionInterval') } else { $null }
        if ($null -eq $interval -or $interval -eq 0) {
            Set-ItResult -Skipped -Because "本机 System Restore 未启用（RPSessionInterval=$interval），该分支前提不成立"
            return
        }

        $rc = 0
        Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root *>&1 | Out-Null
        $rc | Should -Be 0
        $script:enableCalled | Should -Be $false
    }

    It 'is callable in-process and returns a code without killing the host' {
        # ADR-001 回归：Main 内不得 exit。若这里 exit 了，后面的断言根本不会执行。
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        function Get-CimInstance { return [PSCustomObject]@{ RPSessionInterval = 0 } }
        function Checkpoint-Computer { param([string]$Description, [string]$RestorePointType) }
        $rc = 0
        Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root -SkipRestorePoint *>&1 | Out-Null
        $rc | Should -Be 0
        $after = 0
        Main -ExitCode ([ref]$after) -BackupRootOverride $script:root -SkipRestorePoint *>&1 | Out-Null
        $after | Should -Be 0
    }

    It 'proceeds without backup protection when System Restore cannot be enabled' {
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        function Test-SystemRestoreEnabled { return $false }
        # 重新验证也拿不到非零 interval，所以 Enable 之后仍判定为不可用
        function Get-SystemRestoreInterval { return 0 }
        function Enable-ComputerRestore { param([string]$Drive, [object]$ErrorAction) throw 'cannot enable' }
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root *>&1) -join "`n"
        # 关键：即便还原点不可用，注册表备份仍必须完成（不能因此中断）——
        # 但退出码必须如实区分「保护已建立」与「没建立」（REQ-004 / AC-018 / AC-017）。
        # 强制精准保护在 clean-residuals.ps1 那一层，可选层不可用**不是**中止条件。
        $rc | Should -Be 4
        @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory).Count | Should -Be 1
        $statusFile = Join-Path @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory)[0].FullName 'restore-status.json'
        $doc = Get-Content $statusFile -Raw | ConvertFrom-Json
        $doc.restore_point_attempted | Should -BeTrue
        $doc.restore_point_enabled | Should -BeFalse
        $out | Should -Match 'exit code 4'
    }

    It 'reports 0 and enabled=true when the restore point is actually established' {
        # AC-018 的另一半：成功时必须是 0。若这条也返回非零，-ToleratedCodes 就掩盖了
        # 真失败，UI 也无从区分「有最后手段」与「没有」。
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        function Test-SystemRestoreEnabled { return $true }
        function Checkpoint-Computer { param([string]$Description, [string]$RestorePointType) }
        $rc = 0
        Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root *>&1 | Out-Null
        $rc | Should -Be 0
        $statusFile = Join-Path @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory)[0].FullName 'restore-status.json'
        $doc = Get-Content $statusFile -Raw | ConvertFrom-Json
        $doc.restore_point_attempted | Should -BeTrue
        $doc.restore_point_enabled | Should -BeTrue
    }

    It 'Main still works when Get-CimInstance is unavailable' {
        . $script:RestoreScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        # 注册表这一路先失败（读不到），才会落到 WMI 那一路
        function Get-SystemRestoreInterval { return $null }
        function Get-CimInstance { throw 'WMI unavailable' }
        function Enable-ComputerRestore { param([string]$Drive, [object]$ErrorAction) }
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) -BackupRootOverride $script:root *>&1) -join "`n"
        # 检测失败被吞掉、备份流程继续；两路都判不出启用 → 如实的 4，不是 0
        $out | Should -Match 'Cannot determine System Restore status'
        $rc | Should -Be 4
        @(Get-ChildItem -Path $script:root -Filter 'backup-*' -Directory).Count | Should -Be 1
    }
}

Describe 'Test-SystemRestoreEnabled (两路交叉验证，只读)' {
    BeforeAll {
        . "$PSScriptRoot\..\..\references\scripts\create-restore-point.ps1"
    }

    It '注册表 interval 非零 -> 直接 true，不再问 WMI' {
        $script:wmiCalled = $false
        function Get-SystemRestoreInterval { return 1440 }
        function Get-CimInstance {
            param([string]$ClassName, [string]$Namespace, [object]$Filter)
            $script:wmiCalled = $true
            return [PSCustomObject]@{ RPSessionInterval = 0 }
        }
        Test-SystemRestoreEnabled | Should -BeTrue
        $script:wmiCalled | Should -BeFalse
    }

    It '注册表为 0 时 WMI 兜底：RPSessionInterval>0 判为启用' {
        function Get-SystemRestoreInterval { return 0 }
        function Get-CimInstance {
            param([string]$ClassName, [string]$Namespace, [object]$Filter)
            return [PSCustomObject]@{ RPSessionInterval = 1440 }
        }
        Test-SystemRestoreEnabled | Should -BeTrue
    }

    It '两路都说没开 -> false' {
        function Get-SystemRestoreInterval { return 0 }
        function Get-CimInstance {
            param([string]$ClassName, [string]$Namespace, [object]$Filter)
            return [PSCustomObject]@{ RPSessionInterval = 0 }
        }
        Test-SystemRestoreEnabled | Should -BeFalse
    }

    It '注册表读不到且 WMI 抛异常 -> false（绝不抛给调用方）' {
        function Get-SystemRestoreInterval { return $null }
        function Get-CimInstance { throw 'WMI down' }
        # 不合并流：警告是给控制台看的，合并进来会让 Should -BeFalse 拿到数组
        $r = Test-SystemRestoreEnabled
        $r | Should -BeFalse
    }

    It 'WMI 返回空（还原禁用时的真实形态）-> false' {
        function Get-SystemRestoreInterval { return $null }
        function Get-CimInstance {
            param([string]$ClassName, [string]$Namespace, [object]$Filter)
            return $null
        }
        Test-SystemRestoreEnabled | Should -BeFalse
    }
}
