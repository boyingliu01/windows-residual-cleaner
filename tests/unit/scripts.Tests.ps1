# Pester Unit Tests for Windows Residual Cleaner Scripts (Pester 3.x Compatible)
# Tests pure functions that don't require admin privileges

Describe 'Extract-ExecutablePath (scan-residuals.ps1)' {
    BeforeAll {
        . "$PSScriptRoot\..\..\references\scripts\scan-residuals.ps1" *>$null
        if (-not (Get-Command Extract-ExecutablePath -ErrorAction SilentlyContinue)) {
            Set-Alias -Name Extract-ExecutablePath -Value Get-ExecutablePath
        }
    }
    
    It 'Extracts path from quoted command with arguments' {
        $result = Extract-ExecutablePath -pathName '"C:\Program Files\App\app.exe" -param --flag'
        $result | Should -Be 'C:\Program Files\App\app.exe'
    }
    
    It 'Extracts path from unquoted .exe command with arguments' {
        $result = Extract-ExecutablePath -pathName 'C:\Windows\System32\svchost.exe -k netsvcs'
        $result | Should -Be 'C:\Windows\System32\svchost.exe'
    }
    
    It 'Extracts path from unquoted .dll path' {
        $result = Extract-ExecutablePath -pathName 'C:\path\to\service.dll'
        $result | Should -Be 'C:\path\to\service.dll'
    }
    
    It 'Extracts path from unquoted .sys path' {
        $result = Extract-ExecutablePath -pathName 'C:\drivers\mydriver.sys -param'
        $result | Should -Be 'C:\drivers\mydriver.sys'
    }
    
    It 'Returns first token for paths without known extensions' {
        $result = Extract-ExecutablePath -pathName '/usr/bin/someservice arg1 arg2'
        $result | Should -Be '/usr/bin/someservice'
    }
    
    It 'Returns null for empty input' {
        $result = Extract-ExecutablePath -pathName ''
        $result | Should -Be $null
    }
    
    It 'Handles path with spaces in filename' {
        $result = Extract-ExecutablePath -pathName '"C:\Program Files\My App\my app.exe" /start'
        $result | Should -Be 'C:\Program Files\My App\my app.exe'
    }
}

Describe 'Test-Whitelisted (clean-residuals.ps1)' {
    BeforeAll {
        . "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1" *>$null
    }
    
    It 'Returns false when whitelist variable is null' {
        $whitelist = $null
        $result = Test-Whitelisted -Path 'C:\test\path' -Key 'HKLM\test' -ServiceName 'test'
        $result | Should -Be $false
    }
    
    Context 'With mock whitelist' {
        BeforeAll {
            $script:whitelist = @{
                registry_patterns = @(
                    @{pattern='.*Microsoft\\Windows\\CurrentVersion\\.*'}
                    @{pattern='.*\\VCRedist\\.*'}
                )
                path_patterns = @(
                    @{pattern='.*\\Microsoft\\.*'}
                    @{pattern='.*\\WindowsApps\\.*'}
                )
                service_names = @('Winmgmt', 'RpcSs', 'EventLog')
            }
        }
        
        It 'Detects whitelisted registry key' {
            $result = Test-Whitelisted -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            $result | Should -Be $true
        }
        
        It 'Detects whitelisted path' {
            $result = Test-Whitelisted -Path 'C:\Program Files\Microsoft\something'
            $result | Should -Be $true
        }
        
        It 'Detects whitelisted service name' {
            $result = Test-Whitelisted -ServiceName 'EventLog'
            $result | Should -Be $true
        }
        
        It 'Returns false for non-matching registry key' {
            $result = Test-Whitelisted -Key 'HKLM\SOFTWARE\UnknownApp'
            $result | Should -Be $false
        }
        
        It 'Returns false for non-matching path' {
            $result = Test-Whitelisted -Path 'C:\Program Files\MyApp'
            $result | Should -Be $false
        }
        
        It 'Returns false for non-matching service name' {
            $result = Test-Whitelisted -ServiceName 'MyCustomService'
            $result | Should -Be $false
        }
    }
}

Describe 'Set-Id (generate-report.ps1)' {
    BeforeAll {
        . "$PSScriptRoot\..\..\references\scripts\generate-report.ps1" *>$null
    }

    It 'Assigns first ID with prefix and zero padding' {
        $counters = @{ fs=0 }
        $result = Set-Id -counters $counters -key 'fs' -prefix 'fs_'
        $result | Should -Be 'fs_001'
        $counters.fs | Should -Be 1
    }

    It 'Increments IDs sequentially' {
        $counters = @{ reg=5 }
        $result = Set-Id -counters $counters -key 'reg' -prefix 'reg_'
        $result | Should -Be 'reg_006'
        $counters.reg | Should -Be 6
    }

    It 'Uses zero-padding for large numbers' {
        $counters = @{ svc=99 }
        $result = Set-Id -counters $counters -key 'svc' -prefix 'svc_'
        $result | Should -Be 'svc_100'
        $counters.svc | Should -Be 100
    }

    It 'Works with all prefixes' {
        $prefixes = @('fs_', 'reg_', 'svc_', 'tsk_', 'str_', 'shl_', 'path_')
        foreach ($p in $prefixes) {
            $key = $p.TrimEnd('_')
            $counters = @{ $key=0 }
            $result = Set-Id -counters $counters -key $key -prefix $p
            $result | Should -Match "^${p}\d{3}$"
        }
    }
}

Describe 'Get-EffectiveFileCount (scan-filesystem-residuals.ps1)' {
    BeforeAll {
        . "$PSScriptRoot\..\..\references\scripts\scan-filesystem-residuals.ps1" *>$null
        $testDir = "$env:TEMP\pester-test-dir"
        if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }
    
    It 'Counts non-excluded files' {
        'data' | Out-File "$testDir\data.txt"
        'config' | Out-File "$testDir\config.ini"
        $result = Get-EffectiveFileCount -path $testDir -excluded @('.gitkeep', 'desktop.ini')
        $result | Should -Be 2
    }
    
    It 'Excludes files matching patterns' {
        Remove-Item "$testDir\*" -Force
        'data' | Out-File "$testDir\data.txt"
        'hidden' | Out-File "$testDir\desktop.ini"
        $result = Get-EffectiveFileCount -path $testDir -excluded @('desktop.ini')
        $result | Should -Be 1
    }
    
    It 'Excludes files matching wildcard patterns' {
        Remove-Item "$testDir\*" -Force
        'readme' | Out-File "$testDir\README.md"
        'data' | Out-File "$testDir\data.txt"
        $result = Get-EffectiveFileCount -path $testDir -excluded @('README*')
        $result | Should -Be 1
    }
    
    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-AllSubdirsEmpty (scan-filesystem-residuals.ps1)' {
    BeforeAll {
        . "$PSScriptRoot\..\..\references\scripts\scan-filesystem-residuals.ps1" *>$null
    }
    
    It 'Returns true for directory with no subdirectories' {
        $d = "$env:TEMP\pester-no-subdirs"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $result = Test-AllSubdirsEmpty -path $d
        $result | Should -Be $true
        Remove-Item $d -Force
    }
    
    It 'Returns true for directory with empty subdirectories' {
        $d = "$env:TEMP\pester-empty-subs"
        New-Item -ItemType Directory -Path "$d\sub1" -Force | Out-Null
        New-Item -ItemType Directory -Path "$d\sub2" -Force | Out-Null
        $result = Test-AllSubdirsEmpty -path $d
        $result | Should -Be $true
        Remove-Item $d -Recurse -Force
    }
    
    It 'Returns false for directory with non-empty subdirectories' {
        $d = "$env:TEMP\pester-nonempty-subs"
        New-Item -ItemType Directory -Path "$d\sub1" -Force | Out-Null
        'content' | Out-File "$d\sub1\file.txt"
        $result = Test-AllSubdirsEmpty -path $d
        $result | Should -Be $false
        Remove-Item $d -Recurse -Force
    }
}

Describe 'Script Syntax Validation' {
    $testCases = @(
        @{ ScriptName = 'build-installed-index.ps1' }
        @{ ScriptName = 'scan-uninstalled.ps1' }
        @{ ScriptName = 'scan-filesystem-residuals.ps1' }
        @{ ScriptName = 'scan-residuals.ps1' }
        @{ ScriptName = 'generate-report.ps1' }
        @{ ScriptName = 'create-restore-point.ps1' }
        @{ ScriptName = 'confirm-cleanup.ps1' }
        @{ ScriptName = 'clean-residuals.ps1' }
        @{ ScriptName = 'rollback.ps1' }
    )

    It "Script <ScriptName> has no parse errors" -TestCases $testCases {
        $scriptPath = "$PSScriptRoot\..\..\references\scripts\$ScriptName"
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content $scriptPath -Raw), [ref]$errors
        )
        $errors | Should -Be $null
    }
}

Describe 'confirm-cleanup.ps1 non-interactive mode' {
    BeforeAll {
        $script:scriptPath = "$PSScriptRoot\..\..\references\scripts\confirm-cleanup.ps1"
        $script:testReportPath = "$PSScriptRoot\..\..\test-report-ni.json"
        $script:testOutputPath = "$PSScriptRoot\..\..\test-confirmed-ni.json"

        $testReport = @{
            scan_time = '2026-01-01T00:00:00'
            summary = @{ total_residuals=4; safe=2; caution=1; danger=1; estimated_space_recoverable_mb=0 }
            filesystem_residuals = @(
                @{ id='fs_001'; path='C:\TestSafe'; name='TestSafe'; type='empty_directory'; file_count=0; size_mb=0; risk='safe'; reason='test' }
                @{ id='fs_002'; path='C:\TestCaution'; name='TestCaution'; type='orphan_directory'; file_count=1; size_mb=10; risk='caution'; reason='test' }
            )
            path_residuals = @(
                @{ id='path_001'; path='C:\NonExistent'; risk='danger'; reason='test' }
            )
            ghost_services = @(
                @{ id='svc_001'; name='testsvc'; display_name='Test'; binary_path='C:\test.exe'; extracted_path='C:\test.exe'; state='Stopped'; risk='safe'; reason='test' }
            )
            registry_residuals = @()
            ghost_tasks = @()
            startup_residuals = @()
            shell_residuals = @()
            uninstalled_software = @()
        } | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($testReportPath, $testReport)
    }

    BeforeEach {
        Remove-Item $testOutputPath -ErrorAction SilentlyContinue
    }

    It 'Exports safe items with -AutoSelect safe' {
        $result = & $scriptPath -ReportPath $testReportPath -OutputPath $testOutputPath -NonInteractive -AutoSelect safe 2>&1
        $output = $result -join "`n"
        $output | Should -Match 'Safe:.*2'
        $output | Should -Match 'Saved 2 items'

        $confirmed = Get-Content $testOutputPath -Raw | ConvertFrom-Json
        $confirmed | Should -Contain 'fs_001'
        $confirmed | Should -Contain 'svc_001'
        $confirmed | Should -Not -Contain 'fs_002'
        $confirmed | Should -Not -Contain 'path_001'
    }

    It 'Exports caution items with -AutoSelect caution' {
        $result = & $scriptPath -ReportPath $testReportPath -OutputPath $testOutputPath -NonInteractive -AutoSelect caution 2>&1
        $output = $result -join "`n"
        $output | Should -Match 'Caution:.*1'
        $output | Should -Match 'Saved 1 items'

        $confirmed = Get-Content $testOutputPath -Raw | ConvertFrom-Json
        $confirmed | Should -Contain 'fs_002'
        $confirmed | Should -Not -Contain 'fs_001'
        $confirmed | Should -Not -Contain 'path_001'
    }

    It 'Exports specific IDs with -SelectIds' {
        $result = & $scriptPath -ReportPath $testReportPath -OutputPath $testOutputPath -NonInteractive -SelectIds '["fs_001","fs_002"]' 2>&1
        $output = $result -join "`n"
        $output | Should -Match 'Saved 2 items'

        $confirmed = Get-Content $testOutputPath -Raw | ConvertFrom-Json
        $confirmed | Should -Contain 'fs_001'
        $confirmed | Should -Contain 'fs_002'
        $confirmed | Should -Not -Contain 'svc_001'
    }

    It 'Skips Danger items even when specified in -SelectIds' {
        # Write-Warning uses stream 3, so we need 3>&1 to capture it
        $result = & $scriptPath -ReportPath $testReportPath -OutputPath $testOutputPath -NonInteractive -SelectIds '["path_001"]' 3>&1
        $output = $result -join "`n"
        $output | Should -Match 'Skipping Danger item'
        $output | Should -Match 'No items selected'

        Test-Path $testOutputPath | Should -Be $false
    }

    It 'Requires -AutoSelect or -SelectIds when -NonInteractive' {
        $result = & $scriptPath -ReportPath $testReportPath -OutputPath $testOutputPath -NonInteractive 2>&1
        $output = $result -join "`n"
        $output | Should -Match 'requires -AutoSelect or -SelectIds'
    }

    AfterAll {
        Remove-Item $testReportPath -ErrorAction SilentlyContinue
        Remove-Item $testOutputPath -ErrorAction SilentlyContinue
    }
}

Describe 'clean-residuals.ps1 ConfirmFile integration' {
    It 'Filters items by confirmed IDs from JSON file' {
        $scriptPath = "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1"
        # Create a minimal test report
        $testReport = @{
            scan_time = '2026-01-01T00:00:00'
            summary = @{ total_residuals=3; safe=3; caution=0; danger=0; estimated_space_recoverable_mb=0 }
            filesystem_residuals = @(
                @{ id='fs_001'; path='C:\Test1'; name='Test1'; type='empty_directory'; file_count=0; size_mb=0; risk='safe'; reason='test' }
                @{ id='fs_002'; path='C:\Test2'; name='Test2'; type='empty_directory'; file_count=0; size_mb=0; risk='safe'; reason='test' }
            )
            ghost_services = @(
                @{ id='svc_001'; name='testsvc'; display_name='Test'; binary_path='C:\test.exe'; extracted_path='C:\test.exe'; state='Stopped'; risk='safe'; reason='test' }
            )
            registry_residuals = @()
            ghost_tasks = @()
            startup_residuals = @()
            shell_residuals = @()
            path_residuals = @()
            uninstalled_software = @()
        } | ConvertTo-Json -Depth 3
        $testReportPath = "$PSScriptRoot\..\..\test-report-final.json"
        [System.IO.File]::WriteAllText($testReportPath, $testReport)

        # Create confirmed IDs file with only 2 of the 3 items
        $confirmedIds = '["fs_001","svc_001"]'
        $confirmedPath = "$PSScriptRoot\..\..\test-confirmed.json"
        [System.IO.File]::WriteAllText($confirmedPath, $confirmedIds)

        # Mock backup directory to pass restore check
        $backupDir = "$PSScriptRoot\..\..\backup-test"
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null

        # Run in DryRun mode with ConfirmFile
        $result = & $scriptPath -ReportPath $testReportPath -ConfirmFile $confirmedPath -DryRun 2>&1
        $output = $result -join "`n"

        $output | Should -Match 'Loaded 2 confirmed IDs'
        $output | Should -Match 'matched 2 items'
        $output | Should -Match 'Deleting path: C:\\Test1'
        $output | Should -Match 'Stopping and deleting service: testsvc'
        $output | Should -Not -Match 'Deleting path: C:\\Test2'

        # Cleanup
        Remove-Item $testReportPath -ErrorAction SilentlyContinue
        Remove-Item $confirmedPath -ErrorAction SilentlyContinue
        Remove-Item $backupDir -ErrorAction SilentlyContinue
    }

    It 'Skips Danger items even when in confirmed IDs' {
        $scriptPath = "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1"
        $testReport = @{
            scan_time = '2026-01-01T00:00:00'
            summary = @{ total_residuals=2; safe=1; caution=0; danger=1; estimated_space_recoverable_mb=0 }
            filesystem_residuals = @(
                @{ id='fs_001'; path='C:\Test1'; name='Test1'; type='empty_directory'; file_count=0; size_mb=0; risk='safe'; reason='test' }
            )
            path_residuals = @(
                @{ id='path_001'; path='C:\NonExistent'; risk='danger'; reason='test' }
            )
            registry_residuals = @()
            ghost_services = @()
            ghost_tasks = @()
            startup_residuals = @()
            shell_residuals = @()
            uninstalled_software = @()
        } | ConvertTo-Json -Depth 3
        $testReportPath = "$PSScriptRoot\..\..\test-report-danger.json"
        [System.IO.File]::WriteAllText($testReportPath, $testReport)

        # Try to confirm a Danger item (should be blocked)
        $confirmedIds = '["fs_001","path_001"]'
        $confirmedPath = "$PSScriptRoot\..\..\test-confirmed-danger.json"
        [System.IO.File]::WriteAllText($confirmedPath, $confirmedIds)

        $backupDir = "$PSScriptRoot\..\..\backup-test"
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null

        $result = & $scriptPath -ReportPath $testReportPath -ConfirmFile $confirmedPath -DryRun 2>&1
        $output = $result -join "`n"

        # Danger items should be filtered out before ConfirmFile matching
        $output | Should -Match 'matched 1 items'
        $output | Should -Match 'Deleting path: C:\\Test1'
        $output | Should -Not -Match 'Deleting path: C:\\NonExistent'

        Remove-Item $testReportPath -ErrorAction SilentlyContinue
        Remove-Item $confirmedPath -ErrorAction SilentlyContinue
        Remove-Item $backupDir -ErrorAction SilentlyContinue
    }
}
