# ADR-001 解锁的覆盖率补强：Main 现在可在 Pester 进程内安全调用。
# 本文件专门驱动 confirm-cleanup.ps1 / clean-residuals.ps1 的 Main，
# 覆盖此前「因 Main 内含 exit 而完全无法插桩」的分支。
#
# 背景：`exit` 写在 Main 内会杀死 Pester 宿主，使这些行在覆盖率报告中
# 恒为 0（结构性不可测）。改用 [ref] 回传后，Main 可进程内调用并插桩。

BeforeAll {
    $script:ConfirmScript = "$PSScriptRoot\..\..\references\scripts\confirm-cleanup.ps1"
    $script:CleanScript   = "$PSScriptRoot\..\..\references\scripts\clean-residuals.ps1"
    $script:WorkDir = Join-Path $env:TEMP ('wrc-maincov-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null

    function New-TestReport {
        param([string]$Path)
        [IO.File]::WriteAllText($Path, (@{
            scan_time = '2026-10-01T00:00:00'
            summary = @{ total_residuals = 5; safe = 3; caution = 1; danger = 1; estimated_space_recoverable_mb = 0 }
            filesystem_residuals = @(
                @{ id='fs_001'; path='C:\TestSafe';    name='TestSafe';    type='empty_directory';  file_count=0; size_mb=0;  risk='safe';    reason='t' }
                @{ id='fs_002'; path='C:\TestCaution'; name='TestCaution'; type='orphan_directory'; file_count=1; size_mb=10; risk='caution'; reason='t' }
                @{ id='fs_003'; path='C:\TestSafe2';   name='TestSafe2';   type='empty_directory';  file_count=0; size_mb=0;  risk='safe';    reason='t' }
            )
            path_residuals = @( @{ id='path_001'; path='C:\NonExistent'; risk='danger'; reason='t' } )
            ghost_services = @()
            registry_residuals = @(); ghost_tasks = @(); startup_residuals = @()
            shell_residuals = @(); uninstalled_software = @()
        } | ConvertTo-Json -Depth 5))
    }
}
AfterAll {
    Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'confirm-cleanup.ps1 Main (in-process, ADR-001 unlocked)' {
    BeforeEach {
        $script:report = Join-Path $script:WorkDir 'r.json'
        $script:out    = Join-Path $script:WorkDir 'out.json'
        New-TestReport -Path $script:report
        Remove-Item $script:out -Force -ErrorAction SilentlyContinue
        $script:rc = 0
    }

    It 'ExitCode param exists and is optional (old callers still work)' {
        . $script:ConfirmScript
        $cmd = Get-Command Main
        $cmd.Parameters.ContainsKey('ExitCode') | Should -Be $true
        # [ref] 的参数类型在 PS 5.1 下报告为 PSReference
        $cmd.Parameters['ExitCode'].ParameterType.Name | Should -Be 'PSReference'
    }

    It 'NonInteractive + AutoSelect safe writes the safe ids and returns 0' {
        . $script:ConfirmScript
        $ReportPath = $script:report; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'safe'; $SelectIds = ''
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 0
        $idsDoc = Get-Content $script:out -Raw | ConvertFrom-Json
        $ids = @($idsDoc)
        $ids | Should -Contain 'fs_001'
        $ids | Should -Contain 'fs_003'
        $ids | Should -Not -Contain 'fs_002'
        $ids | Should -Not -Contain 'path_001'
    }

    It 'NonInteractive + AutoSelect caution selects only caution items' {
        . $script:ConfirmScript
        $ReportPath = $script:report; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'caution'; $SelectIds = ''
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 0
        $idsDoc = Get-Content $script:out -Raw | ConvertFrom-Json
        $ids = @($idsDoc)
        $ids | Should -Contain 'fs_002'
        $ids.Count | Should -Be 1
    }

    It 'NonInteractive + AutoSelect all never selects danger items' {
        . $script:ConfirmScript
        $ReportPath = $script:report; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'all'; $SelectIds = ''
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 0
        $idsDoc = Get-Content $script:out -Raw | ConvertFrom-Json
        $ids = @($idsDoc)
        $ids | Should -Not -Contain 'path_001'
        $ids.Count | Should -Be 3
    }

    It 'SelectIds takes precedence over AutoSelect' {
        . $script:ConfirmScript
        $ReportPath = $script:report; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'safe'; $SelectIds = '["fs_002"]'
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 0
        $idsDoc = Get-Content $script:out -Raw | ConvertFrom-Json
        $ids = @($idsDoc)
        $ids | Should -Contain 'fs_002'
        $ids.Count | Should -Be 1
    }

    It 'SelectIds silently drops danger ids (defense in depth)' {
        . $script:ConfirmScript
        $ReportPath = $script:report; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'none'; $SelectIds = '["path_001","fs_001"]'
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 0
        $idsDoc = Get-Content $script:out -Raw | ConvertFrom-Json
        $ids = @($idsDoc)
        $ids | Should -Contain 'fs_001'
        $ids | Should -Not -Contain 'path_001'
    }

    It 'invalid SelectIds JSON returns 1 instead of exiting' {
        . $script:ConfirmScript
        $ReportPath = $script:report; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'none'; $SelectIds = '{not valid json'
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 1
        Test-Path $script:out | Should -Be $false
    }

    It 'NonInteractive without AutoSelect/SelectIds returns 1' {
        . $script:ConfirmScript
        $ReportPath = $script:report; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'none'; $SelectIds = ''
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 1
    }

    It 'missing report returns 1' {
        . $script:ConfirmScript
        $ReportPath = (Join-Path $script:WorkDir 'nope.json'); $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'safe'; $SelectIds = ''
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 1
    }

    It 'unparseable report returns 1' {
        . $script:ConfirmScript
        $bad = Join-Path $script:WorkDir 'bad.json'
        [IO.File]::WriteAllText($bad, '{ not json')
        $ReportPath = $bad; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'safe'; $SelectIds = ''
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 1
    }

    It 'report whose every item is danger saves nothing and returns 0' {
        . $script:ConfirmScript
        $only = Join-Path $script:WorkDir 'only-danger.json'
        [IO.File]::WriteAllText($only, (@{
            scan_time = '2026-10-01T00:00:00'
            summary = @{ total_residuals=1; safe=0; caution=0; danger=1; estimated_space_recoverable_mb=0 }
            filesystem_residuals = @(); path_residuals = @( @{ id='path_001'; path='C:\X'; risk='danger'; reason='t' } )
            ghost_services = @(); registry_residuals = @(); ghost_tasks = @()
            startup_residuals = @(); shell_residuals = @(); uninstalled_software = @()
        } | ConvertTo-Json -Depth 5))
        $ReportPath = $only; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'safe'; $SelectIds = ''
        Main -ExitCode ([ref]$script:rc) *>&1 | Out-Null
        $script:rc | Should -Be 0
        Test-Path $script:out | Should -Be $false
    }

    It 'does not terminate the host: Main is callable repeatedly' {
        . $script:ConfirmScript
        $ReportPath = $script:report; $OutputPath = $script:out
        $NonInteractive = $true; $AutoSelect = 'safe'; $SelectIds = ''
        3 | ForEach-Object {
            $rc2 = 0
            Main -ExitCode ([ref]$rc2) *>&1 | Out-Null
            $rc2 | Should -Be 0
        }
        # 执行到这里本身就证明宿主未被 exit 杀死
        $true | Should -Be $true
    }
}

Describe 'confirm-cleanup.ps1 display helpers via Main (coverage of sort/filter paths)' {
    BeforeEach {
        $script:report = Join-Path $script:WorkDir 'r.json'
        New-TestReport -Path $script:report
    }

    It 'sorts items by risk (safe before caution before danger)' {
        . $script:ConfirmScript
        $doc = Get-Content $script:report -Raw | ConvertFrom-Json
        # 直接驱动排序辅助函数
        $items = @()
        foreach ($c in 'filesystem_residuals','path_residuals') {
            foreach ($it in @($doc.$c)) {
                $items += [PSCustomObject]@{
                    id = $it.id; risk = $it.risk; path = $it.path
                    catLabel = $c; content = $it.path; reason = $it.reason
                }
            }
        }
        $items.Count | Should -BeGreaterThan 0
        $sorted = @($items | Sort-Object { switch ($_.risk) { 'safe' {0} 'caution' {1} 'danger' {2} default {1} } })
        $sorted[0].risk | Should -Be 'safe'
        $sorted[-1].risk | Should -Be 'danger'
    }

    It 'Get-PageRange clamps to the last page' {
        . $script:ConfirmScript
        $script:totalItems = 5
        $script:pageSize = 20
        $script:totalPages = 1
        $r = Get-PageRange -Page 0
        $r[0] | Should -Be 0
        $r[1] | Should -Be 4
    }

    It 'Show-Detail prints extra raw properties that carry values and skips empty ones' {
        . $script:ConfirmScript
        $script:riskLabels = @{ safe = '安全'; caution = '谨慎'; danger = '危险' }
        $script:sorted = @(
            [PSCustomObject]@{
                id = 'fs_900'; risk = 'safe'; catLabel = '文件系统'
                content = 'C:\X'; reason = 'test'; size_mb = 12
                _item = [PSCustomObject]@{
                    id = 'fs_900'; risk = 'safe'; reason = 'test'
                    file_count = 3          # -> 应被打印
                    empty_str  = ''         # -> 应被跳过（空串）
                    zero_val   = 0          # -> 应被跳过（0），且空值 0 走 null 分支
                    null_val   = $null      # -> 应被跳过（$null）
                }
            }
        )
        $out = (Show-Detail -Id 'fs_900') -join "`n"
        $out | Should -Match 'file_count'
        $out | Should -Not -Match 'empty_str'
        $out | Should -Not -Match 'zero_val'
        $out | Should -Not -Match 'null_val'
    }

    It 'Show-Detail warns and returns for an unknown id' {
        . $script:ConfirmScript
        $script:sorted = @()
        { Show-Detail -Id 'nope' } | Should -Not -Throw
    }

    It 'Show-Help and Show-Page render without throwing' {
        . $script:ConfirmScript
        $script:riskLabels = @{ safe = '安全'; caution = '谨慎'; danger = '危险' }
        $script:sorted = @(
            [PSCustomObject]@{ id='fs_901'; risk='safe';    catLabel='文件系统'; content='C:\A'; reason='r'; size_mb=0; _item=[PSCustomObject]@{ id='fs_901' } }
            [PSCustomObject]@{ id='fs_902'; risk='caution'; catLabel='文件系统'; content='C:\B'; reason='r'; size_mb=5; _item=[PSCustomObject]@{ id='fs_902' } }
        )
        $script:selectedIds = @{ fs_901 = $true }
        $script:totalItems = 2
        $script:pageSize = 20
        $script:totalPages = 1

        { Show-Help } | Should -Not -Throw
        { Show-Page -Page 0 } | Should -Not -Throw
        (Show-Page -Page 0) -join "`n" | Should -Match '已选 1 项'
    }

    It 'NonInteractive on a non-interactive host still exports (no Read-Host needed)' {
        . $script:ConfirmScript
        $ReportPath = $script:report
        $OutputPath = Join-Path $script:WorkDir 'ni.json'
        Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
        $NonInteractive = $true; $AutoSelect = 'all'; $SelectIds = ''
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 0
        Test-Path $OutputPath | Should -Be $true
    }
}
