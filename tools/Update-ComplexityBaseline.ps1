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

# Measure with the SAME script Gate 3 runs, when it is installed.
#
# Gate 3 (gate-3.sh L79) measures with xp-gate's OWN copy at
# `<xp-gate>/hooks/lib/Measure-PowerShellComplexity.ps1`, not with the one in this repo.
# The two are different implementations and disagree: on 2026-10-26 the live copy
# reported clean-residuals.ps1 Main at CCN 139 while the repo copy said 143. A baseline
# built from the repo copy therefore records numbers the gate never sees -- too HIGH and
# a real regression slips through, too LOW and the gate blocks on a function nobody
# changed. Neither failure is visible: both files produce well-formed `OVER` lines.
#
# So: prefer the live copy, fall back to the repo copy only when xp-gate is not
# installed (a bare checkout, or CI without the gate). The fallback is a degraded mode,
# and says so, because a baseline is only meaningful against the measurer that reads it.
$liveTool = Join-Path $HOME '.config/xp-gate/hooks/lib/Measure-PowerShellComplexity.ps1'
$tool = Join-Path $PSScriptRoot 'Measure-PowerShellComplexity.ps1'
$measurer = 'repo'
$supportsList = $false
if (Test-Path -LiteralPath $liveTool) {
    $tool = $liveTool
    $measurer = 'live'
    # -List only exists on xp-gate's copy. The repo copy has no such switch and would die
    # on an unknown parameter, so it is gated on the measurer actually being the live one.
    $supportsList = $true
}
else {
    Write-Warning ('xp-gate not installed; measuring with the repo copy at {0}. ' -f $tool) +
        'Gate 3 measures with its own copy and the two can disagree (CCN 139 vs 143 on ' +
        'clean-residuals.ps1 Main, 2026-10-26). This copy also has no -List switch, so the ' +
        'baseline will lack the ccn=1 population the gate does measure. Re-run this tool on a ' +
        'machine that has xp-gate before trusting the baseline.'
}
Write-Verbose ("measurer: {0} ({1}), -List: {2}" -f $measurer, $tool, $supportsList)

# -List, because that is how the gate measures (gate-3.sh L136 appends `-List`).
#
# Without it the collector only ever sees OVER lines, i.e. functions strictly above the
# threshold. The gate, with -List, also emits a FUNC line for EVERY function -- including
# ones at ccn=1 that can never be "above" any threshold. Those are measured-but-unknown,
# so the ratchet reports them as "new function" and blocks the commit (measured
# 2026-10-26: `Add-CleanupFailure ccn=1` was the last one standing after the path and
# key-name defects were fixed). Collect the same population the gate compares against.
# Collect the same population the gate compares against.
$measureArgs = @{ Path = $scope; Threshold = $Threshold }
if ($supportsList) { $measureArgs['List'] = $true }
$raw = & $tool @measureArgs
$over = @($raw | Where-Object { $_ -like 'OVER *' -or $_ -like 'FUNC *' })

$entries = @()
foreach ($line in $over) {
    # "<OVER|FUNC> <file>:<line> <name> ccn=<n>"
    # OVER = above threshold, FUNC = every function when -List is passed. Both must land
    # in the baseline: the gate compares against whatever it measured, and a function it
    # measured but the baseline lacks is reported as new.
    if ($line -match '^(?:OVER|FUNC) (.+):(\d+) (\S+) ccn=(\d+)$') {
        $fullPath = $Matches[1]
        $entries += [ordered]@{
            # ABSOLUTE path with NATIVE BACKSLASHES -- exactly how the gate spells it.
            # Nothing else matches, and the failure is silent:
            #
            #   * the gate measures with xp-gate's own hooks/lib/Measure-PowerShellComplexity.ps1,
            #     which emits `$_.FullName`, i.e. `D:\Study\...\run-all.ps1`;
            #   * it compares norm(file) + '::' + name, where gate-3.sh L179 is
            #         function norm(p) { return String(p).replace(/\\\\/g, "/").replace(/^\.\//, ""); }
            #     Inside the single-quoted `node -e '...'` block bash passes FOUR backslashes,
            #     so JS receives the regex /\\\\/ -- which matches TWO CONSECUTIVE backslashes.
            #     A single "\" is never touched: on Windows this norm() is a NO-OP.
            #
            # So the two sides only agree when this file spells the path the same way the
            # gate does, backslashes and all. A forward-slashed baseline (what this tool
            # used to write) keeps its slashes -- it is "already normalised", so the broken
            # regex leaves it alone -- and then nothing matches: `known` stays effectively
            # empty and EVERY function is reported "new function at ccn=N".
            #
            # Measured 2026-10-26, three defects stacked, each hiding the next:
            #   1. baseline key was `function`, gate reads `e.name`      -> known empty
            #   2. relative paths (gate measures absolute)               -> known empty
            #   3. forward slashes vs the gate's broken norm()           -> known empty
            # Only #1 was in the issue I filed; #2 and #3 produce the identical symptom.
            # Do not "tidy" this back to forward slashes -- that reintroduces #3 silently.
            #
            # Trade-off accepted: this file is now machine-specific. Acceptable because CI
            # does not run xp-gate's pre-commit (see .github/workflows/ci.yml); the baseline
            # only ever serves the local ratchet. Re-running this tool on another machine
            # rewrites the prefix.
            file     = (Resolve-Path -LiteralPath $fullPath -ErrorAction SilentlyContinue).Path
            function = $Matches[3]
            # BOTH keys, for the same value. xp-gate issue #632: gate-3.sh reads
            # `e.name` (`if (!e || !e.file || !e.name) continue;`) while this writer —
            # named in the baseline's own `note` — emits `function`. Every entry is then
            # skipped, `known` stays empty, and EVERY function above the threshold is
            # reported as "new function at ccn=N", so Gate 3 blocks unconditionally once
            # a baseline exists. Emitting both spellings makes the data readable by
            # either side without depending on which one upstream settles on.
            # Revert to `function` alone once #632 ships.
            name     = $Matches[3]
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
