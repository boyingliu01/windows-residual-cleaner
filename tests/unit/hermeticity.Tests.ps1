# =============================================================================
# hermeticity.Tests.ps1 — 套件必须能在「干净环境」下真跑，而不是静默塌掉
# =============================================================================
# 背景 (Sprint 2026-10-01-01, blocker B1):
#   clean-residuals.ps1 的 Main 内含 5 处 `exit`，且 Test-AdminPrivilege 有 `exit 2`。
#   在新克隆 / CI / worktree 中（backup-* 是 gitignored，必然缺失），
#   任何 dot-source + 进程内调用 Main 的测试都会命中 `exit 1`，
#   导致 Pester 5.7.1 在收尾时崩溃 (Pester.psm1:4984 $run.Containers.Add)，
#   **整个套件静默消失**，测试数显示为空。
#
#   本文件断言的是「契约」而不是「症状」：
#     Main 必须 *返回* 退出码，绝不能调用 exit。
#
# 这些测试在修复前必须 FAIL（RED），修复后 PASS（GREEN）。

Describe 'Main returns exit code instead of calling exit (hermeticity contract)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
        $script:CleanScript = Join-Path $script:RepoRoot 'references\scripts\clean-residuals.ps1'
        $script:ConfirmScript = Join-Path $script:RepoRoot 'references\scripts\confirm-cleanup.ps1'
    }

    Context 'static: Main must not contain bare exit' {

        It 'clean-residuals.ps1 Main contains no `exit <code>` statement inside the function body' {
            $lines = Get-Content $script:CleanScript
            $mainStart = ($lines | Select-String -Pattern '^function Main' | Select-Object -First 1).LineNumber
            $guardLine = ($lines | Select-String -Pattern 'InvocationName -ne' | Select-Object -First 1).LineNumber
            $mainStart | Should -Not -BeNullOrEmpty -Because 'function Main must exist'
            $guardLine | Should -Not -BeNullOrEmpty -Because 'the execution guard must exist'

            $exitsInMain = @()
            for ($i = $mainStart; $i -lt ($guardLine - 1); $i++) {
                if ($lines[$i] -match '^\s*exit(\s+\d+)?\s*$') {
                    $exitsInMain += "line $($i + 1): $($lines[$i].Trim())"
                }
            }
            # 这是本次 blocker 的直接根因
            $exitsInMain | Should -BeNullOrEmpty -Because "Main must return a code, not exit; found: $($exitsInMain -join '; ')"
        }

        It 'Test-AdminPrivilege does not call exit directly' {
            $lines = Get-Content $script:CleanScript
            $fnStart = ($lines | Select-String -Pattern '^function Test-AdminPrivilege' | Select-Object -First 1).LineNumber
            $fnStart | Should -Not -BeNullOrEmpty
            # 函数体到下一個 top-level function 或 function Main 为止
            $end = ($lines | Select-String -Pattern '^function Main' | Select-Object -First 1).LineNumber

            $exits = @()
            for ($i = $fnStart; $i -lt ($end - 1); $i++) {
                if ($lines[$i] -match '^\s*exit(\s+\d+)?\s*$') {
                    $exits += "line $($i + 1): $($lines[$i].Trim())"
                }
            }
            $exits | Should -BeNullOrEmpty -Because "Test-AdminPrivilege must not exit; found: $($exits -join '; ')"
        }

        It 'clean-residuals.ps1 execution guard propagates the exit code and avoids exit (Main)' {
            # 只检查**可执行代码**，不检查解释性的注释
            $codeLines = @(Get-Content $script:CleanScript | Where-Object { $_ -notmatch '^\s*#' })
            $code = $codeLines -join "`n"
            # `exit (Main)` 会吞掉 Main 的全部 Write-Output（实测），必须用 [ref] 形式
            $code | Should -Not -Match 'exit\s*\(\s*Main\s*\)' -Because 'exit (Main) discards Main''s stdout'
            $code | Should -Match 'Main\s+-ExitCode\s+\(\[ref\]\$exitCode\)' -Because 'the guard must pass a [ref] to receive the exit code'
            $code | Should -Match 'exit\s+\$exitCode' -Because 'the guard must exit with the returned code'
        }

        It 'Main declares a [ref]$ExitCode parameter (not a return-value contract)' {
            $codeLines = @(Get-Content $script:CleanScript | Where-Object { $_ -notmatch '^\s*#' })
            $code = $codeLines -join "`n"
            # 函数返回整数会写进输出流，污染调用方输出断言
            $code | Should -Match 'function Main\s*\{[\s\S]{0,600}?param\(\[ref\]\$ExitCode\)'
        }

        It 'confirm-cleanup.ps1 Main contains no bare exit statement' {
            $lines = Get-Content $script:ConfirmScript
            $mainStart = ($lines | Select-String -Pattern '^function Main' | Select-Object -First 1).LineNumber
            $guardLine = ($lines | Select-String -Pattern 'InvocationName -ne' | Select-Object -First 1).LineNumber
            $mainStart | Should -Not -BeNullOrEmpty
            $guardLine | Should -Not -BeNullOrEmpty

            $exitsInMain = @()
            for ($i = $mainStart; $i -lt ($guardLine - 1); $i++) {
                if ($lines[$i] -match '^\s*exit(\s+\d+)?\s*$') {
                    $exitsInMain += "line $($i + 1): $($lines[$i].Trim())"
                }
            }
            $exitsInMain | Should -BeNullOrEmpty -Because "confirm-cleanup Main must return, not exit; found: $($exitsInMain -join '; ')"
        }
    }

    Context 'behavioural: Main is safe to call in-process on error paths' {

        BeforeAll {
            $script:WorkDir = Join-Path $env:TEMP ('wrc-hermetic-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
            $script:MissingPath = Join-Path $script:WorkDir 'definitely-not-here.json'
        }
        AfterAll {
            if (Test-Path $script:WorkDir) { Remove-Item $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'returns nonzero (does not exit) when the report file is missing' {
            # 直接构造场景：非管理员环境下 Main 会先返回 2（权限门），
            # 所以这里断言**非零**且明确不是 0，并把「报告缺失 => 1」的行为
            # 通过第二个用例（ConfirmFile 缺失）在已 mock 的上下文里验证。
            . $script:CleanScript
            $ReportPath = $script:MissingPath
            $ConfirmFile = ''
            $Mode = 'A'
            $DryRun = $true
            $WhitelistPath = $script:MissingPath

            $rc = 0
            # 修复前：这里会 exit 并终止宿主（测试进程崩溃）
            # 修复后：正常返回并把退出码写进 $rc（当前会话非管理员 => 2）
            Main -ExitCode ([ref]$rc) *>&1 | Out-Null
            $rc | Should -BeGreaterThan 0 -Because 'Main must return a nonzero code instead of exiting'
        }

        It 'returns 1 when the report file exists but cannot be parsed' {
            . $script:CleanScript
            Mock Test-AdminPrivilege { return $true }

            $badReport = Join-Path $script:WorkDir 'bad.json'
            [IO.File]::WriteAllText($badReport, '{ this is not json')

            $ReportPath = $badReport
            $ConfirmFile = ''
            $Mode = 'A'
            $DryRun = $true
            $WhitelistPath = $script:MissingPath

            $rc = 0
            Main -ExitCode ([ref]$rc) *>&1 | Out-Null
            $rc | Should -Be 1 -Because 'an unparseable report must fail with the generic-error code'
        }

        It 'returns nonzero (does not exit) when ConfirmFile is missing' {
            . $script:CleanScript
            Mock Test-AdminPrivilege { return $true }
            Mock Get-CimInstance { return $null }
            Mock Get-ScheduledTask { return $null }

            $report = Join-Path $script:WorkDir 'r.json'
            [IO.File]::WriteAllText($report, (@{
                scan_time = '2026-10-01T00:00:00'
                summary = @{ total_residuals = 0; safe = 0; caution = 0; danger = 0; estimated_space_recoverable_mb = 0 }
                filesystem_residuals = @(); registry_residuals = @(); ghost_services = @()
                ghost_tasks = @(); startup_residuals = @(); shell_residuals = @(); path_residuals = @()
                uninstalled_software = @()
            } | ConvertTo-Json -Depth 5))

            $ReportPath = $report
            $ConfirmFile = $script:MissingPath
            $Mode = 'D'
            $DryRun = $false
            $WhitelistPath = $script:MissingPath

            $rc = 0
            Main -ExitCode ([ref]$rc) *>&1 | Out-Null
            $rc | Should -Be 1
        }

        It 'does not pollute the output stream with the exit code (returns via [ref], not return-value)' {
            # 解析 AST 取 Main 的函数体，比字符串匹配可靠
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CleanScript, [ref]$tokens, [ref]$errors)
            $mainFn = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Main'
            }, $true) | Select-Object -First 1
            $mainFn | Should -Not -BeNullOrEmpty

            # Main 内不得出现 ExitStatementAst（会杀死 Pester 宿主）
            $exits = $mainFn.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.ExitStatementAst]
            }, $true)
            @($exits).Count | Should -Be 0 -Because 'exit inside Main kills the in-process Pester host'

            # Main 内不得出现 `return <数字>`（会把 int 写进输出流，污染调用方断言）
            $retNums = @($mainFn.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.ReturnStatementAst] -and
                $null -ne $n.Pipeline -and
                $n.Pipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $n.Pipeline.PipelineElements[0].Expression -is [System.Management.Automation.Language.ConstantExpressionAst] -and
                $n.Pipeline.PipelineElements[0].Expression.Value -is [int]
            }, $true))
            $retNums.Count | Should -Be 0 -Because 'returning an int would leak it into the output stream'
        }
    }
}
