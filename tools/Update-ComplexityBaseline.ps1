# Regenerate the PowerShell complexity ratchet baseline.
#
# Why a baseline instead of a flat threshold: the repo has 62 functions above
# CCN 5 (max 143 in clean-residuals.ps1 Main) -- all of them pre-date this gate.
# A flat threshold would block every future commit, and refactoring 62 functions
# is not something a commit hook can demand. A baseline changes the question from
# "is this function complex?" to "is this commit making complexity WORSE?", which
# is the only question a pre-commit gate can honestly answer.
#
# The baseline is a snapshot, never a target: entries may only be removed. If a
# refactor lowers a function's CCN, the gate still passes; re-running this script
# then rewrites the lower number so the improvement cannot silently regress.
#
#   pwsh -NoProfile -File tools/Update-ComplexityBaseline.ps1
#   powershell.exe -NoProfile -File tools/Update-ComplexityBaseline.ps1
param(
    [int]$Threshold = 5,
    [string]$OutputPath = '.xp-gate-powershell-ccn-baseline.json'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$scope = @()
$scriptsDir = Join-Path $repoRoot 'references/scripts'
if (Test-Path -LiteralPath $scriptsDir) {
    $scope += @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
}
$setup = Join-Path $repoRoot 'setup.ps1'
if (Test-Path -LiteralPath $setup) { $scope += @($setup) }

$tool = Join-Path $PSScriptRoot 'Measure-PowerShellComplexity.ps1'
$raw = & $tool -Path $scope -Threshold $Threshold
$over = @($raw | Where-Object { $_ -like 'OVER *' })

$entries = @()
foreach ($line in $over) {
    # "OVER <file>:<line> <name> ccn=<n>"
    if ($line -match '^OVER (.+):(\d+) (\S+) ccn=(\d+)$') {
        $fullPath = $Matches[1]
        $entries += [ordered]@{
            file     = (Resolve-Path -LiteralPath $fullPath -Relative -ErrorAction SilentlyContinue) -replace '\\', '/' -replace '^\./', ''
            function = $Matches[3]
            line     = [int]$Matches[2]
            ccn      = [int]$Matches[4]
        }
    }
}

$doc = [ordered]@{
    note      = 'PowerShell cyclomatic-complexity ratchet baseline (Gate 3). Regenerate with tools/Update-ComplexityBaseline.ps1. Entries may only go DOWN: a commit that raises any function''s CCN above its recorded value is blocked.'
    threshold = $Threshold
    measured  = ($raw | Where-Object { $_ -like 'functions_measured=*' }) -replace '^functions_measured=', ''
    entries   = $entries
}

# Write WITHOUT a BOM. Set-Content -Encoding UTF8 emits a BOM on PowerShell 5.1
# (it is only BOM-less from 6.0), and the ratchet consumer is `node -e` +
# `JSON.parse`, which rejects a leading BOM outright:
#   SyntaxError: Unexpected token '', "{" is not valid JSON
# Measured 2026-10-24 -- a gate input that only some parsers can read is exactly
# the trap this repo's own AGENTS.md documents for BOM + tooling.
$json = $doc | ConvertTo-Json -Depth 5
$target = Join-Path $repoRoot $OutputPath
[System.IO.File]::WriteAllText($target, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("Wrote {0} baseline entries to {1}" -f $entries.Count, $OutputPath)
