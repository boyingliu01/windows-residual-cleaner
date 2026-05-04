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
        $counter = 0
        $result = Set-Id -counter ([ref]$counter) -prefix 'fs_'
        $result | Should -Be 'fs_001'
        $counter | Should -Be 1
    }
    
    It 'Increments IDs sequentially' {
        $counter = 5
        $result = Set-Id -counter ([ref]$counter) -prefix 'reg_'
        $result | Should -Be 'reg_006'
        $counter | Should -Be 6
    }
    
    It 'Uses zero-padding for large numbers' {
        $counter = 99
        $result = Set-Id -counter ([ref]$counter) -prefix 'svc_'
        $result | Should -Be 'svc_100'
        $counter | Should -Be 100
    }
    
    It 'Works with all prefixes' {
        $prefixes = @('fs_', 'reg_', 'svc_', 'tsk_', 'str_', 'shl_', 'path_')
        foreach ($p in $prefixes) {
            $c = 0
            $result = Set-Id -counter ([ref]$c) -prefix $p
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
    
    foreach ($script in $scripts) {
        It "Script $script has no parse errors" {
            $scriptPath = "$PSScriptRoot\..\..\references\scripts\$script"
            $errors = $null
            $null = [System.Management.Automation.PSParser]::Tokenize(
                (Get-Content $scriptPath -Raw), [ref]$errors
            )
            $errors | Should -Be $null
        }
    }
}
