# Windows Residual Cleaner

[![CI](https://github.com/boyingliu01/windows-residual-cleaner/actions/workflows/ci.yml/badge.svg)](https://github.com/boyingliu01/windows-residual-cleaner/actions/workflows/ci.yml)

Scan and clean up residuals left by uninstalled software on Windows systems.

This is an **agent-facing skill**, not a hands-off utility: it produces a risk-classified
itemized report, and a human decides what actually gets deleted. Three confirmation gates
stand between "scan" and "delete", and every destructive step is preceded by a restore
point plus a per-item backup. See [docs/agent-workflow-pattern.md](docs/agent-workflow-pattern.md)
for why the flow is shaped that way.

## Features

- **Multi-source installed software index** — Registry, winget, scoop, chocolatey, MSI, UWP (6 sources)
- **Comprehensive residual scanning** — Registry keys, filesystem directories, ghost services, scheduled tasks, COM/Shell extensions, startup entries, PATH entries
- **Risk classification** — Safe / Caution / Danger with unique IDs per item
- **Safety first** — Automatic system restore point + registry backup before cleanup
- **Defense-in-depth** — Whitelist re-checked at cleanup time
- **Four cleanup modes** — Auto-clean Safe (A), Safe+Caution review (B), Full review (C), Report only (D)
- **Dry-run** — Preview what would be deleted without making changes
- **Rollback guidance** — Lists available restore points and backup locations

## Compatibility

- **Platform:** Windows 10/11
- **Requires:** PowerShell 5.1 for the scripts (PowerShell 7 also works); Administrator
  privileges **for deletion only** — see [SKILL.md](SKILL.md) for the exact per-script split
- **Execution Mode:** Agent-driven — the user states intent, the agent scans and presents
  the list, the user selects the items to clean

## Documentation

| Document | What it is | Status |
|----------|-----------|--------|
| [SKILL.md](SKILL.md) | Agent execution manual — privilege model, the three gates, four-tier deletion semantics, exit codes | **Current**, ships in the package |
| [docs/agent-workflow-pattern.md](docs/agent-workflow-pattern.md) | The domain-free design contract for "let an agent perform destructive operations", written so other teams can lift it | **Current**, most portable asset |
| [docs/decisions/ADR-001-main-ref-exit-code.md](docs/decisions/ADR-001-main-ref-exit-code.md) | Why every `Main` returns its exit code via `[ref]` instead of `exit` | **Current**, enforced by an AST test |
| [AGENTS.md](AGENTS.md) | Maintainer guide — 16 PowerShell 5.1 traps, architecture rules, test strategy | **Current** |
| [CHANGELOG.md](CHANGELOG.md) | Release history | **Current** |
| [docs/README.md](docs/README.md) | Index of the documents above plus the historical records | — |

## Quick Start

```powershell
# 0. Environment check (optional)
powershell -ExecutionPolicy Bypass -File setup.ps1

# 1. Scan: restore point + installed index + all residual scans + consolidated report
powershell -ExecutionPolicy Bypass -File references/scripts/run-all.ps1
#    Skip the restore point (cleanup then becomes unrecoverable):
powershell -ExecutionPolicy Bypass -File references/scripts/run-all.ps1 -SkipRestorePoint
#    Manual equivalent, in order:
#      create-restore-point.ps1 → build-installed-index.ps1 → scan-uninstalled.ps1
#      → scan-filesystem-residuals.ps1 → scan-residuals.ps1 → generate-report.ps1

# 2. Confirmation (choose one)
# 2a. Dialog-based (AI agent handles interaction, no window switching):
#     Agent reads report, asks user, then runs non-interactive export:
powershell -ExecutionPolicy Bypass -File references/scripts/confirm-cleanup.ps1 -NonInteractive -AutoSelect safe
#     Or export specific IDs:
powershell -ExecutionPolicy Bypass -File references/scripts/confirm-cleanup.ps1 -NonInteractive -SelectIds '["fs_001","fs_002"]'
# 2b. Interactive TUI (standalone Windows Terminal only — Read-Host crashes in OpenCode):
powershell -ExecutionPolicy Bypass -File references/scripts/confirm-cleanup.ps1
# → Outputs confirmed-ids.json with user-selected items

# 3. Cleanup confirmed items (use -ConfirmFile from step 2)
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -ConfirmFile confirmed-ids.json
# Dry-run preview (recommended first):
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -ConfirmFile confirmed-ids.json -DryRun
# Legacy mode (without interactive confirmation):
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -Mode D

# 4. If needed, show rollback instructions
powershell -ExecutionPolicy Bypass -File references/scripts/rollback.ps1
```

## Project Structure

```
windows-residual-cleaner/
├── SKILL.md                       # Agent execution manual (ships inside the skill package)
├── README.md                      # This file
├── AGENTS.md                      # Maintainer guide: PS 5.1 traps, architecture rules
├── CHANGELOG.md                   # Release-by-release history
├── LICENSE                        # MIT License
├── setup.ps1                      # Environment compatibility check
├── specification.yaml             # REQ/AC registry (source of the exit-code contract)
├── references/
│   ├── config/
│   │   ├── config.json            # Scan thresholds and target directories
│   │   └── whitelist.json         # Protected patterns (never delete)
│   └── scripts/                   # 17 scripts; see the pipeline table below
├── tools/                         # Repo-maintenance tooling (not shipped to users)
│   ├── Update-DocTables.ps1       # Regenerates the exit-code tables in all docs
│   ├── Measure-PowerShellComplexity.ps1  # CCN measurement for the Gate 3 ratchet
│   ├── Update-ComplexityBaseline.ps1     # Rewrites the CCN baseline
│   ├── Test-PowerShellArchitecture.ps1   # Gate 6 architecture check
│   └── New-SkillPackage.ps1       # Builds the distributable skill package
├── ui/                            # Optional local web UI (React + Express, binds 127.0.0.1)
│   ├── src/
│   └── server/                    # Local API; spawns the scripts above with admin rights
├── tests/
│   ├── unit/                      # 24 files: one per script plus cross-cutting contracts
│   └── integration/               # 2 files: per-script Main against fixtures, and the
│                                  #   end-to-end pipeline
└── docs/
    └── README.md                  # Index of every document, with its status
```

`references/scripts/` is split into the scan pipeline and the rollback subsystem:

| Group | Scripts |
|-------|---------|
| Pipeline entry point | `run-all.ps1` — runs steps 1–6 below, scan only |
| Scan steps | `create-restore-point.ps1`, `build-installed-index.ps1`, `scan-uninstalled.ps1`, `scan-filesystem-residuals.ps1`, `scan-residuals.ps1`, `generate-report.ps1` |
| Confirm / clean | `confirm-cleanup.ps1`, `clean-residuals.ps1` |
| Rollback | `rollback.ps1` (CLI) plus the libraries it shares with `clean-residuals.ps1`: `rollback-journal.ps1`, `rollback-backup.ps1`, `rollback-verdicts.ps1`, `rollback-recovery.ps1`, `rollback-exec.ps1`, `rollback-producer.ps1` |
| Shared helper | `native-invoke.ps1` — the only sanctioned way to launch a native executable |

Rollback libraries have no top-level `param()` on purpose: `clean-residuals.ps1` and
`rollback.ps1` dot-source the same five files in the same order, so a stray `param()`
would clobber the caller's variables (see `AGENTS.md` trap 8a).

## Risk Levels

| Level | Behavior | Example |
|-------|----------|---------|
| **Safe** | Auto-cleanable | Empty directory, ghost service with missing binary |
| **Caution** | Requires confirmation | Vendor registry key, COM extension with missing DLL |
| **Danger** | Report only, never auto-delete | PATH entry (may be referenced by other software) |

## Safety

- Before ANY cleanup: System restore point must exist (or user explicitly opted out)
- All registry changes are backed up to `backup-<timestamp>/` directory
- Whitelist patterns are re-checked at cleanup time (defense-in-depth)
- Danger-rated items are never cleaned, even in Mode A

## Running Tests

The suite is Pester 5, and it must pass on **both** engines: the runtime baseline is
PowerShell 5.1, while the pre-commit gate runs Pester under `pwsh` 7.

```powershell
Install-Module Pester -Scope CurrentUser -Force   # if not present

powershell.exe -NoProfile -Command "Invoke-Pester tests"   # 5.1
pwsh -NoProfile -Command "Invoke-Pester tests"             # 7
```

Run the two **serially, never concurrently** — some fixtures use fixed paths under the
repo root and the two runs will corrupt each other. Integration tests that touch real
registry/service state expect an elevated session.

## Code Quality

All scripts pass PSScriptAnalyzer with zero errors and zero warnings:

```powershell
Invoke-ScriptAnalyzer -Path references/scripts -Recurse -Settings PSScriptAnalyzerSettings.psd1
```

The settings file excludes `PSReviewUnusedParameter` only: every script declares its
entry parameters in a top-level `param()` block and consumes them inside `function Main`,
which that rule cannot follow across scopes. The single genuinely unused parameter it
flagged (`run-all.ps1 -Verbose`) was removed instead of suppressed.

### Pre-commit quality gates (xp-gate)

Commits run a 12-gate quality chain (static analysis, tests + coverage ≥ 80%,
semgrep SAST on `.ps1`, secret scanning, architecture diff, sprint-flow
enforcement). The chain lives **outside this repo** in a user-level hook install
(`core.hooksPath` → `~/.config/xp-gate/hooks`), so a **fresh clone on a machine
without that install silently runs the degraded/idle variants** of those gates.
Three tracked files keep the repo-side boundary explicit and are enforced by
tests in `tests/unit/platform-hygiene.Tests.ps1` (门禁边界一致性):

- `.xp-gate-powershell-analysis-paths` — the product scope Gate 1 lint scans;
  **a new product script must add its path in the same commit** (missing paths
  fail closed to WARN).
- `.xp-gate-powershell-prune-dirs` — scratch/drill directories kept out of
  test discovery, coverage denominator, and analysis scope (currently `wrc-drill`).
- `.xp-gate-powershell-coverage-ignore` — intentionally **empty**: per-artifact
  subtraction from the coverage denominator is not allowed.

xp-gate itself is **not** vendored here. Its hooks, adapters and code live in the
xp-gate project and are installed/upgraded through the system-management flow —
this repo only consumes the released version. (An earlier layout kept a hardened
copy under `githooks/` plus a hash comparison against the live install; that
design assumed this repo maintained downstream patches to xp-gate, which it no
longer does. Keeping it meant every upstream release turned the suite red for a
reason that had nothing to do with this repo. The one thing this repo *can* be
responsible for is that the gate chain is still wired up, and
`tests/unit/platform-hygiene.Tests.ps1` still asserts exactly that:
`core.hooksPath` resolves to the xp-gate hooks directory and a `pre-commit`
script exists there.)

## License

MIT License — see [LICENSE](LICENSE).
