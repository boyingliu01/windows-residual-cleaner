# delphi-run.ps1 — per-expert Delphi runner for the delphi-review skill.
#
# The skill contract requires THREE separate runner invocations, one per expert role,
# each with its own model. This script runs exactly ONE expert so the orchestrator can
# dispatch them independently (never one process running all models).
#
# Usage:
#   delphi-run.ps1 -Expert architecture -Mode requirements -PayloadFile <path> -OutFile <path>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('architecture', 'technical', 'feasibility')][string]$Expert,
    [Parameter(Mandatory)][ValidateSet('requirements', 'design', 'code-walkthrough')][string]$Mode,
    [Parameter(Mandatory)][string]$PayloadFile,
    [Parameter(Mandatory)][string]$OutFile,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# Resolve the config relative to this script's own location. Do NOT default it in the
# param() block: $PSScriptRoot is not yet populated when parameter defaults are evaluated
# under `powershell.exe -File`.
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.delphi-config.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Delphi config not found at '$ConfigPath'"
}

# ── Load config ──────────────────────────────────────────────────────────────
$cfg = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path) | ConvertFrom-Json
$profile = $cfg.profiles.($cfg.active_profile)
# NOTE: do NOT name this $expert — the -Expert parameter unconditionally shadows a
# caller-scope variable of the same name (AGENTS.md trap 8b).
$expertCfg = $profile.experts.$Expert
$provider = $profile.providers.($expertCfg.provider)
$apiKey = [Environment]::GetEnvironmentVariable($provider.api_key_env, 'User')
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $apiKey = [Environment]::GetEnvironmentVariable($provider.api_key_env)
}
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw "API key env '$($provider.api_key_env)' is not set" }

# ── Role prompts (distinct lens per expert) ──────────────────────────────────
$rolePrompts = @{
    architecture = @'
You are the ARCHITECTURE expert in a Delphi review panel. Your lens is STRUCTURE and BOUNDARIES:
module decomposition, coupling, data-flow ownership, where state lives, interface contracts,
and whether the design's abstractions will survive contact with reality. You care about whether
the responsibility for each piece of state is in exactly one place.
'@
    technical = @'
You are the TECHNICAL expert in a Delphi review panel. Your lens is IMPLEMENTATION CORRECTNESS:
platform semantics and version differences (this is PowerShell 5.1 with a pwsh 7 test gate),
error handling, race conditions, atomicity, edge cases, resource handling, and whether each
claim in the spec is actually implementable as written.
'@
    feasibility = @'
You are the FEASIBILITY expert in a Delphi review panel. Your lens is REAL-WORLD DELIVERABILITY
and USER RISK: operator safety, blast radius, whether the promised capability can truly be
delivered, what happens on failure, reversibility, and whether the user can be misled into
believing something is safe when it is not. You are the panel's skeptic about over-promising.
'@
}

$modePrompts = @{
    requirements = @'
MODE: REQUIREMENTS REVIEW (lightweight, Round 1).
Assess the requirements specification ONLY. Focus on:
 - missing user scenarios
 - acceptance-criteria coverage and testability
 - clarity of user/persona definition
 - requirement boundaries (what is explicitly in vs out of scope)
 - whether the stated requirements are internally consistent with the observed facts
Do NOT review code style or implementation details.
'@
    design = @'
MODE: DESIGN REVIEW.
Assess the design document and specification. Focus on:
 - correctness and completeness of the design
 - risk assessment quality
 - whether design decisions are justified and their alternatives fairly considered
 - testability of the plan
 - any gap between what is promised and what is achievable
'@
}

$payload = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $PayloadFile).Path)

# NOTE (PS 5.1 trap): do NOT read the payload with `Get-Content -Raw -Encoding UTF8`.
# On this payload that produces a string which makes `ConvertTo-Json` emit 108 MB for a
# 22 KB input (the gateway then rejects it with HTTP 413). `[System.IO.File]::ReadAllText`
# on the very same file yields a string of identical length that serializes to 23 KB.
# Verified: -Raw => 108,377,597 bytes; ReadAllText => 23,509 bytes.

$system = @"
$($rolePrompts[$Expert])

$($modePrompts[$Mode])

You MUST reply with a SINGLE JSON object and nothing else. Schema:
{
  "verdict": "APPROVED" | "REQUEST_CHANGES",
  "confidence": <number 0..1>,
  "findings": [
    { "severity": "critical"|"high"|"medium"|"low", "title": "<short>", "detail": "<what and why>", "suggestion": "<concrete fix>" }
  ],
  "summary": "<2-4 sentence assessment>"
}
Rules:
 - APPROVED means you would accept this to proceed to the next phase. Use REQUEST_CHANGES if any
   CRITICAL or HIGH finding would cause harm, data loss, a false safety claim, or an
   unimplementable requirement.
 - Be specific and cite the section/REQ/AC id you are referring to.
 - Do not invent facts. If something is unverifiable from the material, say so in a finding.
 - BE CONCISE. At most 6 findings. Keep each "detail" and "suggestion" under 300 characters.
   Emit the JSON object and keep it compact; a truncated reply is unusable.
"@

$body = @{
    model      = $expertCfg.model
    messages   = @(
        @{ role = 'system'; content = $system }
        @{ role = 'user'; content = $payload }
    )
    max_tokens = 32000
} | ConvertTo-Json -Depth 8

$uri = "$($provider.base_url)/chat/completions"
# Send explicit UTF-8 BYTES: -Body <string> under PS 5.1 encodes as ISO-8859-1/UTF-16,
# which corrupts the non-ASCII payload and makes the gateway answer
# `{"detail":"There was an error parsing the body"}`.
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
$resp = Invoke-RestMethod -Uri $uri -Method Post `
    -Headers @{ Authorization = "Bearer $apiKey"; 'Content-Type' = 'application/json; charset=utf-8' } `
    -Body $bodyBytes -TimeoutSec 900 -ErrorAction Stop

$content = $resp.choices[0].message.content
$finish = $resp.choices[0].finish_reason

# Strip markdown fences if the model wrapped the JSON
$json = $content -replace '(?s)^\s*```(?:json)?\s*', '' -replace '(?s)\s*```\s*$', ''

$result = @{
    role             = $Expert
    requested_model  = $expertCfg.model
    provider         = $expertCfg.provider
    mode             = $Mode
    result_type      = 'delphi_expert_result'
    finish_reason    = $finish
    raw_content      = $content
}

try {
    $parsed = $json | ConvertFrom-Json
    $result.verdict    = $parsed.verdict
    $result.confidence = $parsed.confidence
    $result.findings   = @($parsed.findings)
    $result.summary    = $parsed.summary
    $result.parsed     = $true
} catch {
    $result.parsed  = $false
    $result.verdict = 'UNPARSEABLE'
    $result.error   = $_.Exception.Message
}

$result | ConvertTo-Json -Depth 8 | Set-Content -Path $OutFile -Encoding UTF8
Write-Output "$Expert ($($expertCfg.model)) -> verdict=$($result.verdict) parsed=$($result.parsed) finish=$finish"
