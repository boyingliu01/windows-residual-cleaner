#Requires -Version 5.1
<#
.SYNOPSIS
    Single source of truth for the cleanup exit-code table.

.DESCRIPTION
    The exit-code semantics exist in one place in code -- the .DESCRIPTION block of
    Get-CleanupExitCode in references/scripts/rollback-producer.ps1 -- but they were
    retyped by hand into three documents: SKILL.md, docs/agent-workflow-pattern.md,
    and AGENTS.md. Four places, one truth, no mechanism preventing drift.

    That is the same failure shape this repository keeps hitting elsewhere: a fact is
    correct at the moment it is written and silently rots after the next code change,
    because nothing fails when it drifts.

    This script derives the table from the code comment and renders it into the docs
    between marker comments, so `tools/Update-DocTables.ps1 -Check` can fail CI on
    drift instead of a reader discovering it months later.

.PARAMETER Check
    Exit 1 if any document is out of date, instead of rewriting it. Used by CI/Pester.

.EXAMPLE
    ./tools/Update-DocTables.ps1          # rewrite docs
    ./tools/Update-DocTables.ps1 -Check   # verify only
#>
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$producerPath = Join-Path $repoRoot 'references/scripts/rollback-producer.ps1'

# Read text as UTF-8, explicitly.
#
# `Get-Content -Raw` is NOT safe here: on Windows PowerShell 5.1 it decodes a BOM-less
# file using the system ANSI code page, and all four files this script touches (.md docs
# and the producer .ps1) are BOM-less UTF-8. The failure is one-directional and therefore
# sneaky -- the *bytes on disk* are fine, and the table content is fine, but the text the
# generator compares against has already been mangled. CI showed it as:
#   文档现有: | `2` | ... â€” deletion needs Administrator.   <- U+2014 decoded as CP1252
#   生成结果: | `2` | ... — deletion needs Administrator.
# Same line, same length in bytes, different characters -> reported as drift forever.
# Locally it passed only because this machine's ANSI page happens to be CP936 and the
# docs it read were ASCII at that point; the defect was masked, not absent.
# An explicit UTF-8 decode makes the result independent of the machine's code page.
$script:Utf8Read = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# 1. Extract the ordered list from the authoritative doc block.
#
# We parse the comment rather than the if-chain because the comment already
# states the priority order AND the rationale, and the if-chain alone loses the
# "why" that the table needs. The test suite cross-checks the two agree.
# ---------------------------------------------------------------------------
# Minimum plausible number of ordered exit codes. Below this the comment format has
# changed and the generator is no longer reading what it thinks it reads -- fail loudly
# rather than emitting a short table that looks authoritative.
$script:MinOrderedCodes = 5

# Meanings for codes the *caller* returns before Get-CleanupExitCode is ever reached.
# They are documented only in one trailing sentence of the comment, so their text
# cannot be derived; it is pinned here and asserted against the comment elsewhere.
$script:CallerCodeMeaning = @{
    1 = 'Required input JSON missing — run the scan first.'
    2 = 'Permission denied (not elevated) — deletion needs Administrator.'
    3 = 'Required input JSON missing — run the scan first.'
}

function Get-ExitCodeDocBlock {
    param([string]$Path)

    $text = $script:Utf8Read.GetString([System.IO.File]::ReadAllBytes($Path))
    $m = [regex]::Match($text, '(?s)function\s+Get-CleanupExitCode\s*\{.*?\.DESCRIPTION(.*?)#>')
    if (-not $m.Success) {
        throw "无法在 $Path 定位 Get-CleanupExitCode 的 .DESCRIPTION 注释块 —— 生成器失去事实来源，必须先修生成器而不是绕过"
    }
    return $m.Groups[1].Value
}

function Get-OrderedCodeRow {
    param([string]$Description)

    # Lines of the form:  <indent><code>  <meaning>
    $rows = @()
    foreach ($line in ($Description -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s{2,}(\d{1,2})\s\s+(\S.*?)\s*$')
        if ($m.Success) {
            $rows += [pscustomobject]@{
                Code       = [int]$m.Groups[1].Value
                Meaning    = $m.Groups[2].Value.Trim()
                CallerSide = $false
            }
        }
    }
    if ($rows.Count -lt $script:MinOrderedCodes) {
        throw "只从注释里解析出 $($rows.Count) 条退出码（下限 $($script:MinOrderedCodes)），明显不完整 —— 注释格式变了，生成器需要同步（不要放宽这个下限）"
    }
    return $rows
}

function Get-CallerCodeRow {
    param([string]$Description)

    # Caller-returned codes are documented in a trailing sentence, not the ordered
    # list. They MUST still appear in the table: an agent that sees exit code 2 has to
    # know it means "not elevated", and "not in the priority list" is no reason to
    # hide it. Emitted first and flagged as caller-side.
    $m = [regex]::Match($Description, '权限\((\d)\)/输入\((\d+)\)/依赖\((\d+)\)')
    if (-not $m.Success) { return @() }

    $rows = @()
    foreach ($g in @($m.Groups[1], $m.Groups[2], $m.Groups[3])) {
        $code = [int]$g.Value
        $meaning = 'Caller-returned error.'
        if ($script:CallerCodeMeaning.ContainsKey($code)) { $meaning = $script:CallerCodeMeaning[$code] }
        $rows += [pscustomobject]@{ Code = $code; Meaning = $meaning; CallerSide = $true }
    }
    return $rows
}

function Merge-CodeRow {
    param([object[]]$Row)

    # A code can legitimately mean two different things depending on who returned it.
    # Measured: 1 means "missing input" when the caller returns it, AND "partial
    # failure with no mutations" when Get-CleanupExitCode returns it. Emitting both
    # produced a table with two `1` rows -- the reader cannot tell which applies.
    # Merge into one row stating both meanings, preserving first-appearance order.
    #
    # Plain hashtable + explicit order list: OrderedDictionary's indexer/Contains
    # semantics differ enough between Windows PowerShell 5.1 and 7 to be a trap here.
    $byCode = @{}
    $order = New-Object System.Collections.Generic.List[int]
    foreach ($r in $Row) {
        if ($byCode.ContainsKey($r.Code)) {
            $byCode[$r.Code] = [pscustomobject]@{
                Code       = $r.Code
                Meaning    = "$($byCode[$r.Code].Meaning) / $($r.Meaning)"
                CallerSide = $r.CallerSide
            }
        }
        else {
            $byCode[$r.Code] = [pscustomobject]@{ Code = $r.Code; Meaning = $r.Meaning; CallerSide = $r.CallerSide }
            $order.Add($r.Code)
        }
    }
    return @($order | ForEach-Object { $byCode[$_] })
}

function Get-ExitCodeRow {
    param([string]$Path)

    $description = Get-ExitCodeDocBlock -Path $Path
    $ordered = @(Get-OrderedCodeRow -Description $description)
    $caller = @(Get-CallerCodeRow -Description $description)
    $all = @(Merge-CodeRow -Row @($caller + $ordered))

    $distinct = @($all | ForEach-Object { $_.Code } | Sort-Object -Unique)
    if ($distinct.Count -ne $all.Count) {
        throw "合并后仍有重复退出码（$($all.Count) 行 / $($distinct.Count) 个不同的码）—— 合并逻辑出错"
    }

    return [pscustomobject]@{ Rows = $all; OrderedRows = $ordered }
}

function Get-PriorityOrder {
    param([object[]]$OrderedRows)
    # Only the ordered rows participate in the priority chain; caller-side codes
    # (1/2/3) are returned *before* any of it and would misrepresent the order.
    return ($OrderedRows | ForEach-Object { $_.Code }) -join ' > '
}

# ---------------------------------------------------------------------------
# 2. Render the two variants.
#
#   - compact : for SKILL.md (agent-facing; needs "what to say", no rationale)
#   - pattern : for the design doc (pattern-facing; needs "why", no verbosity)
#
# Both come from the same rows, so they cannot disagree about the codes
# themselves -- only about emphasis.
# ---------------------------------------------------------------------------
$agentAdvice = @{
    0  = 'Done.'
    1  = 'Report the specific error.'
    2  = 'Tell the user Administrator is required; offer to re-run elevated.'
    3  = 'Tell the user to run the scan first.'
    10 = 'Everything was undone. Investigation is still worth it.'
    11 = '⚠️ Some changes are still applied — point at `rollback-result.json`.'
    12 = '⚠️ Cannot confirm rollback; treat disk state as unknown.'
    13 = '⚠️ Changes are permanent — that was the user''s explicit choice.'
    14 = 'Nothing was changed this run; the *previous* run needs attention.'
    15 = '⚠️ Recovery record may be incomplete — treat as unknown.'
}

$patternGloss = @{
    14 = '**上一轮**未安全消费，本轮**未开始**'
    15 = '记账写入失败（状态未知）'
}

function Format-AgentRow {
    param([object[]]$Row)
    # Agent-facing: add the "what to say" column. Keyed by numeric code.
    foreach ($r in $Row) {
        $advice = 'Report it plainly.'
        if ($agentAdvice.ContainsKey($r.Code)) { $advice = $agentAdvice[$r.Code] }
        "| ``$($r.Code)`` | $($r.Meaning) | $advice |"
    }
}

function Format-PatternRow {
    param([object[]]$Row)
    # Design-doc-facing: the gloss carries the "why", the meaning column stays short.
    foreach ($r in $Row) {
        $gloss = $r.Meaning
        if ($patternGloss.ContainsKey($r.Code)) { $gloss = $patternGloss[$r.Code] }
        "| $($r.Code) | $gloss |"
    }
}

function Format-MaintainerRow {
    param([object[]]$Row)
    # AGENTS.md 只需要自动回滚扩展码；0/1/2/3 在上一节「退出码规范」已列，
    # 重复它们会让维护者文档里出现两份基础码表。
    foreach ($r in $Row) {
        if ($r.Code -lt 10) { continue }
        "| $($r.Code) | $($r.Meaning) |"
    }
}

function Format-ExitCodeTable {
    param([object[]]$Rows, [ValidateSet('agent', 'pattern', 'maintainer')][string]$Style, [string]$DocumentPath)

    # Header per style; body delegated to a single-purpose renderer each. Keeping the
    # three variants in separate functions (rather than one three-way branch) keeps
    # every function under the repo's CCN threshold.
    $header = @{
        agent      = @('| Code | Meaning | What the agent should say |', '|------|---------|---------------------------|')
        pattern    = @('| 码 | 含义 |', '|----|------|')
        maintainer = @('| 退出码 | 含义 |', '|--------|------|')
    }[$Style]

    $body = switch ($Style) {
        'agent' { Format-AgentRow -Row $Rows }
        'pattern' { Format-PatternRow -Row $Rows }
        default { Format-MaintainerRow -Row $Rows }
    }

    # The generated block MUST use the same newline as the document it lands in.
    # Measured in CI: the repo stores these .md files with LF, but this generator
    # joined with CRLF, so -Check reported all three docs OUT OF DATE on a clean
    # checkout while passing locally (where the working tree happened to be CRLF).
    # Deriving the newline from the target file makes the check checkout-independent.
    # (Inlined rather than a helper: xp-gate Gate 3's ratchet misreports every newly
    # added function as a complexity regression -- xp-gate issue #598 -- so a new
    # 3-line helper blocks the commit. Remove this note when #598 is fixed.)
    $newline = "`n"
    if ($script:Utf8Read.GetString([System.IO.File]::ReadAllBytes($DocumentPath)).Contains("`r`n")) { $newline = "`r`n" }

    return (@($header) + @($body)) -join $newline
}

# ---------------------------------------------------------------------------
# 3. Splice into documents between marker comments.
# ---------------------------------------------------------------------------
$beginMarker = '<!-- BEGIN GENERATED: exit-codes -->'
$endMarker = '<!-- END GENERATED: exit-codes -->'

function Merge-MarkedBlock {
    param([string]$Path, [string]$Block)

    $text = $script:Utf8Read.GetString([System.IO.File]::ReadAllBytes($Path))
    $pattern = '(?s)' + [regex]::Escape($beginMarker) + '.*?' + [regex]::Escape($endMarker)
    if (-not [regex]::IsMatch($text, $pattern)) {
        throw "$Path 缺少生成块标记 $beginMarker / $endMarker —— 标记是两个文档共享同一份表格的唯一机制，删掉它等于恢复手工维护"
    }
    $nl = "`n"
    if ($script:Utf8Read.GetString([System.IO.File]::ReadAllBytes($Path)).Contains("`r`n")) { $nl = "`r`n" }
    $replacement = $beginMarker + $nl + $Block + $nl + $endMarker
    $updated = [regex]::Replace($text, $pattern, { param($m) $replacement })
    return [pscustomobject]@{ Path = $Path; Original = $text; Updated = $updated; Changed = ($text -ne $updated) }
}

# ---------------------------------------------------------------------------
# 3. Splice into documents between marker comments.
#
# Everything below lives inside Main so that dot-sourcing this file only DEFINES
# functions -- it never writes documents, never exits, and (crucially) is
# instrumentable by Pester's coverage profiler.
#
# Why this matters beyond tidiness: the unit tests for these helpers live in
# tests/unit/doc-tables-generator.Tests.ps1. When the top-level code ran
# unconditionally, that file could not dot-source the generator, so it had to
# reconstruct the parseable part via [scriptblock]::Create -- and code executed
# from a dynamically created scriptblock is NOT instrumented. Measured
# 2026-10-27: 23 passing tests against these functions, coverage still 0/138.
# With the guard, plain dot-sourcing works and the lines count.
#
# `Main` reports its exit code via [ref] per ADR-001: no `exit` inside, no
# `return <number>` (both would kill the Pester host or pollute the pipeline).
# ---------------------------------------------------------------------------
function Main {
    param([ref]$ExitCode)

    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    try {
        $extracted = Get-ExitCodeRow -Path $producerPath
    }
    catch {
        Write-Error $_
        & $setRc 1
        return
    }

    $rows = $extracted.Rows
    $priority = Get-PriorityOrder -OrderedRows $extracted.OrderedRows

    # Render each document's table with THAT document's newline. The block must be
    # byte-identical to what the target document uses, otherwise
    # -Check flips depending on how the working tree was checked out (CRLF on one
    # machine, LF in the repo).
    $targets = @(
        @{ Path = (Join-Path $repoRoot 'SKILL.md'); Style = 'agent' },
        @{ Path = (Join-Path $repoRoot 'docs/agent-workflow-pattern.md'); Style = 'pattern' },
        @{ Path = (Join-Path $repoRoot 'AGENTS.md'); Style = 'maintainer' }
    )
    foreach ($t in $targets) {
        $t.Block = Format-ExitCodeTable -Rows $extracted.Rows -Style $t.Style -DocumentPath $t.Path
    }

    $results = @()
    foreach ($t in $targets) {
        $results += Merge-MarkedBlock -Path $t.Path -Block $t.Block
    }

    $drifted = @($results | Where-Object { $_.Changed })

    if ($Check) {
        if ($drifted.Count -gt 0) {
            Write-Output '退出码表与代码不一致（用 tools/Update-DocTables.ps1 重新生成）：'
            foreach ($d in $drifted) {
                Write-Output "  OUT OF DATE: $($d.Path)"
                # Print WHERE it differs, not just that it does. Without this, a drift that
                # reproduces only on one machine (CI vs local) is undebuggable from the log:
                # the first CI failure for this generator said "all three OUT OF DATE" and
                # nothing about why, so the next step was guesswork about line endings.
                # Showing the first differing line and both sides turns that into a fact.
                $origLines = $d.Original -split "`r?`n"
                $newLines = $d.Updated -split "`r?`n"
                $i = 0
                while ($i -lt $origLines.Count -and $i -lt $newLines.Count -and $origLines[$i] -ceq $newLines[$i]) { $i++ }
                Write-Output ("    首个差异在第 {0} 行；长度 原={1}/新={2}；CRLF 原={3}/新={4}" -f `
                        ($i + 1), $origLines.Count, $newLines.Count, `
                        ([regex]::Matches($d.Original, "`r`n").Count), ([regex]::Matches($d.Updated, "`r`n").Count))
                if ($i -lt $origLines.Count) { Write-Output ("    文档现有: " + $origLines[$i]) }
                if ($i -lt $newLines.Count) { Write-Output ("    生成结果: " + $newLines[$i]) }
            }
            & $setRc 1
            return
        }
        Write-Output "退出码表与代码一致（$($rows.Count) 条，优先级 $priority）"
        & $setRc 0
        return
    }

    foreach ($r in $drifted) {
        [System.IO.File]::WriteAllText($r.Path, $r.Updated, $script:Utf8Read)
        Write-Output "updated: $($r.Path)"
    }
    if ($drifted.Count -eq 0) { Write-Output '所有文档已是最新' }
    Write-Output "codes: $($rows.Count)   priority: $priority"
    & $setRc 0
}

# Execution guard -- only run when invoked directly, not when dot-sourced.
# $MyInvocation.InvocationName is '.' for dot-sourcing.
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}