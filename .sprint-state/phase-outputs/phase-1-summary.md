# Phase 1/6: PREP — sprint-2026-10-01-01 (auto-rollback)

status: completed
completed_at: 2026-10-02
commits: `45877da`, `34a0817`

## What this phase actually did

PREP was not a paperwork phase: the baseline was **untrustworthy** and had to be repaired
before any safety feature could be built on it.

- **Blocker B1 (resolved).** The suite was not hermetic — `clean-residuals.ps1` `Main` required a
  gitignored `backup-*` directory and called `exit 1` without one. Inside a fresh worktree / clone /
  CI that `exit` killed the Pester host, the run finalization collapsed at `Pester.psm1:4983`, and
  the summary printed `Passed= Failed= Total=` **empty** — so CI reported green while the largest,
  most safety-critical test file (`scripts.Tests.ps1`) never ran.
- **ADR-001** (`docs/decisions/ADR-001-main-ref-exit-code.md`): all `Main` functions relay their
  exit code through `[ref]$ExitCode`; 25 `exit` statements removed from 8 scripts; the single
  `exit` lives in the file-level execution guard. `Test-AdminPrivilege -Mandatory` returns
  `$false` instead of exiting. Two of the three candidate designs were rejected by measurement,
  which the ADR records.
- **Regression guard**: `tests/unit/hermeticity.Tests.ps1` asserts the contract by AST.
- **Coverage gate met honestly**: 70.4% → 80.0% (1065/1331) with real tests. Three real product
  defects were found by those tests (empty-array-in-`if` expression writing `{}` instead of `[]`
  into `final-report.json`; top-level pure functions calling the caller's `$setRc`; three
  duplicated unreachable `& $setRc 3; return` blocks).
- **Pristine-clone proof** (the condition that used to collapse the suite): detached worktree at
  `34a0817` with **zero** `backup-*` directories → 287/287 pass on PS 5.1 **and** pwsh 7, 80%
  coverage, 0 analyzer findings.

## Decisions taken

- **DR-001** — fix the non-hermetic/false-green baseline first (option A), rather than build
  auto-rollback on a signal that cannot be trusted.
- **DR-002** — unblock the 80% gate with real tests/refactors. The user explicitly rejected
  `--no-verify`, adding files to `.xp-gate-powershell-coverage-ignore`, and mock-console coverage.
  Zero `--no-verify` uses in this sprint.

## Outputs

- `docs/decisions/ADR-001-main-ref-exit-code.md`
- `tests/unit/hermeticity.Tests.ps1`, `tests/unit/create-restore-point.Tests.ps1`,
  `tests/unit/rollback.Tests.ps1`
- 10 new/extracted pure functions (`ConvertFrom-WingetJson/Text`, `Get-ResidualVerdict`,
  `Get-MatchingRestorePoint`, …)
- test count 141 → 287; coverage 80.0%; analyzer findings 0

## next_phase_context

The baseline is green **in a clean checkout**, so design work can proceed without the risk of
being validated by a false green. Remaining hazard carried forward: the pre-commit hook is
vacuous for PowerShell when `pwsh`/`node` are absent from the git PATH (gates SKIP silently), so
verification numbers must be re-measured by hand, not inferred from a green gate report.
