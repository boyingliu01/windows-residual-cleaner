# run-all.ps1 / create-restore-point.ps1 的非管理员与失败传播路径。
#
# 这些分支原本完全无法覆盖：Main 内的 exit 会杀死 Pester 宿主（ADR-001 前）。
# ADR-001 之后可进程内调用 Main，并用 Mock 驱动权限门与子进程失败。

BeforeAll {
    $script:RunAllScript = "$PSScriptRoot\..\..\references\scripts\run-all.ps1"
    $script:RestoreScript = "$PSScriptRoot\..\..\references\scripts\create-restore-point.ps1"
}

Describe 'run-all.ps1 Test-AdminPrivilege' {
    BeforeEach { . $script:RunAllScript }

    It 'returns a boolean' {
        Test-AdminPrivilege | Should -BeOfType [bool]
    }

    It 'returns false with -Mandatory in a non-admin session (no exit)' {
        # 本会话是非管理员；关键点是它 return $false 而不是 exit 2
        Test-AdminPrivilege -Mandatory | Should -Be $false
    }

    It 'does not terminate the host when called' {
        # 能执行到这里就证明没有 exit
        { Test-AdminPrivilege -Mandatory | Out-Null } | Should -Not -Throw
    }
}

Describe 'run-all.ps1 Main permission gate' {
    It 'returns 2 and does not run any step when not admin' {
        . $script:RunAllScript
        # 关键顺序：脚本 dot-source 会把 Test-AdminPrivilege 定义到当前作用域，
        # 因此替身必须在 dot-source **之后**再定义，否则会被覆盖。
        function Test-AdminPrivilege { param([switch]$Mandatory) return $false }
        $rc = 0
        Main -ExitCode ([ref]$rc) -SkipRestorePoint *>&1 | Out-Null
        $rc | Should -Be 2
    }

    It 'ExitCode param is a [ref] and optional' {
        . $script:RunAllScript
        $cmd = Get-Command Main
        $cmd.Parameters.ContainsKey('ExitCode') | Should -Be $true
        $cmd.Parameters['ExitCode'].ParameterType.Name | Should -Be 'PSReference'
    }
}

Describe 'run-all.ps1 step failure propagation' {
    It 'relays the failing step exit code through [ref] (no Object[] bug)' {
        . $script:RunAllScript
        # 管理员门放行；把子进程启动替换成「失败」的替身（ExitCode=7）。
        # 二者都必须在 dot-source 之后定义，才能遮蔽脚本内的同名函数。
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        function Start-Process {
            param(
                [string]$FilePath, [object]$ArgumentList,
                [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow
            )
            return [PSCustomObject]@{ ExitCode = 7 }
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) -SkipRestorePoint *>&1 | Out-Null
        # 第一步（build-installed-index）以 7 失败 → Main 必须回传 7
        $rc | Should -Be 7
    }

    It 'returns 0 when every step succeeds' {
        . $script:RunAllScript
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        function Start-Process {
            param(
                [string]$FilePath, [object]$ArgumentList,
                [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow
            )
            return [PSCustomObject]@{ ExitCode = 0 }
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) -SkipRestorePoint *>&1 | Out-Null
        $rc | Should -Be 0
    }
}

Describe 'create-restore-point.ps1 Test-AdminPrivilege' {
    BeforeEach { . $script:RestoreScript }

    It 'returns false with -Mandatory in a non-admin session (no exit)' {
        Test-AdminPrivilege -Mandatory | Should -Be $false
    }

    It 'returns a boolean without -Mandatory' {
        Test-AdminPrivilege | Should -BeOfType [bool]
    }
}

Describe 'create-restore-point.ps1 Main permission gate' {
    It 'returns 2 and skips backup work when not admin' {
        . $script:RestoreScript
        # 替身必须在 dot-source 之后定义（脚本内同名函数会遮蔽之前的定义）
        function Test-AdminPrivilege { param([switch]$Mandatory) return $false }
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 2
    }

    It 'ExitCode param is a [ref] and optional' {
        . $script:RestoreScript
        $cmd = Get-Command Main
        $cmd.Parameters.ContainsKey('ExitCode') | Should -Be $true
        $cmd.Parameters['ExitCode'].ParameterType.Name | Should -Be 'PSReference'
    }
}

Describe 'run-all.ps1 pipeline step-abort propagation' {
    # 每个步骤的 `if ($rc -ne 0) { & $setRc $rc; return }` 都必须在**该步骤**失败时中止，
    # 且把该步骤的退出码原样上抛。
    #
    # 两个关键点（均为实测踩坑）：
    # 1. 替身必须在 dot-source 之后、**同一局部作用域**定义 —— `function global:X`
    #    会被脚本自身的定义遮蔽。
    # 2. `Invoke-Step` 传的是 `-File "`"$ScriptPath`""`（带字面引号），所以从 ArgumentList
    #    里取脚本名必须 `Trim('"')`；否则 `-like '*.ps1'` 一个都匹配不上，
    #    `$script:started` 里只会进一个空串。
    BeforeEach {
        . $script:RunAllScript
        # admin 检查放行，否则 Main 会在权限门提前 return 2
        function Test-AdminPrivilege { param([switch]$Mandatory) return $true }
        $script:started = [System.Collections.Generic.List[string]]::new()

        function Get-StepNameFromArgs {
            param([object]$ArgumentList)
            $hit = @($ArgumentList) | ForEach-Object { "$_".Trim('"') } |
                Where-Object { $_ -like '*.ps1' } | Select-Object -Last 1
            if ($hit) { return [System.IO.Path]::GetFileName($hit) }
            return ''
        }
    }

    It 'aborts at step 1 (create-restore-point) and relays its exit code' {
        $script:failAt = 'create-restore-point.ps1'
        function Start-Process {
            param([string]$FilePath, [object]$ArgumentList, [switch]$NoNewWindow,
                  [switch]$Wait, [switch]$PassThru, [string]$RedirectStandardOutput,
                  [string]$RedirectStandardError)
            $name = Get-StepNameFromArgs -ArgumentList $ArgumentList
            $script:started.Add($name)
            $code = if ($name -eq $script:failAt) { 9 } else { 0 }
            return [PSCustomObject]@{ ExitCode = $code }
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 9
        $script:started.Count | Should -Be 1
        $script:started[0] | Should -Be 'create-restore-point.ps1'
    }

    It 'aborts at a middle step (scan-uninstalled) and relays its exit code' {
        $script:failAt = 'scan-uninstalled.ps1'
        function Start-Process {
            param([string]$FilePath, [object]$ArgumentList, [switch]$NoNewWindow,
                  [switch]$Wait, [switch]$PassThru, [string]$RedirectStandardOutput,
                  [string]$RedirectStandardError)
            $name = Get-StepNameFromArgs -ArgumentList $ArgumentList
            $script:started.Add($name)
            $code = if ($name -eq $script:failAt) { 4 } else { 0 }
            return [PSCustomObject]@{ ExitCode = $code }
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 4
        # create-restore-point + build-installed-index 已跑，scan-uninstalled 失败即止
        $script:started.Count | Should -Be 3
        $script:started[2] | Should -Be 'scan-uninstalled.ps1'
    }

    It 'aborts at the final step (generate-report) after all others ran' {
        $script:failAt = 'generate-report.ps1'
        function Start-Process {
            param([string]$FilePath, [object]$ArgumentList, [switch]$NoNewWindow,
                  [switch]$Wait, [switch]$PassThru, [string]$RedirectStandardOutput,
                  [string]$RedirectStandardError)
            $name = Get-StepNameFromArgs -ArgumentList $ArgumentList
            $script:started.Add($name)
            $code = if ($name -eq $script:failAt) { 5 } else { 0 }
            return [PSCustomObject]@{ ExitCode = $code }
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 5
        $script:started.Count | Should -Be 6
        $script:started[5] | Should -Be 'generate-report.ps1'
    }

    It 'aborts at each intermediate step, never running later steps' -TestCases @(
        @{ FailAt = 'build-installed-index.ps1';           ExpectedCount = 2; Code = 11 }
        @{ FailAt = 'scan-filesystem-residuals.ps1';       ExpectedCount = 4; Code = 12 }
        @{ FailAt = 'scan-residuals.ps1';                  ExpectedCount = 5; Code = 13 }
    ) {
        param($FailAt, $ExpectedCount, $Code)
        $script:failAt = $FailAt
        function Start-Process {
            param([string]$FilePath, [object]$ArgumentList, [switch]$NoNewWindow,
                  [switch]$Wait, [switch]$PassThru, [string]$RedirectStandardOutput,
                  [string]$RedirectStandardError)
            $name = Get-StepNameFromArgs -ArgumentList $ArgumentList
            $script:started.Add($name)
            $c = if ($name -eq $script:failAt) { $Code } else { 0 }
            return [PSCustomObject]@{ ExitCode = $c }
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be $Code
        $script:started.Count | Should -Be $ExpectedCount
        $script:started[-1] | Should -Be $FailAt
    }

    It 'runs all six steps in order and returns 0 when every step succeeds' {
        function Start-Process {
            param([string]$FilePath, [object]$ArgumentList, [switch]$NoNewWindow,
                  [switch]$Wait, [switch]$PassThru, [string]$RedirectStandardOutput,
                  [string]$RedirectStandardError)
            $script:started.Add((Get-StepNameFromArgs -ArgumentList $ArgumentList))
            $script:capturedExe = $FilePath
            return [PSCustomObject]@{ ExitCode = 0 }
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 0
        $script:started.Count | Should -Be 6
        ($script:started -join ',') | Should -Be (
            'create-restore-point.ps1,build-installed-index.ps1,scan-uninstalled.ps1,' +
            'scan-filesystem-residuals.ps1,scan-residuals.ps1,generate-report.ps1')
        # 本机装了 pwsh，所以 $psExe 应为 'pwsh'
        $script:capturedExe | Should -Be 'pwsh'
    }

    It 'falls back to the absolute PS 5.1 path when pwsh is not on PATH' {
        # 覆盖 run-all.ps1:48 的 else 分支。
        # 注意：`-ErrorAction` 是**通用参数**，不能在 param() 里重复声明
        # （会报 "A parameter with the name 'ErrorAction' was defined multiple times"）。
        # 只声明位置参数 $Name 即可，通用参数由 PowerShell 自动接住。
        function Get-Command {
            param([Parameter(Position = 0)][string]$Name)
            if ($Name -eq 'pwsh') { return $null }
            return Microsoft.PowerShell.Core\Get-Command -Name $Name
        }
        function Start-Process {
            param([string]$FilePath, [object]$ArgumentList, [switch]$NoNewWindow,
                  [switch]$Wait, [switch]$PassThru, [string]$RedirectStandardOutput,
                  [string]$RedirectStandardError)
            $script:capturedExe = $FilePath
            $script:started.Add((Get-StepNameFromArgs -ArgumentList $ArgumentList))
            return [PSCustomObject]@{ ExitCode = 0 }
        }
        $rc = 0
        Main -ExitCode ([ref]$rc) *>&1 | Out-Null
        $rc | Should -Be 0
        $script:capturedExe | Should -Be "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    It 'exits via the guard with the code Main relayed (guard path)' {
        # 覆盖 run-all.ps1 末尾执行守卫的 135-137 行：以子进程 -File 方式真正执行脚本，
        # 非管理员下应 exit 2（权限门），且输出不含 "exit" 之外的异常。
        $outFile = Join-Path $env:TEMP ('wrc-ra-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        try {
            $p = Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:RunAllScript`"") `
                -Wait -PassThru -NoNewWindow `
                -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
            # 非管理员 → Main 回传 2 → 守卫 exit 2
            $p.ExitCode | Should -Be 2
        } finally {
            Remove-Item $outFile, "$outFile.err" -Force -ErrorAction SilentlyContinue
        }
    }
}
