# Measure cyclomatic complexity of PowerShell functions from the AST.
#
# Why this exists: `lizard` (Gate 3's default tool) does not understand PowerShell,
# and PSScriptAnalyzer has no complexity rule, so a PowerShell-primary repo gets
# SKIPPED on the complexity dimension while the score implies it was covered.
#
# Cyclomatic complexity = 1 + number of decision points. In PowerShell the decision
# points are AST nodes, which means this is exact and transitive-equivalent to what
# lizard counts for other languages: each `if`/`elseif`/`switch` case/loop/catch/
# `-and`/`-or`/ternary adds one independent path.
#
# The count is computed from the AST, NOT by regex, so strings and comments that
# merely contain the word "if" are not counted.
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Path,

    [int]$Threshold = 5
)

$ErrorActionPreference = 'Stop'

function Get-DecisionNodeTypeSet {
    # StatementAst subtypes that each add exactly one independent path.
    #
    # NOTE the runtime type lookups: `TernaryExpressionAst` only exists in
    # PowerShell 7+, and a bare type literal (`[X]`) is resolved at PARSE time,
    # so naming it unconditionally makes this whole script fail to load on
    # PowerShell 5.1 -- which is this repo's runtime baseline. Over there the
    # ternary operator does not exist either, so the correct behaviour is simply
    # "no ternary nodes to count". Resolve by name instead of by literal.
    $names = @(
        'System.Management.Automation.Language.IfStatementAst',
        'System.Management.Automation.Language.ForStatementAst',
        'System.Management.Automation.Language.ForEachStatementAst',
        'System.Management.Automation.Language.WhileStatementAst',
        'System.Management.Automation.Language.DoWhileStatementAst',
        'System.Management.Automation.Language.DoUntilStatementAst',
        'System.Management.Automation.Language.TernaryExpressionAst',
        'System.Management.Automation.Language.CatchClauseAst'
    )
    $resolved = @(
        foreach ($n in $names) {
            $t = $n -as [type]
            if ($null -ne $t) { $t }
        }
    )
    return $resolved
}

function Test-ShortCircuitOperator {
    param([string]$Operator)
    # `-and` / `-or` (and their case-insensitive/bitwise spellings) each add a path.
    return @('And', 'Or', 'Iand', 'Ior', 'Xor') -contains $Operator
}

function Get-SwitchClauseCount {
    param([System.Management.Automation.Language.SwitchStatementAst]$Switch)
    # `switch` is counted by its CLAUSES, not as a single node: each clause is an
    # independent path. Measured AST shape (PS 5.1 and pwsh 7 agree): a
    # SwitchStatementAst with `'a'{}, 'b'{}, default{}` exposes Clauses.Count=2 --
    # `default` is NOT in Clauses, it is the separate `Default` property.
    # Counting the node itself plus each clause would also double-count a nested
    # switch, because the inner SwitchStatementAst is already among the nodes we
    # walk. Count clauses only: a one-clause switch contributes 1, and `default`
    # contributes 1.
    $count = @($Switch.Clauses).Count
    if ($null -ne $Switch.Default) { $count++ }
    return $count
}

function Get-DecisionPointCount {
    param([System.Management.Automation.Language.Ast]$Ast)

    $decisionTypes = Get-DecisionNodeTypeSet
    $count = 0
    # `$Ast.FindAll` walks the whole subtree; predicate is evaluated per node.
    foreach ($node in $Ast.FindAll({ param($n) $true }, $true)) {
        $count += Get-NodeDecisionWeight -Node $node -DecisionTypes $decisionTypes
    }
    return $count
}

function Get-NodeDecisionWeight {
    # Returns how many independent paths this single AST node contributes:
    # 0 (not a decision), 1 (a normal decision node), or n (a switch's clauses).
    param(
        [System.Management.Automation.Language.Ast]$Node,
        [object[]]$DecisionTypes
    )
    if ($Node -is [System.Management.Automation.Language.SwitchStatementAst]) {
        return Get-SwitchClauseCount -Switch $Node
    }
    if (Test-NodeTypeMatch -Node $Node -Types $DecisionTypes) { return 1 }
    if (Test-ShortCircuitNode -Node $Node) { return 1 }
    return 0
}

function Test-NodeTypeMatch {
    param(
        [System.Management.Automation.Language.Ast]$Node,
        [object[]]$Types
    )
    foreach ($t in $Types) {
        if ($Node -is $t) { return $true }
    }
    return $false
}

function Test-ShortCircuitNode {
    param([System.Management.Automation.Language.Ast]$Node)
    if ($Node -isnot [System.Management.Automation.Language.BinaryExpressionAst]) { return $false }
    return Test-ShortCircuitOperator -Operator ([string]$Node.Operator)
}

function Get-FunctionComplexity {
    param([string]$FilePath)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $FilePath).Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        # A file we cannot parse is a real problem, but it is Gate 1's job to
        # report it; here we simply cannot measure it.
        return @()
    }
    $functions = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true)
    return @(
        foreach ($fn in $functions) {
            [pscustomobject]@{
                file       = $FilePath
                function   = $fn.Name
                start_line = $fn.Extent.StartLineNumber
                ccn        = 1 + (Get-DecisionPointCount -Ast $fn.Body)
            }
        }
    )
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($file in $Path) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    foreach ($row in (Get-FunctionComplexity -FilePath $file)) {
        $results.Add($row)
    }
}

# Report descending by complexity, then emit the same "one line per finding" shape
# Gate 3 already parses so the existing verdict logic keeps working.
#
# `@()` is load-bearing, not style: Sort-Object collapses a single result to a
# scalar, and in Windows PowerShell 5.1 `$scalar.Count` is $null (not 1) unless
# the object happens to carry a Count property. `"{0}" -f $null` renders as the
# empty string, so a one-function file printed `functions_measured=` -- an
# unparsable verdict that Gate 3 would have to WARN on. Force an array.
$sorted = @($results | Sort-Object -Property @{ Expression = 'ccn'; Descending = $true }, file)
$over = @($sorted | Where-Object { $_.ccn -gt $Threshold })
$maxCcn = 0
if ($sorted.Count -gt 0) { $maxCcn = ($sorted | Measure-Object -Property ccn -Maximum).Maximum }

Write-Output ("functions_measured={0}" -f $sorted.Count)
Write-Output ("max_ccn={0}" -f $maxCcn)
Write-Output ("threshold={0}" -f $Threshold)
Write-Output ("over_threshold={0}" -f $over.Count)
foreach ($row in $over) {
    Write-Output ("OVER {0}:{1} {2} ccn={3}" -f $row.file, $row.start_line, $row.function, $row.ccn)
}
