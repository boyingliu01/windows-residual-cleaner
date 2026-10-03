# Decisions — sprint-2026-10-01-01

## Decision DR-001
- **Phase**: 1/6 PREP
- **Question**: Baseline was not hermetic (blocker B1) — how to proceed?
- **Options**: (A) fix the non-hermetic/false-green suite first, then build auto-rollback;
  (B) build the feature on the untrustworthy baseline; (C) abandon the sprint
- **Choice**: **A**
- **Rationale**: the suite silently collapsed in any fresh worktree/clone/CI, so every
  "test passed" signal was untrustworthy — building a safety feature on it would be unsafe.
- **Timestamp**: 2026-10-01

## Decision DR-002
- **Phase**: 1/6 PREP
- **Question**: The commit was blocked by the 80% coverage gate. How to unblock?
- **Options**: (1) make the gate honestly passable with real tests/refactors;
  (2) commit with `--no-verify`; (3) add files to `.xp-gate-powershell-coverage-ignore`;
  (4) raise coverage by mocking consoles/admin paths
- **Choice**: **1**
- **Rationale**: user explicitly rejected 2–4. The gate's own ignore-file comment says
  "Do NOT add files here merely because they are hard to test", and mock-console coverage
  would be gaming the metric rather than earning it.
- **Outcome**: 70.4% → 80.0% with real tests; 3 real product bugs found in the process.
  Committed with **zero** `--no-verify`.
- **Timestamp**: 2026-10-01

## Decision DR-003
- **Phase**: 2/6 DESIGN
- **Question**: What scope for the auto-rollback feature?
- **Options**: fully automatic; semi-automatic (user-triggered rollback); guidance-only
- **Choice**: **fully automatic**
- **Rationale**: user's explicit selection.
- **Follow-up**: the analysis then found that "fully automatic" cannot honestly include
  whole-system `Restore-Computer` (it reverts unrelated changes and requires a reboot), so
  the automatic path is narrowed to in-process targeted undo. See open question Q1 in
  `docs/plans/2026-10-02-auto-rollback-design.md` §7 — pending confirmation.
- **Timestamp**: 2026-10-02

## Decision DR-004
- **Phase**: 2/6 DESIGN
- **Question**: How should real-machine write operations be authorised?
- **Options**: authorise everything; ask before each write; user runs drills themselves
- **Choice**: **authorise, but ask before each real write and wait for confirmation**
- **Rationale**: user's explicit selection. Balancing speed against the risk of an
  unreviewed destructive action on a live machine.
- **Timestamp**: 2026-10-02

## Decision DR-005
- **Phase**: 2/6 DESIGN
- **Question**: Where should the sprint `phase` value sit while the design is unreviewed?
- **Options**: report `phase: 2` (as stale state claimed); report `phase: 0`
- **Choice**: use the **`xp-gate` CLI** as the single source of truth
- **Rationale**: Gate 11 requires `.sprint-state/delphi-reviewed.json` when `phase >= 1`.
  The honest sequence is PREP completed → DESIGN in progress → R1/R2 review → APPROVED.
  Fabricating a `delphi-reviewed.json` to pass the gate would defeat the gate's purpose.
- **Timestamp**: 2026-10-02

## Decision DR-006 — design HARD-GATE approved
- **Phase**: 2/6 DESIGN
- **Question**: Approve the auto-rollback design (`docs/plans/2026-10-02-auto-rollback-design.md`)?
- **Choice**: **APPROVED**, with all four recommendations accepted:
  - **Q1 = in-process targeted rollback**, restore point kept as a manual escape hatch.
    The tool will *arm and document* a restore point but will never fire `Restore-Computer`
    by itself (it would revert unrelated changes and force a reboot).
  - **Q2 = trigger on `summary.failed > 0`**, with **per-item** targeted undo rather than an
    all-or-nothing revert of the whole run.
  - **Q4 = fold the four extra defects into this sprint** (D-1 PATH pre-image, D-2 truthful
    `path_deleted` outcome, D-3/D-4 real backup precondition + loud failure from
    `create-restore-point.ps1`). Rollback built on a lying log and a fake backup gate would
    be worse than no rollback.
  - **Q6 = the admin drill includes a real restore-point creation attempt** (to exercise the
    24h throttle and System Protection state), plus a synthetic
    clean → forced-failure → auto-rollback round trip.
- **Rationale**: user approved the recommendation set as presented.
- **Timestamp**: 2026-10-02

## Decision DR-007
- **Phase**: 2/6 DESIGN
- **Question**: What is the honest scope of the automatic path?
- **Options**: (a) automatic = in-process targeted undo of the reversible subset;
  (b) automatic = unattended whole-system `Restore-Computer`
- **Choice**: **(a)**
- **Rationale**: `Restore-Computer` reverts the entire volume (destroying unrelated user
  work done after the snapshot) and requires a reboot, so it cannot be an automatic,
  in-process step. Capability ceiling documented in the design §3.6 and §3.7. The tool must
  never claim that deleted file/service/task data has been recovered.
- **Timestamp**: 2026-10-02

---

## DR-008 — Delphi R1 requirements review: 11 rounds to convergence (2026-10-02)

**Context.** R1 (requirements mode) ran 11 rounds against the WhaleCloud gateway with three
experts on three distinct models. The spec grew from 23 REQ / 32 AC / 12 DD to
**30 REQ / 60 AC / 18 DD** as a direct result.

**Why so many rounds.** Two distinct causes, and it matters which is which:

1. *Genuine spec defects* the panel was right to block on:
   - REQ-018/REQ-024/REQ-029 each defined their own restore rule and **contradicted each other**.
     Resolved by making REQ-024 the single authoritative decision table.
   - `mutation_succeeded + pre_existing` did **not** prove this run caused the current absence.
     Two further rounds were spent trying to close this with more flags; the panel correctly
     kept rejecting it. See DR-009.
   - Exit-code matrix had no code for `-NoAutoRollback` (13), prior-run recovery failure (14),
     or mid-run journal flush failure (15).
   - Sign (ii) of the external-change detector **self-triggered**: our own registry deletion
     updates the parent key's `LastWriteTime`, so comparing against run start made the tool's
     own mutation look external, rendering auto-restore unreachable. Fixed by recording a
     post-mutation baseline.
   - Journal writes were not atomic, so a crash mid-write left a malformed journal that
     REQ-027 would then reject — defeating T3 recovery.
2. *Churn from my own AC/REQ wording drifting apart.* Several rounds were spent re-aligning
   AC text with REQ text I had just changed (e.g. AC-026/AC-034 still said "absent → restore"
   unconditionally after REQ-024 became conditional). **Lesson: when a REQ changes, sweep every
   AC that references it in the same edit.**

**Decision.** Continue to convergence rather than accept-with-dissent, because every remaining
blocker was a real safety or testability defect, not a stylistic difference.

## DR-009 — Bounding the restore claim instead of stacking unprovable flags (DD-018)

**Context.** Rounds 8, 9 and 10 each added a flag to the causal chain to prove "the current
absence is attributable to this run". The panel defeated each one, correctly: an external
create+delete after the last check satisfies every flag. Windows provides no tamper-evident
channel to close this.

**Decision.** Stop adding flags. **Bound the claim instead**: auto-restore only when the three
flags hold *and* `created_at` is within a 24-hour window *and* none of five mechanically
detectable external-change signs are present; otherwise degrade to `conflict` + manual.

**Rationale.** The alternative — continuing to add flags — cannot converge and would still be a
false guarantee. Denying the limit outright would be dishonest. Bounding it keeps the common
case (immediately after a crash) automatic, which is what the user asked for, while being
explicit that older or ambiguous cases go to a human.

**Consequence.** The UI must not claim "we can always reliably restore". Recorded as DD-018 and
the residual risk is stated in the spec rather than hidden.

## DR-010 — Delphi R1 did not converge in 22 rounds: release with recorded dissent

**Context.** The R1 requirements review ran **22 rounds** against
`.sprint-state/phase-outputs/specification.yaml`, using exactly three experts on three distinct
executable models (`b-claude-4.8-opus`, `g-deepseek-v4-pro`, `gpt-5.5`), each dispatched as its
own process, with a ≥90% consensus threshold and `max_review_rounds: 5`.

**It never reached 3/3.** Best result over 22 rounds was 1/3 APPROVED (architecture at rounds 2-5,
7-8, 10-11, 13; technical once at round 18). The final round was 0/3.

**Why it did not converge — measured, not guessed.** Findings per round by severity, rounds 12-22:

| round | critical | high | medium | low |
|---|---|---|---|---|
| 12 | 2 | 9 | 6 | 0 |
| 13 | 0 | 5 | 6 | 3 |
| 14 | 3 | 6 | 6 | 0 |
| 15 | 2 | 6 | 8 | 1 |
| 16 | 2 | 10 | 5 | 0 |
| 17 | 3 | 9 | 3 | 0 |
| 18 | 2 | 5 | 9 | 2 |
| 19 | 3 | 6 | 4 | 2 |
| 20 | 3 | 6 | 5 | 1 |
| 21 | 3 | 8 | 4 | 0 |
| 22 | 3 | 7 | 5 | 1 |

The rate is **flat, not decaying** — roughly 3 critical + 7 high per round, sustained through
round 22. This is the signature of a review loop that is *generating* findings as fast as it
retires them, not one that is converging.

Crucially, the findings were **genuinely correct** — this is not reviewer noise. Every round
caught real defects, several of them severe:

- **R15**: a *successful* cleanup never closed its journal, so the next launch would treat a
  correctly-finished run as unfinished T3 and **reinstall everything it had just deleted**.
- **R15**: "atomic" was specified as `Move-Item -Force`, which in PS 5.1 is delete-then-move and
  therefore has a window where the journal does not exist. Now `[System.IO.File]::Replace()`.
- **R16**: Step 1 collected *completed* journals, so a prior successful run failed
  self-validation and made **every subsequent cleanup return 14** — the tool could never run again.
- **R16**: sign (ii) self-triggered *during rollback*, so restoring several entries under one
  parent made later entries look externally modified. Fixed with two-phase verdict-then-execute.
- **R17**: a crash *after* a successful cleanup but *before* the completion marker still
  resurrected the just-deleted items. Now suppressed.
- **R19**: the suppression step was ordered *after* self-validation, so it could never be reached
  in exactly the case it existed for. Moved to Step 2.5.
- **R21**: the `kind` enum omitted file/directory deletion entirely, so `path_deleted` actions
  could not be journaled at all.
- **R22**: `path_deleted` still absent (my R21 edit silently no-op'd), and the failed-consumption
  marker was not gated in Step 1.

**Also found: duplicate YAML keys** (`priority`/`addresses` on REQ-019, `test_type` on AC-075 and
AC-087). These were invisible to `yaml.safe_load` (last-wins) and to my own validator until I
added a duplicate-key-detecting loader. Two of them were mine.

**Decision (user-selected).** Run two more rounds (21, 22); if they do not converge, **release
with recorded dissent**. They did not converge, so:

1. All **critical** and **high** findings from rounds 21-22 are fixed in revision 20 of the spec.
2. R1 is **accepted at 1/3 APPROVED with dissent recorded here** — NOT represented as consensus.
3. `requirements-reviewed.json` records `consensus_ratio: 0.33` and the per-expert verdicts
   truthfully, so Gate 11 and any later reader see the real state.
4. **Proceed to BUILD.** Continuing to iterate was rejected because marginal value has fallen
   below the cost: the spec is at 96 ACs and the mechanism's hard parts (T3 recovery, atomic
   journaling, conflict rules) are now pinned down precisely *because* these 22 rounds forced
   them to be.

**Rationale for proceeding rather than looping further.** The remaining findings are
specification-completeness issues on a document that no longer has a build. Crucially, several
of the open questions are ones **only implementation can settle** — e.g. whether
`File.Replace` behaves identically on the target filesystems, and what the real
`LastWriteTime` granularity is for HKLM writes. Those were being argued speculatively for
rounds 14-22. Building the mechanism and testing it against a real machine will retire them
faster and more honestly than another ten rounds of prose review.

**Consequence — carried forward as explicit debt.**
- Unresolved medium/low findings from rounds 21-22 remain open; they are listed in
  `requirements-reviewed.json` under `gaps[]` and must be re-checked in VERIFY.
- **R2 (design review) must still reach a real verdict** on
  `docs/plans/2026-10-02-auto-rollback-design.md` before BUILD writes product code.
- Every REQ/AC added in rounds 14-22 is **untested prose**. The acceptance criteria are the
  deliverable of BUILD+VERIFY, not evidence of working code. Nothing here should be described
  as "verified" until a real drill passes.
- The lesson from DR-008 stands and is now sharpened: **when a REQ changes, sweep every AC that
  references it in the same edit** — and verify the edit actually changed the file, since a
  silent no-op swap cost a full review round (R21→R22 `path_deleted`).

## DR-011 — R2 design review: released at 0/3 after 4 rounds, same non-convergence signature

**Context.** After R1 was released under DR-010, the R2 design review ran over
`docs/plans/2026-10-02-auto-rollback-design.md` using the same three-expert panel and a
design-specific payload. Four rounds were run.

**It did not converge either.** Findings by severity per round:

| round | critical | high | medium | low |
|---|---|---|---|---|
| d1 | 5 | 9 | 4 | 0 |
| d2 | 3 | 9 | 5 | 1 |
| d3 | 2 | 8 | 7 | 0 |
| d4 | 7 | 7 | 2 | 0 |

Critical findings went **5 → 3 → 2 → 7**. This is the same shape as R1: a loop generating
findings as fast as it retires them, not a decaying one. Round d4's rise is partly explained by
my d3 fixes *introducing* new text the panel then reviewed — a treadmill, not a convergence.

**What the design review did catch, and it was worth the rounds.** Unlike R1's prose-polish tail,
this phase found genuine build-blockers:

- **A `14(d)` / `15(ii)` exit-code collision**: "both consumption markers failed to write" was
  specified under *both* codes, so one event had two valid answers. Now split by a single
  decidable rule — failure **inside this run** → 15; a **previous** run's journal unconsumable
  at startup → 14 — and they are mutually exclusive by construction.
- **A design/spec schema divergence**: the design's §3.1 example used `started_at`, `status`,
  `pending`, `file_path`, and a timestamp `run_id`, while REQ-027/REQ-032 require `created_at`,
  `state`, `planned`, `path_deleted`, and a **GUID**. An implementer copying the example — which
  the doc told them to do — would have produced journals that fail self-validation, so on T3 the
  deletions would never be rolled back. All corrected.
- **§3.2 directly contradicted DD-003** on startup-value backup ("parent export + prune is not
  acceptable" vs. DD-003 prescribing exactly that).
- **DD-010 made the System Restore point a hard precondition**, contradicting REQ-003/REQ-025 and
  the approved Q1 decision (optional escape hatch). Corrected: the per-item backup is mandatory,
  the restore point is optional, and what is mandatory is *not reporting success when it failed*.
- **The 24h window was called "configurable"**, contradicting REQ-024's fixed safety boundary.
- **`Get-RegistryKeyLastWriteTime` did not exist and is not reachable via any managed API** — the
  design's sign (ii) was unbuildable. I proved it with a P/Invoke probe (see below).
- **`File.Replace` cannot perform a first write**, and `Replace(tmp,target,$null)` throws.

**Three primitives were settled by measurement rather than argument**, which is the concrete
payoff of switching from review to build:

1. `[Microsoft.Win32.RegistryKey]` exposes **no** `LastWriteTime` in either PS 5.1 or pwsh 7
   (verified), so sign (ii) needs P/Invoke `RegQueryInfoKey`. The working form was probed, and two
   traps were found: `.Handle` returns a `SafeRegistryHandle` (must use
   `.DangerousGetHandle()`), and the PS 5.1 C# compiler rejects `ref`-returning members. A
   `SetValue` was measured to advance the parent timestamp by ~1238 ms, so the signal is real.
2. `File.Replace(tmp, target, prev)` with a **pre-existing** `.prev` works repeatedly across
   generations (verified through gen 6, exactly one `.prev` retained), so the one-generation
   retention protocol is sound. First write must use `File.Move`; `$null` backup throws.
3. The `reg export` → trim → `reg import` path needs **Unicode** encoding end to end
   (`reg export` emits UTF-16LE with BOM; PS 5.1's default `Get-Content` yields NUL garbage).

**Decision.** Stop the design review at 4 rounds and proceed to BUILD, for the same reason as
DR-010 but with a sharper justification: **the remaining findings are now disproportionately
things only implementation can settle.** Rounds d1-d4 repeatedly re-litigated the same
interaction (Step 2.5 vs. Step 3 ordering vs. Step 4a consumption), each time producing a
self-consistent prose fix that generated a new adjacent question. That is the signature of a
specification whose *combinatorial* interactions exceed what prose review can close — and of
questions (real `File.Replace` behaviour on the target filesystem, actual registry timestamp
granularity, whether the trim function's single-value contract holds on real `reg export` output)
that a build plus tests answers definitively in one pass.

**Consequence — accepted, recorded debt.**
- R2 is released at **0/3 APPROVED**. Recorded truthfully in `delphi-reviewed.json`; **not**
  represented as consensus.
- All critical/high findings from d1-d4 that could be fixed in prose **are** fixed.
- Remaining medium/low findings stay open and are listed in the recorded dissent.
- **The feature is still unbuilt.** 35 REQs / 100 ACs are *specification*, not working code.
  Nothing may be described as verified until the drill passes.
- Highest-risk area, to be falsified first in BUILD (per the panel): **T3 journal
  persistence and selection.** The specific falsification test is a crash injected *after* a
  successful cleanup-log write but *before* `completed_at`, asserting the just-deleted items are
  **not** reinstalled.
- Known accepted residual risk, stated rather than hidden: within the window, an external
  create+delete cycle that trips none of signs (i)-(iii) is indistinguishable from our own
  deletion (DD-018). And **T3 automatic recovery is the exception, not the rule** — a user who
  restarts more than 24h after a crash gets `conflict` plus recovery clues, not an automatic
  restore. That limitation is now written into REQ-024 and the design's capability ceiling.