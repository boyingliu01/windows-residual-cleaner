# Pester Integration Tests - Main flow coverage for all reference scripts (v2)
# 目标：每个脚本至少一次真实 Main 执行（fixture 数据驱动可控分支 + 真实只读系统扫描），
# 使 references/scripts 覆盖率 ≥ 80%（pre-commit 门禁）
#
# 覆盖率关键（此前这里是"测试通过但覆盖率不动"的根因）：
#   用 `& script.ps1` 会在**子作用域/新进程**里执行，Pester 的代码覆盖率插桩
#   只看当前进程，因此那些执行一行都不计入覆盖率。
#   正确做法：dot-source 脚本（只加载函数，执行守卫拦住 Main），
#   再在当前进程内直接调用 Main —— 这样每一行才被插桩统计。
#   前提是被调用脚本的 `exit` 只出现在执行守卫里（本项目 10 个脚本均已如此，
#   见 AGENTS.md「函数/执行分离模式」）。若 Main 内部含 exit，则**不要**这样做，
#   它会终止 Pester 宿主（表现为后续用例静默不执行）。
# 模式约定：
#   - 只读脚本（build-installed-index / scan-*）：dot-source + 进程内 Main
#   - 写操作脚本（clean-residuals / create-restore-point / run-all）：
#     dot-source + Mock 权限检查后进程内调用 Main

# 屏蔽外部包管理器（winget/scoop/choco）真实调用：CI/沙箱下慢或不稳定。
# build-installed-index.ps1 会 Get-Command + 调用它们；同名函数遮蔽外部 exe，
# 并返回 fixture 文本驱动其 fallback 文本解析路径。注册表源仍为真实扫描。
# 注意：必须用 global: 作用域——测试经 & 调用的子脚本只能沿作用域链解析到
# global 函数；文件级局部函数在 Pester discovery 阶段结束后即失效（曾导致
# 真实 winget/scoop/choco 被执行而挂起整个测试套件）。
function global:winget {
    param([Parameter(ValueFromRemainingArguments = $true)]$rest)
    if ($rest -contains '--output') { return @('Installed apps matching --json:') }
    return @('Name  Version  Source', '---', '', 'FixtureWingetApp  1.0.0  winget')
}
function global:scoop { param([Parameter(ValueFromRemainingArguments = $true)]$rest) }
function global:choco { param([Parameter(ValueFromRemainingArguments = $true)]$rest) }

# ---------------------------------------------------------------------------
# build-installed-index.ps1: 真实注册表扫描（进程内 Main → 覆盖率可见）
# ---------------------------------------------------------------------------
Describe 'Main-flow: build-installed-index.ps1 real scan' {
    It 'Builds installed software index from real registry' {
        . "$PSScriptRoot\..\..\references\scripts\build-installed-index.ps1"
        $out = "$TestDrive\installed-software-index.json"
        $OutputPath = $out
        Main 2>&1 | Out-Null
        Test-Path $out | Should -Be $true
        # PS 5.1: ConvertFrom-Json 把 JSON 数组作为单个 Object[] 输出，
        # 必须先赋值给变量再 @()，否则 @(cmd | ConvertFrom-Json) 恒为 Count=1
        $idxDoc = Get-Content $out -Raw | ConvertFrom-Json
        $idx = @($idxDoc)
        $idx.Count | Should -BeGreaterThan 10
        @($idx | Where-Object { -not $_.name }) | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# scan-uninstalled.ps1: 真实注册表 + fixture 索引
# ---------------------------------------------------------------------------
Describe 'Main-flow: scan-uninstalled.ps1 real scan' {
    BeforeAll {
        # 生成真实索引作为输入（独立于仓库中的历史产物）
        . "$PSScriptRoot\..\..\references\scripts\build-installed-index.ps1"
        $OutputPath = "$TestDrive\idx.json"
        Main 2>&1 | Out-Null
    }

    It 'Scans real registry and filesystem against real index' {
        . "$PSScriptRoot\..\..\references\scripts\scan-uninstalled.ps1"
        $out = "$TestDrive\uninstalled-list.json"
        $IndexPath = "$TestDrive\idx.json"
        $OutputPath = $out
        Main 2>&1 | Out-Null
        Test-Path $out | Should -Be $true
        $result = Get-Content $out -Raw | ConvertFrom-Json
        # 真实扫描结果可能为空数组，但结构必须完整
        $result.PSObject.Properties.Name | Should -Contain 'uninstalled_software'
        $result.PSObject.Properties.Name | Should -Contain 'candidate_directories'
        # 不变式：每条 evidence/confidence 结构完整
        foreach ($item in @($result.uninstalled_software)) {
            $item.evidence | Should -Not -BeNullOrEmpty
            $item.confidence | Should -Match '^(high|medium|low)$'
        }
    }
}

# ---------------------------------------------------------------------------
# scan-filesystem-residuals.ps1: fixture 目录树驱动所有判定分支
# ---------------------------------------------------------------------------
Describe 'Main-flow: scan-filesystem-residuals.ps1 fixture tree' {
    BeforeAll {
        # fixture config：低阈值以覆盖 minimal/caution/skip 分支
        $pf = "$TestDrive\PF"
        # safe-empty：完全空目录
        New-Item -ItemType Directory -Path "$pf\EmptyApp" -Force | Out-Null
        # safe-minimal：1 个小文件
        New-Item -ItemType Directory -Path "$pf\MiniApp" -Force | Out-Null
        [IO.File]::WriteAllText("$pf\MiniApp\readme.txt", 'x')
        # caution：文件少但体积大（150KB > max_size_mb=0.1）
        New-Item -ItemType Directory -Path "$pf\BigCache" -Force | Out-Null
        $big = [byte[]]::new(150 * 1024)
        [IO.File]::WriteAllBytes("$pf\BigCache\cache.dat", $big)
        # skip-active：文件数 > max_file_count=3
        New-Item -ItemType Directory -Path "$pf\ActiveApp" -Force | Out-Null
        foreach ($i in 1..5) { [IO.File]::WriteAllText("$pf\ActiveApp\file$i.dat", 'y') }
        # skip-protected：受保护目录名（无论内容）
        New-Item -ItemType Directory -Path "$pf\WindowsApps" -Force | Out-Null
        [IO.File]::WriteAllText("$pf\WindowsApps\app.exe", 'z')
        # excluded：目录只有 *.log 文件（excluded_files 匹配）
        New-Item -ItemType Directory -Path "$pf\LogOnly" -Force | Out-Null
        [IO.File]::WriteAllText("$pf\LogOnly\trace.log", 'l')

        $cfg = @{
            file_thresholds = @{
                max_file_count = 3
                max_size_mb = 0.1
                excluded_files = @('*.log')
            }
            target_directories = @($pf)
        }
        $cfgPath = "$TestDrive\config.json"
        [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

        & "$PSScriptRoot\..\..\references\scripts\scan-filesystem-residuals.ps1" -ConfigPath $cfgPath -OutputPath "$TestDrive\fs-residuals.json" 2>&1 | Out-Null
        $fsDoc = Get-Content "$TestDrive\fs-residuals.json" -Raw | ConvertFrom-Json
        $script:fsResult = @($fsDoc)
    }

    It 'Flags empty directory as safe' {
        $item = $script:fsResult | Where-Object { $_.name -eq 'EmptyApp' }
        $item | Should -Not -BeNullOrEmpty
        $item.risk | Should -Be 'safe'
    }

    It 'Flags minimal residual as safe' {
        $item = $script:fsResult | Where-Object { $_.name -eq 'MiniApp' }
        $item | Should -Not -BeNullOrEmpty
        $item.risk | Should -Be 'safe'
    }

    It 'Flags few-files-big-size as caution' {
        $item = $script:fsResult | Where-Object { $_.name -eq 'BigCache' }
        $item | Should -Not -BeNullOrEmpty
        $item.risk | Should -Be 'caution'
        $item.size_mb | Should -BeGreaterThan 0.1
    }

    It 'Skips active directories with many files' {
        $item = $script:fsResult | Where-Object { $_.name -eq 'ActiveApp' }
        $item | Should -BeNullOrEmpty
    }

    It 'Skips protected system directories' {
        $item = $script:fsResult | Where-Object { $_.name -eq 'WindowsApps' }
        $item | Should -BeNullOrEmpty
    }

    It 'Excludes *.log files from counting (LogOnly flagged empty-safe)' {
        $item = $script:fsResult | Where-Object { $_.name -eq 'LogOnly' }
        $item | Should -Not -BeNullOrEmpty
        $item.file_count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# scan-residuals.ps1: 真实系统扫描（注册表/服务/任务/启动/PATH）
# ---------------------------------------------------------------------------
Describe 'Main-flow: scan-residuals.ps1 real scan' {
    BeforeAll {
        # fixture 已卸载列表：与真实索引同源（卸载条目=索引外），空列表亦可（覆盖扫描路径）
        $ul = @{ uninstalled_software = @(); candidate_directories = @() } | ConvertTo-Json -Depth 3
        $ulPath = "$TestDrive\uninstalled-list.json"
        [IO.File]::WriteAllText($ulPath, $ul, [Text.UTF8Encoding]::new($false))

        & "$PSScriptRoot\..\..\references\scripts\scan-residuals.ps1" -UninstalledPath $ulPath -OutputPath "$TestDrive\other-residuals.json" 2>&1 | Out-Null
        $script:other = Get-Content "$TestDrive\other-residuals.json" -Raw | ConvertFrom-Json
    }

    It 'Produces all expected residual categories' {
        foreach ($cat in @('registry_residuals','ghost_services','ghost_tasks','startup_residuals','shell_residuals','path_residuals')) {
            # 真实系统扫描结果可能为空数组，但字段必须存在
            $script:other.PSObject.Properties.Name | Should -Contain $cat
        }
    }

    It 'Ghost services expose executable evidence' {
        foreach ($svc in @($script:other.ghost_services)) {
            $svc.name | Should -Not -BeNullOrEmpty
            $svc.binary_path | Should -Not -BeNullOrEmpty
        }
    }

    It 'Dead PATH entries are flagged caution (not danger)' {
        foreach ($p in @($script:other.path_residuals)) {
            $p.risk | Should -Be 'caution'
        }
    }
}

# ---------------------------------------------------------------------------
# rollback.ps1: 只读输出（真实 cleanup-log + backup 目录）
# ---------------------------------------------------------------------------
Describe 'Main-flow: rollback.ps1 instructions output' {
    It 'Prints rollback instructions with backup listing' {
        $result = & "$PSScriptRoot\..\..\references\scripts\rollback.ps1" 2>&1 | Out-String
        $result | Should -Match 'ROLLBACK INSTRUCTIONS'
        $result | Should -Match 'Available Restore Points'
        $result | Should -Match 'Registry Backup Files'
        $result | Should -Match 'To rollback'
    }
}

# ---------------------------------------------------------------------------
# clean-residuals.ps1: Mode C 真实执行（fixture 数据，Mock 系统写入）
# ---------------------------------------------------------------------------
Describe 'Main-flow: clean-residuals.ps1 execution phases' {
    BeforeAll {
        # 密闭性：本轮是 Mode C 真实执行，Phase 0 会在 projectRoot 下建 backup-<run_id>
        # 并写回滚日志。不注入 ProjectRootOverride 就会把日志留在主仓根目录——
        # 而启动期 T3 现在正是扫那个位置，一份残留的未完成日志会被下一次运行真的恢复。
        # （旧代码在这里建 `backup-test` 糊过 REQ-017 的还原点门禁；该门禁现已改为
        #  自建备份目录，那段 fixture 已成死代码，一并移除。）
        $projRoot = "$TestDrive\projroot"
        New-Item -ItemType Directory -Path $projRoot -Force | Out-Null

        $targetDir = "$TestDrive\clean-target"
        New-Item -ItemType Directory -Path "$targetDir\OldAppFiles" -Force | Out-Null
        [IO.File]::WriteAllText("$targetDir\OldAppFiles\data.bin", 'd')

        $report = [PSCustomObject]@{
            filesystem_residuals = @(
                @{ id='fs_001'; path="$targetDir\OldAppFiles"; name='OldAppFiles'; type='residual_directory'; file_count=1; size_mb=0.01; risk='safe'; reason='Minimal residual' }
            )
            registry_residuals = @(
                @{ id='reg_001'; key='HKLM\SOFTWARE\WRC-Nonexistent-Test-9F3C2E71'; name='WRC-Nonexistent'; risk='caution'; reason='Test key (never exists)' }
            )
            ghost_services = @(
                @{ id='svc_001'; name='WRCGhostSvc9F3C'; display_name='WRC Ghost Svc'; binary_path="C:\nonexistent\ghost-svc.exe"; extracted_path="C:\nonexistent\ghost-svc.exe"; state='Stopped'; risk='safe'; reason='Test ghost service' }
            )
            ghost_tasks = @(
                @{ id='tsk_001'; name='WRCGhostTask9F3C'; execute="C:\nonexistent\ghost-task.exe"; expanded_path="C:\nonexistent\ghost-task.exe"; risk='caution'; reason='Test ghost task' }
            )
            startup_residuals = @()
            shell_residuals = @()
            path_residuals = @(
                @{ id='path_001'; type='path_entry'; path="$TestDrive\DeadPathXYZ9F3C"; risk='caution'; reason='Test dead path' }
            )
        }
        $reportPath = "$TestDrive\report.json"
        [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

        # 注意：此 Describe 验证"非白名单项被正常处理"，白名单必须为空。
        # 若把 fixture 项列入 whitelist，会被 pre-filter 跳过而永远走不到删除逻辑。
        $whitelist = @{
            registry_patterns = @()
            path_patterns = @()
            service_names = @()
        }
        $wlPath = "$TestDrive\whitelist.json"
        [IO.File]::WriteAllText($wlPath, ($whitelist | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    }

    BeforeEach {
        . "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1" -ReportPath $reportPath -WhitelistPath $wlPath `
            -Mode C -DryRun:$false -ProjectRootOverride $projRoot
        Mock Test-AdminPrivilege { return $true }
        Mock Get-ScheduledTask { return @([pscustomobject]@{ TaskName = 'WRCGhostTask9F3C' }) }
        Mock Unregister-ScheduledTask { }
        Mock Get-CimInstance { return $null }
    }

    It 'Phase 1-3 process fixture items with correct action logs' {
        $result = Main 2>&1 | Out-String
        $result | Should -Match 'Phase 1: Stopping services'
        $result | Should -Match 'Phase 2: Deleting files and services'
        $result | Should -Match 'Phase 3: Cleaning registry'
        # filesystem 项真实删除
        $result | Should -Match 'Deleting path:'
        Test-Path "$TestDrive\clean-target\OldAppFiles" | Should -Be $false
        # ghost task 通过 Mock 删除
        $result | Should -Match 'Deleting scheduled task'
        $result | Should -Match 'Scheduled task deleted'
        # registry 键不存在 → skip
        $result | Should -Match 'Registry key does not exist'
        # path_entry 不在真实 Machine PATH → skip
        $result | Should -Match 'PATH entry not found'
        # ghost service：sc delete 失败（不存在）→ cleanup_failed 计入
        $result | Should -Match 'Deleting service: WRCGhostSvc9F3C'
    }
}

Describe 'Main-flow: clean-residuals.ps1 whitelist + danger gating' {
    BeforeAll {
        $report = [PSCustomObject]@{
            filesystem_residuals = @(
                @{ id='fs_101'; path="$TestDrive\ProtectedApp"; name='ProtectedApp'; type='empty_directory'; risk='safe'; reason='Empty' }
            )
            registry_residuals = @(
                @{ id='reg_101'; key='HKLM\SOFTWARE\WRC-Danger-Test-9F3C'; name='WRC-Danger'; risk='danger'; reason='Test danger item' }
            )
            ghost_services = @(); ghost_tasks = @(); startup_residuals = @(); shell_residuals = @(); path_residuals = @()
        }
        $reportPath = "$TestDrive\report2.json"
        [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        $whitelist = @{ registry_patterns = @(); path_patterns = @(@{ pattern='ProtectedApp' }); service_names = @() }
        $wlPath = "$TestDrive\whitelist2.json"
        [IO.File]::WriteAllText($wlPath, ($whitelist | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    }

    It 'Skips whitelisted items in DryRun mode' {
        . "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1" -ReportPath $reportPath -WhitelistPath $wlPath -Mode A -DryRun
        Mock Test-AdminPrivilege { return $true }
        $result = Main 2>&1 | Out-String
        # fs_101 (safe) 命中白名单 → SKIP；reg_101 (danger) 在 Mode A 筛选中已被排除，
        # 永远到不了 pre-filter，因此不会出现在输出中
        $result | Should -Match 'SKIP \(whitelisted\): fs_101'
        $result | Should -Match 'Cleanup summary: 0 succeeded, 0 failed, 1 skipped'
        # 无任何实际删除动作（阶段标题含 "Deleting" 字样，须用具体动作断言）
        $result | Should -Not -Match 'Deleting path:|Stopping service:'
    }

    It 'Mode D performs no cleanup' {
        . "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1" -ReportPath $reportPath -WhitelistPath $wlPath -Mode D -DryRun
        Mock Test-AdminPrivilege { return $true }
        $result = Main 2>&1 | Out-String
        $result | Should -Match 'Report-only mode'
        $result | Should -Not -Match 'Deleting'
    }

    It 'ItemsToClean filters by explicit IDs' {
        # Mode C 已排除 danger（reg_101），因此过滤必须用非 danger ID 才能命中。
        # fs_101 经 ItemsToClean 过滤后进入 pre-filter，命中白名单 → SKIP。
        . "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1" -ReportPath $reportPath -WhitelistPath $wlPath -Mode C -DryRun -ItemsToClean '["fs_101"]'
        Mock Test-AdminPrivilege { return $true }
        $result = Main 2>&1 | Out-String
        $result | Should -Match 'SKIP \(whitelisted\): fs_101'
        # reg_101 不在过滤列表，绝不能出现在任何处理输出中
        $result | Should -Not -Match 'reg_101'
    }
}

# ---------------------------------------------------------------------------
# create-restore-point.ps1: Mock 系统写入，真实备份文件流
# ---------------------------------------------------------------------------
Describe 'Main-flow: create-restore-point.ps1 backup flow' {
    BeforeEach {
        . "$PSScriptRoot\..\..\references\scripts\create-restore-point.ps1" -BackupRoot "$TestDrive\backups"
        Mock Test-AdminPrivilege { return $true }
        Mock Get-CimInstance { return @([pscustomobject]@{ RPSessionInterval = 1440 }) }
        Mock Enable-ComputerRestore { }
        Mock Checkpoint-Computer { }
        # 伪装 reg 外部命令：创建合法 reg 导出文件，避免真实导出 HKLM 大键
        function global:reg {
            param([string]$a, [string]$b, [string]$c, [string]$d)
            if ($a -eq 'export') {
                [IO.File]::WriteAllText($c, "Windows Registry Editor Version 5.00`r`n", [Text.Encoding]::Unicode)
            }
        }
    }

    It 'Creates backup directory with status json' {
        $result = Main 2>&1 | Out-String
        $result | Should -Match 'Restore point created'
        $result | Should -Match 'Backup saved to'
        $result | Should -Match 'Status saved to'
        $backupDir = Get-ChildItem "$TestDrive\backups" -Directory | Select-Object -First 1
        $backupDir | Should -Not -BeNullOrEmpty
        $status = Get-Content "$($backupDir.FullName)\restore-status.json" -Raw | ConvertFrom-Json
        $status.backup_files.Count | Should -Be 3
    }

    AfterEach {
        Remove-Item function:global:reg -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# confirm-cleanup.ps1: NonInteractive AutoSelect 各档位
# ---------------------------------------------------------------------------
Describe 'Main-flow: confirm-cleanup.ps1 auto-select modes' {
    BeforeAll {
        $report = [PSCustomObject]@{
            filesystem_residuals = @(
                @{ id='fs_201'; path='C:\Nonexistent\SafeApp'; name='SafeApp'; type='empty_directory'; risk='safe'; reason='Empty' },
                @{ id='fs_202'; path='C:\Nonexistent\CautiousApp'; name='CautiousApp'; type='residual_directory'; risk='caution'; reason='Caution' }
            )
            registry_residuals = @(
                @{ id='reg_201'; key='HKLM\SOFTWARE\Nonexistent\DangerApp'; name='DangerApp'; risk='danger'; reason='Danger' }
            )
            ghost_services = @(); ghost_tasks = @(); startup_residuals = @(); shell_residuals = @(); path_residuals = @()
        }
        $reportPath = "$TestDrive\report3.json"
        [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    }

    It 'AutoSelect safe writes only safe ids' {
        $out = "$TestDrive\confirmed-safe.json"
        & "$PSScriptRoot\..\..\references\scripts\confirm-cleanup.ps1" -ReportPath $reportPath -OutputPath $out -NonInteractive -AutoSelect 'safe' 2>&1 | Out-Null
        $idsDoc = Get-Content $out -Raw | ConvertFrom-Json
        $ids = @($idsDoc)
        $ids | Should -Contain 'fs_201'
        $ids | Should -Not -Contain 'fs_202'
        $ids | Should -Not -Contain 'reg_201'
    }

    It 'AutoSelect caution writes only caution ids' {
        $out = "$TestDrive\confirmed-caution.json"
        & "$PSScriptRoot\..\..\references\scripts\confirm-cleanup.ps1" -ReportPath $reportPath -OutputPath $out -NonInteractive -AutoSelect 'caution' 2>&1 | Out-Null
        # AutoSelect 语义为"精确匹配风险级别"：caution 只选 fs_202，不含 safe 的 fs_201
        $idsDoc = Get-Content $out -Raw | ConvertFrom-Json
        $ids = @($idsDoc)
        $ids | Should -Contain 'fs_202'
        $ids | Should -Not -Contain 'fs_201'
        $ids | Should -Not -Contain 'reg_201'
    }

    It 'SelectIds skips danger and writes requested ids' {
        # danger 项在任何模式下都不可选：SelectIds 请求 reg_201 会被跳过，
        # 只有 fs_202 被写入输出文件
        $out = "$TestDrive\confirmed-select.json"
        & "$PSScriptRoot\..\..\references\scripts\confirm-cleanup.ps1" -ReportPath $reportPath -OutputPath $out -NonInteractive -SelectIds '["reg_201","fs_202"]' 2>&1 | Out-Null
        $idsDoc = Get-Content $out -Raw | ConvertFrom-Json
        $ids = @($idsDoc)
        $ids | Should -Contain 'fs_202'
        $ids | Should -Not -Contain 'reg_201'
    }
}

# ---------------------------------------------------------------------------
# run-all.ps1: Mock 子进程编排流程
# ---------------------------------------------------------------------------
Describe 'Main-flow: run-all.ps1 pipeline orchestration' {
    BeforeEach {
        . "$PSScriptRoot\..\..\references\scripts\run-all.ps1" -SkipRestorePoint
        Mock Test-AdminPrivilege { return $true }
        Mock Start-Process {
            return [pscustomobject]@{ ExitCode = 0 }
        }
    }

    It 'Runs all scan steps and completes' {
        $result = Main 2>&1 | Out-String
        $result | Should -Match 'Skipping restore point creation'
        $result | Should -Match 'Build Installed Index'
        $result | Should -Match 'Scan Uninstalled'
        $result | Should -Match 'Scan Filesystem'
        $result | Should -Match 'Scan Residuals'
        $result | Should -Match 'Generate Report'
        $result | Should -Match 'Pipeline Complete'
    }

    It 'Runs restore-point step when not skipped' {
        . "$PSScriptRoot\..\..\references\scripts\run-all.ps1"
        Mock Test-AdminPrivilege { return $true }
        Mock Start-Process { return [pscustomobject]@{ ExitCode = 0 } }
        $result = Main 2>&1 | Out-String
        $result | Should -Match 'Create Restore Point'
    }
}
