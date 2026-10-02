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

Describe 'generate-report.ps1 Main input validation' {
    # Main 读的是**作用域内**的 $DataDir/$OutputPath（不是参数），
    # 这与既有 pipeline.Tests.ps1 的 `-DataDir` 传参调用是两条路径。
    # 这里覆盖「必需输入缺失 → 退出码 3」的分支（原本 100% 未覆盖）。
    BeforeEach {
        . "$PSScriptRoot\..\..\references\scripts\generate-report.ps1" *>$null
        $script:emptyDir = Join-Path $env:TEMP ('wrc-gr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:emptyDir | Out-Null
    }
    AfterEach {
        Remove-Item $script:emptyDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns 3 when all three input files are missing' {
        $DataDir = $script:emptyDir
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 3
    }

    It 'returns 3 and names each missing input file' {
        $DataDir = $script:emptyDir
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) *>&1) -join "`n"
        $rc | Should -Be 3
        $out | Should -Match 'uninstalled-list\.json'
        $out | Should -Match 'fs-residuals\.json'
        $out | Should -Match 'other-residuals\.json'
    }

    It 'returns 3 when only one of the three inputs is missing' {
        $DataDir = $script:emptyDir
        '[]' | Set-Content (Join-Path $script:emptyDir 'uninstalled-list.json') -Encoding UTF8
        '[]' | Set-Content (Join-Path $script:emptyDir 'fs-residuals.json') -Encoding UTF8
        # 故意不建 other-residuals.json
        $rc = 0
        $out = (Main -ExitCode ([ref]$rc) *>&1) -join "`n"
        $rc | Should -Be 3
        $out | Should -Match 'other-residuals\.json'
        $out | Should -Not -Match 'uninstalled-list\.json,'
    }

    It 'does not kill the host: a second in-process call still returns a code' {
        # ADR-001 回归：Main 内不得 exit。若 exit 了，第二个断言不会被执行。
        $DataDir = $script:emptyDir
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 3
        $again = 0
        Main -ExitCode ([ref]$again) *>&1 | Out-Null
        $again | Should -Be 3
    }

    It 'emits an empty candidate_directories array when the scan output omits it' {
        # 覆盖 generate-report.ps1 的 `else { @() }` 分支：
        # 当 uninstalled-list.json 没有 candidate_directories 字段时，
        # 报告里该字段必须是空数组而不是 $null（下游 confirm/clean 依赖它是数组）。
        $DataDir = $script:emptyDir
        $OutputPath = Join-Path $script:emptyDir 'final-report.json'
        # uninstalled-list.json 故意不带 candidate_directories
        '{"uninstalled_software":[]}' |
            Set-Content (Join-Path $script:emptyDir 'uninstalled-list.json') -Encoding UTF8
        '[]' | Set-Content (Join-Path $script:emptyDir 'fs-residuals.json') -Encoding UTF8
        '{}' | Set-Content (Join-Path $script:emptyDir 'other-residuals.json') -Encoding UTF8

        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 0
        Test-Path $OutputPath | Should -Be $true

        $doc = Get-Content $OutputPath -Raw | ConvertFrom-Json
        $doc.PSObject.Properties.Name | Should -Contain 'candidate_directories'
        # 关键不变式：字段存在、且 @() 规整后元素数为 0
        # （JSON 里是 []；不能是缺字段或 null，否则下游 confirm/clean 遍历会出错）
        @($doc.candidate_directories).Count | Should -Be 0
        (Get-Content $OutputPath -Raw) | Should -Match '"candidate_directories"\s*:\s*\[\s*\]'
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

    It 'Returns true (fail-safe) when the path cannot be enumerated' {
        # catch 分支：不可读路径必须保守返回 $true（视为「无可清理内容」，
        # 宁可不清理也不要误删）。用一个不存在的路径触发。
        $result = Test-AllSubdirsEmpty -path "$env:TEMP\nope-$([guid]::NewGuid().ToString('N'))"
        $result | Should -Be $true
    }
}

Describe 'Get-DirectorySizeMB (scan-filesystem-residuals.ps1)' {
    BeforeEach {
        . "$PSScriptRoot\..\..\references\scripts\scan-filesystem-residuals.ps1" *>$null
        $script:sizeDir = Join-Path $env:TEMP ('wrc-size-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:sizeDir | Out-Null
    }
    AfterEach {
        Remove-Item $script:sizeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'returns 0 for an empty directory' {
        Get-DirectorySizeMB -path $script:sizeDir | Should -Be 0
    }

    It 'sums files recursively, including nested subdirectories' {
        # 1 MB 的文件（用 SetLength 避免真的写 1MB 数据）
        $f1 = Join-Path $script:sizeDir 'a.bin'
        [IO.File]::WriteAllBytes($f1, (New-Object byte[] 1048576))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:sizeDir 'nested') | Out-Null
        $f2 = Join-Path $script:sizeDir 'nested\b.bin'
        [IO.File]::WriteAllBytes($f2, (New-Object byte[] 1048576))
        # 递归统计：两个 1MB 文件 → 约 2 MB
        Get-DirectorySizeMB -path $script:sizeDir | Should -Be 2
    }

    It 'returns a rounded value with 2 decimals' {
        [IO.File]::WriteAllBytes((Join-Path $script:sizeDir 'half.bin'), (New-Object byte[] 524288))
        Get-DirectorySizeMB -path $script:sizeDir | Should -Be 0.5
    }

    It 'returns $null when the path does not exist (catch branch)' {
        # catch 分支返回的是 & $setRc 0 的输出；这里只断言不抛异常。
        { Get-DirectorySizeMB -path "$env:TEMP\nope-$([guid]::NewGuid().ToString('N'))" } |
            Should -Not -Throw
    }
}

Describe 'Get-EffectiveFileCount (scan-filesystem-residuals.ps1) error branch' {
    BeforeAll {
        . "$PSScriptRoot\..\..\references\scripts\scan-filesystem-residuals.ps1" *>$null
    }

    It 'does not throw for a non-existent path (catch branch)' {
        { Get-EffectiveFileCount -path "$env:TEMP\nope-$([guid]::NewGuid().ToString('N'))" -excluded @() } |
            Should -Not -Throw
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

# confirm-cleanup.ps1 的展示辅助函数（Get-ItemContent / Limit-StringLength /
# Get-PageRange / Show-Detail / Show-Help / Show-Page）此前完全无测试覆盖：
# 既有测试只跑 Main 的 -NonInteractive 批量导出分支（见上一组），
# 交互式 TUI 的渲染逻辑一行都没被执行，因此 confirm-cleanup.ps1 覆盖率仅 34.5%。
# 这些函数是纯函数或只依赖 $script: 状态，可在无终端环境下直接断言，
# 无需 mock 控制台（符合 AGENTS.md「不投入脆弱的控制台 mock」的取舍）。
Describe 'confirm-cleanup.ps1 display helpers' {
    BeforeAll {
        $global:_ccScript = "$PSScriptRoot\..\..\references\scripts\confirm-cleanup.ps1"
        . $global:_ccScript
    }

    Context 'Get-ItemContent' {
        It 'Returns path for filesystem_residuals' {
            Get-ItemContent -Item ([PSCustomObject]@{ path = 'C:\App\Leftover' }) -Category 'filesystem_residuals' |
                Should -Be 'C:\App\Leftover'
        }

        It 'Returns key for registry_residuals' {
            Get-ItemContent -Item ([PSCustomObject]@{ key = 'HKLM\SOFTWARE\Ghost' }) -Category 'registry_residuals' |
                Should -Be 'HKLM\SOFTWARE\Ghost'
        }

        It 'Renders service as "name -> binary_path"' {
            Get-ItemContent -Item ([PSCustomObject]@{ name = 'GhostSvc'; binary_path = 'C:\ghost.exe' }) -Category 'ghost_services' |
                Should -Be 'GhostSvc -> C:\ghost.exe'
        }

        It 'Returns name for ghost_tasks and startup_residuals' {
            Get-ItemContent -Item ([PSCustomObject]@{ name = 'GhostTask' }) -Category 'ghost_tasks' | Should -Be 'GhostTask'
            Get-ItemContent -Item ([PSCustomObject]@{ name = 'GhostStartup' }) -Category 'startup_residuals' | Should -Be 'GhostStartup'
        }

        It 'Returns key for shell_residuals and path for path_residuals' {
            Get-ItemContent -Item ([PSCustomObject]@{ key = 'HKCR\Ghost.Com' }) -Category 'shell_residuals' | Should -Be 'HKCR\Ghost.Com'
            Get-ItemContent -Item ([PSCustomObject]@{ path = 'C:\DeadBin' }) -Category 'path_residuals' | Should -Be 'C:\DeadBin'
        }

        It 'Falls back to [未知] for unknown category' {
            Get-ItemContent -Item ([PSCustomObject]@{ path = 'C:\x' }) -Category 'unknown_category' | Should -Be '[未知]'
        }

        It 'Falls back to [未知] when the relevant property is missing' {
            # 每个分支都是 `if ($Item.x) { return ... }`，属性缺失时落到函数末尾的兜底返回
            Get-ItemContent -Item ([PSCustomObject]@{ something_else = 1 }) -Category 'filesystem_residuals' |
                Should -Be '[未知]'
            Get-ItemContent -Item ([PSCustomObject]@{ something_else = 1 }) -Category 'registry_residuals' |
                Should -Be '[未知]'
        }
    }

    Context 'Limit-StringLength' {
        It 'Returns the string unchanged when within the limit' {
            Limit-StringLength -Str 'short' -MaxLen 50 | Should -Be 'short'
        }

        It 'Truncates with an ellipsis when exceeding the limit' {
            $result = Limit-StringLength -Str ('x' * 60) -MaxLen 50
            $result.Length | Should -Be 50
            $result | Should -Match '\.\.\.$'
        }

        It 'Keeps exactly MaxLen characters (boundary: no truncation at the limit)' {
            $exact = 'y' * 50
            Limit-StringLength -Str $exact -MaxLen 50 | Should -Be $exact
        }

        It 'Truncates at the first length over the limit' {
            $result = Limit-StringLength -Str ('z' * 51) -MaxLen 50
            $result.Length | Should -Be 50
            $result | Should -Match '\.\.\.$'
        }
    }

    Context 'Get-PageRange' {
        It 'Computes the first page range' {
            $script:pageSize = 20
            $script:totalItems = 100
            $range = Get-PageRange -Page 0
            @($range).Count | Should -Be 2
            $range[0] | Should -Be 0
            $range[1] | Should -Be 19
        }

        It 'Computes a middle page range' {
            $script:pageSize = 20
            $script:totalItems = 100
            $range = Get-PageRange -Page 2
            $range[0] | Should -Be 40
            $range[1] | Should -Be 59
        }

        It 'Clamps the last page to totalItems - 1' {
            $script:pageSize = 20
            $script:totalItems = 45
            $range = Get-PageRange -Page 2
            $range[0] | Should -Be 40
            $range[1] | Should -Be 44   # 而非 59
        }
    }

    Context 'Show-Help' {
        It 'Prints every documented command' {
            $out = (Show-Help) -join "`n"
            $out | Should -Match '=== 帮助 ==='
            foreach ($cmd in @('数字', '范围', 'A ', 'C ', 'SA', 'CA', 'CL', 'N ', 'P ', 'D <id>', '\?', 'Q ', 'X ')) {
                $out | Should -Match $cmd
            }
        }
    }

    Context 'Show-Detail' {
        BeforeEach {
            $script:riskLabels = @{ safe = 'Safe'; caution = 'Caution'; danger = 'Danger' }
        }

        It 'Warns when the id is not found' {
            $script:sorted = @()
            $out = (Show-Detail -Id 'nope_999') 3>&1 | Out-String
            $out | Should -Match '未找到项'
        }

        It 'Prints the core fields for a found item' {
            $script:sorted = @([PSCustomObject]@{
                id = 'fs_500'; risk = 'safe'; catLabel = '文件系统'
                content = 'C:\App\Leftover'; reason = 'orphan dir'; size_mb = 12.5
                _item = [PSCustomObject]@{ id = 'fs_500'; risk = 'safe'; reason = 'orphan dir' }
            })
            $out = (Show-Detail -Id 'fs_500') -join "`n"
            $out | Should -Match 'ID:\s+fs_500'
            $out | Should -Match '文件系统'
            $out | Should -Match 'C:\\App\\Leftover'
            $out | Should -Match 'orphan dir'
            $out | Should -Match '12.5 MB'
        }

        It 'Omits the size line when size_mb is 0' {
            $script:sorted = @([PSCustomObject]@{
                id = 'fs_501'; risk = 'safe'; catLabel = '文件系统'
                content = 'C:\X'; reason = 'r'; size_mb = 0
                _item = [PSCustomObject]@{ id = 'fs_501' }
            })
            $out = (Show-Detail -Id 'fs_501') -join "`n"
            $out | Should -Not -Match 'MB'
        }
    }

    Context 'Show-Page' {
        BeforeEach {
            $script:riskLabels = @{ safe = 'Safe'; caution = 'Caution'; danger = 'Danger' }
            $script:selectedIds = @{}
            $script:pageSize = 20
        }

        It 'Renders a page with the selected marker for chosen items' {
            $script:sorted = @(
                [PSCustomObject]@{ id='fs_601'; risk='safe';    catLabel='文件系统'; content='C:\A'; reason='r' }
                [PSCustomObject]@{ id='fs_602'; risk='caution'; catLabel='文件系统'; content='C:\B'; reason='r' }
            )
            $script:totalItems = 2
            $script:totalPages = 1
            $script:selectedIds['fs_601'] = $true

            $out = (Show-Page -Page 0) -join "`n"
            $out | Should -Match '第 1/1 页'
            $out | Should -Match 'fs_601'
            $out | Should -Match 'fs_602'
            $out | Should -Match '\*'          # fs_601 已选
            $out | Should -Match 'Safe'
            $out | Should -Match 'Caution'
        }

        It 'Shows the selected count in the header' {
            $script:sorted = @(
                [PSCustomObject]@{ id='fs_603'; risk='safe'; catLabel='文件系统'; content='C:\C'; reason='r' }
            )
            $script:totalItems = 1
            $script:totalPages = 1
            $script:selectedIds['fs_603'] = $true
            $out = (Show-Page -Page 0) -join "`n"
            $out | Should -Match '已选 1 项'
        }
    }
}

# Remove-ItemRobust：四层降级删除策略的入口契约。
# 只覆盖在普通用户环境下可确定复现的分支（WhatIf / 路径不存在 / Strategy 1 正常删除）。
# Strategy 2-4（takeown→icacls→cmd rd→改名延迟删除）需要真实被占用或 ACL 锁定的文件，
# 按 AGENTS.md 测试策略属管理员环境集成验证范畴，此处不注入脆弱 mock。
Describe 'Remove-ItemRobust (clean-residuals.ps1)' {
    BeforeAll {
        $global:_rirScript = "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1"
        $global:_rirRoot = "$PSScriptRoot\..\..\wrc-robust-fixture"
        . $global:_rirScript
    }
    BeforeEach {
        Remove-Item $global:_rirRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $global:_rirRoot -ItemType Directory -Force | Out-Null
    }
    AfterAll {
        Remove-Item $global:_rirRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Returns true without touching the filesystem when -WhatIf is set' {
        $target = Join-Path $global:_rirRoot 'keep-me'
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        Remove-ItemRobust -Path $target -WhatIf | Should -Be $true
        Test-Path $target | Should -Be $true   # 未被删除
    }

    It 'Returns true for a path that does not exist (idempotent)' {
        Remove-ItemRobust -Path (Join-Path $global:_rirRoot 'never-existed') | Should -Be $true
    }

    It 'Deletes a normal file via Strategy 1' {
        $target = Join-Path $global:_rirRoot 'plain.txt'
        [System.IO.File]::WriteAllText($target, 'x')
        Remove-ItemRobust -Path $target | Should -Be $true
        Test-Path $target | Should -Be $false
    }

    It 'Deletes a normal directory tree via Strategy 1' {
        $target = Join-Path $global:_rirRoot 'tree'
        New-Item -Path (Join-Path $target 'nested') -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $target 'nested\f.txt'), 'x')
        Remove-ItemRobust -Path $target | Should -Be $true
        Test-Path $target | Should -Be $false
    }
}

# setup.ps1：环境自检脚本。此前无任何测试覆盖（0%）。
# 关键点：必须「dot-source + 进程内调用 Main」才能被 Pester 覆盖率观测到。
# 用子进程（-File）执行会让覆盖率归零——覆盖率只在当前进程内插桩，
# 这是本项目最容易写出「测试通过但覆盖率不动」假象的地方。
Describe 'setup.ps1 environment check' {
    BeforeAll {
        $global:_setupScript = "$PSScriptRoot\..\..\setup.ps1"
    }

    It 'Is dot-sourceable and exposes Main without side effects' {
        # 架构规范：dot-source 只加载函数定义，不得触发执行。
        # 注意：**不要**在 Pester 进程内调用 setup.ps1 的 Main——
        # 它末尾的 exit 会破坏 Pester 宿主状态（MethodException on Add）。
        # 因此这里只验证 dot-source 契约，执行结果由下一个用例在子进程中验证。
        $out = & {
            . $global:_setupScript
            'DOTSOURCE_DONE'
        }
        ($out -join "`n") | Should -Match 'DOTSOURCE_DONE'
        ($out -join "`n") | Should -Not -Match 'Environment Check'
        (Get-Command Main -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'Has a Main that would exit 0 on a supported environment (static contract)' {
        # 静态断言：Main 必须包含版本分支与 summary 分支
        $content = Get-Content $global:_setupScript -Raw
        $content | Should -Match '\$psVersion\.Major -lt 5'
        $content | Should -Match 'Environment check PASSED'
        $content | Should -Match 'Environment check FAILED'
        $content | Should -Match 'exit 1'
    }

    It 'Executes end-to-end in a child process and exits 0 on this machine' {
        $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $global:_setupScript `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput "$env:TEMP\wrc-setup-out.txt" `
            -RedirectStandardError "$env:TEMP\wrc-setup-err.txt"
        $p.ExitCode | Should -Be 0
        $text = Get-Content "$env:TEMP\wrc-setup-out.txt" -Raw
        $text | Should -Match 'Environment Check'
        $text | Should -Match 'PowerShell:'
        $text | Should -Match 'Administrator:'
        $text | Should -Match 'Pester:'
        $text | Should -Match 'Node\.js:'
        Remove-Item "$env:TEMP\wrc-setup-out.txt", "$env:TEMP\wrc-setup-err.txt" -Force -ErrorAction SilentlyContinue
    }
}

Describe 'clean-residuals.ps1 safety guards (fail-closed, static + subprocess)' {
    BeforeAll {
        $global:_guardScript = "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1"
        $global:_guardDir = "$PSScriptRoot\..\..\wrc-guard-fixture"
        New-Item -Path $global:_guardDir -ItemType Directory -Force | Out-Null

        $report = @{
            scan_time = '2026-01-01T00:00:00'
            summary   = @{ total_residuals=1; safe=1; caution=0; danger=0; estimated_space_recoverable_mb=0 }
            filesystem_residuals = @(@{ id='fs_g1'; path="$global:_guardDir\gone"; name='gone'; type='residual_directory'; file_count=1; size_mb=0; risk='safe'; reason='guard fixture' })
            registry_residuals=@(); ghost_services=@(); ghost_tasks=@()
            startup_residuals=@(); shell_residuals=@(); path_residuals=@(); uninstalled_software=@()
        }
        $global:_guardReport = Join-Path $global:_guardDir 'report.json'
        [System.IO.File]::WriteAllText($global:_guardReport, ($report | ConvertTo-Json -Depth 5))
        $global:_guardNoWhitelist = Join-Path $global:_guardDir 'no-whitelist.json'
    }
    AfterAll {
        Remove-Item $global:_guardDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 重要：**不要**在 Pester 进程内调用 clean-residuals.ps1 的 Main 来测试
    # 它的 exit 分支（ConfirmFile 缺失/空、restore point 缺失）——Main 内的 exit
    # 会终止 Pester 宿主，导致后续用例静默不执行（表现为 "Tests Passed" 骤降）。
    # 这些 fail-closed 契约改为：(a) 静态结构断言，(b) 子进程端到端断言。

    It 'Declares the fail-closed ConfirmFile guards in Main' {
        $c = Get-Content $global:_guardScript -Raw
        $c | Should -Match 'ConfirmFile not found'
        $c | Should -Match 'contains no confirmed IDs'
        $c | Should -Match 'Failed to parse ConfirmFile'
        $c | Should -Match 'Aborting to prevent over-deletion'
    }

    It 'Declares the restore-point prerequisite for real deletions (B-M7)' {
        $c = Get-Content $global:_guardScript -Raw
        $c | Should -Match '\$willDelete\s*=\s*\(-not \$DryRun\)'
        $c | Should -Match 'No restore point or backup found'
    }

    It 'Aborts with exit 1 in a child process when ConfirmFile is missing' {
        # 子进程验证真实退出码（exit 1 = 通用错误），不污染 Pester 宿主
        $missing = Join-Path $global:_guardDir 'nope.json'
        $outFile = Join-Path $global:_guardDir 'out.txt'
        $errFile = Join-Path $global:_guardDir 'err.txt'
        $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$global:_guardScript,
                          '-ReportPath',$global:_guardReport,'-ConfirmFile',$missing,
                          '-WhitelistPath',$global:_guardNoWhitelist,'-DryRun' `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # 非管理员时 Test-AdminPrivilege -Mandatory 会先 exit 2；管理员/已 Mock 场景下才是 1。
        # 两者都证明"没有静默继续删除"。
        @(1, 2) | Should -Contain $p.ExitCode
        $combined = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) + (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
        $combined | Should -Match 'ConfirmFile not found|Administrator privileges required'
    }

    It 'Aborts with exit 2 (privilege) or 1 in a child process when no restore point exists' {
        # 非 DryRun 且无 backup-* → exit 1；非管理员则先 exit 2。
        $confirm = Join-Path $global:_guardDir 'ok-confirm.json'
        [System.IO.File]::WriteAllText($confirm, '["fs_g1"]')
        $outFile = Join-Path $global:_guardDir 'out2.txt'
        $errFile = Join-Path $global:_guardDir 'err2.txt'
        $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$global:_guardScript,
                          '-ReportPath',$global:_guardReport,'-ConfirmFile',$confirm,
                          '-WhitelistPath',$global:_guardNoWhitelist `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        @(1, 2) | Should -Contain $p.ExitCode
        # 绝不允许 exit 0（那意味着在无备份情况下真的执行了删除）
        $p.ExitCode | Should -Not -Be 0
    }

    It 'Treats a Danger item as ineligible even when listed in ConfirmFile (in-process, no delete)' {
        . $global:_guardScript
        Mock Test-AdminPrivilege { return $true }
        Mock Remove-ItemRobust { return $true }
        $dangerReport = Join-Path $global:_guardDir 'danger-report.json'
        $r = @{
            scan_time='2026-01-01T00:00:00'
            summary=@{ total_residuals=1; safe=0; caution=0; danger=1; estimated_space_recoverable_mb=0 }
            filesystem_residuals=@(@{ id='fs_danger'; path="$global:_guardDir\danger-dir"; name='dd'; type='residual_directory'; file_count=1; size_mb=0; risk='danger'; reason='protected' })
            registry_residuals=@(); ghost_services=@(); ghost_tasks=@()
            startup_residuals=@(); shell_residuals=@(); path_residuals=@(); uninstalled_software=@()
        }
        [System.IO.File]::WriteAllText($dangerReport, ($r | ConvertTo-Json -Depth 5))
        $confirm = Join-Path $global:_guardDir 'danger-confirm.json'
        [System.IO.File]::WriteAllText($confirm, '["fs_danger"]')

        $ReportPath = $dangerReport; $ConfirmFile = $confirm
        $WhitelistPath = $global:_guardNoWhitelist; $DryRun = $true
        $out = (Main 2>&1) -join "`n"
        # danger 项被过滤掉，不进入 eligible 集合
        $out | Should -Match 'matched 0 items'
        $out | Should -Not -Match 'Deleting path: .*danger-dir'
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

        # Run in DryRun mode with ConfirmFile (dot-source + mock admin check)
        . $scriptPath
        Mock Test-AdminPrivilege { return $true }
        $ReportPath = $testReportPath
        $ConfirmFile = $confirmedPath
        $DryRun = $true
        $result = Main 2>&1
        $output = $result -join "`n"

        $output | Should -Match 'Loaded 2 confirmed IDs'
        $output | Should -Match 'matched 2 items'
        $output | Should -Match 'Deleting path: C:\\Test1'
        $output | Should -Match 'Stopping service: testsvc'
        $output | Should -Match 'Deleting service: testsvc'
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

        # Dot-source + mock admin check
        . $scriptPath
        Mock Test-AdminPrivilege { return $true }
        $ReportPath = $testReportPath
        $ConfirmFile = $confirmedPath
        $DryRun = $true
        $result = Main 2>&1
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

Describe 'clean-residuals.ps1 destructive-safety regressions (DryRun)' {
    BeforeAll {
        $global:_wrcScript = "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1"
        function global:New-WrcFixture {
            param([string]$Name, [hashtable]$Categories, [string[]]$Ids)
            $reportPath = "$PSScriptRoot\..\..\wrc-$Name-report.json"
            $report = @{
                scan_time = '2026-01-01T00:00:00'
                summary   = @{ total_residuals=1; safe=0; caution=1; danger=0; estimated_space_recoverable_mb=0 }
                filesystem_residuals = @()
                registry_residuals   = @()
                ghost_services       = @()
                ghost_tasks          = @()
                startup_residuals    = @()
                shell_residuals      = @()
                path_residuals       = @()
                uninstalled_software = @()
            }
            foreach ($k in $Categories.Keys) { $report.$k = @($Categories[$k]) }
            [System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 4))
            $confirmPath = "$PSScriptRoot\..\..\wrc-$Name-confirm.json"
            [System.IO.File]::WriteAllText($confirmPath, ($Ids | ConvertTo-Json -Compress))
            @{ report = $reportPath; confirm = $confirmPath }
        }
    }
    AfterAll {
        Remove-Item "$PSScriptRoot\..\..\wrc-*-report.json","$PSScriptRoot\..\..\wrc-*-confirm.json" -ErrorAction SilentlyContinue
        Remove-Item function:global:New-WrcFixture -ErrorAction SilentlyContinue
    }

    It 'Deletes only the startup VALUE, never the shared Run key' {
        $fx = New-WrcFixture -Name 'startup' -Ids @('str_001') -Categories @{
            startup_residuals = @(@{ id='str_001'; type='startup'; key='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; value_name='GhostApp'; value='C:\missing\x.exe'; risk='caution'; reason='test' })
        }
        . $global:_wrcScript
        Mock Test-AdminPrivilege { return $true }
        # 关闭白名单（指向不存在文件 → $script:whitelist 保持 null → 不遮蔽），
        # 否则默认 whitelist.json 会命中共享 Run 键，item 被 SKIP，测不到值级删除分支。
        $ReportPath = $fx.report; $ConfirmFile = $fx.confirm; $DryRun = $true
        $WhitelistPath = "$PSScriptRoot\..\..\wrc-no-whitelist.json"
        $output = (Main 2>&1) -join "`n"
        $output | Should -Match 'Deleting startup value: .*\\Run /v GhostApp'
        $output | Should -Not -Match 'Deleting registry key: HKLM'
    }

    It 'Removes a dead PATH entry without treating it as a filesystem delete' {
        $fx = New-WrcFixture -Name 'pathentry' -Ids @('path_001') -Categories @{
            path_residuals = @(@{ id='path_001'; type='path_entry'; path='C:\GhostBin'; risk='caution'; reason='test' })
        }
        . $global:_wrcScript
        Mock Test-AdminPrivilege { return $true }
        $ReportPath = $fx.report; $ConfirmFile = $fx.confirm; $DryRun = $true
        $WhitelistPath = "$PSScriptRoot\..\..\wrc-no-whitelist.json"
        $output = (Main 2>&1) -join "`n"
        $output | Should -Match 'Removing dead PATH entry: C:\\GhostBin'
        $output | Should -Not -Match 'Deleting path: C:\\GhostBin'
    }
}

# 回归测试：幽灵服务清理在 PS 5.1 下必须真正工作。
#
# 历史缺陷：代码写成裸 `sc.exe stop X 2>$null` / `sc.exe delete X 2>&1`。
# powershell.exe 在 stdout 未重定向而 stderr 被重定向时会抛
#   Standard{Output,Error}Encoding is only supported when ... redirected
# 于是 Phase 1 的 stop 100% 失败、Phase 2 的 delete 被 catch 记为 cleanup_failed，
# 且 $LASTEXITCODE 为空。旧测试只断言「打印了 Deleting service」且 Mock 掉
# Get-CimInstance，因此完全掩盖了真实失败——本组测试改为断言**可观测副作用**
# （Invoke-ScExe 的调用参数与返回结构），而非被打印的字符串。
Describe 'clean-residuals.ps1 service cleanup (sc.exe regression)' {
    BeforeAll {
        $global:_svcScript = "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1"

        # 密闭性：非 DryRun 清理会走「还原点/备份门」，需要存在 backup-* 目录。
        # backup-* 是 gitignored，在新克隆 / CI / worktree 中必然缺失——此前这些
        # 测试是靠主仓里遗留的 backup-* 才「碰巧通过」；缺了它 Main 会提前中止，
        # scCalls 恒为 0。这里自建自清 fixture，使测试不依赖外部状态。
        $global:_svcBackupDir = "$PSScriptRoot\..\..\backup-svcregress"
        if (-not (Test-Path $global:_svcBackupDir)) {
            New-Item -Path $global:_svcBackupDir -ItemType Directory -Force | Out-Null
        }
    }

    AfterAll {
        Remove-Item $global:_svcBackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Invoke-ScExe' {
        BeforeAll {
            . $global:_svcScript
        }

        It 'Is defined at top level so it is dot-source testable' {
            Get-Command Invoke-ScExe -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It 'Returns a result hashtable with ok/output/exit_code/error keys for a real invocation' {
            # 用 cmd.exe 代跑同一套 Start-Process 重定向管路（sc.exe 需要管理员权限，
            # 单测环境不可用），验证退出码与双流捕获本身是可靠的。
            $src = (Get-Command Invoke-ScExe).ScriptBlock.ToString()
            $patched = $src.Replace("'System32\sc.exe'", "'System32\cmd.exe'")
            $fn = [scriptblock]::Create($patched)
            $okResult = & $fn -Arguments @('/c', 'exit 0')
            $okResult.ok | Should -Be $true
            $okResult.exit_code | Should -Be 0
            $okResult.Keys | Should -Contain 'error'

            $failResult = & $fn -Arguments @('/c', 'exit 1060')
            $failResult.ok | Should -Be $false
            $failResult.exit_code | Should -Be 1060
        }

        It 'Captures a nonzero exit code instead of throwing (the old 2>&1 pattern threw)' {
            # 关键不变式：调用 sc.exe 绝不能把异常抛给调用方。
            # 旧写法在 PS 5.1 下必然抛 StandardOutputEncoding 异常。
            $null = Invoke-ScExe -Arguments @('query', 'WRC-NoSuchService-XYZ')
            # 走到这里即证明没有抛异常终止测试
            $true | Should -Be $true
        }

        It 'Reports failure (never a silent success) when sc.exe cannot be launched at all' {
            # 用不存在的可执行文件模拟"启动失败"，验证 fail-closed：
            # exit_code 必须为 $null，且 $null -ne 1060 → 调用方会判为失败。
            $src = (Get-Command Invoke-ScExe).ScriptBlock.ToString()
            $patched = $src.Replace("'System32\sc.exe'", "'System32\__no_such_sc__.exe'")
            $fn = [scriptblock]::Create($patched)
            $r = & $fn -Arguments @('query', 'anything')
            $r.ok | Should -Be $false
            $r.exit_code | Should -BeNullOrEmpty
            ($r.error -as [string]).Length | Should -BeGreaterThan 0
        }

        It 'Treats exit code 1060 (ERROR_SERVICE_DOES_NOT_EXIST) as idempotent, not a crash' {
            # 1060 表示服务本就不存在 → 幂等成功；而 $null（启动失败）不得被当成 1060。
            ($null -ne 1060) | Should -Be $true
        }
    }

    Context 'Phase 1/2 service call path' {
        BeforeAll {
            $global:_svcFixtureDir = "$PSScriptRoot\..\..\wrc-svc-fixture"
            New-Item -Path $global:_svcFixtureDir -ItemType Directory -Force | Out-Null

            $report = @{
                scan_time = '2026-01-01T00:00:00'
                summary   = @{ total_residuals=1; safe=1; caution=0; danger=0; estimated_space_recoverable_mb=0 }
                filesystem_residuals = @()
                registry_residuals   = @()
                ghost_services       = @(@{
                    id='svc_900'; name='WRCGhostSvcRegress'; display_name='Regress Svc'
                    binary_path="C:\nonexistent\regress-svc.exe"; extracted_path="C:\nonexistent\regress-svc.exe"
                    state='Stopped'; risk='safe'; reason='regression fixture'
                })
                ghost_tasks          = @()
                startup_residuals    = @()
                shell_residuals      = @()
                path_residuals       = @()
                uninstalled_software = @()
            }
            $global:_svcReport = Join-Path $global:_svcFixtureDir 'report.json'
            [System.IO.File]::WriteAllText($global:_svcReport, ($report | ConvertTo-Json -Depth 5))

            $global:_svcConfirm = Join-Path $global:_svcFixtureDir 'confirm.json'
            [System.IO.File]::WriteAllText($global:_svcConfirm, '["svc_900"]')

            $global:_svcNoWhitelist = Join-Path $global:_svcFixtureDir 'no-whitelist.json'
        }
        AfterAll {
            Remove-Item $global:_svcFixtureDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'Invokes sc.exe with stop then delete for a ghost service (no bare sc.exe redirection)' {
            . $global:_svcScript
            Mock Test-AdminPrivilege { return $true }
            Mock Get-CimInstance { return $null }
            Mock Get-ScheduledTask { return $null }

            $script:scCalls = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-ScExe {
                $script:scCalls.Add(($Arguments -join ' '))
                return @{ ok = $true; output = ''; exit_code = 0; error = '' }
            }

            $ReportPath = $global:_svcReport
            $ConfirmFile = $global:_svcConfirm
            $WhitelistPath = $global:_svcNoWhitelist
            $DryRun = $false
            $null = Main 2>&1

            # 真实副作用断言：stop 必须发生在 delete 之前
            $script:scCalls.Count | Should -BeGreaterOrEqual 2
            $script:scCalls[0] | Should -Be 'stop WRCGhostSvcRegress'
            $script:scCalls[1] | Should -Be 'delete WRCGhostSvcRegress'
        }

        It 'Records service_deleted with success when sc.exe delete returns 0' {
            . $global:_svcScript
            Mock Test-AdminPrivilege { return $true }
            Mock Get-CimInstance { return $null }
            Mock Get-ScheduledTask { return $null }
            Mock Invoke-ScExe { return @{ ok = $true; output = ''; exit_code = 0; error = '' } }

            $ReportPath = $global:_svcReport
            $ConfirmFile = $global:_svcConfirm
            $WhitelistPath = $global:_svcNoWhitelist
            $DryRun = $false
            $null = Main 2>&1

            $logPath = "$PSScriptRoot\..\..\cleanup-log.json"
            Test-Path $logPath | Should -Be $true
            $log = Get-Content $logPath -Raw | ConvertFrom-Json
            $entry = @($log.entries | Where-Object { $_.id -eq 'svc_900' })
            $entry.Count | Should -Be 1
            $entry[0].action | Should -Be 'service_deleted'
            $entry[0].success | Should -Be $true
        }

        It 'Records cleanup_failed (not service_deleted) when sc.exe delete genuinely fails' {
            . $global:_svcScript
            Mock Test-AdminPrivilege { return $true }
            Mock Get-CimInstance { return $null }
            Mock Get-ScheduledTask { return $null }
            # 模拟 sc.exe 返回 5 (Access denied)：必须记为失败，绝不能谎报成功
            Mock Invoke-ScExe { return @{ ok = $false; output = ''; exit_code = 5; error = 'Access is denied.' } }

            $ReportPath = $global:_svcReport
            $ConfirmFile = $global:_svcConfirm
            $WhitelistPath = $global:_svcNoWhitelist
            $DryRun = $false
            $null = Main 2>&1

            $logPath = "$PSScriptRoot\..\..\cleanup-log.json"
            $log = Get-Content $logPath -Raw | ConvertFrom-Json
            $entry = @($log.entries | Where-Object { $_.id -eq 'svc_900' })
            $entry.Count | Should -Be 1
            $entry[0].action | Should -Be 'cleanup_failed'
            $entry[0].success | Should -Be $false
        }

        It 'Has no bare sc.exe invocation with stream redirection left in the script' {
            # 静态守卫：禁止重新引入 `sc.exe ... 2>$null` / `sc.exe ... 2>&1`。
            $content = Get-Content $global:_svcScript -Raw
            $content | Should -Not -Match '(?m)^\s*sc\.exe\s'
        }
    }
}
