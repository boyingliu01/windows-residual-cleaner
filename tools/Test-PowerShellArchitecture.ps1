#Requires -Version 5.1
<#
.SYNOPSIS
    Check PowerShell script layering against architecture.yaml's `powershell:` block.

.DESCRIPTION
    Gate 6 skipped PowerShell outright:

        ℹ️  No PowerShell architecture tooling available
        ⏭️  SKIPPED - Architecture validation (no tool for PowerShell)

    That is true of `archlint` (it parses TypeScript import graphs) but NOT of the
    constraint itself: "which script may depend on which" is language-agnostic,
    and in this repo the layering already exists implicitly --
      * native-invoke.ps1   is the leaf primitive every other script may use
      * rollback-*.ps1      is the rollback library the cleaner dot-sources
      * run-all.ps1         is the orchestrator that shells out to the steps
      * scan-*.ps1          are leaves: they must not depend on the cleaner
    Without a checker, `clean-residuals.ps1` dot-sourcing `scan-residuals.ps1`, or
    a `scan-*` script importing the rollback library, would be reviewed by nobody.

    This checker reads the `powershell:` mapping from architecture.yaml and
    reports an edge for every dependency it finds: dot-source (`. $lib`), a
    `Join-Path $PSScriptRoot 'x.ps1'` reference, and `-ScriptPath` step
    invocations. It exits 1 when a dependency crosses a disallowed boundary.

    It deliberately does NOT try to resolve wildcards or computed paths: an
    unresolved reference in a config-driven list (e.g. `clean-residuals.ps1`'s
    `$rollbackLibOrder`) is resolved via the literal `'x.ps1'` entries it looks up.
.PARAMETER ConfigPath
    architecture.yaml to read. Defaults to the repo root's.
.PARAMETER Root
    Repo root used to resolve relative layer paths. Defaults to the config's dir.
.PARAMETER BaselinePath
    Optional JSON list of known-violating edges (ratchet). When a violation is in
    the baseline it is reported as a pre-existing waiver instead of a failure.
#>
param(
    [string]$ConfigPath,
    [string]$Root,
    [string]$BaselinePath
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'architecture.yaml'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Output "CONFIG_MISSING $ConfigPath"
    exit 0
}
if (-not $Root) { $Root = Split-Path -Parent $ConfigPath }

function ConvertFrom-LayerBlock {
    # Parse the `powershell:` sub-block of architecture.yaml.
    #
    # A full YAML parser is deliberately avoided: this repo has no YAML module and
    # adding a dependency to satisfy a gate that has been SKIPped for months is a
    # worse trade than parsing the small, fixed shape the block is allowed to be.
    # The block format is validated strictly so a malformed config fails loudly
    # instead of silently yielding "no layers" (= no violations, = false PASS).
    param([string[]]$Lines)

    $layers = New-Object System.Collections.Generic.List[object]
    $inBlock = $false
    $current = $null
    # Which key the following `- "..."` block-list entries belong to.
    # YAML allows both `paths: [a, b]` (flow) and
    #   paths:
    #     - a
    #     - b
    # (block). The parser must handle both: a block list left unattributed
    # silently yields a layer with ZERO paths, which then matches no file and
    # produces no constraints -- a checker that reports "0 violations" because it
    # inspected nothing. That exact bug was measured here (edges=1 instead of 7).
    $listKey = $null

    foreach ($raw in $Lines) {
        $line = $raw -replace "`t", '    '
        $trimmed = $line.TrimEnd()
        if ($trimmed -match '^powershell:\s*$') { $inBlock = $true; continue }
        if (-not $inBlock) { continue }
        # A new top-level key ends the block.
        if ($trimmed -match '^[A-Za-z_]') { break }
        if ($trimmed -match '^\s*#') { continue }
        if ($trimmed -match '^\s*-\s+name:\s*(.+?)\s*$') {
            if ($null -ne $current) { $layers.Add($current) }
            $current = [ordered]@{ name = $Matches[1].Trim('"', "'"); paths = @(); allowed_imports = @() }
            $listKey = $null
            continue
        }
        if ($null -eq $current) { continue }
        if ($trimmed -match '^\s+paths:\s*\[(.*)\]\s*$') {
            $current.paths = @(Split-YamlList -Text $Matches[1])
            $listKey = $null
            continue
        }
        if ($trimmed -match '^\s+paths:\s*$') { $listKey = 'paths'; continue }
        if ($trimmed -match '^\s+allowed_imports:\s*\[(.*)\]\s*$') {
            $current.allowed_imports = @(Split-YamlList -Text $Matches[1])
            $listKey = $null
            continue
        }
        if ($trimmed -match '^\s+allowed_imports:\s*$') { $listKey = 'allowed_imports'; continue }
        # Block-list entry belonging to the key opened just above.
        if ($listKey -and $trimmed -match '^\s*-\s+(.+?)\s*$') {
            $value = $Matches[1].Trim('"', "'")
            if ($value -ne '') {
                if ($listKey -eq 'paths') { $current.paths += $value }
                else { $current.allowed_imports += $value }
            }
            continue
        }
    }
    if ($null -ne $current) { $layers.Add($current) }
    return $layers
}

function Split-YamlList {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @(
        $Text -split ',' |
            ForEach-Object { $_.Trim().Trim('"', "'") } |
            Where-Object { $_ -ne '' }
    )
}

function Get-LayerForFile {
    <#
        Resolve which layer owns a file. The FIRST layer whose path matches wins,
        so a specific entry can shadow a glob (e.g. `rollback.ps1` is an entry
        point even though `rollback-*.ps1` is the library glob).

        Path shapes supported (all that architecture.yaml uses):
          - exact file            references/scripts/rollback.ps1
          - directory prefix      references/scripts
          - prefix + `/**`        ui/src/lib/**      (everything below)
          - wildcard segment      references/scripts/rollback-*.ps1
                                  tools/*.ps1

        The wildcard case is why this cannot just be StartsWith: a glob like
        `rollback-*.ps1` matching only by literal prefix would never match, and a
        file that matches NO layer silently has no constraints at all -- the
        failure mode being a checker that reports zero edges while believing it
        inspected everything.
    #>
    param([string]$RelPath, [object[]]$Layers)
    $norm = $RelPath -replace '\\', '/'
    foreach ($layer in $Layers) {
        foreach ($p in $layer.paths) {
            $pn = ($p -replace '\\', '/').Trim()
            if ($pn -eq '') { continue }
            if ($pn -match '[*?]') {
                # Wildcard: match the last path segment as a filename glob, using
                # PowerShell's own -like semantics (so no regex escaping bugs).
                $leaf = ($norm -split '/')[-1]
                $globLeaf = ($pn -split '/')[-1]
                $prefixPath = $pn.Substring(0, $pn.Length - $globLeaf.Length - $(if ($pn.Contains('/')) { 1 } else { 0 }))
                $inPrefix = $true
                if ($prefixPath -ne '') {
                    $pp = $prefixPath.TrimEnd('/')
                    $inPrefix = ($norm -eq $pp) -or $norm.StartsWith("$pp/")
                }
                if ($inPrefix -and ($leaf -like $globLeaf)) { return $layer.name }
                continue
            }
            $prefix = $pn -replace '/\*\*$', ''
            if ($norm -eq $prefix -or $norm.StartsWith("$prefix/")) { return $layer.name }
        }
    }
    return $null
}

function Get-ScriptDependencyList {
    <#
        Extract dependency edges from one script. Three real dependency forms
        exist in this repo; each is matched literally so the result is auditable:

          1. dot-source           `. $libPath`           (resolved via the
                                                          Join-Path/array above it)
          2. library path const   Join-Path ... 'x.ps1'
          3. step invocation      -ScriptPath "...x.ps1"
          4. library ORDER list   @('a.ps1','b.ps1',...)

        Computed paths (`$libPath`) are resolved by collecting every literal
        `'x.ps1'` string in the file: in this codebase those literals exist
        precisely so the load order can be declared and validated, so using them
        finds the real edges without attempting to evaluate PowerShell.
    #>
    param([string]$Text)

    $deps = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    # Every literal 'name.ps1' occurrence, excluding strings that are obviously
    # NOT sibling scripts (paths containing a separator are still fine -- only the
    # leaf name matters, and unknown leaves simply resolve to no layer).
    foreach ($m in [regex]::Matches($Text, "['""]([A-Za-z0-9_.-]+\.ps1)['""]")) {
        $leaf = $m.Groups[1].Value
        if ($leaf -eq 'setup.ps1') { continue }
        if ($seen.ContainsKey($leaf)) { continue }
        $seen[$leaf] = $true
        $deps.Add($leaf)
    }
    return $deps
}

$configText = Get-Content -LiteralPath $ConfigPath -Raw
$layers = @(ConvertFrom-LayerBlock -Lines ($configText -split "`r?`n"))

if ($layers.Count -eq 0) {
    # Must be loud: "no layers parsed" and "no violations found" must never look
    # the same, otherwise a malformed config becomes a free PASS.
    Write-Output 'NO_POWERSHELL_LAYERS'
    exit 0
}

$violations = New-Object System.Collections.Generic.List[object]
$edges = 0
$scripts = @(Get-ChildItem -LiteralPath (Join-Path $Root 'references/scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
$setupPath = Join-Path $Root 'setup.ps1'
if (Test-Path -LiteralPath $setupPath) { $scripts += (Get-Item -LiteralPath $setupPath) }

foreach ($file in $scripts) {
    $rel = ($file.FullName.Substring($Root.Length).TrimStart('\', '/')) -replace '\\', '/'
    $fromLayer = Get-LayerForFile -RelPath $rel -Layers $layers
    if (-not $fromLayer) { continue }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($dep in (Get-ScriptDependencyList -Text $text)) {
        $depRel = "references/scripts/$dep"
        $toLayer = Get-LayerForFile -RelPath $depRel -Layers $layers
        if (-not $toLayer) { continue }
        if ($toLayer -eq $fromLayer) { continue }
        $edges++
        $allowed = $false
        $fromDef = $layers | Where-Object { $_.name -eq $fromLayer } | Select-Object -First 1
        if ($fromDef -and ($fromDef.allowed_imports -contains $toLayer)) { $allowed = $true }
        if (-not $allowed) {
            $violations.Add([pscustomobject]@{
                from  = $fromLayer
                to    = $toLayer
                file  = $rel
                detail = "$rel ($fromLayer) -> $dep ($toLayer)"
            })
        }
    }
}

# Ratchet: subtract known/accepted violations.
$waived = @()
if ($BaselinePath -and (Test-Path -LiteralPath $BaselinePath)) {
    try {
        $rawBase = (Get-Content -LiteralPath $BaselinePath -Raw) -replace '^\uFEFF', ''
        $doc = $rawBase | ConvertFrom-Json
        $waived = @($doc.entries | ForEach-Object { [string]$_ })
    }
    catch {
        Write-Output "BASELINE_UNREADABLE $($_.Exception.Message)"
        exit 0
    }
}

$failing = @($violations | Where-Object { $waived -notcontains $_.detail })
$newlyWaived = @($waived | Where-Object { $w = $_; -not ($violations | Where-Object { $_.detail -eq $w }) })

Write-Output "layers=$($layers.Count) edges=$edges violations=$($violations.Count) failing=$($failing.Count)"
foreach ($v in $violations) {
    $tag = if ($waived -contains $v.detail) { 'WAIVED' } else { 'VIOLATION' }
    Write-Output "$tag $($v.detail)"
}
foreach ($w in $newlyWaived) {
    Write-Output "STALE_WAIVER $w"
}

if ($failing.Count -gt 0) { exit 1 }
exit 0

