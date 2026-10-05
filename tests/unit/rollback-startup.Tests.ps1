# tests/unit/rollback-startup.Tests.ps1
# REQ-028 / AC-033 / AC-038 / AC-042：启动期 T3 与新一轮清理的**固定顺序**。
#
# 为什么单独一个文件：这一段是 clean-residuals.ps1 的 Phase -1，它决定「本轮清理到底
# 有没有开始」。断言一律落在**可观测副作用**上（目录是否被真删、backup-* 是否被创建、
# 日志是否被标记），不断言「打印了某个字符串」（AGENTS.md 的测试设计教训）。
#
# 密闭性：全部落盘都在自建的 $script:proj 下，绝不碰主仓根目录的 backup-*/cleanup-log.json
# ——启动期 T3 扫的正是那个位置，泄漏一份未完成日志会让下一次运行真的去改系统。

BeforeAll {
    $script:libRoot = Join-Path $PSScriptRoot '..\..\references\scripts'
    . (Join-Path $script:libRoot 'rollback-journal.ps1')
    . (Join-Path $script:libRoot 'rollback-backup.ps1')
    . (Join-Path $script:libRoot 'rollback-verdicts.ps1')
    . (Join-Path $script:libRoot 'rollback-recovery.ps1')
    . (Join-Path $script:libRoot 'rollback-exec.ps1')
    . (Join-Path $script:libRoot 'rollback-producer.ps1')
    $script:CleanScript = Join-Path $script:libRoot 'clean-residuals.ps1'
    # 先做一次无参数的 dot-source，把 Get-StartupRecoveryExitCode / Main 注册进本容器的作用域，
    # 让下面「纯函数表」那组用例不必依赖任何一次真实清理就能取到函数。
    # 执行守卫（$MyInvocation.InvocationName -eq '.'）保证这一步不会跑起 Main。
    . $script:CleanScript

    $script:proj = Join-Path $PSScriptRoot '..\..\wrc-startup-projroot'
    $script:fingerprint = [string](Get-MachineFingerprint).Value

    function script:Reset-StartupProject {
        if (Test-Path -LiteralPath $script:proj) { Remove-Item -LiteralPath $script:proj -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $script:proj -Force
    }

    # 一份「自证有效、completed_at 为空」的日志 = T3 的标准消费对象。
    function script:New-StartupBackup {
        param([string]$Name, [string]$CreatedAt)
        $dir = Join-Path $script:proj $Name
        $null = New-Item -ItemType Directory -Path $dir -Force
        $j = ConvertTo-RollbackJournal -BackupDir $dir -MachineFingerprint $script:fingerprint `
            -FingerprintSource 'machine_guid'
        if (-not [string]::IsNullOrWhiteSpace($CreatedAt)) { $j['created_at'] = $CreatedAt }
        $path = Write-RollbackJournal -BackupDir $dir -Journal $j
        return @{ Dir = $dir; Path = $path; Journal = $j }
    }

    function script:Read-StartupJournal {
        param([string]$Dir)
        return Read-JsonFileSafe -Path (Join-Path $Dir 'rollback-journal.json')
    }

    # 一份最小可清理报告：一个真实存在的临时目录（唯一的破坏性副作用就在它身上），
    # 外加一个永不存在的注册表键（走 Phase 3 的 skip 分支，不碰注册表）。
    function script:New-StartupReport {
        $target = Join-Path $script:proj 'victim\OldAppFiles'
        $null = New-Item -ItemType Directory -Path $target -Force
        [IO.File]::WriteAllText((Join-Path $target 'data.bin'), 'x')
        $report = @{
            filesystem_residuals = @(
                @{ id = 'fs_001'; path = $target; name = 'OldAppFiles'; type = 'residual_directory'
                   file_count = 1; size_mb = 0.01; risk = 'safe'; reason = 'startup T3 fixture' }
            )
            registry_residuals = @(
                @{ id = 'reg_001'; key = 'HKCU\Software\WRC-Startup-NoSuch-Key-9F3C'; name = 'WRC-Startup'
                   risk = 'caution'; reason = 'never exists -> skipped, no registry write' }
            )
            ghost_services = @(); ghost_tasks = @(); startup_residuals = @()
            shell_residuals = @(); path_residuals = @()
        }
        $rp = Join-Path $script:proj 'startup-report.json'
        [IO.File]::WriteAllText($rp, ($report | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        $wl = Join-Path $script:proj 'startup-whitelist.json'
        [IO.File]::WriteAllText($wl, (@{ registry_patterns = @(); path_patterns = @(); service_names = @() } | ConvertTo-Json),
            (New-Object System.Text.UTF8Encoding($false)))
        return @{ ReportPath = $rp; WhitelistPath = $wl; Target = $target }
    }

    # 顺序记录仪：T3 的恢复引擎与本轮的新备份各自记一笔，AC-038 断言的是**先后**，
    # 不是「各自被调用过」。
    function script:Install-StartupOrderProbe {
        $script:order = @()
        Mock Invoke-RollbackRestore {
            $script:order += 't3-restore'
            return $script:restoreShape
        }
        Mock New-RollbackBackupDirectory {
            $script:order += 'new-backup'
            $rid = [guid]::NewGuid().ToString()
            $p = Join-Path $ProjectRoot "backup-$rid"
            $null = New-Item -ItemType Directory -Path $p -Force
            return @{ Ok = $true; RunId = $rid; Path = $p }
        }
    }

    function script:Invoke-StartupMain {
        param([switch]$DryRun)
        $fx = $script:fx
        . $script:CleanScript -ReportPath $fx.ReportPath -WhitelistPath $fx.WhitelistPath `
            -Mode C -ProjectRootOverride $script:proj -DryRun:$DryRun.IsPresent
        Mock Test-AdminPrivilege { return $true }
        Mock Invoke-ScExe { return @{ ok = $true; exit_code = 0; stdout = ''; error = '' } }
        Install-StartupOrderProbe
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) *>&1) | Out-String
        return @{ Rc = $rc; Out = $out }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:proj) { Remove-Item -LiteralPath $script:proj -Recurse -Force }
}

Describe 'Get-StartupRecoveryExitCode（Outcome → 本轮清理是否开始）' {
    It '<O> → <E>' -ForEach @(
        @{ O = 'no_journal'; E = 0 },
        @{ O = 'already_completed'; E = 0 },
        @{ O = 'suppressed'; E = 0 },
        @{ O = 'acknowledged_without_restore'; E = 0 },
        @{ O = 'consumed'; E = 0 },
        @{ O = 'dry_run_reported'; E = 0 },
        @{ O = 'partial_restore'; E = 14 },
        @{ O = 'ambiguous'; E = 14 },
        @{ O = 'needs_acknowledgement'; E = 14 },
        @{ O = 'rejected'; E = 14 },
        @{ O = 'consumed_with_skipped'; E = 14 },
        @{ O = 'input_error'; E = 14 },
        @{ O = 'unreadable'; E = 14 },
        @{ O = 'brand_new_outcome'; E = 14 }
    ) {
        Get-StartupRecoveryExitCode -Outcome $O | Should -Be $E
    }

    It '本轮持久化写失败 → 15，且优先于 14（REQ-026：失败发生在本轮之内）' {
        Get-StartupRecoveryExitCode -Outcome 'persistence_failed' | Should -Be 15
    }

    It '恢复完全成功是「继续」，不是 14（与 rollback.ps1 的 -Auto 语义相反）' {
        # 同一条 Outcome 在两个调用方那里含义不同：-Auto 的那次运行结束了 = 0；
        # 启动期问的是「本轮清理能不能开始」= 继续。这两件事必须分开映射，不能共用一张表。
        # -Auto 侧的表在 rollback-auto.Tests.ps1 逐条钉住（consumed → 0、
        # consumed_with_skipped → 14），这里只钉启动期侧。
        Get-StartupRecoveryExitCode -Outcome 'consumed' | Should -Be 0
        Get-StartupRecoveryExitCode -Outcome 'consumed_with_skipped' | Should -Be 14
    }
}

Describe '启动期 T3 会真的消费上一轮未完成的日志（AC-033 接线）' {
    BeforeEach {
        Reset-StartupProject
        $script:fx = New-StartupReport
        $script:restoreShape = @{
            Report = @('mock: reg_001 restored'); PersistenceError = $false
            Counts = @{ restored = 1; already_present = 0; not_restorable = 0; restore_failed = 0 }
            ResultPath = 'mock-rollback-result.json'; UnrepairedPath = ''; Unrepaired = @()
        }
    }

    It '发现未完成日志 → 先恢复，再创建本轮新备份（AC-038 的固定顺序）' {
        $old = New-StartupBackup -Name 'backup-t3-old' -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $r = Invoke-StartupMain
        # 顺序：T3 的恢复必须排在本轮新备份**之前**，否则新备份捕获的是尚未修复的状态。
        $script:order -join '>' | Should -Be 't3-restore>new-backup'
        $r.Rc | Should -Be 0
        # 真实副作用：旧日志被标记完成，本轮新备份目录被建出来。
        (Read-StartupJournal -Dir $old.Dir)['completed_at'] | Should -Not -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:proj -Filter 'backup-*' -Directory).Count | Should -Be 2
        # 本轮清理确实进行了（victim 目录被真删），不是「恢复完就悄悄什么都不做」。
        (Test-Path -LiteralPath $script:fx.Target) | Should -BeFalse
    }

    It '没有未完成日志 → 不调用恢复引擎，直接走本轮清理' {
        $r = Invoke-StartupMain
        $script:order -join '>' | Should -Be 'new-backup'
        $r.Rc | Should -Be 0
        (Test-Path -LiteralPath $script:fx.Target) | Should -BeFalse
    }

    It '上一轮的日志本轮不会被自己消费（本轮新建的备份不参与 T3）' {
        # 反证：本轮创建的 backup-<run_id> 在完成前也是「未完成日志」。若 Phase -1 排在
        # 建备份**之后**，它会立刻把自己的日志当成上轮残留 —— 顺序错了就会在这里露出来。
        $null = Invoke-StartupMain
        $again = Invoke-StartupMain
        # 第二次运行的 Phase -1 看到的是第一次留下的、已写 completed_at 的日志 → 不恢复。
        ($script:order -join '>') | Should -Be 'new-backup'
        $again.Rc | Should -Be 0
    }

    It '抑制路径不建未修复清单，但补写 completed_at 后继续清理（AC-076 同族）' {
        $old = New-StartupBackup -Name 'backup-t3-sup' -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        # 绑定一份「summary.failed == 0」的清理日志 → Step 2.5 抑制，不恢复但补标记。
        $logPath = Join-Path $script:proj 'startup-cleanup-bound.json'
        $json = @{ run_id = [string]$old.Journal['run_id']; summary = @{ failed = 0 }; entries = @() } | ConvertTo-Json
        [IO.File]::WriteAllText($logPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        $old.Journal['cleanup_log_path'] = $logPath
        $old.Journal['cleanup_log_timestamp'] = Format-IsoUtc -Value (Get-Item -LiteralPath $logPath).LastWriteTimeUtc
        $old.Journal['cleanup_log_sha256'] = Get-Sha256Hex -Path $logPath
        $null = Write-RollbackJournal -BackupDir $old.Dir -Journal $old.Journal

        $r = Invoke-StartupMain
        $r.Rc | Should -Be 0
        # 抑制 = 不恢复，所以恢复引擎一次都不该被调用；本轮清理照常开始。
        ($script:order -join '>') | Should -Be 'new-backup'
        (Read-StartupJournal -Dir $old.Dir)['completed_at'] | Should -Not -BeNullOrEmpty
        (Test-Path -LiteralPath $script:fx.Target) | Should -BeFalse
    }
}

Describe '启动期 T3 未能安全消费时本轮清理中止（AC-042 / REQ-026 14）' {
    BeforeEach {
        Reset-StartupProject
        $script:fx = New-StartupReport
        $script:restoreShape = @{
            Report = @('mock: reg_002 restore_failed(conflict)')
            PersistenceError = $false
            Counts = @{ restored = 0; already_present = 0; not_restorable = 0; restore_failed = 1 }
            ResultPath = 'mock-rollback-result.json'
            UnrepairedPath = Join-Path $script:proj 'mock-unrepaired.json'
            Unrepaired = @()
        }
    }

    It '恢复有失败项 → 14，且未创建新备份、未执行任何破坏性操作、旧日志保持未完成' {
        $old = New-StartupBackup -Name 'backup-bad' -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $r = Invoke-StartupMain
        $r.Rc | Should -Be 14
        # 顺序记录里**只有** t3-restore：本轮的备份目录从未被创建 → 前置检查也没走到。
        $script:order -join '>' | Should -Be 't3-restore'
        @(Get-ChildItem -LiteralPath $script:proj -Filter 'backup-*' -Directory).Count | Should -Be 1
        # 没有任何破坏性操作：待删目录仍在原处。
        (Test-Path -LiteralPath $script:fx.Target) | Should -BeTrue
        Should -Invoke Invoke-ScExe -Times 0 -Exactly
        # REQ-031 / AC-077：系统仍有未修复项 → 日志保持未完成，下次启动继续 T3。
        (Read-StartupJournal -Dir $old.Dir)['completed_at'] | Should -BeNullOrEmpty
    }

    It '自证无效的日志 → 14 中止，且不把它标记成已消费（REQ-019 Step 4b）' {
        $old = New-StartupBackup -Name 'backup-invalid' -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $old.Journal['journal_version'] = 99
        $null = Write-RollbackJournal -BackupDir $old.Dir -Journal $old.Journal
        $r = Invoke-StartupMain
        $r.Rc | Should -Be 14
        $script:order -join '>' | Should -Be ''
        (Read-StartupJournal -Dir $old.Dir)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath $script:fx.Target) | Should -BeTrue
    }

    It 'created_at 平局 → 14，一份都不动（exit 14 分支 (c)）' {
        $same = Format-IsoUtc -Value (Get-Date).ToUniversalTime()
        $null = New-StartupBackup -Name 'backup-tie1' -CreatedAt $same
        $null = New-StartupBackup -Name 'backup-tie2' -CreatedAt $same
        $r = Invoke-StartupMain
        $r.Rc | Should -Be 14
        $script:order -join '>' | Should -Be ''
        foreach ($n in @('backup-tie1', 'backup-tie2')) {
            (Read-StartupJournal -Dir (Join-Path $script:proj $n))['completed_at'] | Should -BeNullOrEmpty
        }
        (Test-Path -LiteralPath $script:fx.Target) | Should -BeTrue
    }

    It '歧义候选经人确认后只补标记，然后本轮清理照常开始（REQ-030 的确认出口）' {
        $same = Format-IsoUtc -Value (Get-Date).ToUniversalTime()
        $dirs = @()
        foreach ($n in @('backup-ack1', 'backup-ack2')) {
            $b = New-StartupBackup -Name $n -CreatedAt $same
            $dirs += $b.Dir
        }
        $fx = $script:fx
        . $script:CleanScript -ReportPath $fx.ReportPath -WhitelistPath $fx.WhitelistPath `
            -Mode C -ProjectRootOverride $script:proj -AcknowledgeConflicts $true
        Mock Test-AdminPrivilege { return $true }
        Mock Invoke-ScExe { return @{ ok = $true; exit_code = 0; stdout = ''; error = '' } }
        Install-StartupOrderProbe
        $rc = 0
        $null = (Main -ExitCode ([ref]$rc) *>&1)
        $rc | Should -Be 0
        # 确认 = 「承认结束、不再自动恢复」，所以恢复引擎仍是一次都没调用。
        ($script:order -join '>') | Should -Be 'new-backup'
        foreach ($d in $dirs) {
            $j = Read-StartupJournal -Dir $d
            $j['completed_at'] | Should -Not -BeNullOrEmpty
            $j['consumed_with_failure'] | Should -BeTrue
        }
        # 先清单后标记（AC-060 / AC-079）：两份清单必须都在盘上，且落在 output/ 而非备份目录内。
        @((Get-ChildItem -LiteralPath (Join-Path $script:proj 'output') -Filter 'rollback-unrepaired-*.json').Count) | Should -Be 2
    }

    It '非管理员运行 → 2，且优先于任何恢复（不得因恢复失败而回 14）' {
        $null = New-StartupBackup -Name 'backup-nonadmin' -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $fx = $script:fx
        . $script:CleanScript -ReportPath $fx.ReportPath -WhitelistPath $fx.WhitelistPath `
            -Mode C -ProjectRootOverride $script:proj
        Mock Test-AdminPrivilege { return $false }
        Install-StartupOrderProbe
        $rc = 0
        $null = (Main -ExitCode ([ref]$rc) *>&1)
        $rc | Should -Be 2
        # 权限门排在 T3 之前：连恢复引擎都不该被碰一下。
        $script:order -join '>' | Should -Be ''
        (Read-StartupJournal -Dir (Join-Path $script:proj 'backup-nonadmin'))['completed_at'] | Should -BeNullOrEmpty
    }
}

Describe '-DryRun 下的启动期 T3 保持零副作用（AC-033 / 不返回 14）' {
    BeforeEach {
        Reset-StartupProject
        $script:fx = New-StartupReport
        $script:restoreShape = @{
            Report = @('mock: would have restored'); PersistenceError = $false
            Counts = @{ restored = 1; already_present = 0; not_restorable = 0; restore_failed = 3 }
            ResultPath = 'mock.json'; UnrepairedPath = ''; Unrepaired = @()
        }
    }

    It '发现未完成日志 → 不消费、不恢复、不改标记，且本轮照常跑完（干跑不背 14）' {
        # 恢复引擎即便被调用也会回报 restore_failed=3 —— 用来证明干跑**没有**走到恢复，
        # 否则本轮就会以 14 中止。
        $old = New-StartupBackup -Name 'backup-dry' -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $r = Invoke-StartupMain -DryRun
        $r.Rc | Should -Be 0
        $script:order -join '>' | Should -Be ''
        (Read-StartupJournal -Dir $old.Dir)['completed_at'] | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $old.Dir 'rollback-consumed.json')) | Should -BeFalse
        # 干跑连本轮的备份都不该建（REQ-016 的 dry-run 语义）。
        @(Get-ChildItem -LiteralPath $script:proj -Filter 'backup-*' -Directory).Count | Should -Be 1
        (Test-Path -LiteralPath $script:fx.Target) | Should -BeTrue
    }
}

Describe '启动期门禁与 T3 的交互（组件缺失 / 报告缺失）' {
    It '回滚组件缺失 → 告警后继续到 Phase 0，由同一道门禁 fail-closed 返回 3' {
        Reset-StartupProject
        $fx = New-StartupReport
        $saved = $script:RollbackLibsMissing
        try {
            . $script:CleanScript -ReportPath $fx.ReportPath -WhitelistPath $fx.WhitelistPath `
                -Mode C -ProjectRootOverride $script:proj
            $script:RollbackLibsMissing = @('rollback-exec.ps1')
            Mock Test-AdminPrivilege { return $true }
            $rc = 0
            $out = (Main -ExitCode ([ref]$rc) *>&1) | Out-String
            $rc | Should -Be 3
            $out | Should -Match 'Startup recovery \(T3\) skipped'
            # 一条恢复都不做，也不建备份目录。
            @(Get-ChildItem -LiteralPath $script:proj -Filter 'backup-*' -Directory).Count | Should -Be 0
        } finally {
            $script:RollbackLibsMissing = $saved
        }
    }

    It 'final-report.json 缺失不会让上轮的恢复饿死（T3 排在报告加载之前）' {
        Reset-StartupProject
        $null = New-StartupBackup -Name 'backup-noreport' -CreatedAt (Format-IsoUtc -Value (Get-Date).ToUniversalTime())
        $script:restoreShape = @{
            Report = @(); PersistenceError = $false
            Counts = @{ restored = 0; already_present = 0; not_restorable = 0; restore_failed = 0 }
            ResultPath = 'mock.json'; UnrepairedPath = ''; Unrepaired = @()
        }
        . $script:CleanScript -ReportPath (Join-Path $script:proj 'no-such-report.json') `
            -WhitelistPath (Join-Path $script:proj 'no-such-whitelist.json') `
            -Mode C -ProjectRootOverride $script:proj
        Mock Test-AdminPrivilege { return $true }
        Install-StartupOrderProbe
        $rc = 0
        $null = (Main -ExitCode ([ref]$rc) *>&1)
        # 报告缺失是本轮的输入错误（1），但上轮的日志已经先被消费掉了 —— 这正是
        # 「T3 必须在加载报告之前」要换来的东西。
        $script:order -join '>' | Should -Be 't3-restore'
        $rc | Should -Be 1
        (Read-StartupJournal -Dir (Join-Path $script:proj 'backup-noreport'))['completed_at'] | Should -Not -BeNullOrEmpty
    }
}
