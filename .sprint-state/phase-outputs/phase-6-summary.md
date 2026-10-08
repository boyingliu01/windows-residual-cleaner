# Phase 6/6: CLOSE — sprint-2026-10-01-01 (auto-rollback)

status: completed
date: 2026-10-08

## What CLOSE did

**Retired the sprint isolation, with proof before deletion** (user-authorized):

- `master..sprint/2026-10-01-01` = **0** unmerged commits; `master..fix/test-dotsource-hang` = **0**;
  `git cherry` on both sides = **0** patches absent from master (patch-id level, so a rebase could not
  have hidden anything).
- The worktree's only uncommitted content was `M .sprint-state/decisions.md` (a strict subset — it
  lacked DR-013…DR-015) and `?? sprint-state.json.backup`. Both, plus the worktree's `.sprint-state`
  JSONs (including its `delphi-reviewed.json`, verified byte-equivalent `design_hash`
  `bfb0032…`), `.xp-gate/` gate history, and `.quality-history.jsonl`, were archived to
  `.delphi-work/worktree-archive/` **before** removal.
- Then: `git worktree remove --force`, `git branch -d sprint/2026-10-01-01`,
  `git branch -D fix/test-dotsource-hang` (the `-d` refusal was purely the stale *upstream* ref: the
  remote branch is 16 commits behind local, and all local commits are in master). Empty
  `.worktrees/sprint/` pruned. `master` is the only local branch.

**Side effect worth knowing**: removing `.worktrees/` eliminates 255 of the ~675 repo-wide
PSScriptAnalyzer findings that would block every commit if `pwsh` were put on the hook PATH. It does
**not** fix Gate 1's unfiltered `Invoke-ScriptAnalyzer -Path . -Recurse` (tests + `wrc-drill` still
produce ~420 findings), and the `.worktrees` prune patch in `~/.config/xp-gate/**` is still a manual
user handoff.

**Wrote the missing rule-5 deliverables**: `phase-1-summary.md` … `phase-6-summary.md` in this
directory.

## `xp-gate sprint-audit` after CLOSE

Phase coverage 6/6. Two warnings remain **and are deliberately not silenced**:

- *Phase 1/2 "completed but has no duration recorded"* — those history entries were hand-written by
  the previous harness before the `xp-gate` CLI became the single sanctioned writer (DR-005). Any
  duration I write now would be invented. The warning is the accurate state.
- `.sprint-state/sprint-state.json` still carries a stale `phase_note` ("phase=0 (PREP)
  deliberately … no delphi-reviewed design yet") from that same hand-written era. The CLI does **not**
  own `phase_note` (no flag exists for it) and the sprint-flow skill forbids hand-editing that file,
  so the corrected sequence is recorded here and in `decisions.md` instead. Phases 3–6 were recorded
  through `xp-gate phase-transition` with measured outputs.

## Items handed forward (not closed by assertion)

1. **Release decision**: `VERSION` is `1.4.1.0` and the auto-rollback work is under
   `## [Unreleased]`; no bump, no tag. Cutting a release is another commit ⇒ another Gate MW run.
2. **DR-012 Residual 1**: AC-094's `restored_with_low_confidence` has no mechanical semantics in the
   spec, so `rollback-exec.ps1` `counts` does not split it. Needs a design decision, not a patch.
3. **Design §8 Q2 stale draft text** (Residual 2) — left unedited on purpose to preserve
   `design_hash`; REQ-024 is normative and the implementation follows it.
4. **Remote branch** `fix/test-dotsource-hang` still on the server (safe to delete; shared-state
   action, so untouched).
5. **Gate 1 analyzer scope** + `.worktrees` prune patch: user-side hook edit, still pending.
6. **Unreproduced pwsh 7 flake** (720/1 once, then 721/0 and 727/727) — see `phase-4-summary.md`.
7. `wrc-drill/` and `.delphi-work/` stay untracked by decision (DR-015).
