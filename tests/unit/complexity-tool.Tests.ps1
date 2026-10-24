#Requires -Version 5.1
<#
.SYNOPSIS
    Guard tests for tools/Measure-PowerShellComplexity.ps1 (Gate 3's PowerShell arm).

.DESCRIPTION
    Gate 3 skipped PowerShell entirely until 2026-10-24 ("no PowerShell tool
    available"). It now measures cyclomatic complexity from the PowerShell AST.
    That makes the measurement itself a quality contract, so it needs its own
    tests: a complexity gate that miscounts is worse than no complexity gate,
    because it makes a claim.

    These tests pin the counting semantics rather than the project's numbers:
    a function's CCN must be exactly 1 + its decision points, and it must be
    derived from the AST (so `if` inside a string does not count).
#>

Describe 'Measure-PowerShellComplexity (Gate 3 PowerShell arm)' {
    BeforeAll {
        $script:Tool = Join-Path $PSScriptRoot '..\..\tools\Measure-PowerShellComplexity.ps1'
        $script:ToolExists = Test-Path -LiteralPath $script:Tool

        function Invoke-ComplexityTool {
            param([string[]]$Paths, [int]$Threshold = 5)
            $output = & $script:Tool -Path $Paths -Threshold $Threshold 2>&1
            $map = @{}
            foreach ($line in @($output)) {
                if ($line -match '^(\w+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
            }
            return [pscustomobject]@{
                Raw      = @($output)
                Measured = Get-MapInt -Map $map -Key 'functions_measured'
                Max      = Get-MapInt -Map $map -Key 'max_ccn'
                Over     = Get-MapInt -Map $map -Key 'over_threshold'
                Lines    = @($output)
            }
        }

        function Get-MapInt {
            param([hashtable]$Map, [string]$Key)
            if ($Map.ContainsKey($Key)) { return [int]$Map[$Key] }
            return -1
        }

        function New-TempScript {
            param([string]$Body)
            $path = Join-Path $TestDrive ('ccn-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
            return $path
        }
    }

    It '量测工具入库（否则 Gate 3 的 PowerShell 分支退回 SKIP）' {
        $script:ToolExists | Should -BeTrue -Because 'tools/Measure-PowerShellComplexity.ps1 是 Gate 3 PowerShell 分支的唯一测量来源；文件缺席时适配器会诚实地退回 SKIP，复杂度就又不被测了'
    }

    It 'ratchet 基线入库且无 BOM（node 的 JSON.parse 拒绝 BOM）' {
        $baselinePath = Join-Path $PSScriptRoot '..\..\.xp-gate-powershell-ccn-baseline.json'
        Test-Path -LiteralPath $baselinePath | Should -BeTrue -Because 'Gate 3 的 PowerShell ratchet 依赖这份基线；缺席时门禁只能 SKIP，复杂度就又不受约束了'
        # 2026-10-24 实测：`Set-Content -Encoding UTF8` 在 PS 5.1 下会写 BOM，
        # 而消费方是 node 的 JSON.parse，它直接抛
        #   SyntaxError: Unexpected token '', "{" is not valid JSON
        # 于是一份「提交上去但读不了」的基线会把 ratchet 变成 WARN。
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $baselinePath).Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
            Should -BeFalse -Because '基线文件不得带 UTF-8 BOM；带 BOM 时 node 侧解析失败，ratchet 静默降级为 WARN'
        $doc = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
        @($doc.entries).Count | Should -BeGreaterThan 0 -Because '基线里必须有存量条目，否则「基线存在」只是空壳'
        foreach ($e in @($doc.entries)) {
            $e.file | Should -Match '\.ps1$'
            [int]$e.ccn | Should -BeGreaterThan 0
            [string]::IsNullOrWhiteSpace([string]$e.function) | Should -BeFalse
        }
    }

    It 'ratchet 基线里的每条都对应真实存在的文件（防止重构后留下死条目）' {
        $baselinePath = Join-Path $PSScriptRoot '..\..\.xp-gate-powershell-ccn-baseline.json'
        Test-Path -LiteralPath $baselinePath | Should -BeTrue
        $doc = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
        $missing = @()
        foreach ($e in @($doc.entries)) {
            $abs = Join-Path (Join-Path $PSScriptRoot '..\..') ([string]$e.file -replace '/', '\')
            if (-not (Test-Path -LiteralPath $abs)) { $missing += [string]$e.file }
        }
        $missing | Should -BeNullOrEmpty -Because "基线引用了不存在的文件：$($missing -join ', ')（文件改名/删除后必须重跑 tools/Update-ComplexityBaseline.ps1）"
    }

    It 'ratchet 基线被 git 跟踪（否则 clone/CI 上不存在，门禁静默退回 SKIP）' {
        # 2026-10-24 CI run 40100344167 实测：`.gitignore` 的 `*.json` 兜底规则把
        # .xp-gate-powershell-ccn-baseline.json 一起忽略了。于是它存在于**每台开发机**
        # 上，却不在**任何 clone** 里、也不在 CI 里。本文件的「基线入库」用例因此
        # 本地绿、CI 红——同一份提交两种结果，差别只在「本机留着 git 没带走的产物」。
        #
        # 上面那条用例只断言文件「存在」。存在 ≠ 入库：真正的契约是**新 clone 里也有**，
        # 而唯一可靠的判据是 `git ls-files`。这正是本条要钉住的东西。
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) { Set-ItResult -Skipped -Because 'git 不在 PATH 上，无法判定跟踪状态'; return }
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
        $tracked = & git -C $root ls-files --error-unmatch '.xp-gate-powershell-ccn-baseline.json' 2>$null
        $LASTEXITCODE | Should -Be 0 -Because "基线必须被 git 跟踪，否则新 clone/CI 上不存在，Gate 3 的棘轮退化为 SKIP，PowerShell 复杂度维度静默消失。若被 .gitignore 挡住，请加 '!.xp-gate-powershell-ccn-baseline.json'"
        $tracked | Should -Not -BeNullOrEmpty
    }

    It '无分支函数的 CCN 恰为 1' {
        $f = New-TempScript @'
function F { return 42 }
'@
        $r = Invoke-ComplexityTool -Paths @($f)
        $r.Measured | Should -Be 1
        $r.Max | Should -Be 1 -Because '没有任何决策点的函数，圈复杂度就是 1'
        $r.Over | Should -Be 0
    }

    It '每个决策点恰好 +1（if / elseif / 循环 / catch / -and / -or）' {
        # 1 (base) + if + elseif + and + for + foreach + while + catch + or = 9
        $f = New-TempScript @'
function G {
    param($x, $y)
    if ($x -and $y) { }
    elseif ($x) { }
    for ($i = 0; $i -lt 2; $i++) { }
    foreach ($j in @(1)) { }
    while ($false) { }
    try { } catch { }
    if ($x -or $y) { }
}
'@
        $r = Invoke-ComplexityTool -Paths @($f)
        $r.Max | Should -Be 9 -Because '函数 G 有 8 个决策点，CCN 必须是 1+8=9'
    }

    It 'switch 的每个 case 各算一个决策点' {
        $f = New-TempScript @'
function S {
    param($v)
    switch ($v) {
        'a' { }
        'b' { }
        default { }
    }
}
'@
        $r = Invoke-ComplexityTool -Paths @($f)
        # base 1 + 3 cases
        $r.Max | Should -Be 4 -Because 'switch 的三个分支（含 default）各是一条独立路径'
    }

    It '嵌套 switch 不被重复计数（外层只按自己的 clause 计）' {
        # 2026-10-24 实测：初版把 SwitchStatementAst 本身算 +1、又按 clause 累加，
        # 而内层 SwitchStatementAst 已在外层 FindAll 的结果里，于是嵌套 switch
        # 被计两遍。修法是「switch 只按自己的 clause 计数」。
        $f = New-TempScript @'
function N {
    param($v, $w)
    switch ($v) {
        'a' {
            switch ($w) {
                'x' { }
                'y' { }
            }
        }
        'b' { }
    }
}
'@
        $r = Invoke-ComplexityTool -Paths @($f)
        # 外层 2 clause + 内层 2 clause = 4 决策点 -> CCN 5
        $r.Max | Should -Be 5 -Because "外层 switch 有 2 个 clause、内层 2 个，共 4 个决策点，CCN 必须是 5；实测 $($r.Max) 说明有重复计数"
    }

    It 'switch 的 default 单独算一个决策点' {
        $f = New-TempScript @'
function D {
    param($v)
    switch ($v) {
        'a' { }
        default { }
    }
}
'@
        $r = Invoke-ComplexityTool -Paths @($f)
        # PS 的 SwitchStatementAst 把 default 放在 .Default 属性，不在 .Clauses 里。
        $r.Max | Should -Be 3 -Because 'Clauses 只有 a 一个，default 在 .Default 属性上；漏掉它就是 2'
    }

    It '字符串与注释里的 if 不计入（AST 而非正则）' {        $f = New-TempScript @'
function T {
    # if if if if if
    $s = 'if if if if if'
    return $s
}
'@
        $r = Invoke-ComplexityTool -Paths @($f)
        $r.Max | Should -Be 1 -Because '注释和字符串里的 if 不是决策点；正则实现会在这里数出 10'
    }

    It '阈值是严格大于（CCN == 阈值不算超标）' {
        $f = New-TempScript @'
function U {
    param($a, $b)
    if ($a) { }
    if ($b) { }
}
'@
        # CCN = 1 + 2 = 3
        $atThreshold = Invoke-ComplexityTool -Paths @($f) -Threshold 3
        $atThreshold.Over | Should -Be 0 -Because 'CCN 恰好等于阈值时不应判超标'
        $below = Invoke-ComplexityTool -Paths @($f) -Threshold 2
        $below.Over | Should -Be 1 -Because 'CCN 3 大于阈值 2 时必须判超标'
    }

    It '对真实产品脚本能量出结果（不是空跑）' {
        $productFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '..\..\references\scripts') -Filter '*.ps1' -Recurse |
            ForEach-Object { $_.FullName })
        $productFiles.Count | Should -BeGreaterThan 0
        $r = Invoke-ComplexityTool -Paths $productFiles -Threshold 15
        $r.Measured | Should -BeGreaterThan 50 -Because "本仓库 references/scripts 的函数总数量级在百位；量出 $($r.Measured) 个说明解析大面积失败"
        $r.Max | Should -BeGreaterThan 0
        # 一个靠谱的复杂度工具必须能指出本仓库最复杂的那个函数。
        ($r.Lines -join "`n") | Should -Match 'OVER .*ccn=' -Because '本仓库确实有 CCN > 15 的函数；一个都报不出来说明阈值解析错了'
    }

    It 'PowerShell 5.1 能加载（TernaryExpressionAst 是 7+ 独有，不能写成裸类型字面量）' {
        # 2026-10-24 实测：初版在 $decisionTypes 里写了裸
        # [System.Management.Automation.Language.TernaryExpressionAst]。
        # PS 5.1 在 PARSE 期解析类型字面量，于是整个脚本加载失败：
        #   Unable to find type [System.Management.Automation.Language.TernaryExpressionAst]
        # 而 PS 5.1 是本项目运行时基线——「只在 pwsh 7 上能跑」的门禁工具
        # 等于没有工具。这里用 PS 5.1 起子进程做真实加载断言。
        $powershell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powershell51)) {
            Set-ItResult -Inconclusive -Because 'PS 5.1 可执行文件不在标准位置（非 Windows 或精简镜像）'
            return
        }
        $f = New-TempScript 'function V { return 1 }'
        $out = & $powershell51 -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -Command "& '$($script:Tool)' -Path @('$f') -Threshold 5" 2>&1
        ($out -join "`n") | Should -Match 'functions_measured=1' -Because "PS 5.1 下工具必须能加载并量出结果；实际输出：$($out -join ' | ')"
        ($out -join "`n") | Should -Not -Match 'Unable to find type' -Because '类型字面量必须在 PS 5.1 下也解析得通'
    }
}
