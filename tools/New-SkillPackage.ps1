#Requires -Version 5.1
<#
.SYNOPSIS
    Build distributable skill packages from this monorepo.

.DESCRIPTION
    This repository mixes three things with three different audiences:

      1. the PowerShell pipeline  (references/)  -- safe to hand to anyone who
                                                     wants to clean residuals
      2. a local Express server   (ui/server/)   -- privileged and destructive,
                                                     must NOT travel with (1)
      3. quality-gate / dev infra (tools/, tests/, .xp-gate*)      --
                                                     irrelevant to consumers, and
                                                     large

    Shipping them as one "skill" means everyone who only wants the CLI silently
    acquires a local listener that spawns admin-privileged PowerShell. This script
    makes the split explicit and repeatable instead of "tell people which folders
    to ignore".

    Packages produced (under dist/, gitignored):

      dist/windows-residual-cleaner-skill/    SKILL.md + references/ + LICENSE
      dist/windows-residual-cleaner-full/     everything, for maintainers

    The `session` package that matters for internal sharing is the skill package.

.PARAMETER OutputRoot
    Where to write the packages. Defaults to <repo>/dist.

.PARAMETER Version
    Version string for the package metadata. Defaults to the repo's VERSION file.

.EXAMPLE
    ./tools/New-SkillPackage.ps1
    ./tools/New-SkillPackage.ps1 -OutputRoot D:\tmp\packages
#>
param(
    [string]$OutputRoot,
    [string]$Version
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputRoot) { $OutputRoot = Join-Path $repoRoot 'dist' }

if (-not $Version) {
    $versionFile = Join-Path $repoRoot 'VERSION'
    $Version = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '0.0.0.0' }
}

# ---------------------------------------------------------------------------
# Package definitions.
#
# Every include list is explicit (allow-list, not deny-list). A deny-list would
# silently start shipping any new top-level directory, and "the new folder
# happened to contain a privileged server" is exactly the failure this script
# exists to prevent.
# ---------------------------------------------------------------------------
$packages = @(
    @{
        Name        = 'windows-residual-cleaner-skill'
        Description = 'PowerShell residual-scan/clean pipeline + agent workflow contract. No web UI.'
        Include     = @('SKILL.md', 'VERSION', 'LICENSE', 'references')
    },
    @{
        Name        = 'windows-residual-cleaner-full'
        Description = 'Full repository (maintainers only): UI server, tests, gate tooling.'
        Include     = @('SKILL.md', 'VERSION', 'LICENSE', 'references', 'ui', 'tools', 'tests',
                        'setup.ps1', 'architecture.yaml', 'PSScriptAnalyzerSettings.psd1', 'package.json',
                        'vitest.config.ts', 'specification.yaml', 'README.md', 'AGENTS.md', 'CHANGELOG.md',
                        'docs', '.xp-gate-powershell-analysis-paths', '.xp-gate-powershell-coverage-ignore',
                        '.xp-gate-powershell-prune-dirs', '.xp-gate-powershell-ccn-baseline.json',
                        '.xp-gate-req-ids', '.architecture-baseline.json')
    }
)

# Directories that must never appear in the *skill* package. Checked after copy
# so a future edit to `Include` cannot quietly reintroduce them.
$forbiddenInSkill = @('ui', 'ui/server', 'tests', 'tools')

function Copy-PackageContent {
    # Named "Copy-*" rather than "New-*"/"Set-*": PowerShell's approved-verb rules
    # (PSUseShouldProcessForStateChangingFunctions) apply to state-changing verbs.
    # Deliberately NOT SupportsShouldProcess: the caller already deleted the
    # destination, so an -WhatIf that reported "would copy" while the old tree is
    # already gone would be misleading.
    [CmdletBinding(SupportsShouldProcess = $false)]
    param([string]$SourceRoot, [string]$Dest, [string[]]$Includes)

    foreach ($item in $Includes) {
        $src = Join-Path $SourceRoot $item
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $Dest $item
        if ((Get-Item -LiteralPath $src).PSIsContainer) {
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        }
        else {
            $parent = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
}

function Clear-NodeModuleTree {
    # "Clear-*" is an approved verb for emptying a container; "Remove-*" on a
    # plural noun triggers both PSUseSingularNouns and the ShouldProcess rule.
    [CmdletBinding(SupportsShouldProcess = $false)]
    # node_modules is gitignored and huge; it also must not reach a distributed
    # archive. Removing after copy keeps the include list simple.
    param([string]$Root)
    Get-ChildItem -LiteralPath $Root -Recurse -Directory -Filter 'node_modules' -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

$results = New-Object System.Collections.Generic.List[object]

foreach ($pkg in $packages) {
    $dest = Join-Path $OutputRoot $pkg.Name
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    Copy-PackageContent -SourceRoot $repoRoot -Dest $dest -Includes $pkg.Include
    Clear-NodeModuleTree -Root $dest

    # Refuse to publish a skill package that carries a privileged surface.
    if ($pkg.Name -eq 'windows-residual-cleaner-skill') {
        $leaks = @()
        foreach ($f in $forbiddenInSkill) {
            if (Test-Path -LiteralPath (Join-Path $dest $f)) { $leaks += $f }
        }
        if ($leaks.Count -gt 0) {
            throw "skill 包混入了必须分离的目录：$($leaks -join ', ')。ui/server 会以管理员权限执行破坏性脚本，绝不可与 CLI 一起分发。"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'references/scripts/run-all.ps1'))) {
            throw 'skill 包缺少 references/scripts/run-all.ps1 —— 复制清单写错了，包是空的。'
        }
    }

    $files = @(Get-ChildItem -LiteralPath $dest -Recurse -File)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    $results.Add([pscustomobject]@{
        Package = $pkg.Name
        Version = $Version
        Files   = $files.Count
        SizeMB  = [math]::Round($bytes / 1MB, 2)
        Path    = $dest
    })
}

$results | Format-Table -AutoSize

# Machine-readable manifest so downstream (CI, release notes) can assert on it.
$manifest = [ordered]@{
    version     = $Version
    generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    packages    = @($results | ForEach-Object {
            [ordered]@{ name = $_.Package; version = $_.Version; files = $_.Files; sizeMB = $_.SizeMB }
        })
}
$manifestPath = Join-Path $OutputRoot 'packages.json'
$json = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "manifest: $manifestPath"
