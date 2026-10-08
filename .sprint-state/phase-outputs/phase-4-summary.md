# Phase 4/6: VERIFY — sprint-2026-10-01-01 (auto-rollback)

status: completed
commits: `def77d9`, `b613d71`, `0d7b658`, `07de72c`, `5808da7`, `12bf152`, `d2cd8c6`,
`fec90f6`, `5dd0a17`, `721cada`

## Final measurements (re-measured by hand at the final HEAD, both engines)

| Check | Result |
|---|---|
| Pester, PS 5.1 | **727 / 727**, 0 failed |
| Pester, pwsh 7 (the engine Gate 5 uses) | **727 / 727**, 0 failed |
| JaCoCo **line** coverage (the number the gate parses) | **84.08%** — 2804 covered / 531 missed / 3335 total, 17 files |
| PSScriptAnalyzer (`-Settings PSScriptAnalyzerSettings.psd1`) | **0** findings on `references/scripts` **and** `setup.ps1` |
| ui/ vitest | 9 files / 59 tests pass, incl. `ui/server/security.test.mjs` (10 cases) |
| Admin drill drill5 (elevated, user authorized UAC) | **23 / 23** checks pass |
| `--no-verify` uses | **0**; `.xp-gate-powershell-coverage-ignore` additions: **0** (the file now excludes nothing) |

> Pester prints a *command*-based "Covered 80.26%" figure; the gate reads JaCoCo line counters from
> `coverage.xml`. The two numbers are not the same metric — quote the JaCoCo one.

## DR-012 — re-check of every open medium/low finding from both Delphi releases

29 findings (r21: 4, r22: 6, d1: 4, d2: 6, d3: 7, d4: 2) → **27 resolved, 2 residual.**
Resolved items were verified against the current text or the built code, not against promises.
The falsification test the panel demanded — crash **after** the cleanup-log write and **before**
`completed_at` — was executed as drill5 fixture `fs_951`: suppressed, and the items were **not**
reinstalled.

**Residual 1 (open, carried to the next sprint).** AC-094's aggregate
`restored_with_low_confidence` exists as a verdict/flag, but `rollback-exec.ps1` `counts` only
splits `restored` / `already_present` / `not_restorable` / `restore_failed`. The mechanical
semantics of "需人工确认" (its own exit code? a UI gate?) are unspecified in the spec, so wiring it
unilaterally would be a new design decision — deliberately deferred.

**Residual 2 (documentation).** Design §8 Q2 still carries stale draft text (per-item undo) that
contradicts normative REQ-024 (any partial failure restores every reversible `mutation_succeeded`
entry). The design document was **left unedited on purpose** — its sha256 is the recorded
`design_hash`, and the built behavior follows REQ-024 (tests + drill5).

## Real defects VERIFY caught (none of them "test didn't run")

1. **`12bf152`** — an unbound `[string]` override parameter is `''`, never `$null`, so
   `$null -ne $MachinePathOverride` was true and the live registry PATH read was **skipped**;
   sign (iii) then compared `''` against the expected value and every real `path_entry` was refused
   as `conflict(external_change_sign_iii)`. This was drill5's 5-failure cascade root cause, and
   **mock tests structurally cannot see it** (they always pass an override). Fixed with
   `$PSBoundParameters.ContainsKey` at all three forwarding sites + regression groups that pin
   "not injected ⇒ the live registry read happens".
2. **`fec90f6` + `5dd0a17`** — REQ-031 exempted only exit 11 from writing `completed_at`, so
   **rc=15 marked the journal complete while damage remained**, permanently cancelling the next
   launch's T3 recovery. Fixed by the pure predicate `Test-CompletionMarkerSuppressed` with three
   damage shapes (a) `restore_failed > 0`, (b) un-journaled mutations > 0, (c) `failedCount > 0`
   **and rollback never attempted**. Shape (c) is load-bearing: every mid-run failure site sets
   `$persistenceError` before `break`, and T2 is skipped once it is set, so **every** 15 has
   `restore_failed == 0` — the narrow rule was unreachable code.
3. **`721cada`** — `setup.ps1`'s coverage exemption ("structurally uninstrumentable") was a code
   defect, not a structural limit: it simply lacked the `Main` + `[ref]` shape ADR-001 mandates.
   Refactored; the ignore list is now **empty**, and the hermeticity contract became an **exhaustive**
   AST sweep over all 11 scripts containing `function Main` (it previously checked only 2, which is
   how the defect survived).
4. **`d2cd8c6`** — the loopback admin server answered cross-origin requests with wildcard CORS;
   replaced by an origin guard, plus `validateItemIds` on `/api/confirm` and removal of a root-path
   leak in `/api/status`.
5. Earlier in the phase: `def77d9` (failed deletion recorded as success ⇒ auto-rollback never
   triggered), `b613d71` (pwsh 7 `ConvertFrom-Json` `[datetime]` breaking journal self-validation),
   `0d7b658` (PATH comparison evidence so a conflict is diagnosable next time).

## Harness traps documented this phase (AGENTS.md 9–13)

Two are measurement-faithfulness traps that produced convincing fake numbers: `$ErrorActionPreference
= 'Stop'` in a local Pester wrapper fabricated 30 failures and pushed coverage down to 79.63%; and
Pester 5 treats `<…>` in an `It` title as a data placeholder while `BeforeDiscovery`-built
`-ForEach` data is unusable.

## Honestly recorded, not reproduced

One pwsh 7 full run reported **720 passed / 1 failed**; two subsequent identical runs were 721/0, and
5 targeted rounds on `scripts` / `rollback-auto` / `rollback-exec` / `permission-gates` each ran
243/0. The failing case was never localized; judged environment-level contention (fixture/handle
residue under back-to-back runs) and kept here as a reference point should it recur.

## next_phase_context

SHIP must re-run the Gate MW panels **after** the final commit — the walkthrough evidence binds to
`git rev-parse HEAD` and any new commit, docs-only included, invalidates all five batches.
