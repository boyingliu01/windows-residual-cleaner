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

---

## DR-012 — VERIFY re-check of the open medium/low findings (2026-10-07)

**Context.** Both Delphi releases (DR-010, DR-011) recorded that their open **medium/low**
findings "must be re-checked in VERIFY". This is that re-check, performed against the built
code plus the current spec/design text (master `@ 896d0fe` with the 2026-10-07 fixes).

**Scope.** 29 findings total: r21 (4), r22 (6), d1 (4), d2 (6), d3 (7), d4 (2).

**Result: 27 resolved, 2 residuals recorded.**

Resolved — fixed in spec/design text during the review rounds, verified present in the
current files: REQ-021 window order ("先看窗口，再看漂移") and the T2 two-signal arbitration
rule are now written into the normative text, not just notes; REQ-005's atomic-write
protocol is rewritten (File.Move first write / File.Replace after; no copy-first phrase);
REQ-019 gained the corrupt-sidecar-forensics rule ("解析失败的旁路文件…不得在 Step 1 被改写
或删除") and the `rollback-consumed.failed.json` gate; the sign-(ii) leftover phrase is gone;
the duplicate YAML keys are gone; AC-074 covers **both** entry points (in-process T2 and
startup T3, compare-all-then-restore-all, cleanup phase intentionally different); AC-060
asserts the unrepaired-list write order; the design's run_id example is a GUID with an
explicit callout of the earlier mistake; promise wording is bounded ("bounded, not proven").

Resolved — in the built implementation, verified by code inspection plus tests/drill:
multi-journal convergence (newest consumed, older get `skipped_older_journal`; tie →
ambiguous → 14; partial-unparsable → ambiguous — `rollback-auto.Tests.ps1:555`,
`rollback-recovery.Tests.ps1:555/572`); suppression is evaluated as Step 2.5 but its
outcome is gated by Step 3 self-validation, so a schema-invalid journal is rejected and can
never be suppressed (`Get-RollbackConsumptionDecision`); exit 15's definition was broadened
to include the unrepaired-list write (its documented meaning now: 日志落盘 / 未修复清单 /
完成或消费标记); a mid-run flush failure stops the destructive sequence and marks the entry
`restore_failed(unjournaled)` — the code explicitly does not claim to "return to the last
durable point"; the unrepaired list has one writer and one schema (`Write-UnrepairedList`,
fields `run_id`/`created_at`/`reason`/`backup_dir`/`candidate_unparseable`/`unrepaired[]`);
the reg-export trim keeps the version header and parent-key rows (`reg import` minimum) and
re-checks its own output; restore-point failure paths (disabled protection, Checkpoint
failure, WMI exceptions) are covered by `create-restore-point.Tests.ps1` + exit code 4.
The d3 falsification test demanded by the panel — crash **after** the cleanup-log write,
**before** `completed_at` — was executed as drill5 fixture `fs_951`: suppressed, items were
**not** reinstalled.

Residual 1 (code-adjacent, open): **AC-094's aggregate `restored_with_low_confidence` is
not implemented.** The spec requires that when **all** restorable entries are
evidence-incomplete, the run is judged `restored_with_low_confidence` and requires human
confirmation — "不得静默宣告完全成功". The code implements the per-entry half
(`EvidenceIncomplete` flag in every verdict + `[evidence-incomplete]` annotation in the
report; such entries count as restored and do not force 14), but there is no aggregate
verdict/flag and `counts` only splits `restored`/`already_present`/`not_restorable`/
`restore_failed` (`rollback-exec.ps1:794`). The mechanical semantics of "需人工确认" (exit
code? UI gate?) are unspecified in the spec, so wiring it unilaterally would be a new
design decision — deferred and flagged for the next touch of `rollback-exec.ps1`.

Residual 2 (doc-note): **design §8 Q2 is stale draft text.** It still recommends per-item
undo ("the items we could not complete plus the ones tied to them"), which contradicts
normative REQ-024 (any partial failure restores every reversible `mutation_succeeded`
entry). The design doc was intentionally **left unedited** so its sha256 keeps matching
`design_hash` in `delphi-reviewed.json`; REQ-024 is normative and the built behavior follows
it (verified by tests + drill5).

**Data-quality note.** The per-round expert JSONs (r1–r22, d1–d4) were captured with a
double-encoding defect: Chinese segments are stored mojibake and bytes 0x80–0x9F were
stripped, so parts are irrecoverable. English text, severities, titles and REQ/AC citations
are intact; this re-check used those plus the readable sources (spec/design/code). The full
raw set has been synced from the sprint worktree into the main repo's `.sprint-state/delphi/`
(it previously existed only in the worktree).

## DR-013 — REQ-031's completion marker under exit code 15 (2026-10-08)

**Context.** REQ-031 / AC-070 exempt **only exit code 11** from writing `completed_at`; every
other terminal code marks the journal complete. Startup T3 recovery consumes **unfinished**
journals only, so a written marker permanently removes the next launch's chance to restore.
Exit 15 (this run's persistence write failed) is exactly a state where damage can remain
unrepaired while the marker still gets written.

**Question.** Follow the letter (only 11) or the intent (never mark a still-damaged round done)?

**Options**: (A) keep the literal rule; (B) amend per intent — suppress the marker while this
round's changes are still unrepaired, and amend REQ-031 in the spec; (C) suppress for all 15.

**Choice**: **B** (user ruling: 按精神补判定：仍受损就不写标记).

**Key finding during implementation.** The narrow rule "15 && `restore_failed > 0`" is
**unreachable code**: every mid-run failure site sets `$persistenceError = $true` before
`break`, and `clean-residuals.ps1:1195` skips T2 entirely once that flag is set — so **every**
exit 15 has `restore_failed == 0`. Damage under 15 therefore had to be expressed as three
shapes: (a) `restore_failed > 0`; (b) un-journaled mutations > 0 (AC-052 — the recovery side
sees nothing); (c) `failedCount > 0` **and** the rollback never ran, which required a new
`$rollbackAttempted` seam in `Main` (it cannot be inferred from `restoreFailed`).

**Outcome**. Pure predicate `Test-CompletionMarkerSuppressed` (`rollback-producer.ps1`) is the
single answer to the question "is the system still carrying changes this round failed to fix";
`completed_at == null` for 11 and for 15(a)/(b)/(c), written otherwise (a clean 15 round must
still be marked, or the next T3 reinstalls what was correctly removed — REQ-024 rule 3).
Code `fec90f6`, spec amendment `5dd0a17`. Tests: 8 predicate cases plus a `Main`-level
integration case that forces 15(c) by planting `cleanup-log.json` as a **directory**, asserted
against a **negative control** (the case goes red without the fix).

## DR-014 — setup.ps1 was exempted from coverage for the wrong reason (2026-10-08)

**Context.** `.xp-gate-powershell-coverage-ignore` contained exactly one entry, `setup.ps1`,
justified as "structurally uninstrumentable: its Main ends in `exit`, which kills the Pester
host". AGENTS.md repeated that justification in 已知限制.

**Question.** Keep the exemption, or treat it as the code defect it actually was?

**Options**: (A) refactor `setup.ps1` to ADR-001 (`function Main` + `param([ref]$ExitCode)` +
one injection seam), measure it, empty the ignore list; (B) leave the exemption and its note;
(C) leave it but add more scripts to the list as coverage work gets hard.

**Choice**: **A** (user ruling: 本 sprint 重构为 Main + [ref]$ExitCode).

**Rationale.** The exemption dressed up an **ADR-001 violation** as a structural limit: the
same "cannot be instrumented" claim had already been disproved for 8 other scripts by the
2026-10-01 refactor. C was rejected on the ignore file's own rule ("Do NOT add files here
merely because they are hard to test").

**Outcome** (`721cada`). `setup.ps1` now has `Main` + `[ref]$ExitCode` + the uniform guard, with
`-PSVersionOverride` as its only seam (so "environment not satisfied → 1" is testable); the
ignore list is **empty**; the child-process end-to-end case is kept (it proves the real
process `exit` code). The ADR-001 contract in `tests/unit/hermeticity.Tests.ps1` was turned
into an **exhaustive** AST sweep over every script containing `function Main` (currently 11:
10 under `references/scripts` + `setup.ps1`) — previously it named only 2 scripts, which is
precisely how this debt survived. Line coverage 83.94% (2765/3294, 16 files) →
**84.08% (2804/3335, 17 files)**.

## DR-015 — drill5 elevated re-run authorized; wrc-drill stays out of the repo (2026-10-08)

**Context.** DR-004 requires the user to run/authorize every real-machine destructive/admin
action. The 2026-10-07 drill ended 18/23, its 5 failures cascading from one PATH-entry restore
refused as `conflict(external_change_sign_iii)` that controlled reproduction could not
recreate. `12bf152` root-caused it (an unbound `[string]` override read as "injected as empty"
masked the live registry read — AGENTS.md trap 11's injection-seam variant).

**Choice.** User authorized an immediate elevated re-run and completed the UAC prompt
(推荐: 现在跑，我点 UAC). Result: **23/23 PASS**, `pe_951` restored, rc=10 with counts
3/0/3/0, machine PATH byte-identical after the drill's own finally-round-trip check.

**Disposition of `wrc-drill/`.** Stays **untracked** by user decision: the drills create real
services, machine-PATH segments and registry keys on the developer's own machine, their safety
depends on running them by hand under UAC, and committing them would invite an agent to run
them unattended. AGENTS.md 变更历史 now records that disposition instead of "去向待定".
