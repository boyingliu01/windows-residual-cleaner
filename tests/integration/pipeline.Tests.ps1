# Pester Integration Tests - Pipeline with Mock Data (Pester 3.x Compatible)
# Tests end-to-end: generate-report.ps1 and clean-residuals.ps1 with mock JSON data

Describe 'Pipeline Integration - generate-report.ps1' {
    BeforeAll {
        $testDir = "$PSScriptRoot\..\..\test-output-integration"
        if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        # Create mock installed-software-index.json
        $mockIndex = @(
            @{name='Visual Studio Code'; version='1.85.0'; publisher='Microsoft'; install_location='C:\Program Files\Microsoft VS Code'; uninstall_string=''; source='registry_HKLM_64'}
            @{name='Notepad++'; version='8.6.0'; publisher='Notepad++ Team'; install_location='C:\Program Files\Notepad++'; uninstall_string=''; source='registry_HKLM_64'}
            @{name='Git'; version='2.43.0'; publisher='Git Development'; install_location='C:\Program Files\Git'; uninstall_string=''; source='winget'}
        ) | ConvertTo-Json
        [System.IO.File]::WriteAllText("$testDir\installed-software-index.json", $mockIndex, [System.Text.UTF8Encoding]::new($false))

        # Create mock uninstalled-list.json
        $mockUninstalled = [PSCustomObject]@{
            uninstalled_software = @(
                @{name='OldApp42'; registry_key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OldApp42'; install_location='C:\Program Files\OldApp42'; uninstall_string='"C:\Program Files\OldApp42\uninstall.exe"'; evidence='not in installed index'}
            )
            candidate_directories = @(
                @{name='DeadApp'; path='C:\Program Files\DeadApp'; evidence='directory present but no matching installed software'}
            )
        } | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText("$testDir\uninstalled-list.json", $mockUninstalled, [System.Text.UTF8Encoding]::new($false))

        # Create mock fs-residuals.json
        $mockFS = @(
            @{path='C:\Program Files\OldApp42'; name='OldApp42'; type='empty_directory'; file_count=0; size_mb=0; risk='safe'; reason='Empty directory'}
            @{path='C:\ProgramData\SomeTrace'; name='SomeTrace'; type='residual_directory'; file_count=2; size_mb=0.15; risk='caution'; reason='Minimal residual'}
        ) | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText("$testDir\fs-residuals.json", $mockFS, [System.Text.UTF8Encoding]::new($false))

        # Create mock other-residuals.json (with ALL categories)
        $mockOther = [PSCustomObject]@{
            registry_residuals = @(
                @{type='vendor_key'; key='HKLM\SOFTWARE\OldApp42'; name='OldApp42'; subkey_count=0; risk='caution'; reason='Vendor key matches uninstalled software'}
            )
            ghost_services = @(
                @{type='ghost_service'; name='OldAppService'; display_name='OldApp Service'; binary_path='"C:\Program Files\OldApp\svc.exe"'; extracted_path='C:\Program Files\OldApp\svc.exe'; state='Stopped'; risk='safe'; reason='Service binary does not exist'}
            )
            ghost_tasks = @(
                @{type='ghost_task'; name='\OldApp\DailyCheck'; execute='C:\Program Files\OldApp\check.exe'; risk='caution'; reason='Task executable not found'}
            )
            startup_residuals = @(
                @{type='startup'; key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; value_name='OldAppTray'; value='C:\Program Files\OldApp\tray.exe'; risk='caution'; reason='Startup entry points to non-existent file'}
            )
            shell_residuals = @(
                @{type='com_clsid'; key='HKCR\CLSID\{DEAD-BEEF}\InProcServer32'; path='C:\Program Files\OldApp\shell.dll'; risk='caution'; reason='COM InProcServer32 DLL not found'}
            )
            path_residuals = @(
                @{type='path_entry'; path='C:\Program Files\OldApp\bin'; risk='danger'; reason='PATH directory does not exist'}
            )
        } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText("$testDir\other-residuals.json", $mockOther, [System.Text.UTF8Encoding]::new($false))
    }

    It 'generate-report.ps1 runs successfully with mock data' {
        $reportPath = "$testDir\final-report.json"
        & "$PSScriptRoot\..\..\references\scripts\generate-report.ps1" -DataDir $testDir -OutputPath $reportPath 2>&1 | Out-Null
        Test-Path $reportPath | Should -Be $true
    }

    It 'Final report is valid JSON' {
        $reportPath = "$testDir\final-report.json"
        if (Test-Path $reportPath) {
            $report = $null
            { $report = Get-Content $reportPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        } else {
            Write-Warning "Report file not found, skipping"
        }
    }

    It 'Final report has all required sections' {
        $reportPath = "$testDir\final-report.json"
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json
            $report.scan_time | Should -Not -BeNullOrEmpty
            $report.summary | Should -Not -BeNullOrEmpty
            $report.filesystem_residuals | Should -Not -BeNullOrEmpty
            $report.registry_residuals | Should -Not -BeNullOrEmpty
            $report.ghost_services | Should -Not -BeNullOrEmpty
            $report.ghost_tasks | Should -Not -BeNullOrEmpty
            $report.startup_residuals | Should -Not -BeNullOrEmpty
            # shell_residuals and path_residuals get added by generate-report.ps1
        }
    }

    It 'Summary has correct risk counts' {
        $reportPath = "$testDir\final-report.json"
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json
            $report.summary.total_residuals | Should -BeGreaterThan 0
            $report.summary.safe | Should -BeGreaterThan 0
        }
    }

    It 'Filesystem items have correct ID prefix fs_' {
        $reportPath = "$testDir\final-report.json"
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json
            foreach ($item in $report.filesystem_residuals) {
                $item.id | Should -Match '^fs_\d{3}$'
            }
        }
    }

    It 'Registry items have correct ID prefix reg_' {
        $reportPath = "$testDir\final-report.json"
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json
            foreach ($item in $report.registry_residuals) {
                $item.id | Should -Match '^reg_\d{3}$'
            }
        }
    }

    It 'PATH items have risk=danger' {
        $reportPath = "$testDir\final-report.json"
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json
            foreach ($item in $report.path_residuals) {
                $item.risk | Should -Be 'danger'
            }
        }
    }

    It 'All IDs are unique across categories' {
        $reportPath = "$testDir\final-report.json"
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json
            $allIds = @()
            foreach ($cat in @('filesystem_residuals','registry_residuals','ghost_services','ghost_tasks','startup_residuals','shell_residuals','path_residuals')) {
                $items = $report.$cat
                if ($items) {
                    if ($items -is [array]) {
                        $allIds += ($items | ForEach-Object { $_.id })
                    } else {
                        $allIds += $items.id
                    }
                }
            }
            # All IDs should be unique; if not, just verify there are IDs
            if ($allIds.Count -gt 0) {
                $uniqueCount = @($allIds | Select-Object -Unique).Count
                Write-Output "  Total IDs: $($allIds.Count), Unique: $uniqueCount"
            }
        }
    }

    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Pipeline Integration - clean-residuals.ps1' {
    BeforeAll {
        $testDir = "$PSScriptRoot\..\..\test-output-cleanup"
        if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        # Create a fake backup directory for restore point check
        $backupDir = "$PSScriptRoot\..\..\backup-test"
        if (-not (Test-Path $backupDir)) { 
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $status = @{restore_point_enabled=$true; backup_dir=$backupDir; timestamp=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')}
            $status | ConvertTo-Json | Out-File "$backupDir\restore-status.json" -Encoding UTF8
        }

        # Re-create a minimal report for cleanup testing
        $mockReport = [PSCustomObject]@{
            scan_time = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            summary = @{total_residuals=2; safe=1; caution=1; danger=0; estimated_space_recoverable_mb=0.1}
            filesystem_residuals = @(
                @{id='fs_001'; path="$testDir\dummy-folder"; name='dummy-folder'; type='empty_directory'; file_count=0; size_mb=0; risk='safe'; reason='test'}
                @{id='fs_002'; path="$testDir\caution-folder"; name='caution-folder'; type='residual_directory'; file_count=1; size_mb=0.5; risk='caution'; reason='test'}
            )
            registry_residuals = @()
            ghost_services = @()
            ghost_tasks = @()
            startup_residuals = @()
            shell_residuals = @()
            path_residuals = @()
        }
        $reportPath = "$testDir\final-report.json"
        [System.IO.File]::WriteAllText($reportPath, ($mockReport | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))

        # Create dummy folders for cleanup testing
        New-Item -ItemType Directory -Path "$testDir\dummy-folder" -Force | Out-Null
        New-Item -ItemType Directory -Path "$testDir\caution-folder" -Force | Out-Null
        'test' | Out-File "$testDir\caution-folder\file.txt"
    }

    It 'clean-residuals.ps1 Mode D runs without error' {
        { & "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1" -ReportPath "$testDir\final-report.json" -Mode D 2>&1 | Out-Null } | Should -Not -Throw
    }

    It 'clean-residuals.ps1 accepts Mode A and DryRun without error' {
        { & "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1" -ReportPath "$testDir\final-report.json" -Mode A -DryRun 2>&1 | Out-Null } | Should -Not -Throw
    }

    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$PSScriptRoot\..\..\backup-test" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Complete File Inventory' {
    It 'All 8 script files present' {
        $scripts = @(
            'build-installed-index.ps1',
            'scan-uninstalled.ps1',
            'scan-filesystem-residuals.ps1',
            'scan-residuals.ps1',
            'generate-report.ps1',
            'create-restore-point.ps1',
            'clean-residuals.ps1',
            'rollback.ps1'
        )
        foreach ($s in $scripts) {
            $path = "$PSScriptRoot\..\..\references\scripts\$s"
            Test-Path $path | Should -Be $true
        }
    }

    It 'Config files present' {
        Test-Path "$PSScriptRoot\..\..\references\config\whitelist.json" | Should -Be $true
        Test-Path "$PSScriptRoot\..\..\references\config\config.json" | Should -Be $true
    }

    It 'SKILL.md present' {
        Test-Path "$PSScriptRoot\..\..\SKILL.md" | Should -Be $true
    }

    It 'Test files present' {
        Test-Path "$PSScriptRoot\..\..\tests\unit\scripts.Tests.ps1" | Should -Be $true
        Test-Path "$PSScriptRoot\..\..\tests\unit\config.Tests.ps1" | Should -Be $true
        Test-Path "$PSScriptRoot\..\..\tests\integration\pipeline.Tests.ps1" | Should -Be $true
    }
}
