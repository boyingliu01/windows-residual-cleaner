# Phase 3/6: BUILD — sprint-2026-10-01-01 (auto-rollback)

status: completed
commits: `81a1e91` (S1 journal core), `74da08e` (S2 T3 crash recovery), `17556f3` (`-Auto` entry),
`e1ee356` (shared consumption protocol), `ce44851` (restore-point code 4), `896d0fe` (UI honesty),
then the code-walkthrough hardening chain `b90393d` → `84b39ba` (11 commits, 2026-10-05)

## What was built

Six new modules under `references/scripts/`, all pure-function-first so every decision is testable
in-process:

| Module | Role |
|---|---|
| `rollback-journal.ps1` | journal schema, self-validation, atomic write (REQ-005) |
| `rollback-producer.ps1` | cleanup-side journaling, `Get-CleanupExitCode`, `Test-CompletionMarkerSuppressed` |
| `rollback-verdicts.ps1` | the REQ-024 decision table, `PathCompare` evidence, restorability verdicts |
| `rollback-exec.ps1` | the restore sequence itself (compare-all-then-restore-all) |
| `rollback-recovery.ps1` | T3 crash-window suppression + multi-journal convergence |
| `rollback-backup.ps1` | pre-image capture (registry / PATH / file) |

Wiring: `clean-residuals.ps1` produces and consumes the journal and triggers in-process rollback;
`rollback.ps1 -Auto` is the manual entry; `run-all.ps1` and the UI pipeline run startup T3 in a
fixed order; `create-restore-point.ps1` reports code 4 when the optional layer was not established;
`ui/` tells the truth about protection, exit codes, and rollback verdicts.

The five §3.4 pure functions the design named (`Test-RollbackRestorable`, `Get-RestorableEntry`,
`Resolve-PathEntryScope`, `Get-RollbackVerdict`, `Format-RollbackReport`) are all present, and the
exit-code matrix 10–15 is decided by functions, not by inline arithmetic.

## How BUILD was verified

Every REQ slice went through the pre-commit gate set with `node` on the PATH, with **zero**
`--no-verify` uses. Because the PowerShell gates SKIP silently when `pwsh` is absent from the git
PATH, each slice was additionally re-measured by hand (dual-engine Pester + PSScriptAnalyzer with
`-Settings PSScriptAnalyzerSettings.psd1`).

## What BUILD could not finish inside the phase

The 2026-10-05 hardening chain is the record of a code-walkthrough review that kept finding real
issues (self-validation contract, identity binding, locale handling, blank `cleanup_log_sha256`,
mixed sortable/unparsable candidates, strict three-state `completed_at`). None of those were
cosmetic; each landed with a regression test. Residual open items were handed to VERIFY (DR-012),
not closed by assertion.

## next_phase_context

VERIFY's job: re-check the 29 open medium/low findings from both Delphi releases, run the admin
drill with the user present for UAC, and re-measure the whole suite on both engines at the final
HEAD.
