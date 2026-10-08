# Phase 5/6: SHIP — sprint-2026-10-01-01 (auto-rollback)

status: completed
pushed: `origin/master` fast-forward `afd6304` → `3327484` (**46 commits**, 0 behind, 0 force)
date: 2026-10-08

## Gate MW (code-walkthrough) evidence

The pre-push gate requires `.code-walkthrough-result.json` bound to the exact HEAD being pushed.
It was produced by **five real Delphi panels** over the push diff, not written by hand:

| Batch | Scope | Rounds | Final round |
|---|---|---|---|
| A | rollback engine (`rollback-journal/producer/verdicts/exec/recovery`) | 3 | 3/3 APPROVED, ratio 1.0 |
| B | cleanup/scan surface + `setup.ps1` | 2 | 3/3 APPROVED, ratio 1.0 |
| C | `ui/` (React client + `server/index.cjs`) | 2 | 3/3 APPROVED, ratio 1.0 |
| D | heaviest rollback/auto/exec/recovery/scripts tests | 1 | 3/3 APPROVED, ratio 1.0 |
| E | remaining tests + hermeticity contract | 2 | 3/3 APPROVED, ratio 1.0 |

Three distinct models per panel (`g-deepseek-v4-pro` / `doubao-seed-2.0-pro` / `g-qwen3.7-plus`),
roles exactly {architecture, technical, feasibility}, `consensus_ratio = min` over batches = **1.0**,
threshold 90%. Aggregated by `.delphi-work/make-evidence.mjs`; 80 code files reviewed, prose
(`AGENTS.md` / `CHANGELOG.md` / `docs/` / `.sprint-state/`) declared with `--stat` only, matching the
precedent set for the earlier push.

**Why the panels were re-run from scratch:** the first pass at `5808da7` blocked batches B and C at
1/3 approvals, and both blocking reports were genuine defects that were subsequently fixed
(completion marker under rc=15; wildcard CORS on the admin-spawning server). Fixing a finding in
one batch creates a commit, which invalidates the commit-bound evidence for **all** batches — so the
correct move is a full re-run against fixed code, not arguing the old report down. A full
sequential re-run costs about 2.5 minutes of wall time.

One expert raised a path-traversal finding on `runPS`/`streamPS` in its final round and then
withdrew it in the same report (every call site hardcodes the script name; no user input reaches the
argument). Read the report to its end before treating a table row as a blocker.

## What SHIP did **not** do (open, needs a release decision)

- **No version bump and no tag.** `VERSION` is still `1.4.1.0` and the whole auto-rollback body of
  work sits under `## [Unreleased]` in `CHANGELOG.md`. Cutting a release (e.g. `v1.5.0.0`, tag,
  changelog section move) is a separate decision — it is one more commit, which means another
  Gate MW re-run before it can be pushed.
- The remote branch `refs/heads/fix/test-dotsource-hang` (at `41c2f09`) was left on the server. Its
  patches are provably all in master (`git cherry master origin/fix/test-dotsource-hang` → 0 `+`),
  so deleting it is safe — but deleting a **remote** ref is a shared-state action and was not part of
  the authorized cleanup.

## next_phase_context

CLOSE: retire the sprint worktree/branches, write the per-phase summaries (this file set), and
re-run `xp-gate sprint-audit` for completeness.
