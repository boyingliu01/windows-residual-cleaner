# issue #12：uninstalled_software（孤儿卸载注册项）从「只进报告」变为「可选中、可清理」。
# 本文件覆盖三层的契约：
#   1. generate-report.ps1 的 Test-UninstalledActionable —— 什么证据才允许删；
#   2. clean-residuals.ps1 的形状/存在性判定与 Phase 3 分支 —— 删之前校验什么；
#   3. confirm-cleanup.ps1 的选择集与 SelectIds 的未知 id 报错。

BeforeAll {
    $script:Scripts = "$PSScriptRoot\..\..\references\scripts"
    $script:WorkDir = Join-Path $env:TEMP ('wrc-uni-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
}

AfterAll {
    Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'generate-report.ps1 Test-UninstalledActionable (issue #12)' {
    BeforeAll {
        . "$script:Scripts\generate-report.ps1"
        $script:MissingDir = Join-Path $script:WorkDir 'definitely-missing-dir'
        $script:PresentDir = $script:WorkDir
        $script:MissingExe = Join-Path $script:WorkDir 'missing-uninstaller.exe'
        $script:PresentExe = Join-Path $script:WorkDir 'present-uninstaller.exe'
        [System.IO.File]::WriteAllText($script:PresentExe, 'x')
    }

    It 'is actionable only when BOTH install dir and uninstaller exe are missing' {
        $item = [PSCustomObject]@{
            name = 'DeadApp'
            install_location = $script:MissingDir
            uninstall_string = "`"$script:MissingExe`""
        }
        $verdict = Test-UninstalledActionable -Item $item
        $verdict.actionable | Should -BeTrue
    }

    It 'is NOT actionable when the install dir still exists' {
        $item = [PSCustomObject]@{
            name = 'AliveApp'
            install_location = $script:PresentDir
            uninstall_string = "`"$script:MissingExe`""
        }
        (Test-UninstalledActionable -Item $item).actionable | Should -BeFalse -Because '目录还在就说明软件可能还装着，删卸载项会让它无法卸载'
    }

    It 'is NOT actionable when the uninstaller exe still exists' {
        $item = [PSCustomObject]@{
            name = 'HalfAliveApp'
            install_location = $script:MissingDir
            uninstall_string = "`"$script:PresentExe`""
        }
        (Test-UninstalledActionable -Item $item).actionable | Should -BeFalse
    }

    It 'is NOT actionable when InstallLocation is empty (unknown, not missing)' {
        $item = [PSCustomObject]@{
            name = 'NoLocationApp'
            install_location = ''
            uninstall_string = "`"$script:MissingExe`""
        }
        (Test-UninstalledActionable -Item $item).actionable | Should -BeFalse -Because '空路径不算缺失（与 Test-PathMissing 同一口径）'
    }

    It 'is NOT actionable for MSI-style uninstall strings (system uninstaller never has a fixed exe)' {
        $item = [PSCustomObject]@{
            name = 'MsiApp'
            install_location = $script:MissingDir
            uninstall_string = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'
        }
        (Test-UninstalledActionable -Item $item).actionable | Should -BeFalse
    }

    It 'expands environment variables before judging (AGENTS.md trap 5)' {
        $item = [PSCustomObject]@{
            name = 'EnvApp'
            install_location = '%WRC_ISSUE12_NONEXISTENT%\App'
            uninstall_string = '"%WRC_ISSUE12_NONEXISTENT%\unins000.exe"'
        }
        (Test-UninstalledActionable -Item $item).actionable | Should -BeTrue
    }

    It 'strips quotes from InstallLocation (AGENTS.md trap 4)' {
        $item = [PSCustomObject]@{
            name = 'QuotedApp'
            install_location = "`"$script:MissingDir`""
            uninstall_string = "`"$script:MissingExe`""
        }
        (Test-UninstalledActionable -Item $item).actionable | Should -BeTrue
    }

    It 'assigns uni_ ids, caution risk and keeps non-actionable entries in the report without a key' {
        $dataDir = Join-Path $script:WorkDir 'report-input'
        New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
        $uninstalled = @{
            uninstalled_software = @(
                @{ name='DeadApp'; registry_key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DeadApp';
                   install_location=$script:MissingDir; uninstall_string="`"$script:MissingExe`""; evidence='e'; confidence='medium'; source='HKLM' }
                @{ name='WeakApp'; registry_key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WeakApp';
                   install_location=$script:PresentDir; uninstall_string="`"$script:PresentExe`""; evidence='e'; confidence='low'; source='HKLM' }
            )
            candidate_directories = @(
                @{ name='SomeDir'; path='C:\Program Files\SomeDir'; evidence='directory present but no matching installed software' }
            )
        }
        [System.IO.File]::WriteAllText((Join-Path $dataDir 'uninstalled-list.json'), ($uninstalled | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $dataDir 'fs-residuals.json'), '[]', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $dataDir 'other-residuals.json'),
            '{"registry_residuals":[],"ghost_services":[],"ghost_tasks":[],"startup_residuals":[],"shell_residuals":[],"path_residuals":[]}',
            [System.Text.UTF8Encoding]::new($false))

        $reportPath = Join-Path $script:WorkDir 'final-report.json'
        $rc = 0
        $DataDir = $dataDir
        $OutputPath = $reportPath
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 0

        $doc = [System.IO.File]::ReadAllText($reportPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $items = @($doc.uninstalled_software)
        $items.Count | Should -Be 2
        foreach ($i in $items) {
            $i.id | Should -Match '^uni_\d{3}$'
            $i.risk | Should -Be 'caution'
            $i.PSObject.Properties.Name | Should -Contain 'actionable'
        }
        $dead = $items | Where-Object { $_.name -eq 'DeadApp' }
        $weak = $items | Where-Object { $_.name -eq 'WeakApp' }
        $dead.actionable | Should -BeTrue
        $weak.actionable | Should -BeFalse
        # 只有可清理的条目才带 key —— 不可清理的条目即使被确认也没有可执行的删除目标
        $dead.key | Should -Not -BeNullOrEmpty
        $weak.PSObject.Properties.Name | Should -Not -Contain 'key'

        # summary 只统计可清理项：报告里显示的「可清理 N 项」不能把只读条目录进去
        $doc.summary.PSObject.Properties.Name | Should -Contain 'total_residuals'
        $doc.summary.total_residuals | Should -Be 1
        # 只命中一条时 Where-Object 返回单对象，.Count 取的是属性数（陷阱 3）——
        # 这正是本次在 generate-report.ps1 里修掉的 $cautionCount 缺陷的回归断言。
        $doc.summary.caution | Should -Be 1

        # candidate_directories 保持只读，且显式标注
        $dirs = @($doc.candidate_directories)
        $dirs.Count | Should -Be 1
        $dirs[0].actionable | Should -BeFalse
        $dirs[0].PSObject.Properties.Name | Should -Not -Contain 'id'
    }
}

Describe 'clean-residuals.ps1 uninstalled key shape (issue #12)' {
    BeforeAll {
        . "$script:Scripts\clean-residuals.ps1"
    }

    It 'accepts the three supported Uninstall roots as direct children' {
        Test-UninstalledKeyShape -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{7B0CC9B6-78D5-4103-A070-EC35B69E92B8}_is1' | Should -BeTrue
        Test-UninstalledKeyShape -Key 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OldApp42' | Should -BeTrue
        Test-UninstalledKeyShape -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\OldApp42' | Should -BeTrue
    }

    It 'is case-insensitive and tolerates trailing separators/quotes' {
        Test-UninstalledKeyShape -Key 'hklm\software\microsoft\windows\currentversion\uninstall\oldapp42\' | Should -BeTrue
        Test-UninstalledKeyShape -Key '"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OldApp42"' | Should -BeTrue
    }

    It 'rejects keys deeper than a direct child' {
        Test-UninstalledKeyShape -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OldApp42\Sub' | Should -BeFalse
    }

    It 'rejects sibling subtrees whose name merely starts with Uninstall' {
        Test-UninstalledKeyShape -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\UninstallX\OldApp42' | Should -BeFalse
        Test-UninstalledKeyShape -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' | Should -BeFalse
    }

    It 'rejects paths escaping the Uninstall root via ..' {
        Test-UninstalledKeyShape -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\..\Run\X' | Should -BeFalse
    }

    It 'rejects unsupported hives and empty input' {
        Test-UninstalledKeyShape -Key 'HKCR\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OldApp42' | Should -BeFalse
        Test-UninstalledKeyShape -Key '' | Should -BeFalse
        Test-UninstalledKeyShape -Key $null | Should -BeFalse
    }

    It 'Test-UninstalledKeyPresent reports key_absent for a missing key and never throws' {
        $r = Test-UninstalledKeyPresent -Key 'HKCU\Software\WRC-Issue12-NoSuchKey\Uninstall\Nothing' -ExpectedDisplayName 'X'
        $r.Present | Should -BeFalse
        $r.Reason | Should -Be 'key_absent'
    }

    It 'Test-UninstalledKeyPresent finds a real key and detects a changed DisplayName' {
        $key = 'HKCU\Software\WRC-Issue12-Probe'
        try {
            New-Item -Path "Registry::$key" -Force | Out-Null
            New-ItemProperty -Path "Registry::$key" -Name 'DisplayName' -Value 'Original Name' -PropertyType String -Force | Out-Null

            $same = Test-UninstalledKeyPresent -Key $key -ExpectedDisplayName 'Original Name'
            $same.Present | Should -BeTrue
            $same.HasDisplayName | Should -BeTrue

            $changed = Test-UninstalledKeyPresent -Key $key -ExpectedDisplayName 'Different Name'
            $changed.Present | Should -BeTrue
            $changed.HasDisplayName | Should -BeFalse
            $changed.Reason | Should -Be 'display_name_changed'
        } finally {
            Remove-Item -Path "Registry::$key" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'clean-residuals.ps1 Remove-UninstalledRegistryEntry: runtime gate (issue #12)' {
    BeforeAll {
        . "$script:Scripts\clean-residuals.ps1"
    }

    # 外部副作用全部走 Mock，判定逻辑与返回结构保持真实：这里断言的是「删之前查了什么、
    # 哪些校验不通过时必须放弃删除」，而不是「打印了某行日志」（AGENTS.md 陷阱 7 的教训）。
    BeforeEach {
        $script:OkKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\WrcIssue12'
        $script:Item = [PSCustomObject]@{ id = 'uni_001'; kind = 'uninstalled'; name = 'DeadApp'; key = $script:OkKey }
        $script:Journal = ConvertTo-RollbackJournal -RunId ([guid]::NewGuid().ToString()) -BackupDir 'backup-x' -MachineFingerprint 'fp'
        $script:BDir = Join-Path $script:WorkDir ('bk-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:BDir | Out-Null
    }

    It 'refuses without a backup dir even when the key is perfectly valid' {
        Mock Invoke-RegExe { throw 'reg must not be invoked without a backup dir' }
        $r = Remove-UninstalledRegistryEntry -Item $script:Item -Journal $script:Journal -BackupDir ''
        $r.Status | Should -Be 'failed'
        $r.Error | Should -Be 'backup_dir_missing'
        Should -Invoke Invoke-RegExe -Times 0 -Exactly
    }

    It 're-checks key shape at execution time and never touches the registry when out of scope' {
        $bad = [PSCustomObject]@{ id = 'uni_002'; kind = 'uninstalled'; name = 'X'
                                  key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\X\Nested' }
        Mock Invoke-RegExe { throw 'must not run' }
        $r = Remove-UninstalledRegistryEntry -Item $bad -Journal $script:Journal -BackupDir $script:BDir
        $r.Status | Should -Be 'failed'
        $r.Error | Should -Be 'uninstalled_key_out_of_scope'
        Should -Invoke Invoke-RegExe -Times 0 -Exactly
    }

    It 'skips (no delete, no journal entry) when the key disappeared after the scan' {
        Mock Test-UninstalledKeyPresent { @{ Present = $false; HasDisplayName = $false; Reason = 'key_absent' } }
        Mock Invoke-RegExe { throw 'must not run' }
        $r = Remove-UninstalledRegistryEntry -Item $script:Item -Journal $script:Journal -BackupDir $script:BDir
        $r.Status | Should -Be 'skipped'
        @($r.Records)[0].action | Should -Be 'registry_skip'
        (Get-RollbackJournalEntryList -Journal $script:Journal).Count | Should -Be 0 -Because '探针判定键已不存在时，连 planned 都不该登记'
        Should -Invoke Invoke-RegExe -Times 0 -Exactly
    }

    It 'refuses to delete when DisplayName changed since the scan (key reused by another product)' {
        Mock Test-UninstalledKeyPresent { @{ Present = $true; HasDisplayName = $false; Reason = 'display_name_changed' } }
        Mock Invoke-RegExe { throw 'must not run' }
        $r = Remove-UninstalledRegistryEntry -Item $script:Item -Journal $script:Journal -BackupDir $script:BDir
        $r.Status | Should -Be 'failed'
        $r.Error | Should -Be 'display_name_changed'
        Should -Invoke Invoke-RegExe -Times 0 -Exactly
    }

    It 'fails closed (persistence_failed, nothing deleted) when the .reg backup cannot be produced' {
        Mock Test-UninstalledKeyPresent { @{ Present = $true; HasDisplayName = $true; Reason = '' } }
        Mock Export-RegistryKeyBackup { @{ Ok = $false; Path = ''; Sha256 = $null; Reason = 'export_failed(reg_exit_1)' } }
        $deleteArgs = @()
        Mock Invoke-RegExe { $deleteArgs += ($Arguments -join ' '); @{ ok = $true; exit_code = 0; error = '' } }
        $r = Remove-UninstalledRegistryEntry -Item $script:Item -Journal $script:Journal -BackupDir $script:BDir
        $r.Status | Should -Be 'persistence_failed'
        $deleteArgs | Should -Not -Contain ('delete ' + $script:OkKey + ' /f') -Because '没有备份就绝不能删'
        $st = (Get-RollbackJournalEntryList -Journal $script:Journal)[0]['state']
        $st | Should -Be 'planned' -Because '卡在备份阶段时条目必须如实停在 planned，而不是记成已变更'
    }

    It 'journals planned -> backup_created -> mutation_succeeded and deletes with a single reg delete' {
        Mock Test-UninstalledKeyPresent { @{ Present = $true; HasDisplayName = $true; Reason = '' } }
        Mock Export-RegistryKeyBackup {
            $p = Join-Path $script:BDir 'reg-uni_001.reg'
            [System.IO.File]::WriteAllText($p, 'REGEDIT4')
            @{ Ok = $true; Path = $p; Sha256 = 'deadbeef' }
        }
        Mock Get-ParentBaselineSnapshot { $null }
        Mock Invoke-RegExe { @{ ok = $true; exit_code = 0; error = '' } }
        Mock Confirm-RegistryTargetAbsent { @{ Absent = $true } }

        $r = Remove-UninstalledRegistryEntry -Item $script:Item -Journal $script:Journal -BackupDir $script:BDir

        $r.Status | Should -Be 'deleted'
        @($r.Records)[0].action | Should -Be 'uninstalled_key_deleted'
        $entry = Get-RollbackJournalEntryList -Journal $script:Journal
        $entry.Count | Should -Be 1
        $entry[0]['kind'] | Should -Be 'uninstalled_key'
        $entry[0]['state'] | Should -Be 'mutation_succeeded'
        $entry[0]['backup_file'] | Should -Be 'reg-uni_001.reg'
        $entry[0]['absent_confirmed_after_mutation'] | Should -BeTrue
        # 只删这一个直接子键：reg delete 恰好一次、目标就是报告里记录的键
        Should -Invoke Invoke-RegExe -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -eq ('delete ' + $script:OkKey + ' /f')
        }
    }
}

Describe 'rollback producer: uninstalled_key mapping (issue #12)' {
    BeforeAll {
        . "$script:Scripts\clean-residuals.ps1"
    }

    It 'maps an uninstalled item to the uninstalled_key kind with its registry key as target' {
        $item = [PSCustomObject]@{
            id = 'uni_001'; kind = 'uninstalled'; name = 'DeadApp'
            key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DeadApp'
        }
        $kinds = @(Get-ItemMutationKindList -Item $item)
        $kinds | Should -Contain 'uninstalled_key'
        $kinds | Should -Not -Contain 'registry_key'
        (ConvertTo-RollbackJournalTarget -Kind 'uninstalled_key' -Item $item) |
            Should -Be 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DeadApp'
    }

    It 'keeps uninstalled items out of service/task/path kinds' {
        $item = [PSCustomObject]@{ id = 'uni_002'; kind = 'uninstalled'; name = 'DeadApp'; key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\DeadApp' }
        $kinds = @(Get-ItemMutationKindList -Item $item)
        $kinds | Should -Not -Contain 'service'
        $kinds | Should -Not -Contain 'task'
        $kinds | Should -Not -Contain 'path_deleted'
    }

    It 'treats uninstalled_key as restorable through the .reg backup' {
        (Test-RollbackRestorable -Kind 'uninstalled_key').Restorable | Should -BeTrue
    }
}

Describe 'clean-residuals.ps1: uninstalled_software handling in Main (in-process, DryRun)' {
    BeforeEach {
        $script:report = Join-Path $script:WorkDir 'r.json'
        $script:confirm = Join-Path $script:WorkDir 'ids.json'
        $script:rc = 0
    }

    It 'deletes only actionable items, applies the narrow inclusion rule instead of the CurrentVersion whitelist' {
        $report = @{
            scan_time = '2026-11-18T00:00:00'
            summary = @{ total_residuals = 2; safe = 0; caution = 2; danger = 0; estimated_space_recoverable_mb = 0 }
            uninstalled_software = @(
                @{ id='uni_001'; name='DeadApp'; kind='uninstalled'; risk='caution'; actionable=$true
                   key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DeadApp'
                   registry_key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DeadApp' }
                @{ id='uni_002'; name='OutOfScopeApp'; kind='uninstalled'; risk='caution'; actionable=$true
                   key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OutOfScopeApp\Nested'
                   registry_key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OutOfScopeApp\Nested' }
                @{ id='uni_003'; name='WeakApp'; kind='uninstalled'; risk='caution'; actionable=$false
                   registry_key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WeakApp' }
            )
            filesystem_residuals=@(); registry_residuals=@(); ghost_services=@(); ghost_tasks=@()
            startup_residuals=@(); shell_residuals=@(); path_residuals=@()
        }
        [System.IO.File]::WriteAllText($script:report, ($report | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($script:confirm, '["uni_001","uni_002","uni_003"]', [System.Text.UTF8Encoding]::new($false))

        $repoCleanupLog = Join-Path "$PSScriptRoot\..\.." 'cleanup-log.json'
        $repoLogHashBefore = if (Test-Path -LiteralPath $repoCleanupLog) {
            (Get-FileHash -LiteralPath $repoCleanupLog -Algorithm SHA256).Hash
        } else { $null }

        . "$script:Scripts\clean-residuals.ps1"
        Mock Test-AdminPrivilege { return $true }
        $ProjectRootOverride = $script:WorkDir
        $ReportPath = $script:report; $ConfirmFile = $script:confirm; $DryRun = $true; $Mode = 'D'
        $out = (Main -ExitCode ([ref]$script:rc) 2>&1) -join "`n"

        $repoLogHashAfter = if (Test-Path -LiteralPath $repoCleanupLog) {
            (Get-FileHash -LiteralPath $repoCleanupLog -Algorithm SHA256).Hash
        } else { $null }
        $repoLogHashAfter | Should -Be $repoLogHashBefore -Because '测试不得覆盖主仓的 cleanup-log.json'
        $testLog = Get-Content -LiteralPath (Join-Path $script:WorkDir 'cleanup-log.json') -Raw | ConvertFrom-Json
        $testLog.summary.total_processed | Should -Be 2

        $script:rc | Should -Be 0
        $out | Should -Match 'Deleting uninstall entry: HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\DeadApp'
        # 「在删除动作之前被挡下」的证据是它只出现在 SKIP 行、**没有**出现在 Deleting 行
        $out | Should -Match 'SKIP \(uninstalled_key_out_of_scope\): uni_002'
        $out | Should -Not -Match 'Deleting uninstall entry: .*OutOfScopeApp'
        $out | Should -Not -Match 'uni_003' -Because 'actionable=false 的条目根本不进 cleanupItems'
    }
}

Describe 'confirm-cleanup.ps1: unknown SelectIds are an error (issue #12)' {
    It 'returns 1 and writes nothing when SelectIds contains an id that is not selectable' {
        $report = @{
            filesystem_residuals = @(
                @{ id='fs_901'; path='C:\Nonexistent\A'; name='A'; type='empty_directory'; risk='safe'; reason='r' }
            )
            registry_residuals=@(); ghost_services=@(); ghost_tasks=@()
            startup_residuals=@(); shell_residuals=@(); path_residuals=@()
            uninstalled_software = @(
                @{ id='uni_901'; name='Weak'; kind='uninstalled'; risk='caution'; actionable=$false; registry_key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Weak' }
            )
        }
        $reportPath = Join-Path $script:WorkDir 'cc-report.json'
        $outPath = Join-Path $script:WorkDir 'cc-ids.json'
        [System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue

        & "$script:Scripts\confirm-cleanup.ps1" -ReportPath $reportPath -OutputPath $outPath -NonInteractive -SelectIds '["fs_901","uni_901"]' 2>&1 | Out-Null

        $LASTEXITCODE | Should -Be 1 -Because 'uni_901 不可选（actionable=false），拼进 SelectIds 必须报错而不是产出少一项的清单'
        Test-Path -LiteralPath $outPath | Should -BeFalse
    }
}
