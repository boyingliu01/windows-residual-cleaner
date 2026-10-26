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
#
# WHY -Threshold 1 AND NOT 5 (read before "fixing" this):
#   The ratchet branch of xp-gate's adapters/gate-3.sh measures the staged files with
#   `-Threshold 1` and then treats EVERY `OVER` line it gets back as a comparison
#   target. A function absent from the baseline is reported as
#   "new function at ccn=N" and BLOCKS the commit -- regardless of N. So the set of
#   functions the gate hands it is "every function with CCN >= 2", not "every
#   function above 5". A baseline built at 5 therefore leaves every low-CCN function
#   permanently unblockable; measured 2026-10-25, all 11 functions in
#   tools/Update-DocTables.ps1 (max CCN 5) were rejected on every commit.
#   Building the baseline at the SAME threshold the gate measures with is what makes
#   the two halves agree; it does NOT raise any existing function's recorded number
#   (verified: UP=0 on regeneration), it only adds the entries that were missing.
#   When xp-gate issue #598 is fixed (gate should compare all functions, not just
#   threshold-crossers), pass -Threshold 5 to shrink the file back.
param(
    [int]$Threshold = 1,
    [string]$OutputPath = '.xp-gate-powershell-ccn-baseline.json'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# Scope = every tracked product source, which is exactly the set Gate 1 analyses
# (`.xp-gate-powershell-analysis-paths`). Anything outside this set has no baseline
# entry, and Gate 3 treats "measured but not in the baseline" as a NEW function and
# blocks the commit -- so a scope narrower than the gate's means every function in
# an unscoped file is permanently unblockable (measured 2026-10-25: `tools/` was
# absent here, so all 11 functions in tools/Update-DocTables.ps1 were reported as
# "new function at ccn=N" on every commit).
# Fall back to the historical two-root list if the config file is missing, so this
# tool still works in a partial checkout.
$scope = @()
$analysisPaths = Join-Path $repoRoot '.xp-gate-powershell-analysis-paths'
if (Test-Path -LiteralPath $analysisPaths) {
    foreach ($entry in (Get-Content -LiteralPath $analysisPaths)) {
        $trimmed = $entry.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $resolved = Join-Path $repoRoot $trimmed
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            $scope += @(Get-ChildItem -LiteralPath $resolved -Filter '*.ps1' -File -Recurse | ForEach-Object { $_.FullName })
        }
        elseif (Test-Path -LiteralPath $resolved -PathType Leaf) {
            $scope += @((Resolve-Path -LiteralPath $resolved).Path)
        }
    }
}
if ($scope.Count -eq 0) {
    $scriptsDir = Join-Path $repoRoot 'references/scripts'
    if (Test-Path -LiteralPath $scriptsDir) {
        $scope += @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
    }
    $setup = Join-Path $repoRoot 'setup.ps1'
    if (Test-Path -LiteralPath $setup) { $scope += @($setup) }
}

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
