# REQUIREMENTS REVIEW PAYLOAD (Round 3 — revised specification) — auto-rollback

## The requirement as stated by the user

> 全自动回滚：清理前自动创建还原点+注册表备份，失败时自动执行回滚。
> (Fully automatic rollback: automatically create a restore point + registry backup before
> cleanup, and automatically execute a rollback when cleanup fails.)

The user explicitly REJECTED a semi-automatic (user-triggered) variant in favour of fully automatic.

## All prior-round findings that were ACCEPTED and fixed

R1: AC-009 vs AC-019 exit-code contradiction -> REQ-011 now explicitly exit-code independent.
R1: REQ-016 added for the previously orphaned AC-016.
R2 critical: no per-item fail-closed rule -> REQ-006/REQ-007 now require the export to succeed
  BEFORE deleting, else the deletion is skipped and logged export_failed (AC-024).
R2 critical: REQ-012/AC-012 said '-NoAutoRollback behaves exactly like today', which would
  resurrect the known-unsafe behaviour that REQ-001..004/015 fix. Rewritten: the switch disables
  ONLY the automatic rollback trigger; all safety/honesty fixes still apply.
R2 critical: journal state machine undefined -> REQ-018 (planned/backup_created/
  mutation_succeeded) + AC-025/AC-026. Rollback restores ONLY mutation_succeeded entries, so a
  crash-after-journal-write-before-mutation cannot cause a false restore.
R2 critical: stale/wrong journal unaddressed -> REQ-019 + AC-027 (self-validating journal,
  reject previous-run/mismatched/unverifiable journals without touching the system).
R2 high: REQ-017 'protection' ambiguous (restore point vs targeted backup) -> REQ-017 now
  defines two distinct tiers: mandatory targeted protection fails closed; the optional system
  restore point only warns. AC-022/AC-013 aligned.
R2 high: no requirement defined WHO invokes auto-rollback -> REQ-020 + AC-028 (in-process).
R2 high: REQ-003 depended on an undefined restore-status.json -> REQ-022 + AC-030 add the
  writer, schema and first-run semantics.
R2 high: startup-value restore untested -> AC-031 (re-query the value + assert sibling values
  in the shared Run/RunOnce key are untouched).
R2 medium: PATH rollback algorithm under-specified -> REQ-021 + AC-029 (whole-scope restore
  from the captured original; never blind-overwrite if PATH changed concurrently).
R2 medium: AC-016 implied Tier-4 renamed content was restorable, contradicting DD-006 ->
  AC-016 now states renamed content is reported for MANUAL recovery only (AC-032).
R2 low: AC-020 mapped to REQ-005 though it is cross-cutting -> REQ-023 added.
R2 low: REQ-015 addresses typo AC-002 -> AC-019.

R3 critical (technical + feasibility): REQ-003/AC-017 still made the LEGACY restore-status.json
  a hard pre-flight gate, contradicting REQ-017's tiering -> REQ-003 rescoped to validate only
  the MANDATORY targeted protection; AC-017 now asserts restore-point unavailability does NOT abort.
R3 critical: registry/value restore had no conflict detection (asymmetric with the PATH rule) ->
  REQ-024 + AC-034 (absent -> restore; identical -> already_present; different -> conflict, no
  overwrite).
R3 critical: clean-residuals handling of create-restore-point's non-zero was unspecified ->
  REQ-025 + AC-035 (optional-layer failure warns and continues; mandatory-layer failure aborts).
R3 high: T3 had NO invoker - after a crash no process exists to run rollback, so 'fully automatic'
  was an over-promise -> REQ-016 rewritten as 'recover on NEXT launch' + AC-033, and the design
  forbids claiming instant crash rollback.
R3 high: the crash window between mutation and the mutation_succeeded write made AC-026
  unimplementable -> REQ-018 now defines a recovery protocol where the TARGET'S CURRENT STATE
  decides (marker is supporting evidence only); AC-026 rewritten to test that protocol.
R3 high: exit codes after auto-rollback were untestable -> REQ-026 + DD-013 give a fixed matrix
  (0/1/2/3 preserved; 10 = rollback fully OK; 11 = rollback partial/failed; 12 = no journal) + AC-036.
R3 medium: first-run semantics were asserted as 'defined' rather than defined -> REQ-022/AC-030 now
  state them exactly (no prior cleanup-log => skip the newer-than comparison).
R3 medium: personas/entry points were implicit -> design doc section 4 now enumerates them.
R3 medium: REQ-007 trim-failure path -> trimming failure is treated as export failure (AC-040).

R4 high (feasibility): REQ-018 and REQ-024 CONTRADICTED each other ('divergent -> restore' vs
  'different -> conflict, no overwrite') -> REQ-018 now defers entirely to REQ-024's conflict
  rule; the two are explicitly the same rule.
R4 high: the exit-code matrix had no code for -NoAutoRollback -> 13 added (REQ-026/DD-013/AC-036).
R4 high: no AC proved the global fail-closed path -> AC-041 covers unwritable backup dir, reg
  export unavailable, and Machine PATH capture failure, each asserting NOTHING was modified.
R4 high: 'target absent -> restore' could resurrect a key the USER deliberately deleted later ->
  REQ-029/AC-039 require proving the absence was caused by THIS run, else conflict/manual.
R4 medium: journal self-validation was unverifiable -> REQ-027/AC-037 define the exact schema
  and the precise self-validation predicate (version + guid + parseable time + existing files).
R4 medium: T3 sequencing vs the new run's backup was ambiguous -> REQ-028/AC-038 fix the order
  (consume journal -> recover -> pre-flight -> create new backup).
R4 medium: registry comparison semantics were undefined -> REQ-024 now specifies structural
  comparison (subkey set + all (name,type,data) tuples; metadata ignored) vs exact PATH equality.
R4 low: AC-029's drift detection mechanism -> REQ-021 defines expected = original minus removed.

R5 CRITICAL (all three experts): REQ-024 ('absent -> restore') contradicted REQ-029 ('must prove
  this run caused it') -> REQ-024 is now the SINGLE authoritative 4-rule decision table; REQ-018
  and REQ-029 explicitly defer to it and no longer define their own rules. Absent targets are
  restored ONLY with this-run causal evidence (state mutation_succeeded + pre_existing), else
  conflict/manual. AC-026 and AC-039 no longer assert opposite outcomes.
R5 high: journal integrity binding was too weak (a copied/replaced journal passed) -> REQ-027 now
  requires machine_fingerprint + per-backup SHA-256 + pre_existing, with AC-044 for copied/
  tampered/foreign journals.
R5 high: failure of a PRIOR run's recovery had no gate -> REQ-030 + AC-042 (abort the new run
  before pre-flight rather than cleaning on top of unrepaired damage).
R5 medium: state-name inconsistency (AC-003 said 'pending', AC-025 said 'planned') -> AC-003
  now uses 'planned'; REQ-027 pins the enum to REQ-018's.
R5 medium: AC-008 vs REQ-028 ordering ambiguity -> AC-008 scoped to the CURRENT run only;
  AC-038 still asserts the prior-run journal is consumed first.
R5 medium: AC-005 vs AC-029 could not both hold under drift -> AC-005 scoped to no-drift.
R5 medium: pre-flight failure exit codes were unmapped -> REQ-026/AC-036/AC-041 assert them.
R5 low: REQ-007 export subcases -> AC-043 (IO failure, reg.exe missing, permission denied).

R6 CRITICAL (all three experts, same item): AC-026(b)/AC-034 still asserted 'target absent ->
  restore' UNCONDITIONALLY, contradicting REQ-024 rule 3's causal requirement. Both ACs rewritten
  to assert BOTH branches: restore only with mutation_succeeded + pre_existing, else conflict.
R6 CRITICAL: REQ-024 rule 3 clarified - pre_existing ALONE is not causal proof; it requires
  mutation_succeeded as well. planned/backup_created falls to rule 4 (conflict) regardless.
R6 CRITICAL: REQ-007/AC-040 trim-failure did not mirror the fail-closed wording -> REQ-007 now
  says a trim failure SKIPS the deletion, and AC-040 asserts the value still exists.
R6 high: machine_fingerprint was undefined -> REQ-027 defines it (MachineGuid, fallback
  hostname+volume serial) and adds cleanup_log_sha256 to the self-validation predicate.
R6 high: REQ-030 'completely successful' was undefined for not_restorable items -> REQ-030 now
  defines success as 'no restore_failed'; not_restorable is an honest report that warns but
  does not block. Also fixed the REQ-028/REQ-030 ordering (consume -> recover -> abort if
  failed, BEFORE pre-flight and BEFORE creating a new backup).
R6 high: -NoAutoRollback vs prior-run T3 recovery was unspecified -> REQ-030 makes T3 recovery
  mandatory regardless of the switch; REQ-012/AC-012 carve it out explicitly.
R6 medium: REQ-003 did not list Machine PATH capture among mandatory protection -> added (c),
  making AC-041 traceable.
R6 medium: REQ-022 still claimed REQ-003 depended on restore-status.json -> corrected: that
  file is informational for the OPTIONAL restore-point layer only.
R6 medium: DD-003 claimed a 'pure function' while AC-040 tests failure -> DD-003 now specifies
  the trim function takes/returns .reg TEXT (no IO), with the caller owning IO and error path.
R6 medium: REQ-024 registry comparison depth was unbounded -> scoped to the reg-export scope.
R6 medium: added AC-045 (per-action not_restorable reasons end-to-end).

R7 high: T3 journal DISCOVERY was undefined -> REQ-019 now defines where journals are found
  (backup-*/rollback-journal.json), the unfinished predicate (completed_at == null + >=1 real
  entry), the selection rule (newest created_at, warn about others; tie => reject all), and a
  completion marker (completed_at + consumed_by_run_id) so a stale journal is never replayed.
  AC-046/AC-047 test selection and non-replay.
R7 high: no exit code existed for 'prior-run recovery failed' -> code 14 added to REQ-026/
  DD-013/AC-036, distinct from 13 (-NoAutoRollback) and 11 (rollback of THIS run failed).
R7 medium: the all-not_restorable edge case was ambiguous -> REQ-030 states explicitly that even
  if EVERY entry is not_restorable it counts as complete success (warn, do not abort); AC-048.
R7 medium: REQ-024 comparison scope for trimmed startup-value exports -> scoped to the trimmed
  minimal .reg's structural content, not the whole Run/RunOnce tree.
R7 medium: machine_fingerprint fallback was weaker than AC-044 claimed -> REQ-027 records
  fingerprint_source and adds an extra binding requirement when the fallback is used.
R7 medium: DD-016 overstated crash-window recovery -> rationale now states plainly that the
  ambiguous window becomes conflict/manual, NOT automatic restoration.

R8 CRITICAL (all three experts): REQ-024 rule 3 was STILL insufficient - mutation_succeeded +
  pre_existing only proves 'this run deleted something', not that the CURRENT absence is ours;
  an external delete/recreate-delete satisfies both, so the tool could resurrect user action.
  Fixed with a THIRD mandatory flag: absent_confirmed_after_mutation (re-check immediately after
  deleting). All three are now required. AC-050 asserts the negative case.
R8 critical/high: 'copied journal' rejection was unachievable - a same-machine full copy is
  byte-identical and self-consistent, so content cannot distinguish it. DD-017 + REQ-027 now
  state the achievable rule honestly: refuse all journals sharing a run_id and require manual
  intervention, and do NOT promise to reject a self-consistent same-machine copy. AC-044 scoped.
R8 high: the self-validation predicate omitted cleanup_log_sha256 -> predicate now includes it
  (when non-null), plus the completed_at==null requirement.
R8 high: the journal had no Machine PATH original, so T3 (no cleanup log) could not restore PATH
  -> REQ-027 adds machine_path_original + machine_path_scope; AC-021 asserts PATH restore from
  the journal alone.
R8 high: no rule for a mid-run journal FLUSH failure after a mutation -> REQ-005 now makes it
  fail-closed: stop further destructive actions, roll back from the last durable state, distinct
  exit code. AC-049.
R8 high: the schema could not express not_restorable entries (backup_file required) -> REQ-027
  defines nullability rules for path/service/task vs registry entries. AC-051.
R8 medium: AC-025 invented an undefined 'unchanged' verdict -> REQ-009 now fixes the enum to
  four values and maps 'unchanged' to already_present; AC-025 rewritten.

R9 CRITICAL (all three experts, same item): even the three-flag chain cannot prove the CURRENT
  absence is ours - an external delete/recreate/delete after our post-mutation check satisfies
  every flag. This is not fixable by adding flags. RESOLVED BY BOUNDING THE CLAIM (DD-018):
  auto-restore only within a 24h window of created_at; outside it, or with any sign of external
  change, degrade to conflict/manual. The spec now explicitly documents this limit instead of
  over-promising. AC-050 asserts both the window and the missing-flag branches.
R9 CRITICAL: REQ-005 'roll back from the last durable state' implied an unjournaled mutation was
  recoverable - contradiction with REQ-018's state machine. Rewritten: in-process best effort +
  explicit restore_failed/'not recorded' marking; never a silent unrepaired deletion. AC-052.
R9 high: completion-marker write failure could replay a stale journal -> REQ-019 requires an
  atomic durable marker; failure => abort with 14, never re-consume. AC-053.
R9 high: self-validation failure and zero-entry journals were unmapped in REQ-030 -> now explicit
  (self-validation failure/duplicate run_id => 14 before pre-flight; zero processable entries =>
  complete success, continue). AC-054.
R9 high: AC-044 overclaimed rejection of a byte-identical same-machine copy -> rescoped to the
  five mechanically verifiable cases; DD-017 remains the honest statement of the limit.
R9 high: REQ-027's hostname_fallback clone-resistance was aspirational -> now states plainly that
  clone detection is NOT guaranteed under that fallback.
R9 medium: REQ-021 'expected value' was ambiguous for multiple PATH deletions -> defined as
  original minus entries with success=true in the cleanup log.
R9 medium: AC-026(c)/AC-034(3) did not list all three flags -> updated to match REQ-024 exactly.

R10 high: REQ-005's 'distinct exit code' was never mapped -> code 15 (journal flush failed,
  fail-closed, reports ahead of 10/11/12/13) added to REQ-026/DD-013/AC-036.
R10 high: a permanent prior-run conflict could BRICK all future cleanup, since completed_at is
  only written on success -> REQ-030 now has a required manual acknowledgement path
  (-AcknowledgeConflicts or removing the backup dir) that marks the journal
  consumed_with_failure=true and lets cleanup resume, always keeping the unrepaired list in the
  report. AC-055 proves cleanup is not permanently blocked.
R10 high: 'any sign of external change' was undefined -> REQ-024 now enumerates five
  mechanically detectable signs ((i) target present-but-different, (ii) parent key/dir last-write
  newer than this run, (iii) PATH drift, (iv) duplicate run_id, (v) hash mismatch) and AC-056
  asserts each degrades to conflict. The residual (undetectable) risk is recorded, not denied.
R10 high: a marker-write failure would re-select the journal next launch, so AC-053 was
  untestable -> REQ-019 adds a sidecar rollback-consumed.json; either marker suppresses
  re-consumption; if BOTH fail, refuse the journal and return 14. AC-057.
R10 high: only the newest of several unfinished journals was consumed, so later runs could fall
  back to an OLDER journal -> REQ-019 now marks all other candidates consumed_with_failure=true
  and returns 14, preserving the 'only the immediately preceding run' non-goal.
R10 high: AC-014 ('second rollback reports already_present') contradicted the no-replay rule ->
  rescoped to an in-process retry before the marker is written; a cross-process second call
  reports 'already completed' and changes nothing.
R10 medium: REQ-019's unfinished predicate required a non-skipped entry, which made AC-054
  untestable -> discovery now selects all completed_at==null journals and lets REQ-030 classify
  zero processable entries as success.
R10 medium: PATH drift detection had no time bound -> REQ-021 states the 24h window applies only
  to REQ-024's auto-restore decision; PATH drift is unbounded and always degrades to manual.
R10 low: fingerprint_source was not itself validated -> added to the REQ-027 predicate.
R10 low: created_at tie behaviour had no exit code -> REQ-019 states it returns 14 and routes to
  the same acknowledgement path.

R11 CRITICAL: external-change sign (ii) SELF-TRIGGERED - our own registry deletion necessarily
  updates the parent key LastWriteTime, so comparing it to the run start timestamp made every
  own-mutation look external and rendered rule 3 auto-restore UNREACHABLE. Fixed: the journal now
  records parent_lastwrite_after_mutation immediately AFTER the delete, and sign (ii) compares
  against that baseline. AC-056 asserts our own mutation is not misflagged.
R11 high: REQ-021's expected-PATH formula needed the cleanup log, but T3 has only the journal ->
  REQ-021 now defines the journal-only derivation (machine_path_original minus entries with
  state=mutation_succeeded); if neither source is usable, degrade to conflict and never
  overwrite. AC-059.
R11 high: journal updates were not atomic, so a crash mid-write leaves malformed JSON that
  REQ-027 rejects - defeating T3 recovery. REQ-005 now requires temp-file + fsync + atomic
  replace, and fallback to the last parseable state. AC-058.
R11 high: deleting the backup dir as an acknowledgement would destroy the only copy of the
  unrepaired list -> REQ-030 now requires the list be persisted OUTSIDE the backup dir first,
  and -AcknowledgeConflicts is the confirmation path (dir removal is last resort, with the list
  emitted and its location reported). The ack path explicitly covers all three code-14 cases.
  AC-060.
R11 medium: exit code 14 covered only 'recovery incomplete' while REQ-019 also returns 14 for
  ambiguity -> REQ-026 now defines 14 as 'prior journal could not be safely consumed' covering
  incomplete recovery, self-validation failure/duplicate run_id, and created_at tie/multiple
  journals.
R11 medium: exit code 15 precedence was stated in DD-013 but not REQ-026 -> REQ-026 now says a
  run returns exactly one code and 15 is terminal (10/11/12/13 are not evaluated).
R11 medium: REQ-024's 'structural content' for a trimmed .reg was undefined -> now (value name,
  type, data) with metadata ignored, symmetric with registry comparison.
R11 low: REQ-027 machine_path_original nullability -> null is allowed only when the journal has
  no successful path_entry_removed entry; otherwise self-validation fails.
R11 low: REQ-005's unjournaled-mutation verdict -> explicitly restore_failed(unjournaled) +
  manual, NOT silently skipped via rule 4.

R12 critical: sign (ii)'s baseline was in-process only, so it was UNIMPLEMENTABLE for T3
  (recovery runs in a different process) -> REQ-027 now requires
  parent_lastwrite_after_mutation to be PERSISTED per entry, nullable for path/service/task
  (no parent-key semantics) where sign (ii) does not apply.
R12 critical: the created_at tie case had no working acknowledgement path (nothing was
  SELECTED, so there was nothing to mark consumed) -> REQ-030 defines -AcknowledgeConflicts
  for ties as: mark ALL candidate journals consumed_with_failure, emit each backup_dir/run_id/
  created_at for review, then continue. Without confirmation the tool stays at 14. AC-063.
R12 high: signs (iv)/(v) were listed as PER-ENTRY conflict signs while REQ-019/REQ-027/REQ-030
  treat them as whole-journal rejection -> REQ-024 now separates per-entry signs (i)-(iii) from
  journal-level rejections (iv)/(v); AC-056 asserts 14/abort for the latter.
R12 high: the 24h window's reference point was ambiguous -> measured from created_at to the
  RECOVERY ATTEMPT time; comparison is strictly < 24h. AC-050 asserts 24h and 24h+1s degrade
  while 23h59m restores. The delayed-recovery tradeoff is stated explicitly.
R12 high: -DryRun vs mandatory T3 recovery was contradictory -> REQ-030 states -DryRun stays
  zero-side-effect (does not consume, recover, or rewrite markers; only reports) and never
  returns 14. AC-061.
R12 high: non-admin ordering would have produced 14 instead of 2 -> REQ-030 puts the admin
  check BEFORE T3 recovery; permission errors during recovery also report 2. AC-062.
R12 high: REQ-005's 'last parseable state' was undefined -> concrete protocol: keep one
  previous generation as rollback-journal.prev.json, fall back to it, depth fixed at 1
  generation. AC-058.
R12 medium: rollback-consumed.json had no schema -> REQ-019 fixes it to
  {run_id, consumed_at} with the same atomic write protocol; unparseable counts as absent.
  AC-064.
R12 medium: AC-046 did not assert the return code or the side-effect marking -> extended.
R12 high (feasibility): the restore-point product promise conflicted with the verified
  unreliability of System Restore -> REQ-017 now revises the user-facing promise to
  'mandatory per-item protection + best-effort restore point', and forbids the unconditional
  'backed up via restore point' wording. AC-065.

R13 high: sign (ii) self-triggered EVEN AFTER the post-mutation baseline fix, when multiple
  entries share one parent (each later delete advances the parent's LastWriteTime, invalidating
  earlier entries' baselines) -> the baseline is now aggregated PER PARENT
  (parent_baseline = last recorded for that parent, i.e. the max) and written at run end.
  AC-056(c) now covers the multi-entry-same-parent case.
R13 high: REQ-018's state machine was undefined for null-backup path/service/task entries
  (they cannot legitimately enter backup_created) -> they now travel planned -> mutation_succeeded,
  skipping backup_created, and are always not_restorable. AC-066.
R13 high: REQ-019 marked all other candidate journals consumed BEFORE proving the selected one
  self-valid, so one tampered newer journal could destroy a valid older recovery record ->
  REQ-019 now validates ALL candidates first and, if any fails, marks/consumes NONE and returns
  14. AC-067.
R13 medium: the 24h window's configurability was undefined -> fixed at 24h with NO config
  switch, because a tunable safety boundary invites 'widen it for more automation'.
R13 medium: PATH auto-restore's window relation was ambiguous -> REQ-021 now states PATH auto-
  restore is subject to the SAME 24h window (drift detection itself is unbounded). AC-069.
R13 medium: cleanup_log_timestamp was required but never validated -> the REQ-027 predicate now
  checks cleanup_log_path exists and its last-write time matches within 2s. AC-068.
R13 low: the 1-generation fallback depth had no rationale -> DD-019 records why 1 generation
  suffices (it covers the atomic-replace crash) and why deeper chains are not worth it.

R14 critical: parent_baseline was written only at run END, which is precisely the case T3
  excludes (the run crashed) -> REQ-027 now persists it per mutation and the RECOVERY side
  re-derives it as the MAX across entries sharing that parent; a missing field skips sign (ii)
  for that entry and is noted in the report.
R14 critical: the cleanup-log self-validation checks contradicted T3 recovery (they required
  cleanup_log_path to exist, which T3 by definition lacks) -> all three cleanup-log checks are
  now gated on cleanup_log_sha256 being non-null; AC-068 asserts both branches.
R14 high: AC-060's acknowledgement could not work for an UNPARSEABLE journal (you cannot edit
  it in place) -> REQ-030 now defines a sidecar rollback-acknowledged.json written by the
  HUMAN, distinct from rollback-consumed.json written by the TOOL.
R14 high: the unrepaired-list had no schema/location -> REQ-030 fixes it to
  output/rollback-unrepaired-<run_id>.json with an atomic write and a defined item shape.
R14 high: REQ-019's 'validate all then select' order was ambiguously worded -> restated as an
  explicit 5-step sequence with the two terminal branches.
R14 medium: AC-053 vs AC-057 disagreed about re-consumption -> AC-053 now scoped to the case
  where the sidecar write SUCCEEDS; if both fail, the next run sees it again and returns 14
  (intended conservative behaviour).
R14 medium: multiple-journal 14 semantics were inconsistent (auto vs ack) -> clarified:
  DIFFERENT created_at auto-converges via REQ-019 (next run does not return 14); a TIE requires
  -AcknowledgeConflicts. AC-063 asserts the distinction.
R14 medium: AC-059 vs REQ-027 disagreed on null machine_path_original -> reconciled: null + a
  successful path_entry_removed is a self-validation failure (14); null + none is fine and
  PATH restore is skipped.
R14 medium: REQ-024's trimmed-.reg comparison algorithm was under-specified -> now only the
  target value's (name,type,data) is compared; the version line, parent-key line, blank lines
  and metadata never participate.

R15 CRITICAL: a SUCCESSFUL cleanup never closed its journal, so the next launch would treat a
  correctly-finished run as unfinished T3 and RE-INSTALL everything it had just deleted ->
  new REQ-031 requires every normal termination path (all-success, partial+rollback-ok,
  -NoAutoRollback) to atomically write completed_at before exit. AC-070.
R15 high: 'atomic' was specified as Move-Item -Force, which in PS 5.1 deletes-then-moves and
  therefore has a window where the journal does not exist -> REQ-005 now mandates
  [System.IO.File]::Replace() (or ReplaceFile), with first-write falling back to write+Move.
  AC-071 asserts the target always exists and the previous generation survives.
R15 high: -AcknowledgeConflicts' 'human writes the sidecar' vs 'the tool writes it' was
  contradictory -> clarified: the switch is a HUMAN authorization; the tool performs the
  mechanical write only when the human supplied it. Decision by human, persistence by tool.
R15 high: REQ-003(c) required PATH capture unconditionally, which made 'null + no PATH change'
  a false failure -> scoped to 'only when PATH entries are actually to be removed'; the
  null+successful-entry self-validation failure is documented as a defensive check.
R15 medium: REQ-019's ordering was prose -> now explicit numbered Steps 1..5 with the two
  terminal branches (4a all-pass -> restore newest, mark rest, 14; 4b any-fail -> mark nothing).
R15 medium: output/ was ambiguous (project root vs backup subdir) -> pinned to
  <project_root>/output/, sibling of backup-*/, so deleting a backup dir cannot lose the list.
R15 medium: the 24h delayed-recovery tradeoff was not surfaced to users -> REQ-014/AC-065 now
  require UI and docs to state that crash recovery must happen within 24h or it degrades to
  manual.

R16 high: Step 1 collected ALL journals including COMPLETED ones, and REQ-027 requires
  completed_at==null, so a prior successful run's journal failed self-validation and Step 4b
  made EVERY subsequent cleanup return 14 - the tool would never run again. Step 1 now filters
  completed candidates (completed_at set, or a consumed/acknowledged sidecar) before Step 3.
  AC-072.
R16 high: sign (ii) also self-triggered during ROLLBACK, because restoring several entries
  under one parent advances that parent's LastWriteTime, making later entries look externally
  modified -> recovery is now TWO-PHASE (compute all Rule-3 verdicts first, then execute), so
  our own writes cannot influence the verdicts. AC-074.
R16 high: Step 4b (ALL candidates corrupt) had no unlock - nothing was selected, so nothing
  could be acknowledged -> -AcknowledgeConflicts now writes rollback-acknowledged.json for all
  self-failing candidates. AC-073.
R16 high: consumed_with_failure was used throughout but absent from the schema -> added to
  REQ-027 with default false.
R16 high: fingerprint_source was added to the predicate but not enumerated in its bullets ->
  now explicit, and AC-037 asserts a missing/illegal value fails.
R16 high: parent_baseline could be missing mid-crash, and recovery had to tolerate it -> REQ-027
  now states per-entry tolerance: skip sign (ii) for that entry, mark its evidence incomplete,
  but do NOT reject the whole journal. AC-075.
R16 medium: AC-041 required PATH-capture failure to abort unconditionally, contradicting
  REQ-003(c)'s conditional -> AC-041 now aborts only when PATH entries are actually to be
  removed.
R16 medium: AC-071's 'previous generation survives' was untestable on a first write -> carve-out
  added.
R16 medium: DD-003's trim output was not contractually single-value -> DD-003 now fixes the
  contract (exactly one value definition + the parent key line), asserted by AC-002.

R17 CRITICAL: a crash AFTER a successful cleanup but BEFORE the completion marker would make
  the next launch treat a finished run as unfinished T3 and resurrect everything just deleted.
  REQ-031 now adds the fallback: completed_at==null BUT cleanup log present AND
  summary.failed==0 => SUPPRESS auto-restore, report 'completed (marker missing)', treat as
  consumed. AC-076.
R17 CRITICAL: exit 11 (partial failure, rollback incomplete) had no defined journal state ->
  REQ-031 now requires the journal to REMAIN UNFINISHED and the unrepaired list to be persisted,
  so the next launch retries T3 instead of treating a still-damaged system as finished. AC-077.
R17 high: -AcknowledgeConflicts' ordering and failure handling were undefined -> REQ-030 fixes
  the order (atomically write the unrepaired list FIRST; only on success write the marker), and
  a list-write failure aborts without writing any marker, returning 15. AC-078. 'Confirmed but
  the list is lost' is now impossible.
R17 high: the ack sidecar's path for an unparseable journal was undefined -> pinned to the
  backup-* dir the candidate physically lives in (run_id from the dir name, 'unknown' if
  undeterminable).
R17 high: MAX(parent_baseline) with a null element was undefined -> nulls are skipped; if all
  entries for a parent are null, sign (ii) is skipped for that parent and noted. AC-075(a).
R17 high: REQ-027 made parent_baseline mandatory while REQ-024 tolerated its absence ->
  reconciled: registry entries may have null (T3 tolerance) and skip sign (ii) for that entry.
R17 high: AC-036 asserted only one of the four code-14 branches -> now all four have cases.
R17 medium: Step 4a marked older journals consumed without persisting their unrepaired lists ->
  REQ-019 now requires a list for those too. AC-079.

R18 high: REQ-031's fallback was not wired into REQ-019's fixed 5-step flow, so a literal
  implementation of Step 5 would still resurrect -> new Step 3.5 applies the suppression
  BEFORE Step 4/5. AC-076 now names Step 3.5, and adds the contrast case (failed>0 still T3).
R18 high: REQ-031's fallback didn't state the converse -> explicitly: completed_at==null AND
  summary.failed>0 (e.g. exit 11) still goes through T3 recovery; the only discriminator is
  whether summary.failed is 0.
R18 high: AC-044 listed completed_at non-empty as a self-validation rejection, but Step 1
  silently FILTERS such journals before validation -> AC-044 rescoped to the four real
  rejection cases; AC-072 covers the filtering.
R18 high: exit code 14 vs AC-048 conflicted when multiple journals exist AND all entries are
  not_restorable -> precedence defined: multiple-candidate 14 wins; AC-048 scoped to a single
  candidate.
R18 high: Step 4a marked the OTHER journals consumed without their unrepaired lists -> REQ-019
  now writes each list BEFORE marking (same order rule as REQ-030). AC-079.
R18 high: Step 4b's acknowledgement did not say which directory/run_id to use for an
  unparseable journal -> one sidecar per candidate in its own backup-* dir, run_id from the
  directory name or 'unknown'; if the directory cannot be identified, instruct manual removal.
  AC-073 asserts per-candidate sidecars.
R18 medium: sign (ii) said 'parent key/parent directory' while parent_baseline is null for
  path/service/task -> sign (ii) is now explicitly registry-key only.
R18 medium: sign (ii)'s comparison was ambiguous -> strictly later than the baseline (equal
  counts as our own operation).
R18 medium: machine_path_original nullability vs REQ-003(c) -> null is a self-validation
  failure only if a path_entry_removed SUCCEEDED; all-failed removals make null legitimate.

R19 CRITICAL: the suppression step ran AFTER self-validation, so a journal whose
  cleanup_log_sha256 was non-null while the log itself had vanished would fail Step 3 and
  return 14, never reaching suppression - the exact opposite of the intent. The step is now
  Step 2.5, BEFORE Step 3, and reads the REAL cleanup log rather than trusting the journal's
  sha256 field. The converse branch (failed>0 => normal T3) is stated explicitly.
R19 CRITICAL: AC-056(c)'s multi-entry aggregation cannot hold under T3 (no baseline written if
  the run died) -> marked best-effort and scoped to normal completion.
R19 high: AC-074 conflated cleanup-time (continuous per-entry writes, required for T3 survival)
  with recovery-time (two-phase compute-then-execute) -> AC-074 scoped to recovery only.
R19 high: REQ-030's Step 4b acknowledgement needed a run_id for an UNPARSEABLE journal, but the
  backup-* naming convention was never defined -> new REQ-032 fixes directory naming to
  backup-<run_id>, making the directory name the run_id and making duplicate-run_id detection
  directly implementable. Legacy dirs degrade to run_id=unknown, deduped by path. AC-080.
R19 high: Step 1 filtered candidates by sidecar EXISTENCE, contradicting AC-064's
  'unparseable counts as absent' -> Step 1 now PARSES sidecars; a corrupt sidecar no longer
  suppresses mandatory T3 recovery. AC-082.
R19 medium: cleanup_log_path/timestamp/sha256 nullability was asymmetric -> the three must be
  all-null or all-non-null. AC-083.
R19 medium: exit 12 had no reachable trigger -> defined concretely as 'summary.failed>0 and the
  journal file is missing/unreadable at rollback time', with a constructible fixture. AC-081.
R19 medium: exit 15 covered only journal flush failure but AC-078 required it for an
  unrepaired-list write failure -> broadened to 'persistence-record write failure'.

R20 CRITICAL: Step 2.5 trusted ANY existing successful cleanup log, so a tampered journal
  pointing at ANOTHER run's successful log could skip mandatory T3 recovery entirely -> the
  cleanup log must now be BOUND to this candidate (path exists; if cleanup_log_sha256 is
  non-null the hash must match or the candidate is rejected; run_id must agree). AC-084.
R20 CRITICAL: if ALL entries for a parent lack parent_baseline (crash before the first
  baseline write), sign (ii) is now explicitly skipped for that whole parent, symmetric with
  the per-entry tolerance in REQ-027/AC-075(a). AC-087. AC-056(c) is best-effort.
R20 high: rollback-consumed.json was not covered by REQ-005's atomic protocol -> a crash
  mid-write would leave a malformed sidecar that Step 1 treats as absent, causing
  RE-CONSUMPTION of an already-consumed journal. Now uses File.Replace like the journal.
R20 high: REQ-030's unrepaired-list item_id had no defined relationship to the journal's
  entries -> REQ-027 now enumerates kind (registry_key|startup_value|path_entry|service|task)
  and fixes item_id = '<kind>:<normalized target>'. AC-085.
R20 high: sidecars were accepted as proof of consumption without checking run_id -> the parsed
  sidecar run_id must match the journal or the directory-derived run_id; mismatches count as
  absent, so a copied sidecar cannot skip mandatory recovery. AC-086.
R20 medium: AC-076 referenced a non-existent 'Step 3.5' -> corrected to Step 2.5.
R20 medium: REQ-026 enumerated three code-14 branches while AC-036 required four -> REQ-026 now
  lists all four, including 'both consumption markers failed to write'.
R20 medium: cleanup-log success=true vs journal state=mutation_succeeded equivalence was
  undefined -> they must correspond one-to-one; on disagreement the journal wins and the
  discrepancy is reported. AC-059.
R20 medium: AC-072 did not cover the 'marker written but sidecar missing' branch -> added the
  mutual-exclusion assertion (Step 1 filters; Step 2.5 is not reached).

R21 CRITICAL: the kind enum omitted file/directory deletion, so path/file cleanup actions
  (REQ-018, AC-045/066, DD-006) could not be journaled at all -> kind now has SIX values,
  adding path_deleted (distinct from path_entry, which is PATH-environment-entry removal).
  AC-085 updated.
R21 CRITICAL: Step 2.5's binding required the cleanup log to EXIST, but T3 is defined by that
  log being absent - so the REQ-031 fallback could never fire. Binding is now graded by
  evidence availability: (1) readable -> verify hash+run_id, may suppress; (2) gone and sha256
  null -> do not suppress; (3) gone but sha256 non-null -> do not reject, do not suppress,
  defer to Step 3. AC-090.
R21 CRITICAL: Step 2.5 is stated to read ONLY the cleanup log's summary.failed and must NOT
  depend on the journal's parent_baseline (that aggregation belongs to Step 5's sign-(ii)
  evaluation, consistent with AC-074's two-phase design).
R21 high: REQ-027 tolerates a missing cleanup log with non-null sha256, but AC-068 asserted it
  fails self-validation -> AC-068 rewritten to match REQ-027 (three branches).
R21 high: Step 2.5's run_id binding was unimplementable because cleanup-log.json had no run_id
  -> new REQ-033 requires it to carry the same run_id as the journal; legacy logs without it
  degrade to the 'insufficient evidence' branch. AC-088.
R21 high: if BOTH consumption markers failed to write, the next launch would pass
  self-validation and RE-CONSUME the journal, making AC-053 untestable -> a small durable
  rollback-consumed.failed.json is now written, and that candidate requires
  -AcknowledgeConflicts. AC-089.
R21 high: Step 4a's unrepaired list for OLDER journals had no valid reason code (they were
  never restored, so conflict/not_restorable are wrong) -> reason is fixed to
  skipped_older_journal. AC-091.
R21 high: AC-050 overclaimed that no branch resurrects user-deleted content, contradicting
  REQ-024/DD-018's admitted residual risk -> the overclaim is removed and the residual risk is
  cited explicitly instead.
R21 medium: REQ-021's 24h window constraint was only in a note -> now in the body, with a fixed
  evaluation order (window first, then drift).
R21 medium: duplicate test_type keys existed on AC-075/AC-087 (and duplicate priority/addresses
  on REQ-019) -> all duplicates removed; the file now has zero duplicate YAML keys.

## Verified ground truth about the existing system (all read from code / executed)

# Auto-Rollback — Requirements Analysis (R1 input)

- **Sprint**: `sprint-2026-10-01-01`
- **Feature**: 自动回滚（auto-rollback）—— 清理前自动建立还原点 + 备份；清理失败时自动回滚
- **Author**: Lead (sprint-flow Phase 2 DESIGN, Part A Step 1–2 input)
- **Status**: draft → feeds `/delphi-review --mode requirements`
- **Method**: direct code reading + executed experiments. Every claim about *existing*
  behaviour cites file:line. Every claim about *mechanics* was executed on this machine
  and the observed output is quoted.

---

## 1. Ground truth about the current system

These are not assumptions; they were read out of the code and/or executed.

### 1.1 Cleanup never signals failure via its exit code

`clean-residuals.ps1` sets a non-zero code **only in pre-flight gates**:

| line | code | condition |
|------|------|-----------|
| 235 | 2 | not admin (mandatory) |
| 249/271/302/309/314 | 1 | bad input / report unreadable / bad ConfirmFile |
| 325 | 0 | report-only mode |
| **530** | **0** | **end of a real cleanup run — always 0** |

Per-item failures are recorded **only** in `cleanup-log.json` as
`{ action = 'cleanup_failed', error = ..., success = $false }` (lines 462, 507), and the
summary counts them (`summary.failed`, line 516) — but **the process still exits 0**.

> **Consequence for design**: "cleanup failed" cannot be defined by exit code alone.
> The authoritative failure signal is `cleanup-log.json → summary.failed > 0`.

### 1.2 The complete set of cleanup actions (the rollback contract)

Everything `clean-residuals.ps1` can do, from the `$log.Add(...)` sites:

| action | line | payload logged | reversible? |
|--------|------|----------------|-------------|
| `path_deleted` | 409 | `path` | **partially** — see §2.1 |
| `service_deleted` | 422 | `name` | **no** (binary already deleted first) |
| `task_deleted` | 440 | `name` | **no** |
| `path_entry_removed` | 459 | `path` | **yes** (string edit) |
| `registry_deleted` | 503 | `key` | **yes, if exported first** (proved in §1.4) |
| `startup_value_deleted` | 489 | `key`, `value` | **yes, if exported first** |
| `registry_skip` | 483, 497 | `key` | n/a (nothing changed) |
| `skipped_whitelisted` | 350 | `id` | n/a |
| `skipped_danger` | 355 | `id` | n/a |
| `cleanup_failed` | 462, 507 | `error` | n/a (the action did not complete) |

Critical **ordering** detail: files are deleted **before** services (line 412 comment:
"Delete services (after files, so binaries are released)"). So by the time
`service_deleted` is reached, the service's binaries are already gone — restoring the
service registration alone yields a **broken** service pointing at a missing binary.

### 1.3 The existing registry backup does NOT cover what cleanup deletes

`create-restore-point.ps1` lines 104–108 export exactly three keys — all of them
`...\CurrentVersion\Uninstall` keys. But `clean-residuals.ps1` deletes keys of the form
`HKLM\Software\<Vendor>` / startup **values** (lines 471–503), and edits `PATH`
(lines 430–459). **None of those are covered by the current backup.**

> **Consequence for design**: the existing backup is adequate for *scanning* safety but
> **insufficient for rollback**. Auto-rollback must export each key *at the moment it is
> about to be deleted*, not rely on the pre-flight backup.

### 1.4 Targeted registry restore works — proved by execution

Executed on this machine (HKCU sandbox, no admin needed):

```
1) created HKCU\Software\WRC_RollbackProbe with Marker=hello and Sub\Nested=0x2a
2) reg export  -> 376-byte .reg file
3) reg delete  -> key gone
4) reg import  -> exit 0
5) reg query /s -> Marker REG_SZ hello ; Nested REG_DWORD 0x2a   ← fully restored
```

So **export-before-delete + import-to-restore is a real, working mechanism**, and unlike a
whole-system restore point it is *targeted*: it restores exactly what we removed.

### 1.5 System Restore availability is not guaranteed, and is throttled

From `create-restore-point.ps1` (§ 38–98): restore-point creation is best-effort.
It can be **disabled** (System Protection off) and `Checkpoint-Computer` can **throw**;
on throw the script sets `$restorePointEnabled = $false` and prints
`"Cleanup will proceed WITHOUT backup protection."` (line 97).
Windows also throttles restore-point creation (default once per 24h via
`SystemRestorePointCreationFrequency`), so a second cleanup in a day silently creates none.

---

## 2. Requirements

### 2.1 What auto-rollback can and cannot undo

This is the most important section. Being honest here is what keeps the feature from
becoming dangerous snake oil.

**CAN be rolled back — reliably**

| item | mechanism | notes |
|------|-----------|-------|
| `registry_deleted` | `reg import` of a per-key `.reg` exported immediately before deletion | proved §1.4; covers subkeys/values |
| `startup_value_deleted` | same, exported at value granularity | must export the **value**, not the shared Run key |
| `path_entry_removed` | re-append the exact string to the same scope (user/machine) | must record scope + original position |

**CANNOT be rolled back**

| item | why | honest statement to the user |
|------|-----|------------------------------|
| `path_deleted` (file/dir contents) | `Remove-ItemRobust` deletes recursively with no archive; tier 4 even renames then schedule-deletes | **contents are gone.** A restore point *would* help, but only if one was successfully created |
| `service_deleted` | binaries are deleted *before* the service (line 412), so re-creating the registration yields a service pointing at nothing | registration restorable, service **functionality** is not |
| `task_deleted` | we delete the task but never captured its XML/action | not restorable |
| anything after a reboot mid-rollback | state is in-memory unless journaled | must journal to disk |

> **Design consequence (non-negotiable)**: auto-rollback must never *claim* to have
> "undone" the cleanup. It must report **per item** what was restored and what was not.
> A blanket "Rollback complete ✓" would be a lie for path/service/task deletions.

### 2.2 What counts as "cleanup failed" (triggers rollback)

Three distinct triggers must be considered separately:

- **T1 — hard abort**: a pre-flight gate returns non-zero (exit 2/1). **Nothing was
  changed**, so **no rollback should run**. (Rolling back here would be pure noise, and
  worse: it could restore state the user did not ask us to touch.)
- **T2 — item-level failure**: `summary.failed > 0` in `cleanup-log.json` while the
  process still exited 0 (§1.1). This is the real case auto-rollback exists for.
- **T3 — partial completion**: the run died mid-way (power loss, Ctrl-C, crash). The log
  may be missing entirely or truncated.

**Recommended rule** (needs the user's confirmation, see §4 Q1):
rollback triggers on **T2 only**, plus **T3 when a journal exists** — and never on T1.

### 2.3 The scariest risk: a system restore point is a blunt instrument

`Restore-Computer` rolls the **entire system** back to the restore point. If the user
installed software, saved documents, or changed settings *after* the restore point was
created, auto-executing `Restore-Computer` would **destroy those changes too** — far worse
than the residue we were trying to clean. It also **forces a reboot**.

> **Design consequence**: `Restore-Computer` must **never** be invoked automatically.
> Automatic rollback is restricted to **targeted** restoration (registry import + PATH
> edit + reported-manual steps). The restore point stays a manually-invoked last resort,
> and the tool must say so explicitly.

This is the single most important safety constraint in the whole feature.

### 2.4 Acceptance criteria (draft)

Each is written to be mechanically verifiable.

| id | criterion | test_type |
|----|-----------|-----------|
| AC-001 | Before deleting a registry key, the key is exported to a per-item `.reg` inside the run's backup dir; the filename is recorded in the journal | unit |
| AC-002 | Before deleting a startup **value**, only that value is exported (the shared Run key is never deleted or wholly re-imported) | unit |
| AC-003 | A journal file is written **before** the first destructive action and flushed after each item, so a crash leaves a usable record | integration |
| AC-004 | Rollback restores `registry_deleted` items via `reg import` and each restored key is re-queried to confirm it exists | integration |
| AC-005 | Rollback restores `path_entry_removed` items and the resulting PATH string equals the pre-cleanup string | integration |
| AC-006 | Rollback output lists, per item, one of `restored` / `not_restorable` / `restore_failed`, with a reason for the latter two | unit |
| AC-007 | Rollback **never** invokes `Restore-Computer` automatically; a test asserts the command is never called on the auto path | unit |
| AC-008 | Pre-flight gate failures (exit 2/1) do **not** trigger rollback, even when a journal is present | unit |
| AC-009 | `summary.failed > 0` with process exit 0 **does** trigger rollback | integration |
| AC-010 | `-DryRun` writes no journal and performs no rollback | unit |
| AC-011 | If rollback itself fails partway, it continues with the remaining items and reports partial success rather than aborting | integration |
| AC-012 | Auto-rollback can be disabled by an explicit switch, and when disabled the behaviour is exactly today's | unit |
| AC-013 | The tool warns the user *before* cleanup when it cannot create a restore point, stating that file/dir deletions will be **unrecoverable** | unit |
| AC-014 | Rollback is idempotent-enough to be re-run: a second run reports already-restored items as `already_present` instead of erroring | integration |

### 2.5 Non-functional requirements

- **NFR-1** PS 5.1 compatible (runtime baseline) and must also pass under pwsh 7 — the
  pre-commit gate runs Pester on **pwsh 7**. (Learned the hard way this sprint.)
- **NFR-2** Every new script keeps the ADR-001 shape: `Main` relays via `[ref]$ExitCode`,
  no `exit` inside `Main`, guard does the single `exit`.
- **NFR-3** No new `--no-verify`, no additions to `.xp-gate-powershell-coverage-ignore`;
  new code must arrive with tests that keep coverage ≥ 80%.
- **NFR-4** Backup/journal artefacts go to the gitignored `backup-*` area, and tests must
  build/clean their own fixtures (hermeticity — blocker B1's lesson).
- **NFR-5** Rollback must be usable when the machine is in a bad state: it must not depend
  on the report/scan JSONs being present or valid.

---

## 3. Recommended shape (for the design doc)

1. **Journal-first**: `clean-residuals.ps1` writes `rollback-journal.json` before its first
   destructive act, appending one record per item *before* that item is touched.
2. **Per-item pre-export**: immediately before `reg delete`, `reg export` that exact key;
   immediately before removing a startup value, export that value.
3. **Targeted restore** (`rollback.ps1 -Auto`): consume the journal, restore what is
   restorable, and print an explicit per-item verdict plus a manual-steps list for the rest.
4. **Never** auto-invoke `Restore-Computer`; surface the restore point as a manual option.
5. **Report honestly** when protection was unavailable.

---

## 4. Open questions (must be resolved before BUILD)

| id | question | why it matters | lead's recommendation |
|----|----------|----------------|------------------------|
| Q1 | Does rollback trigger on T2 only, or also on T3 (crash)? | T3 needs a journal that survives a hard kill; more code, more risk | **T2 + T3-with-journal** |
| Q2 | If rollback itself fails, should it retry, or stop and report? | retry loops can make things worse | **continue per item, report partial** |
| Q3 | Should the user be asked before an automatic rollback runs? | the user asked for *fully automatic*; a prompt contradicts that, but silent destructive action is scary | **no prompt** (user's explicit choice), but log loudly and make the run fully auditable |
| Q4 | Interaction with `-DryRun`? | must be a true no-op | **no journal, no rollback** |
| Q5 | Should `service_deleted` / `task_deleted` attempt best-effort restore? | a service pointing at a deleted binary is worse than no service — it *looks* installed | **no**; report as `not_restorable` and explain |
| Q6 | Should auto-rollback be on by default? | default-on turns every cleanup into a potentially destructive re-write | **on by default**, since the user chose fully-automatic, but with an explicit `-NoAutoRollback` switch |
| Q7 | Where does the journal live, and for how long? | `backup-*` is gitignored; stale journals could trigger a wrong rollback | journal in the run's `backup-<ts>` dir, and rollback only honours a journal whose run id matches the log being rolled back |

---

## 5. Risks

| id | risk | severity | mitigation |
|----|------|----------|------------|
| R-1 | User believes "auto-rollback" means everything is undoable; deletes files, loses data | **critical** | explicit per-item verdict + pre-cleanup warning that file deletions are unrecoverable |
| R-2 | Auto `Restore-Computer` wipes unrelated post-restore-point user changes | **critical** | forbid auto-invocation (AC-007) |
| R-3 | Restore point silently unavailable (protection off / 24h throttle) → user thinks they're protected | high | surface `restore_point_enabled` prominently; AC-013 |
| R-4 | Journal written but stale → wrong rollback applied | high | bind journal to run id + verify against cleanup-log timestamp (Q7) |
| R-5 | Crash mid-rollback leaves half-restored state | medium | per-item verdict + rerunnable (AC-014) |
| R-6 | `reg import` of a large export partially fails | medium | re-query each key (AC-004) |
| R-7 | Coverage gate blocks the commit if new branches are untested | medium | TDD from the start; keep ≥80% |

---

## 6. Explicit non-goals

- Recovering deleted **file/directory contents**. Not possible without a file-level archive,
  which was never built. (Could be a *future* feature: archive paths before deletion.)
- Rolling back beyond the immediately preceding cleanup run.
- Restoring services or scheduled tasks to a *functional* state.
- Anything involving `Restore-Computer` on an automatic path.


## The specification under review

specification:
  feature: auto-rollback
  sprint: sprint-2026-10-01-01
  design_doc: docs/plans/2026-10-02-auto-rollback-design.md
  requirements_doc: .sprint-state/phase-outputs/requirements-auto-rollback.md
  approved: 2026-10-02

  # ─────────────────────────────────────────────────────────────────────────
  # REQ-001..004 are the PREREQUISITE DEFECTS (approved as in-scope, DR-006 Q4).
  # They are not polish: rollback built on a lying log and a fake backup gate
  # would be worse than no rollback at all.
  # ─────────────────────────────────────────────────────────────────────────
  requirements:
    - id: REQ-001
      description: 捕获 Machine PATH 的逐字原值（每次运行一次，在第一次 PATH 删除之前）并写入日志，使 PATH 条目可被回滚，并消除同一轮内多次读-改-写的竞争。User PATH 当前不在清理范围内（clean-residuals.ps1:449/453 只读写 'Machine'），因此本项只覆盖 Machine 作用域；若将来扩展到 User 作用域，必须同样先备份
      priority: critical
      addresses: "D-1 (design doc 1.3), DD-008"

    - id: REQ-002
      description: path_deleted 日志必须记录真实结果（deleted vs renamed:<newname>），Tier-4 重命名不得再被记为成功删除
      priority: critical
      addresses: "D-2 (design doc 1.3), DD-009"

    - id: REQ-003
      description: |
        清理前置条件必须校验**强制精准保护**（见 REQ-017）真实有效，而非仅检查目录存在：
        (a) 回滚日志可创建且可写；
        (b) 逐项备份机制可用（备份目录可写、reg export 可用）；
        (c) **Machine PATH 原值可被捕获**——**仅当本轮存在要删除的 PATH 条目时**要求；
        若本轮没有 PATH 条目待删，则不要求捕获、`machine_path_original` 允许为 null。
        这消除了「没改 PATH 却因未捕获而被拒」的假失败。
        **不**把 restore-status.json / 系统还原点作为中止条件——它是可选层（REQ-017(b)），
        不可用时按 REQ-014 告警后继续。
      priority: critical
      addresses: "D-3 (design doc 1.3), DD-010, REQ-017"

    - id: REQ-004
      description: |
        create-restore-point.ps1 必须如实报告「可选系统还原点」是否建立成功：
        成功写出 restore-status.json 且 restore_point_enabled=true → 返回 0；
        未能建立（System Protection 关闭 / 24h 节流 / 无权限）→ restore_point_enabled=false
        并返回一个**可区分**的非零码（用于 UI 与日志如实呈现），但该非零码
        **不得**被 clean-residuals.ps1 当作中止条件（见 REQ-025）。
        绝不静默 fail-open：不得在未建立保护时假装成功。
      priority: critical
      addresses: "D-4 (design doc 1.3), DD-010, AC-018"

    - id: REQ-005
      description: |
        新增 rollback-journal.json，在第一次破坏性操作之前创建，并在每一项处理前后落盘，
        使硬杀死后仍留下可用记录。
        **每次落盘必须原子**：写临时文件 → flush → 用**真正的原子替换原语**交换到目标路径。
        **不得使用 `Move-Item -Force`**：在 PowerShell 5.1 下它是「先删除目标再移动」，
        中间存在目标缺失的窗口，崩溃即丢失日志——这正好违背本节要保证的性质。
        应使用 .NET 的 `[System.IO.File]::Replace()`（或 Win32 `ReplaceFile`），
        它提供原子换入并自动保留上一代副本；
        若目标文件尚不存在（首次写入），则退化为「写临时文件 + `File.Move`」，
        此时不存在需要保留的旧内容，窗口无害。
        绝不原地重写 JSON——崩溃在写入中途会留下畸形日志，而 REQ-027 会拒绝畸形日志，
        反而使 T3 恢复不可用。
        **最后一次完好状态的具体协议**：每次成功原子替换后保留上一代副本
        `rollback-journal.prev.json`（先复制当前文件为 `.prev`，再替换）。当下一次读取
        发现 `rollback-journal.json` 无法解析时，回退读取 `.prev.json`；仍不可解析则视为
        无日志并如实报告。**回退深度固定为 1 代**（不做多代链，避免复杂度失控）。
        **运行中落盘失败必须 fail-closed**：若在某项变更后日志落盘失败（磁盘满、权限变化等），
        必须立即停止后续所有破坏性操作，并**如实报告**：
          - 对「最后一次成功落盘的日志状态」执行回滚；
          - 该次**未能落盘**的变更**不**假装可回滚——它不在 durable 日志中，
            REQ-024 的规则 3/4 因此判不了它，只能从进程内证据尽力恢复，
            并在结果中明确标记为 `restore_failed(unjournaled)` 或「未能记录」，
            要求人工介入；**绝不**因为「规则 4 说不自动恢复」就直接静默跳过；
          - 绝不静默留下一处未修复且无记录的删除；
          - 返回区别于普通部分失败的退出码。
        选择「原地尽力恢复 + 明确报告」而非「仅记为 T3 下次再恢复」，是为了避免把
        已知的受损状态留在机器上。
      priority: critical
      addresses: "DD-002, AC-003, AC-049"

    - id: REQ-006
      description: 在 reg delete 之前，对该精确键执行 reg export 到本轮备份目录，并把导出文件记入日志。**逐项 fail-closed**：若导出未能创建或校验失败（权限、IO、注册表读取失败），则该次删除必须被跳过并记为 cleanup_failed，原因注明 export_failed——绝不允许在没有可用备份的情况下删除
      priority: critical
      addresses: "DD-001, AC-001, AC-024"

    - id: REQ-007
      description: 在删除启动项 VALUE 之前，对该 value 做精确备份（见 DD-003），且备份成功是删除的前置条件；**导出失败或裁剪失败一律跳过删除**并记为 export_failed（裁剪失败记为 trim_error）。绝不删除或整键重导共享的 Run/RunOnce 键
      priority: high
      addresses: "DD-003, AC-002, AC-024"

    - id: REQ-008
      description: rollback.ps1 新增 -Auto 模式，消费日志并逐项精准恢复；不带 -Auto 时行为与今天完全一致
      priority: critical
      addresses: "AC-004, AC-005"

    - id: REQ-009
      description: 回滚必须逐项输出且仅输出四种判定之一：restored / already_present / not_restorable / restore_failed，并给出后两者的原因。「未变更（planned/backup_created 且目标与清理前一致）」一律归入 already_present，不另立第五种判定
      priority: critical
      addresses: "AC-006, DD-006"

    - id: REQ-010
      description: 回滚绝不自动调用 Restore-Computer；还原点仅作为手动、需显式同意的逃生口被记录和展示
      priority: critical
      addresses: "DD-002, AC-007"

    - id: REQ-011
      description: 当 summary.failed > 0 时触发自动回滚（逐项精准撤销，而非整轮推翻）；触发条件只看日志内容，与进程退出码无关；-DryRun 不写日志也不回滚
      priority: high
      addresses: "AC-008, AC-009, AC-010, DR-006 Q2"

    - id: REQ-012
      description: 自动回滚可通过 -NoAutoRollback 显式关闭。该开关**只**关闭「自动触发与执行回滚」，不关闭任何安全性/诚实性修复——REQ-001..004 与 REQ-015 的修复在 -NoAutoRollback 下**依然生效**（否则该开关会复活已知的不安全与误导行为）
      priority: medium
      addresses: "AC-012, DD-005"
      note: 因此 AC-012 断言的是「不调用本轮回滚、不尝试本轮恢复」，而非「行为与今天逐字一致」。上轮遗留日志的 T3 消费/恢复不受该开关影响（REQ-030）

    - id: REQ-013
      description: 回滚自身部分失败时继续处理剩余项并报告部分成功，不整体中止；重复运行报告 already_present 而非报错
      priority: high
      addresses: "AC-011, AC-014"

    - id: REQ-014
      description: 无法建立保护时在清理前给出显著告警；CleanupPanel.tsx 的“已通过系统还原点备份”文案改为按真实状态条件渲染。**还必须告知 T3 的时间边界**：崩溃后的自动恢复必须在 **24 小时内**的下一次启动时完成，超时即降级为需人工介入；该说明必须出现在 UI 与文档中，使用户事先知情
      priority: high
      addresses: "AC-013, DD-011, AC-065"

    - id: REQ-015
      description: clean-residuals.ps1 在 summary.failed > 0 时返回可区分的非零退出码，使 UI 与调用方能够识别部分失败
      priority: high
      addresses: "DD-012, AC-019"
      note: 与 REQ-011 正交——回滚触发判定只读日志，不读退出码；本项只改变「调用方能否从退出码看出部分失败」，不改变「何时回滚」

    - id: REQ-016
      description: |
        T3（崩溃/硬杀死/断电）边界必须**如实**定义，不得过度承诺：
        进程已死，没有任何自动调用者能在崩溃瞬间发起回滚。因此 T3 的恢复是
        **「下次启动时恢复」**：在下一次 clean-residuals.ps1 运行开始时，若发现一个
        自证有效的未完成回滚日志（REQ-019），必须先消费它完成恢复，再开始新的清理。
        清理日志缺失或截断但回滚日志存在时，以回滚日志为准；两者都缺失时
        明确报告「无可回滚记录」且不修改系统。用户可见文案不得声称崩溃能即时自动回滚。
      priority: high
      addresses: "AC-021, AC-033, design doc 3.5 T3"

    - id: REQ-024
      description: |
        恢复注册表键与启动项 value 之前必须做冲突检测。判定规则是**唯一权威规则**，
        REQ-018/REQ-029 一律引用本规则，不得另立：
          1. 目标已存在且与备份**一致** → 报告 already_present，不重复恢复；
          2. 目标已存在但与备份**不同** → 报告 restore_failed(conflict)，**不覆盖**；
          3. 目标**不存在** 且 状态 = mutation_succeeded 且 pre_existing = true
             且 `absent_confirmed_after_mutation` = true → 执行恢复；
          4. 其它一切「目标不存在」的情形（含仅 planned/backup_created，或缺少
             `absent_confirmed_after_mutation`）→ 报告 conflict/需人工介入，**不**自动恢复。
         因果证据链（缺一不可）：
           - `pre_existing = true`  → 清理前确实存在；
           - `mutation_succeeded`   → 本轮确实执行了删除且成功；
           - `absent_confirmed_after_mutation = true` → 删除后**立即**复查确认目标已消失。
         **诚实的边界（重要）**：上述三项目标只能证明「本轮删除时目标消失了」，
         **不可能**证明「此刻的缺失仍归因于本轮」——两件事之间外部仍可能创建又删除。
         Windows 未提供无篡改的时间戳/审计通道，因此该窗口无法在规格层面消除。据此：
           - 窗口从 journal 的 `created_at` 量到**恢复尝试时刻**（T3 下即下次启动那一刻，
             而非崩溃时刻）。当 `completed_at` 为空且**经过时间严格小于 24 小时**
             （`now - created_at < 24h`；恰好 24h 视为超窗）时，接受三项目标并恢复；
           - **明确的取舍**：延迟恢复（超过 24h 才启动）会失去自动恢复能力，降级为人工。
             这是为安全付出的代价，必须在设计中写明并让用户可见；
           - **可检测的「外部变更迹象」**（任一命中即降级为 conflict/需人工，**不**自动恢复）：
             (i) 目标当前存在但与备份内容不同（规则 2）；
             (ii) **仅适用于注册表键/value 条目**：备份的**注册表父键**的 LastWriteTime
                  **严格晚于该父键的恢复端聚合基线** `MAX(parent_baseline)`
                  （path/service/task 条目跳过本检查——它们 `parent_baseline` 恒为 null，
                  也没有「注册表父键」语义）。
                  **比较对象只有这一个**：恢复端聚合基线。**不**与「本轮开始时间」比较——
                  因为我们自己的删除**必然**会更新父键 LastWriteTime，
                  用开始时间作比较会让本工具的变更被误判为外部变更，规则 3 将永不成立。
                  且**比较必须发生在本轮回滚写任何东西之前**——因为回滚自身对同一父键下
                  多个条目的顺序恢复同样会推进父键时间戳，若边恢复边比较，
                  后面的条目会把**我们自己刚做的恢复**误判为外部变更而拒绝恢复。
                  因此实现必须**先对全部条目算出冲突判定，再逐个执行恢复**
                  （两阶段：判定 → 执行），而不是边判定边写，
                  用开始时间作比较会让本工具的变更被误判为外部变更，使规则 3 永不成立。
                  **聚合方式（恢复端计算，无需运行结束落盘）**：取日志中该父键下**所有**
                  条目 `parent_baseline` 的**最大值**，**计算时跳过 null 值**；
                  若该父键下**全部**条目的该字段都为 null（例如崩溃发生在第一次基线写入之前），
                  则对该父键的所有条目**跳过**迹象 (ii)，并在报告中标注该父键证据不完整。
                  这与 REQ-027/AC-075(a) 的**逐条目**容错是对称的：一个是「个别条目缺」，
                  一个是「该父键一个都没写上」，两者都不得导致整份日志被拒绝。
                  AC-056(c) 的多条目聚合断言属于**尽力而为**，仅要求在至少一条基线
                  于崩溃前落盘时成立。
                  **比较语义**：聚合基线即「本轮对该父键的最后一次操作时刻」，
                  因此判定条件是父键当前 LastWriteTime **严格晚于**该基线
                  （相等视为本轮自身操作，不算外部变更），同一父键（如 `HKLM\Software` 或
                  `...\Run`）下若有多个条目，后一个条目的删除会再次推进父键时间戳，
                  用「本条目的」基线会使先前条目被误判为外部变更——取最大值即可消除该问题。
                  T3 下该字段由每个条目变更后**立即**持久化，不依赖运行结束；
                  若某条目缺失该字段（老版本日志或未及写入），迹象 (ii) **对该条目不做检查**，
                  退化为仅依据三项目标与窗口判定，并在报告中注明该项证据不完整；
             (iii) Machine PATH 当前值 ≠ 预期值（见 REQ-021）。
        另有**日志级**拒绝条件（(iv)/(v)），它们在处理任何条目前即生效，不走本表的
        逐条 conflict 判定，而是整份日志自证失败、返回 14（见 REQ-019/REQ-027/REQ-030）：
             (iv) 同一 run_id 的日志出现在多个备份目录（DD-017）；
             (v) 日志/备份哈希与记录不符（REQ-027 自证不通过）。
           - 超过 24 小时、无法确认时间、或命中上述任一迹象时，一律降级为 conflict，
             **不**自动恢复。
           - **残留风险（显式记录，见 DD-018）**：在「本轮变更完成并记录基线」之后、
             「恢复执行」之前，若外部又发生创建+删除，则三项目标齐备、窗口内、迹象均不命中，
             工具仍会将当前缺失归因于本轮。`parent_baseline` 只能证明「父键此后未被外部写入」，
             **不能**证明「此缺失是本轮的」。该窗口无法通过增加标记消除，
             设计中如实记录，不宣称可以完全消除。
         该 24 小时窗口**固定为 24 小时，不提供配置开关**：它是一条安全边界，
         不是调优参数，可配置只会制造「把窗口调大以追求更自动」的危险诱因。
         设计文档必须写明其存在与含义，UI 文案不得宣称「任何时刻都能可靠还原」。
        **比较口径**：注册表按结构比较——**导出范围内**（与 `reg export` 的递归范围一致，
        即该键及其全部后代）的子键集合与所有 value 的 (name, type, data) 元组必须一致；
        导出范围之外的子键不参与比较。对于 DD-003 的启动项 value（先导出父键再裁剪），
        比较范围为**目标 value 本身**：解析裁剪后的最小 .reg，取出该 value 的
        `(name, type, data)`，与当前注册表中同名 value 的 `(name, type, data)` 做结构比较。
        `.reg` 中的 **Windows Registry Editor Version 行、父键行、空行、以及父键的时间戳/ACL
        等元数据一律不参与比较**（与注册表键比较口径对称），而非整个 Run/RunOnce 树。
        DD-003 的裁剪函数因此必须产出「只含单 value 定义 + 必要父键行」的最小 .reg，
        不得包含其它 value。注册表键比较同样忽略时间戳/ACL；PATH 按字符串精确相等比较。
      priority: critical
      addresses: "AC-034, AC-039, REQ-008, REQ-009, REQ-018, REQ-029"

    - id: REQ-030
      description: |
        上轮未完成日志的恢复判定：
        - **完全成功** = 没有任何 restore_failed 条目；not_restorable（文件/服务/任务删除）属于
          「已如实报告」而非失败，不阻止后续运行，但必须显著告警。
          即使**全部**条目都是 not_restorable（上轮只删过文件），也属于完全成功：上轮未留下
          可修复状态，告警后继续，**不**中止；
        - 恢复**未完全成功**（存在 restore_failed，或上轮 T3 恢复被跳过）→ 必须中止本轮清理
          （在 REQ-003 前置检查之前），返回明确的非零码并写出恢复结果。
        - 候选日志**未通过 REQ-027 自证**，或发现重复 run_id（DD-017）时：视为上轮恢复未完成，
          返回 14 并在前置检查之前中止（绝不带病继续清理）；
        - 候选日志存在但**没有任何可处理条目**（全部为 skipped/not_restorable，或条目为空）：
          视为完全成功，告警后继续（不返回 14）；
        - **人工确认出口（必需）**：`restore_failed(conflict)` 不得让工具永久无法清理。
          确认方式为 `-AcknowledgeConflicts`（显式开关）：
          此时日志被标记为 `completed_at` + `consumed_with_failure=true`，
          后续运行按「已完成（带未修复项）」处理并继续。
        - **「完全成功」的精确定义（避免把证据缺失误判为失败）**：本轮判为
          「完全成功」的充要条件是**不存在 restore_failed 条目**；
          `not_restorable` 只告警、不阻断；而**证据不完整但仍通过规则 3/4 的条目**
          （如缺 `parent_baseline` 而跳过迹象 (ii)）判定为
          `restored (evidence_incomplete)`——它**算成功**、会计入已恢复，
          只在报告中标注证据不完整，**不**使本轮退化为 14。
          真正的失败只有：conflict、unjournaled、export_failed（这些才是 restore_failed）。
        - **未修复清单必须先落盘到 backup 目录之外**，再允许日志被标记为已消费。
          执行顺序固定为：(1) 原子写未修复清单 → (2) **成功后才**写日志标记/旁路文件。
          对**自证失败/不可解析**的候选（Step 4b 情形）没有可读的条目列表可展开，
          此时写一份**候选级**清单：`unrepaired[]` 为空数组，
          但在顶层记录 `candidate_unparseable: true` 与该 `backup_dir`，
          使 AC-060 的「先清单后标记」顺序对三类 14 情形都成立且可测。
          若 (1) 失败，则**中止且不写任何标记**，返回 15——
          绝不允许出现「已确认但清单丢失」的状态：那会让用户以为问题已被记录，
          而实际上唯一的证据已经没了。
          约定：路径固定为**项目根目录**下的 `<project_root>/output/rollback-unrepaired-<run_id>.json`
          （与 `backup-*/` 同级；**不是**某个 `backup-*` 的子目录，
          否则删除该备份目录仍会连带丢掉清单），原子写（`[System.IO.File]::Replace()`，见 REQ-005），
          模式至少含 `run_id`、`created_at`、`backup_dir` 与 `unrepaired[]`；
          `unrepaired[]` 每项含 `item_id`、`kind`、`target`、`reason`（conflict/unjournaled/
          not_restorable 等）。**不把「删除 backup 目录」作为确认路径**——目录一旦删除，
          未修复条目清单即唯一副本丢失，与本节「始终保留清单」的要求冲突。
          删除目录仅作为最后手段，且此时必须先输出清单并告知用户其位置。
        - 该确认出口必须同时适用于「恢复未完全成功」「自证失败/重复 run_id」
          「created_at 平局/多日志歧义」三种 14 情形，否则歧义一旦出现同样会永久锁死清理。
        - **Step 4b（任一候选自证失败）也必须能解锁**：此时没有任何日志被「选中」，
          因此 `-AcknowledgeConflicts` 必须为**全部**自证失败的候选**各写一份**
          `rollback-acknowledged.json`（写在各自实际所在的 `backup-*` 目录下；
          `run_id` 取目录名，无法确定时写 `unknown`），使其在 Step 1 就被剔除。
          若连目录标识都无法确定，则提示人工删除对应 `backup-*` 目录后重试。
          没有这条路径，「所有日志都损坏」会让工具永远返回 14、彻底无法使用；
        - **日志不可改写时的确认旁路**：畸形/无法解析的日志**不能**原地写入
          `completed_at`（写不进去，也写不对），无法用上面的方式标记。
          因此确认信息必须能落在日志之外：在**该候选日志实际所在的 `backup-*` 目录**下
          写旁路文件 `rollback-acknowledged.json`（对不可解析的日志，`run_id` 取目录名；
          若连目录名都无法作为标识，则写固定值 `unknown`，仍以**文件所在目录**为准），
          模式固定为
          `{"run_id":"<guid 或目录标识>","acknowledged_at":"<ISO 8601>","reason":"<...>"}`，
          原子写（`[System.IO.File]::Replace()`）。发现规则读取它：
          **存在即视为该日志已被确认消费**，不再返回 14。
          语义澄清（避免「人写 vs 工具写」的歧义）：`-AcknowledgeConflicts` 是
          **必须由人显式给出的授权开关**——工具在未加该开关时绝不自行确认，一直返回 14；
          加了开关后，由**工具代为执行**写旁路/标记的机械动作。
          也就是说：**决定权在人，落盘由工具**。
          同理，`rollback-consumed.json` 是**工具**在成功消费后自动写入的，
          用户无需也不应手工创建它。
        - **平局/选不中日志**时没有「被选中的日志」可标记，因此
          `-AcknowledgeConflicts` 的语义定义为：对**全部**候选未完成日志
          （可解析的写 `completed_at`+`consumed_with_failure`；不可解析的写
          `rollback-acknowledged.json`），并先输出每份日志的
          `backup_dir`/`run_id`/`created_at` 清单供用户核对，然后继续清理。
          若用户不确认，则工具保持 14 中止——**默认安全，出错必须由人拍板**。
        顺序为：消费日志 → 尝试恢复 → 若未完全成功则中止（此时**不**执行新的前置检查，也**不**创建新备份）。
        **该 T3 消费与恢复是强制的，-NoAutoRollback 也不能跳过**——该开关只关闭「本轮清理失败后的自动回滚」。
        **两处必须明确的例外与顺序**：
          - `-DryRun` 必须保持**零副作用**：它**不**消费日志、**不**执行恢复、**不**改写任何
            标记，只**报告**发现了未完成日志并提示用户正常启动一次以恢复。
            这与 AC-010 的零副作用断言一致；
          - **管理员权限检查先于 T3 恢复**：非管理员运行时先返回 2，
            不得因恢复失败而返回 14（否则非管理员会看到一个误导性的退出码）。
            若在已通过权限检查后恢复过程中仍遇权限错误，则按 2 报告权限问题。
      priority: critical
      addresses: "AC-042, REQ-028, REQ-026"
    - id: REQ-029
      description: 恢复前必须能区分「本工具删除的」与「他人后来删除的」：日志记录清理前的存在状态与备份文件，只有在能满足 REQ-024 第 3 条的因果证据（状态 mutation_succeeded + 记录清理前存在）时才自动恢复；否则按 REQ-024 第 4 条报告 conflict/需人工介入，绝不自动复活用户主动删除的内容
      priority: critical
      addresses: "AC-039, REQ-018, REQ-024"

    - id: REQ-025
      description: clean-residuals.ps1 必须把「可选系统还原点不可用」与「前置门禁失败」区分开：前者按 REQ-014 告警后**继续**清理，后者才中止。强制精准保护（REQ-017(a)）不可用时中止，可选层不可用时不停机
      priority: critical
      addresses: "AC-035, REQ-003, REQ-004, REQ-017"

    - id: REQ-026
      description: |
        必须定义明确的退出码矩阵（见 design doc §3.5.1），区分：
        0=成功；1=输入/前置错误；2=权限错误；3=依赖缺失；
        10=清理部分失败但回滚完全成功；11=清理部分失败且回滚部分/完全失败；
        12=部分失败但无可回滚记录——具体触发条件为「`summary.failed > 0` 且需要回滚时
        发现回滚日志文件已不存在或不可读」（例如被外部清理工具删除、或备份目录被移走）；
        该码是可构造的，AC-081 用「删除日志后再触发部分失败」的 fixture 覆盖它；
        13=部分失败且 -NoAutoRollback 已显式关闭回滚；
        14=上轮未完成日志未能安全消费，本轮清理**未开始**即中止（REQ-030）。
        **四个分支并列**（AC-036 逐项断言）：(a) 恢复未完全成功（存在 restore_failed）；
        (b) 自证失败或重复 run_id（REQ-019 Step 4b）；
        (c) 候选日志歧义（created_at 平局或多个不同时刻的未完成日志）；
        (d) 消费标记（`rollback-consumed.json` 与日志内 `completed_at`）**两者都写失败**；
        15=运行中**持久化记录写入失败**（回滚日志落盘失败，或未修复清单写入失败，
        见 REQ-005/REQ-030），已按 fail-closed 停止。
        **一次运行只返回一个码；15 是终态**：一旦日志落盘失败，立即返回 15 并**不再**判定
        10/11/12/13（后续破坏性操作已停止，回滚判定不再执行）。
        13/14/15 都是必需的：否则调用方无法区分「已修复」「你让我别修」「上一轮还没修好」
        「记录已失效，必须人工处理」。
      priority: high
      addresses: "AC-028, AC-036, REQ-020"

    - id: REQ-017
      description: |
        「保护」分两层，语义必须区分：
        (a) **强制精准保护** = 回滚日志 + 逐项注册表/PATH 备份。它失败时清理必须在第一次破坏性操作之前 fail-closed 中止（非零码），不得继续删除。
        (b) **可选系统还原点** = 尽力而为的最后手段。它不可用（System Protection 关闭 / 24h 节流 / 无权限）时**不**中止清理，而是由 REQ-014 在清理前显著告警。
        两层不可混为一谈：否则装了还原点不可用的机器将永远无法清理，或反过来在无强制保护时继续删除。
        **对用户可见承诺的修订（必须写进 UI 文案与文档）**：产品承诺从「已通过系统还原点备份」
        改为**「强制逐项精准保护 + 尽力而为的系统还原点」**。
        理由是系统还原点在本机已被验证为**不可靠**：需要管理员权限才能查询、受 24h 节流限制、
        System Protection 可能整体关闭。把不可靠的一层当作主要承诺就是虚假陈述。
        还原点创建**仍然是尽力而为地尝试**（用户已批准的 Q6），失败时按 REQ-014 告警并继续，
        但**不得**再被表述为「已备份」。系统还原点不可用时清理照常进行，
        因为强制精准保护（a）已经承担了真正的安全责任。
      priority: critical
      addresses: "AC-022, AC-013, DD-010, AC-065"

    - id: REQ-018
      description: |
        回滚日志必须实现显式状态机，并定义**恢复协议**以消除「崩溃窗口」歧义：
        状态枚举固定为 `planned` → `backup_created` → `mutation_succeeded`（或 `mutation_failed`），
        并额外记录布尔证据字段 `pre_existing` 与 `absent_confirmed_after_mutation`（含义见 REQ-024）。
        **对按 DD-006 不可恢复的 path/service/task 条目（`backup_file` 为 null，无备份可言）**：
        它们**跳过** `backup_created`，状态路径为 `planned` → `mutation_succeeded`
        （失败则 `mutation_failed`）。这类条目在恢复时一律判为 `not_restorable` 并给出原因，
        不参与 REQ-024 的恢复判定；其 `pre_existing`/`absent_confirmed_after_mutation`
        仅用于如实报告。这样状态机对两类条目都有定义，不存在「无法进入 backup_created」的悬空状态。
        写入顺序固定；「变更已完成但 mutation_succeeded 未落盘」的窗口无法事后消除，
        因此恢复判定**不**自行定义规则，而是**完全引用 REQ-024 的四条判定规则**
        （本项与 REQ-024/REQ-029 必须语义一致，不得互相矛盾）。
        状态标记的作用是提供「本轮是否确实变更过」的因果证据，供 REQ-024 第 3/4 条使用。
      priority: critical
      addresses: "AC-025, AC-026, REQ-016, REQ-024, REQ-029"

    - id: REQ-027
      description: |
        rollback-journal.json 的模式必须明确规定并可机器校验，使 REQ-019 的「自证」不是空话。
        必需字段：journal_version、run_id(guid)、created_at(ISO 8601)、machine_fingerprint
        （**首选** `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`，记录
        `fingerprint_source: machine_guid`；仅在不可读时退化为
        `hostname + OS volume serial` 并记 `fingerprint_source: hostname_fallback`。
        **诚实说明**：克隆的虚拟机共享 MachineGuid，退化来源同样不唯一，因此
        `hostname_fallback` 下**不保证**能识别克隆机/同机副本。规格不承诺做不到的事：
        该情形下仅做「run_id 唯一 + 备份哈希一致 + 完成标记为空」的校验，
        识别克隆的能力明确记为**不保证**，并由备份目录路径一致性提供辅助约束）、
        backup_dir(绝对路径)、cleanup_log_path、cleanup_log_timestamp 与
        cleanup_log_sha256（清理日志的 SHA-256）。**三者必须同时为 null 或同时非 null**：
        T3 下清理日志缺失时三个字段全为 null 且都不参与校验，自证改由
        run_id + created_at + machine_fingerprint + backup_dir + 备份哈希承担；
        只把 sha256 置 null 而保留 path/timestamp，视为模式错误并拒绝、
        completed_at（可空 ISO 8601）、consumed_by_run_id（可空 guid）与
        consumed_with_failure（bool，默认 false）——用于 REQ-019 的「不重复消费」，
        其中 `consumed_with_failure=true` 表示「日志已被消费，但仍留有未修复条目」，
        由 REQ-019 Step 4a 与 REQ-030 的确认出口写入，
        以及 `machine_path_original` 与 `machine_path_scope`（本轮捕获的 Machine PATH 原值，
        使其在清理日志缺失的 T3 下仍可恢复 PATH，见 REQ-001/REQ-021）。
        每项条目含 item_id、kind、target、backup_file、backup_file_sha256、pre_existing(bool)、
        absent_confirmed_after_mutation(bool)、
        `parent_baseline`（该条目变更完成后**立即持久化**的父键最后写入时间，ISO 8601）。
        **kind 取值固定枚举**为六种：`registry_key`、`startup_value`、`path_entry`、
        `path_deleted`、`service`、`task`（其它取值自证失败）。
        其中 `path_deleted` 专指「文件/目录删除」动作（`backup_file` 为 null、
        判为 not_restorable，见 DD-006 与 REQ-002），与 `path_entry`
        （**PATH 环境变量条目的移除**，可经 REQ-021 恢复）是两回事——
        二者的 target 形态与恢复语义都不同，合并会丢失信息。
        **item_id 生成规则固定为** `"<kind>:<规范化后的 target>"`
        （规范化 = 去除首尾空白与引号、路径去掉尾随反斜杠、注册表路径统一大小写形式；
        该算法是**唯一权威定义**，REQ-030 的清单必须复用，不得另立），
        因此 item_id 在轮内唯一、可由 target 复现，且 REQ-030 未修复清单里的 item_id
        可直接回指到日志条目。
        **不依赖运行结束时的统一落盘**——T3 恰恰是运行未结束就崩溃的情形，
        运行结束才写等于在最需要它的场景下缺失。
        **写入载体**：`parent_baseline` 作为该条目 `mutation_succeeded` 那次日志落盘的
        **同一个原子写**的一部分写入，不另开一次落盘（因此 REQ-005 的原子性/持久性
        自动覆盖它）。这意味着 REQ-005 的 fail-closed 只影响**后续**变更：
        已成功落盘的条目的基线照常存活，只有「落盘失败那一条」的基线会缺失，
        而该缺失按下面的容错规则处理（AC-075a），不牵连其它条目。
        同父键有多个条目时，**恢复端**取该父键所有条目 `parent_baseline` 的**最大值**
        （等价于该父键最后一次变更后的时间），因此后发生的变更不会使先前条目的记录失效，
        也无需在写入时就聚合。
        它同时是 REQ-024 迹象 (ii) 的比较基线，避免本工具自身的变更被误判为外部变更。
        **可空性**：理想情况下注册表键/value 条目必填、path/service/task 条目为 null
        （无「父键」语义，迹象 (ii) 对该类条目不适用）；但为兼容 T3 崩溃容错，
        注册表条目的该字段**允许为 null**，此时按 REQ-024 对该条目跳过迹象 (ii)
        并在报告中标注证据不完整。两处约束与 `backup_file` 对称。
        **写入失败的容错**：T3 恰恰可能发生在某次写入未完成时，因此恢复端必须容忍
        个别条目缺该字段——缺失时对该条目**跳过**迹象 (ii)（退化为仅按三项目标与窗口判定），
        并在报告中标注该条目的证据不完整；**不**因个别条目缺字段而拒绝整份日志
        （否则一次写入失败就会让整轮恢复不可用，与 REQ-016 的目标相悖）、
        state（枚举同 REQ-018：planned|backup_created|mutation_succeeded|mutation_failed）。
        **可空规则**：对 path/service/task 等按 DD-006 不可恢复的条目，
        `backup_file`/`backup_file_sha256` 必须为 null（本就没有备份）；对注册表/value 条目
        必须是有效路径且哈希匹配。`planned` 状态下 `backup_file` 允许为 null。
        `machine_path_original` 可为 null；**若为 null 且日志中存在
        `state = mutation_succeeded` 的 path_entry_removed 条目，则自证失败**
        （无原值即不可恢复，必须交人工）。
        若所有 path_entry_removed 条目都是 `mutation_failed`（本轮并未真正删掉 PATH），
        则 null 合法，自证可通过。
        这是一个**防御性检查**：按 REQ-003(c)，存在待删 PATH 条目时捕获失败会在破坏前中止，
        因此「null + 成功 entry」理论上不可达；保留该检查是为了在实现有缺陷时**响亮失败**
        而不是静默地无法恢复。本轮无 PATH 变更时自证正常通过。
        **自证通过** 需同时满足：journal_version 被消费者支持 且 run_id 是合法 guid 且
        created_at 可解析 且 `machine_fingerprint` 存在 且
        `fingerprint_source` 存在且取值为 `machine_guid` 或 `hostname_fallback`
        （其它值一律拒绝）且 machine_fingerprint 与本机一致 且 backup_dir 存在 且
        每个**非 null** 的 backup_file 存在且其 SHA-256 与记录一致 且
        （**仅当 cleanup_log_sha256 非 null 时**才校验清理日志：
        哈希一致 且 `cleanup_log_path` 存在 且其最后写入时间与 `cleanup_log_timestamp`
        一致（容差 2 秒，吸收文件系统时间戳精度差异）。
        **若 cleanup_log_sha256 非 null 但 `cleanup_log_path` 已不存在**（崩溃后日志被删除或
        移动），**不**据此拒绝整份日志：按 REQ-019 Step 2.5 的抑制规则处理——
        能读到清理日志且 `summary.failed == 0` 则按已消费处理；
        确实读不到清理日志时才继续走自证（此时该字段的证据缺失必须记录）。
        **T3 下清理日志缺失、cleanup_log_sha256 为 null 时，上述三项校验全部跳过**，
        自证改由 run_id + created_at + machine_fingerprint + backup_dir + 备份哈希承担，
        否则 AC-021 要求的「仅凭日志恢复」将与自证条件互相矛盾）且
        `completed_at` 为 null（已消费的日志不得再被消费）。
        **「复制」的判定**：同机完整复制一份日志+备份+清理日志后，其字段全部自洽，
        因此**无法**仅凭内容与原件区分。故规则为：`run_id` 必须唯一——
        发现同一 run_id 出现于多个 backup 目录时，**全部拒绝**并要求人工介入；
        只有唯一且未被消费的 run_id 才被采纳（AC-044 断言此行为，不承诺能拒绝内容完全
        自洽的同机副本）。
        完整性校验用于拒绝对被篡改/替换/复制到别机的日志执行恢复；任一条不满足即拒绝且不修改系统。
      priority: critical
      addresses: "AC-027, AC-037, REQ-019"

    - id: REQ-028
      description: T3 恢复与新一轮清理的**顺序**必须固定：启动时先 (1) 检测并消费未完成的自证日志、(2) 完成恢复并记录结果、(3) **然后**才执行 REQ-003 前置检查并为本轮创建新备份。顺序颠倒会让新备份捕获一个尚未修复的受损状态
      priority: high
      addresses: "AC-033, AC-038, REQ-016"

    - id: REQ-033
      description: |
        `cleanup-log.json` 必须写入本轮标识 `run_id`（guid，与该轮回滚日志的 `run_id`
        **相同**），使 REQ-019 Step 2.5 能把清理日志与回滚日志绑定，
        而不是仅凭「存在且成功」就采信——否则一份被篡改的回滚日志只要指向
        **另一轮**的成功清理日志，就能把强制 T3 恢复整轮跳过。
        该字段对**新写入的**清理日志必填；对历史遗留的、缺该字段的清理日志，
        读取端按 REQ-019 Step 2.5 的「证据不足」处理（不抑制、交自证），
        并在报告中说明本次判定缺少绑定证据。
      priority: high
      addresses: "AC-088, REQ-019, REQ-027"

    - id: REQ-032
      description: |
        `backup-*` 目录的命名规则必须固定并写明，使 REQ-019/REQ-030 能可靠定位日志：
        目录名为 `backup-<run_id>`，其中 `run_id` 为 guid（去掉连字符亦可）。
        这样每份日志所在的目录名**就是**其 `run_id`，
        使「对不可解析日志写旁路文件」有确定的落点，无需退化为 `unknown`。
        该规则同时让 REQ-019 的「重复 run_id 出现在多个目录」这一检测变得可直接实现
        （目录名重复即重复）。若历史遗留目录不符合该规则，
        读取端必须容忍：`run_id` 退化为 `unknown` 并按目录路径本身去重。
      priority: high
      addresses: "AC-080, REQ-019, REQ-030"

    - id: REQ-031
      description: |
        **每一轮正常结束的清理都必须在退出前原子地把回滚日志标记为完成**
        （写 `completed_at` 与 `run_id`），无论本轮是全部成功、部分失败后回滚成功、
        还是被 `-NoAutoRollback` 跳过回滚。
        **唯一例外是退出码 11（部分失败且回滚部分/完全失败）**：此时系统仍处于
        未修复状态，日志**必须保持未完成**，同时把未修复清单落盘到
        `<project_root>/output/rollback-unrepaired-<run_id>.json`，
        以便下一次启动按 T3 再次尝试恢复并向用户报告。
        若此时写入 `completed_at`，就会把「仍受损」的状态标记成「已结束」，
        下次启动便不再尝试修复——这与 REQ-030 的目的直接冲突。
        否则「成功的一轮」会留下 `completed_at == null` 的日志，
        下一次启动就会把**已经正确清理过**的一轮当作未完成的 T3 来恢复，
        按 REQ-024 规则 3 把注册表/value/PATH 条目**重新装回去**——
        这是比不恢复更严重的错误（用户会看到刚清理掉的残留又回来了）。
        该写入必须发生在所有破坏性操作与回滚都结束之后、进程退出之前，
        且失败时按 REQ-005 的 fail-closed 处理（返回 15）。
        **标记未写入就崩溃的兜底（必需）**：若日志 `completed_at` 为 null，
        但**清理日志存在且 `summary.failed == 0`**，说明本轮清理**已经成功完成**、
        只是标记没来得及写。此时**必须抑制自动恢复**，把该日志报告为
        「已完成（标记缺失）」并按已消费处理，**绝不**按 REQ-024 规则 3
        把刚清理掉的条目装回去。这是最容易被忽略的窗口。
        **反过来必须说清**：若 `completed_at` 为 null 且 `summary.failed > 0`
        （例如退出码 11 的路径），则该日志**仍按未完成处理**，
        下一次启动照常按 T3 尝试恢复。两条规则的区分点只有一个：`summary.failed` 是否为 0。
        `completed_at` 的语义因此明确为**「本轮清理运行已正常结束（含跳过回滚的情形）」**，
        **不**意味着「回滚已执行」。
      priority: critical
      addresses: "AC-070, REQ-019, REQ-020"

    - id: REQ-019
      description: |
        回滚只承认 run_id 与 cleanup-log 时间戳/哈希**匹配**的日志；不匹配、陈旧、被复制或
        属于上一轮且已消费的日志一律拒绝且不修改系统状态。
        **发现与选择规则必须明确**（T3 依赖它）：
        - 发现位置：扫描项目根下 `backup-*` 目录中的 `rollback-journal.json`；
        - 未完成判定：`completed_at` 为 null（**不去**要求「至少一条非 skipped 条目」——
          零可处理条目由 REQ-030 归类为完全成功）；
        - **固定顺序（Step 1..5，实现必须严格按此顺序）**：
          **Step 1** 扫描 `backup-*` 目录，收集全部 `rollback-journal.json` 及其旁路标记，
          并**先剔除已完成的候选**（`completed_at` 非空；或存在**可解析且格式合法**的
          `rollback-consumed.json`；或存在**可解析且格式合法**的
          `rollback-acknowledged.json`）。
          **旁路文件必须解析后判定**：不存在的、或存在但**不可解析/格式非法**的旁路文件
          一律**视为不存在**（与 AC-064 一致），不得因一个损坏的旁路文件而
          跳过本该执行的 T3 恢复——那会把「强制恢复」变成「一个坏文件就能绕过」。
          **解析失败的旁路文件只影响「是否剔除候选」，不得在 Step 1 被改写或删除**：
          它是取证材料，保持原样，仅记一条告警；改写只发生在确实要写标记的那一刻
          （见 AC-064 的写入侧语义）。
          **另一道闸门**：若存在**可解析且格式合法**的 `rollback-consumed.failed.json`，
          说明该候选此前「尝试消费但两个标记都写失败了」。此时候选**不得**自动消费，
          必须由 `-AcknowledgeConflicts` 显式确认后才继续（与 AC-089 一致）。
          没有这道闸门，下次运行会直接重新消费它，AC-053/AC-089 的断言就不成立。
          这一步是必需的：否则上一轮**正常成功**留下的日志会被当成候选，
          在 Step 3 因 `completed_at` 非空而自证失败，使 Step 4b 让**此后每一次清理都返回 14**，
          整个工具再也无法运行；
          **Step 2** 解析剩余候选；
          **Step 2.5（必需，先于 Step 3）抑制误恢复**：对每个候选应用 REQ-031 的兜底规则。
          **必须先确认该清理日志属于这份日志本身，不得采信任意一份「存在且成功」的清理日志**
          ——否则一份被篡改的日志只要指向**另一轮**的成功清理日志，就能把强制 T3 恢复整轮跳过。
          绑定条件按**证据可用性分级**，不要求证据齐全——否则清理日志一旦被删，
          抑制永不触发，REQ-031 的兜底就形同虚设：
          **先执行模式检查**：若 `cleanup_log_path`/`cleanup_log_timestamp`/
          `cleanup_log_sha256` 不是「同 null 或同非 null」（违反 AC-083），
          则该候选**直接交给 Step 3 拒绝**，绝不进入任何抑制分支——
          否则一份模式非法的日志可能在被 Step 3 拒绝之前就先被「抑制」放行；
          ① 文件**存在且可读**：校验哈希（`cleanup_log_sha256` 非 null 时必须匹配，
          不匹配即拒绝该候选、不进抑制分支）与 `run_id` 一致（见 REQ-033），
          两者都通过才可抑制；
          ② 文件**已不存在**但 `cleanup_log_sha256` **为 null**：无任何可校验证据，
          **不进**抑制分支（保守），交 Step 3 自证；
          ③ 文件**已不存在**但 `cleanup_log_sha256` **非 null**：本轮确实写过清理日志，
          但不**拒绝**该候选，也**不**据其抑制（读不到 `summary.failed`，无法判断成败），
          交 Step 3 自证；自证通过则按正常 T3 恢复。
          绑定成立后：若 `completed_at` 为 null 且清理日志中 `summary.failed == 0`，
          **本步骤只读取清理日志的 `summary.failed`，不读取也不依赖回滚日志的
          `parent_baseline`**（parent_baseline 的 MAX 聚合属于 Step 5 恢复阶段的迹象 (ii)
          判定，见 REQ-024 与 AC-074 的两阶段设计；在此之前日志尚未自证，
          其字段不得作为决策输入），
          则该轮清理已经成功完成、只是标记缺失，必须**按已消费处理**
          （写标记并报告「已完成（标记缺失）」），**不得**进入 Step 3/Step 4/Step 5；
          **反向分支必须明确**：若 `summary.failed > 0`，**不**施加抑制，
          继续走 Step 3/Step 4/Step 5 的正常恢复流程。
          判定只看 `summary.failed` 是否为 0 这一个条件。
          放在 Step 3 之前是必要的：否则一份指向已消失清理日志的候选会先在 Step 3 自证失败，
          工具返回 14 而**永远走不到**抑制分支，与 REQ-031 的意图相反；
          **Step 3** 对**全部**候选逐个执行 REQ-027 自证；
          **Step 4a** 若全部通过 → 按 `created_at` 选**最新**者执行恢复（Step 5）；
          对**其余每一份**日志先写各自的未修复清单（`reason` 统一为
          `skipped_older_journal`——这些日志**未被执行恢复**，清单记录的是
          「因非最新而未被恢复」，不是 conflict/not_restorable），
          **成功后才**标记 `consumed_with_failure=true`（与 REQ-030 的顺序要求一致，
          禁止出现「标记已消费但清单缺失」）；此情形返回 14；
          **Step 4b** 若**任一**未通过（含重复 run_id）→ **一份都不标记、一份都不消费**，
          保持原状、返回 14 并要求人工介入；
          **Step 5** 执行恢复。
          标记（Step 4a 的「其余」与 `rollback-consumed.json`）**只在 Step 3 全部通过后**才发生，
          因此一份被篡改的较新日志不会连带毁掉一份有效的较旧日志；
        - 全部候选通过自证后：取 `created_at` **最新**的一个执行恢复，并把其余标记为
          `completed_at` + `consumed_with_failure=true`（避免后续运行回退到更旧的日志，
          越过「只回滚紧邻上一轮」的非目标）；此情形返回码 14 并告警；
        - 恢复成功完成后必须在日志中写入 `completed_at` 与 `consumed_by_run_id`；
          **已标记 completed_at 的日志不得再次消费**（防止重复回放陈旧日志）；
        - 该完成标记必须**原子且可持久化**（先写临时文件再原子替换）；
          若标记写入失败，则**不得**宣告恢复完成，必须按 REQ-030 中止本轮并返回 14；
        - `rollback-consumed.json` 必须采用与日志**相同的 REQ-005 原子写协议**
          （临时文件 + `[System.IO.File]::Replace()`）。这不是形式要求：若写入中途崩溃留下
          畸形文件，Step 1 会因不可解析而视为不存在，于是该日志被**再次消费**——
          而这正是该机制要防止的事。原子写保证畸形文件根本不会出现；
        - **标记写入失败的兜底**：仅靠 `completed_at=null` 无法区分「未消费」与「消费过但
          标记没写上」。因此另写一个同目录的旁路标记文件 `rollback-consumed.json`，
          模式固定为 `{"run_id":"<guid>","consumed_at":"<ISO 8601>"}`，
          采用与日志相同的原子写协议（`[System.IO.File]::Replace()`）；
          发现规则同时读取它，两者任一表明已消费即**不得**再次消费。
          该文件**不可解析时视为不存在**并重新尝试写入（它是幂等的辅助标记，不是权威数据）。
          若两个标记都无法写入，则**先尝试写更小的持久失败标记
          `rollback-consumed.failed.json`**（原子写，
          内容 `{"run_id":"<guid>","failed_at":"<ISO 8601>"}`），
          然后返回 14。Step 1 把该标记的存在视为「曾尝试消费但未能确认」，
          该候选**不得**自动重复消费，必须由 `-AcknowledgeConflicts` 显式确认后才继续。
          绝不能只靠「下次还会看到它」来兜底——因为 Step 3 自证会通过，
          于是它会被**再次消费**，AC-053 的断言也就无法成立。
        - 同一 `created_at` 冲突时全部拒绝、返回 14 并要求人工介入（不做任意选择）；
          人工按 REQ-030 的确认出口处理后继续。
        清理日志缺失（T3）时，日志须能自证（见 REQ-027 的自证谓词）才被采信。
      priority: critical
      addresses: "AC-027, DD-004, R-4, REQ-030"

    - id: REQ-020
      description: 必须明确「谁来调用自动回滚」：clean-residuals.ps1 在自身进程内完成回滚（无需外部进程），并在回滚结束后给出明确的最终退出码与日志顺序；-NoAutoRollback 时该调用不发生
      priority: high
      addresses: "AC-028, REQ-011, REQ-008"

    - id: REQ-021
      description: PATH 回滚算法必须明确：以「整作用域」为单位从捕获的原值恢复（而非逐条 re-append，后者会产生重复项并打乱顺序）。若回滚前检测到 PATH 已被外部并发修改（当前值 ≠ 清理后预期值），必须报告 restore_failed/需人工介入，而不是盲目覆盖
      priority: high
      addresses: "AC-005, AC-029, REQ-001"
      note: |
        「清理后预期值」的推导有两条等价来源，按可用性择一：
          - 有清理日志时：捕获原值逐字移除**日志中 success=true 的 path_entry_removed 条目**
            （不是「移除所有候选条目」——失败项并未真正移除）；
          - 仅有回滚日志（T3）时：捕获原值（`machine_path_original`）逐字移除
            **state = mutation_succeeded 的 path_entry_removed 条目**。
        **判定顺序固定为：先看窗口，再看漂移**——窗口内（严格小于 24h，与 REQ-024 同口径）
        且无漂移才自动恢复；超窗或检出漂移一律降级 conflict/人工，**不改写** PATH。
        该顺序要求写在此处（正文）而非仅靠注记，以免实现只做漂移检测而漏掉窗口约束。
        两种来源都不可用、或推导结果与当前值不一致时，一律降级为 conflict/人工介入，
        **绝不**盲目覆盖当前 PATH。**PATH 自动恢复与 REQ-024 适用同一个 24h 窗口**
        （从 `created_at` 量到恢复尝试时刻，严格小于 24 小时）：窗口内且无漂移才自动恢复；
        超窗或检出漂移一律转人工，不再自动改写。漂移**检测**本身不受窗口限制
        （任何时刻发现的漂移都如实报告），受窗口约束的是**是否自动改写**。

    - id: REQ-022
      description: create-restore-point.ps1 必须写出 restore-status.json 并定义其模式（至少含 restore_point_enabled、backup_dir、timestamp、backup_files[]，每项含 valid）。该文件是**可选系统还原点层的状态与 UI 诊断来源**，**不是**强制精准保护的校验依据（见 REQ-003/REQ-025）；其写入方、时机与首次运行（无上次清理记录）语义必须明确规定
      priority: high
      addresses: "AC-017, AC-018, REQ-003"

    - id: REQ-023
      description: 全部新增/修改代码与测试必须在 PowerShell 5.1（运行时基线）与 pwsh 7（pre-commit Gate 5 使用的引擎）下同时通过；涉及 JSON 序列化的断言必须同时断言可解析性与原始文本形态（见 AGENTS.md「测试与门禁的双引擎要求」）
      priority: high
      addresses: "AC-020, NFR-1, NFR-2"

  acceptance_criteria:
    - id: AC-001
      requirement: REQ-006
      criteria: 每个 registry_deleted 条目在日志中都有对应的 .reg 导出文件，且该文件在删除前已存在
      test_type: integration
    - id: AC-002
      requirement: REQ-007
      criteria: 删除启动项 value 时只备份该 value；共享的 Run/RunOnce 键本身从未被删除或整键重导
      test_type: unit
    - id: AC-003
      requirement: REQ-005
      criteria: 第一次破坏性操作之前日志文件已存在且含 planned 条目；每项处理后日志已落盘（状态名与 REQ-018/REQ-027 一致）
      test_type: integration
    - id: AC-004
      requirement: REQ-008
      criteria: 回滚后重新查询每个已恢复的注册表键，确认其存在且值数据一致
      test_type: integration
    - id: AC-005
      requirement: REQ-008
      criteria: 无外部并发修改时，回滚后 Machine PATH 字符串等于清理前的逐字原值（存在外部漂移的情形由 AC-029 断言）
      test_type: integration
    - id: AC-006
      requirement: REQ-009
      criteria: 每个条目都输出四种判定之一；not_restorable 与 restore_failed 必带原因
      test_type: unit
    - id: AC-007
      requirement: REQ-010
      criteria: 断言自动路径从不调用 Restore-Computer（以 stub 记录调用）
      test_type: unit
    - id: AC-008
      requirement: REQ-011
      criteria: 前置门禁失败（退出 1/2）时不触发**本轮**回滚；上一轮的自证未完成日志仍按 REQ-028 先行消费（两者顺序由 AC-038 断言）
      test_type: unit
    - id: AC-009
      requirement: REQ-011
      criteria: 日志含 cleanup_failed（summary.failed > 0）时触发回滚；触发判定只读日志，不依赖退出码（与 REQ-015 的退出码变更正交：无论退出码是 0 还是非零都触发）
      test_type: integration
    - id: AC-010
      requirement: REQ-011
      criteria: -DryRun 不写日志文件、不做任何回滚、不修改系统
      test_type: unit
    - id: AC-011
      requirement: REQ-013
      criteria: 注入一个失败的恢复步骤后，其余条目仍被处理，且输出报告部分成功
      test_type: integration
    - id: AC-012
      requirement: REQ-012
      criteria: -NoAutoRollback 下不触发**本轮**自动回滚；但 (a) REQ-001..004/REQ-015 的安全性与诚实性修复仍生效，(b) 上轮遗留日志的 T3 消费与恢复仍然执行（REQ-030）
      test_type: unit
    - id: AC-013
      requirement: REQ-014
      criteria: restore_point_enabled=false 时输出显著告警且明确说明文件删除不可恢复；UI 文案不出现“已通过系统还原点备份”
      test_type: unit
    - id: AC-014
      requirement: REQ-013
      criteria: 同一次恢复过程中的**进程内重试**（未写完成标记前）报告 already_present 且不产生新变更；跨进程的第二次调用因日志已标记完成而**不消费**该日志，返回「已完成」且不产生任何系统变更
      test_type: integration
    - id: AC-015
      requirement: REQ-001
      criteria: PATH 原值在第一次 PATH 删除前已被逐字记录；同一轮内两个 path_entry 不互相干扰
      test_type: integration
    - id: AC-016
      requirement: REQ-002
      criteria: Tier-4 重命名产生 renamed:<newname> 记录而非 path_deleted success=true，且新名字被报告出来供人工定位（与 DD-006 一致：重命名内容**不**参与自动恢复）
      test_type: unit
    - id: AC-017
      requirement: REQ-003
      criteria: 回滚日志不可创建/不可写时中止清理；而 restore-status.json 缺失或系统还原点不可用时**不**中止，仅告警后继续（两层的区分被直接断言）
      test_type: integration
    - id: AC-018
      requirement: REQ-004
      criteria: Checkpoint-Computer 抛异常时 create-restore-point.ps1 返回可区分的非零码且 restore-status.json 如实写明 restore_point_enabled=false；成功建立时返回 0
      test_type: unit
    - id: AC-019
      requirement: REQ-015
      criteria: 日志含 cleanup_failed 时 clean-residuals.ps1 返回非零；全部成功时返回 0
      test_type: unit
    - id: AC-020
      requirement: REQ-023
      criteria: 全部测试在 PowerShell 5.1 与 pwsh 7 下均通过（AGENTS.md 双引擎规则）；任何 JSON 往返断言必须同时断言可解析性与原始文本形态
      test_type: unit
    - id: AC-021
      requirement: REQ-016
      criteria: 清理日志缺失/截断但回滚日志存在时，以回滚日志执行恢复（含从 `machine_path_original` 恢复 Machine PATH）；两者都缺失时报告「无可回滚记录」且不修改任何系统状态
      test_type: integration
    - id: AC-022
      requirement: REQ-017
      criteria: 回滚日志写入失败时，清理在第一次破坏性操作之前以非零码中止（fail-closed），且未删除任何内容
      test_type: unit
    - id: AC-023
      requirement: REQ-014
      criteria: CleanupPanel 在备份状态为不可用时不得渲染「已通过系统还原点备份」文案（UI 层断言）
      test_type: unit
    - id: AC-024
      requirement: REQ-006
      criteria: 注入「导出失败」后，该条目被记为 cleanup_failed(export_failed)，且对应的 reg delete / value 删除**未发生**（断言目标键/value 仍然存在）
      test_type: integration
    - id: AC-025
      requirement: REQ-018
      criteria: 崩溃发生在「已写 planned 日志但尚未变更」时，回滚不对该条目做任何恢复，且该条目判定为 already_present（不引入 REQ-009 之外的第五种判定）
      test_type: integration
    - id: AC-026
      requirement: REQ-018
      criteria: 按 REQ-024 断言三种情形：(a) 状态 backup_created 且目标存在且一致 → 不恢复、报 already_present；(b) 状态 backup_created 但目标已缺失 → **不恢复**（落入 REQ-024 规则 4：报 conflict、需人工介入）；(c) 状态 mutation_succeeded + pre_existing=true + absent_confirmed_after_mutation=true 且目标缺失（且在 24h 窗口内）→ 恢复
      test_type: integration
    - id: AC-027
      requirement: REQ-019
      criteria: 上一轮的日志、run_id 不匹配的日志、清理日志缺失时无法自证的日志，三种情况均被拒绝且不修改任何系统状态
      test_type: integration
    - id: AC-028
      requirement: REQ-020
      criteria: summary.failed > 0 且启用自动回滚时，回滚在同一进程内完成（不依赖外部进程）；日志顺序为 cleanup-log 先写、rollback-result 后写；-NoAutoRollback 时不发生该调用。具体退出码由 REQ-026/AC-036 断言
      test_type: integration
    - id: AC-029
      requirement: REQ-021
      criteria: 多个 path_entry 被移除后回滚，PATH 精确等于原值且无重复项、顺序不变；若当前 PATH 已被外部修改则报告 restore_failed 而非盲目覆盖
      test_type: integration
    - id: AC-030
      requirement: REQ-022
      criteria: restore-status.json 含 restore_point_enabled / backup_dir / timestamp / backup_files[]（每项含 valid）。首次运行（无上次 cleanup-log）不做「新于上次清理」比较；后续运行要求时间戳严格递增
      test_type: unit
    - id: AC-031
      requirement: REQ-007
      criteria: 回滚后重新查询启动项 value，断言其存在且数据正确，同时断言共享 Run/RunOnce 键中的其它 value 未被改动
      test_type: integration
    - id: AC-032
      requirement: REQ-002
      criteria: Tier-4 重命名的路径在回滚中被归类为 not_restorable 并给出可操作的人工恢复线索（新名字），且该归类与 DD-006 一致
      test_type: unit
    - id: AC-033
      requirement: REQ-016
      criteria: 下一次 clean-residuals 运行开始时，若发现自证有效的未完成回滚日志，必须先消费它完成恢复再开始新清理；用户可见文案不得声称崩溃能即时自动回滚
      test_type: integration
    - id: AC-034
      requirement: REQ-024
      criteria: 按 REQ-024 四条规则逐项断言：(1) 目标一致→already_present；(2) 目标不同→restore_failed(conflict) 且**未覆盖**；(3) 目标缺失 + mutation_succeeded + pre_existing + absent_confirmed_after_mutation 四项齐备且在窗口内→恢复；(4) 目标缺失但缺少任一证据或超出 24h 窗口→**不恢复**，报 conflict/需人工
      test_type: integration
    - id: AC-035
      requirement: REQ-025
      criteria: create-restore-point 因还原点不可用返回非零时，clean-residuals 在强制精准保护有效的前提下**继续**清理（仅告警）；强制保护无效时才中止
      test_type: integration
    - id: AC-036
      requirement: REQ-026
      criteria: 退出码矩阵逐项断言：清理成功=0、部分失败+回滚全成功=10、部分失败+回滚部分失败=11、无可回滚记录=12、-NoAutoRollback 且部分失败=13、运行中落盘失败=15；每个码唯一且固定；15 的优先级高于 10/11/12/13。退出码 14 的四个分支各有一条用例：(a) 恢复存在 restore_failed；(b) 自证失败或重复 run_id（Step 4b）；(c) created_at 平局或多个未完成日志；(d) 两个消费标记都写失败
      test_type: unit
    - id: AC-037
      requirement: REQ-027
      criteria: 日志缺 journal_version/合法 run_id/可解析 created_at/存在的 backup_dir/任一被引用的 backup_file/合法的 fingerprint_source 时，自证不通过并被拒绝，且不修改系统
      test_type: integration
    - id: AC-038
      requirement: REQ-028
      criteria: 断言启动顺序为「消费未完成日志并恢复 → 再做前置检查 → 再创建新备份」；顺序颠倒的实现在测试中失败
      test_type: integration
    - id: AC-039
      requirement: REQ-029
      criteria: 清理前该键已不存在（或缺失非本轮所致）时，回滚报告 conflict/需人工介入，**不**自动恢复；能证明系本轮删除时才自动恢复
      test_type: integration
    - id: AC-040
      requirement: REQ-007
      criteria: .reg 裁剪函数抛异常或产出不可解析的 .reg 时，视为导出失败：**断言该 value 未被删除**（注册表中仍存在）且记为 export_failed(trim_error)
      test_type: unit
    - id: AC-041
      requirement: REQ-003
      criteria: 备份目录不可写、reg export 不可用两种情形导致第一次破坏性操作之前 fail-closed 中止且无任何修改；Machine PATH 原值无法捕获时，**存在待删 PATH 条目**则同样中止，**不存在**待删条目则不中止（不产生假失败）
      test_type: integration
    - id: AC-042
      requirement: REQ-030
      criteria: 上轮日志恢复存在 restore_failed 时，本轮清理中止并返回明确非零码，且**未执行前置检查、未创建新备份、未执行任何破坏性操作**；仅含 not_restorable 的恢复不算失败，告警后继续
      test_type: integration
    - id: AC-043
      requirement: REQ-007
      criteria: reg export 的 IO 失败、reg.exe 不可用、源键读取被拒三种情形均导致删除被跳过并记为 export_failed
      test_type: unit
    - id: AC-044
      requirement: REQ-027
      criteria: 可机械验证的**自证失败**拒绝情形：同一 run_id 出现在多个 backup 目录、backup_file 的 SHA-256 不符、machine_fingerprint 不匹配、cleanup_log_sha256 不符——四者均被拒绝且不修改系统。（`completed_at` 非空的日志由 REQ-019 Step 1 **静默剔除**，不属于自证失败，见 AC-072。不承诺拒绝内容完全自洽的同机字节级副本，见 DD-017）
      test_type: integration
    - id: AC-045
      requirement: REQ-009
      criteria: 端到端断言 path/service/task 三类删除各自输出 not_restorable 判定并附**针对该类型**的原因与人工恢复指引（而非通用文案）
      test_type: integration
    - id: AC-046
      requirement: REQ-019
      criteria: 多个 backup-* 目录下同时存在日志时：选取 created_at 最新的未完成日志、将其余标记 consumed_with_failure=true 并返回 14；created_at 相同的多个日志全部拒绝并返回 14；已写 completed_at 的日志不被再次消费
      test_type: integration
    - id: AC-047
      requirement: REQ-019
      criteria: 恢复成功完成后日志被写入 completed_at 与 consumed_by_run_id；紧接着第二次运行不会重复消费该日志
      test_type: integration
    - id: AC-048
      requirement: REQ-030
      criteria: 候选日志只有一份时，上轮条目全部为 not_restorable 判为完全成功：告警后继续（返回码不是 14）。优先级：若同时存在多个未完成候选（AC-046 的情形），则先按 REQ-019 Step 4a 返回 14，not_restorable 不覆盖该结果
      test_type: unit
    - id: AC-049
      requirement: REQ-005
      criteria: 注入「变更后日志落盘失败」后，后续破坏性操作立即停止，并对最后一次成功落盘的状态执行回滚，返回码区别于普通部分失败
      test_type: integration
    - id: AC-050
      requirement: REQ-024
      criteria: (a) 三项目标齐备但恢复时刻距 created_at 已 ≥24h（含恰好 24h 与 24h+1s）→ 不恢复，报 conflict；(b) absent_confirmed_after_mutation 缺失/false → 不恢复，报 conflict；(c) 23h59m 时仍恢复。不断言「三者均不会复活用户后续删除的内容」——REQ-024/DD-018 明确承认：窗口内且迹象 (i)-(iii) 均不命中的「创建+删除」循环无法被识别，该残留风险是已知且接受的；测试只断言上述三个可判定分支
      test_type: integration
    - id: AC-051
      requirement: REQ-027
      criteria: path/service/task 条目（backup_file 为 null）与注册表条目（backup_file 非 null）混在同一日志时，自证按可空规则通过；注册表条目哈希不符则整体拒绝
      test_type: unit
    - id: AC-052
      requirement: REQ-005
      criteria: 落盘失败后，未记录的变更被明确标记为 restore_failed(unjournaled)/未记录（而非静默留下或按规则 4 静默跳过），已 durable 的部分被回滚，退出码为 15 且不再判定 10/11/12/13
      test_type: integration
    - id: AC-053
      requirement: REQ-019
      criteria: 完成标记写入失败时不得宣告恢复完成、本轮中止并返回 14；若旁路标记 rollback-consumed.json 写入成功，则下次运行不重复消费该日志。两个标记都写失败时先写 rollback-consumed.failed.json（小型持久失败标记），下次运行**不**自动重复消费、必须 -AcknowledgeConflicts 确认后才继续
      test_type: integration
    - id: AC-054
      requirement: REQ-030
      criteria: 候选日志未通过自证、或存在重复 run_id 时，返回 14 并在前置检查前中止；候选日志无可处理条目时视为完全成功、告警后继续（不返回 14）
      test_type: integration
    - id: AC-055
      requirement: REQ-030
      criteria: 存在 restore_failed(conflict) 时，经人工确认出口处理后日志被标记 consumed_with_failure，后续运行不再返回 14 而是继续清理，且报告始终保留未修复条目清单（证明一次冲突不会永久锁死清理）
      test_type: integration
    - id: AC-056
      requirement: REQ-024
      criteria: (a) 迹象 (i)/(ii)/(iii) 各自命中时降级为 conflict 且不自动恢复（逐项断言）；(b) 三项目标齐备、窗口内但命中 (ii)/(iii) 时同样不恢复；(c) 本工具自身的删除**不会**因更新父键 LastWriteTime 而被误判为外部变更——含**同一父键下多个条目**的场景（断言基线按父键聚合，较早条目不被后续条目的删除误判为外部变更）。该多条目聚合是**尽力而为**的：仅在至少一个条目于崩溃前写入了基线时成立，不要求在 T3 下也成立；(d) 日志级条件 (iv)/(v) 不走逐条 conflict，而是整份日志自证失败并返回 14
      test_type: integration
    - id: AC-057
      requirement: REQ-019
      criteria: 完成标记写入失败但旁路标记 rollback-consumed.json 写入成功时，该日志不被再次消费；两个标记都写失败时拒绝该日志并返回 14
      test_type: integration
    - id: AC-058
      requirement: REQ-005
      criteria: 模拟写入中途崩溃后主日志畸形时，回退读取 rollback-journal.prev.json 继续（回退深度 1 代）；两代都不可解析时如实报告「无日志」而非静默继续
      test_type: integration
    - id: AC-061
      requirement: REQ-030
      criteria: -DryRun 发现未完成日志时零副作用：不消费、不恢复、不改标记，仅报告；且 -DryRun 下不返回 14
      test_type: integration
    - id: AC-062
      requirement: REQ-030
      criteria: 非管理员且存在未完成日志时返回 2（权限）而非 14，证明权限检查先于 T3 恢复
      test_type: integration
    - id: AC-063
      requirement: REQ-030
      criteria: created_at **平局**时 -AcknowledgeConflicts 把全部候选日志标记 consumed_with_failure 并输出清单后继续；不确认时保持 14 中止。**区分**：多个不同 created_at 的日志由 REQ-019 自动收敛（选最新、其余标记后返回 14，下一次运行不再返回 14），**不需要**人工确认
      test_type: integration
    - id: AC-064
      requirement: REQ-019
      criteria: 本条只约束**写入侧**：格式为标准 JSON、含 run_id 与 ISO 8601 的 consumed_at，且原子写入（File.Replace）。**读取侧**的解析失败语义归 AC-082：Step 1 视为不存在（不剔除候选）且**不改写**该文件。写入侧遇到已存在但不可解析的 rollback-consumed.json 时，允许原子覆盖它（此时是在写新的消费记录，不是 Step 1 的读取路径）
      test_type: unit
    - id: AC-065
      requirement: REQ-017
      criteria: UI 与文档不再出现无条件的「已通过系统还原点备份」表述；还原点不可用时展示如实状态（可用/不可用 + 原因）且清理继续；强制精准保护不可用时则展示中止并给出原因；且文档/UI 明确说明「崩溃后需在 24h 内下次启动才会自动恢复，超时转人工」
      test_type: unit
    - id: AC-059
      requirement: REQ-021
      criteria: 仅有回滚日志（无清理日志）时，PATH 预期值由 machine_path_original 减去 state=mutation_succeeded 的 path_entry_removed 条目推出；machine_path_original 为 null 且存在**成功的** path_entry_removed 时自证失败并返回 14（无原值不可恢复）；machine_path_original 为 null 且**无成功的** path_entry_removed 时自证通过且跳过 PATH 恢复（本轮未改 PATH）。**两套信号等价性**：清理日志中 `action=path_entry_removed` 且 `success=true` 的条目，与回滚日志中同 `target` 且 `state=mutation_succeeded` 的条目**必须一一对应**；若两者不一致，以**回滚日志**为准并在报告中标注不一致
      test_type: integration
    - id: AC-066
      requirement: REQ-018
      criteria: path/service/task 条目（backup_file 为 null）走 planned → mutation_succeeded，跳过 backup_created；恢复时一律判为 not_restorable 且不参与 REQ-024 的恢复判定
      test_type: unit
    - id: AC-067
      requirement: REQ-019
      criteria: 候选为「一份未通过自证的较新日志 + 一份有效的较旧日志」时，**不标记、不消费任何一份**，保持原状并返回 14；较旧日志未被破坏
      test_type: integration
    - id: AC-068
      requirement: REQ-027
      criteria: (a) cleanup_log_sha256 为 null（T3）时跳过三项清理日志校验并仍可通过自证；(b) cleanup_log_sha256 非 null 且文件存在时，最后写入时间与 cleanup_log_timestamp 相差超过 2 秒则自证失败；(c) cleanup_log_sha256 非 null 但文件已不存在时**不**据此拒绝（采纳 REQ-027 的容忍规则），继续自证并在报告中标注证据缺失
      test_type: unit
    - id: AC-069
      requirement: REQ-021
      criteria: PATH 自动恢复遵守 24h 窗口：23h59m 且无漂移时自动恢复；≥24h 或检出漂移时一律转人工且不改写 PATH
      test_type: integration
    - id: AC-070
      requirement: REQ-031
      criteria: 一轮完全成功的清理退出后，回滚日志已被原子标记 completed_at；紧接着的下一次运行**不**把它当作 T3 消费、**不**重新装回任何已删除的条目；部分失败后回滚成功、以及 -NoAutoRollback 两种结束路径同样写入 completed_at
      test_type: integration
    - id: AC-076
      requirement: REQ-031
      criteria: 模拟「清理已成功（清理日志 summary.failed=0）但在写 completed_at 之前崩溃」：下一次运行在 REQ-019 **Step 2.5** 抑制自动恢复，把该日志按已消费处理并报告「已完成（标记缺失）」，**不**装回任何已删除条目；对照用例：summary.failed>0 且标记缺失时**仍按 T3 尝试恢复**（AC-077）
      test_type: integration
    - id: AC-077
      requirement: REQ-031
      criteria: 退出码 11（部分失败且回滚未完全成功）时日志**保持未完成**且未修复清单已落盘到 output/；下一次运行仍按 T3 尝试恢复并报告，而不是视为已结束
      test_type: integration
    - id: AC-078
      requirement: REQ-030
      criteria: -AcknowledgeConflicts 下未修复清单写入失败时，**不**写任何日志标记/旁路文件并返回 15；断言不存在「已确认但清单丢失」的状态
      test_type: integration
    - id: AC-079
      requirement: REQ-019
      criteria: Step 4a 把非选中的旧日志标记 consumed_with_failure 时，同样先为它们各写一份未修复清单（或在清单中列出其条目），不出现「标记已消费但清单缺失」
      test_type: integration
    - id: AC-080
      requirement: REQ-032
      criteria: 新建备份目录名为 backup-<run_id>；对不符合该规则的历史目录，读取端以 run_id=unknown 并按目录路径去重，不因此崩溃或误判
      test_type: unit
    - id: AC-081
      requirement: REQ-026
      criteria: summary.failed>0 且回滚日志文件已被外部删除时返回 12（可构造：先制造部分失败，再删除日志，再触发回滚）
      test_type: integration
    - id: AC-082
      requirement: REQ-019
      criteria: Step 1 按「可解析」判定旁路文件：存在且格式合法的 consumed/acknowledged 才剔除候选；存在但不可解析的旁路**不**剔除（断言损坏的旁路文件无法绕过强制 T3 恢复）
      test_type: integration
    - id: AC-083
      requirement: REQ-027
      criteria: cleanup_log_path / cleanup_log_timestamp / cleanup_log_sha256 三者必须同 null 或同非 null；只把 sha256 置 null 而保留另两项视为模式错误并拒绝
      test_type: unit
    - id: AC-084
      requirement: REQ-019
      criteria: Step 2.5 只在清理日志**属于本候选**（路径存在、sha256 非 null 时哈希匹配、run_id 一致）时才施加抑制；断言「被篡改的日志指向另一轮的成功清理日志」**不**触发抑制，仍走 Step 3 并返回 14
      test_type: integration
    - id: AC-085
      requirement: REQ-027
      criteria: kind 只接受 registry_key/startup_value/path_entry/service/task 五种取值，其它取值自证失败；item_id 等于 "<kind>:<规范化 target>"，同一 target 在不同轮次产生同一 item_id，且 REQ-030 清单中的 item_id 能回指日志条目
      test_type: unit
    - id: AC-086
      requirement: REQ-019
      criteria: 旁路文件（rollback-consumed.json / rollback-acknowledged.json）的 run_id 必须与候选日志或其目录名一致；不一致的旁路视为不存在，断言复制来的旁路无法跳过强制 T3 恢复
      test_type: integration
    - id: AC-087
      requirement: REQ-027
      criteria: 父键下全部条目缺 parent_baseline 时，该父键所有条目跳过迹象 (ii) 且不拒绝整份日志；与「个别条目缺失」的容错路径分别断言
      test_type: unit
    - id: AC-088
      requirement: REQ-033
      criteria: 新写入的 cleanup-log.json 含 run_id 且与该轮回滚日志的 run_id 相同，Step 2.5 据此完成绑定；缺该字段的历史清理日志走「证据不足」分支（不抑制、交自证）且报告说明原因
      test_type: unit
    - id: AC-089
      requirement: REQ-019
      criteria: 两个消费标记都写失败时写入 rollback-consumed.failed.json；下次启动该候选**不**被自动重复消费，必须 -AcknowledgeConflicts 确认后才继续
      test_type: integration
    - id: AC-090
      requirement: REQ-019
      criteria: Step 2.5 的 ①/②/③ 三分支逐项断言：文件可读且哈希与 run_id 均匹配→可抑制；文件不存在且 sha256 为 null→不抑制；文件不存在但 sha256 非 null→不拒绝、不抑制、交 Step 3
      test_type: integration
    - id: AC-091
      requirement: REQ-019
      criteria: Step 4a 为较旧日志写的清单 reason 一律为 skipped_older_journal，不出现 conflict/not_restorable 等语义不符的原因
      test_type: unit
    - id: AC-092
      requirement: REQ-024
      criteria: 规则逐条独立断言（每条一个 It，便于定位失败）：(a) 规则1 存在且一致→already_present、无写入；(b) 规则2 存在但不同→restore_failed(conflict)、不覆盖；(c) 规则3 三项证据齐备+窗口内+迹象(i)(ii)(iii)均不命中→恢复；(d) 规则4 缺任一证据→conflict 且不写入
      test_type: unit
    - id: AC-093
      requirement: REQ-024
      criteria: 迹象 (i)/(ii)/(iii) 与多条目聚合各自独立断言：三个迹象各自命中时降级 conflict；同一父键多条目时聚合基线取 MAX，且回滚自身写入不使其误判（与 AC-074 一致）
      test_type: unit
    - id: AC-094
      requirement: REQ-030
      criteria: 证据不完整但通过规则 3/4 的条目判定为 restored(evidence_incomplete)、计入已恢复、**不**使本轮返回 14；仅 conflict/unjournaled/export_failed 才算 restore_failed
      test_type: integration
    - id: AC-095
      requirement: REQ-027
      criteria: parent_baseline 与该条目 mutation_succeeded 的日志落盘是同一次原子写（不另开一次写）；断言落盘失败只使**该条目**基线缺失，先前已落盘条目的基线仍存在且可用
      test_type: unit
    - id: AC-096
      requirement: REQ-019
      criteria: 自证失败/不可解析的候选在 Step 4b 下写**候选级**清单（unrepaired 为空数组、顶层 candidate_unparseable=true 与 backup_dir），且该清单先于任何旁路标记写入
      test_type: integration
    - id: AC-071
      requirement: REQ-005
      criteria: 落盘使用 [System.IO.File]::Replace（或等价原子原语）而非 Move-Item -Force：断言替换过程中目标路径始终存在；**第二次及以后**的写入保留上一代副本（`.prev`）；**首次**写入无上一代可保留，不适用该断言
      test_type: unit
    - id: AC-072
      requirement: REQ-019
      criteria: 已完成的日志（completed_at 非空，或存在 rollback-consumed.json / rollback-acknowledged.json）在 Step 1 即被剔除，不参与 Step 3 自证；断言「一个已完成日志 + 一个新未完成日志」共存时不返回 14，且仅消费新日志。**另断言互斥性**：`completed_at` 已写但旁路缺失时，Step 1 剔除、**不**走 Step 2.5 抑制分支，下次运行不消费
      test_type: integration
    - id: AC-073
      requirement: REQ-019
      criteria: (a) 全部候选自证失败时，-AcknowledgeConflicts 为**每一份**候选在其各自 backup-* 目录下写入 rollback-acknowledged.json，下一次运行不再返回 14（证明「全部损坏」不会永久锁死工具）；(b) 仅部分候选失败时，同样各自写入，未受影响的候选行为不变
      test_type: integration
    - id: AC-074
      requirement: REQ-024
      criteria: 仅针对恢复阶段（rollback -Auto）：同一父键下多个条目顺序恢复时，回滚自身的写入不会使后续条目被误判为外部变更（两阶段判定→执行），断言全部条目均被恢复而非仅第一个。清理阶段（cleanup）不适用两阶段：它按条目连续写入基线以保证 T3 存活，两者是有意不同的行为
      test_type: integration
    - id: AC-075
      requirement: REQ-027
      criteria: 个别条目缺少 parent_baseline、或 fingerprint_source 缺失/取值非法时：(a) 缺 parent_baseline 仅对该条目标注证据不完整并跳过迹象 (ii)，且该父键下全部条目都缺时对该父键全部跳过；(b) fingerprint_source 缺失或非法则整份日志自证失败
      test_type: unit
    - id: AC-060
      requirement: REQ-030
      criteria: -AcknowledgeConflicts 对三种 14 情形（恢复未完全成功/自证失败或重复 run_id/平局或多日志）均有效；断言执行顺序为「先原子写未修复清单到 output/（backup 目录之外），成功后才写日志标记/旁路文件」
      test_type: integration

  design_decisions:
    - id: DD-001
      decision: 逐项 pre-export，而非依赖既有三棵 Uninstall 备份树
      rationale: 既有备份与清理实际删除的路径重叠为 0（已机械验证 7/7 covered=False），因此对主要破坏路径毫无恢复能力
      alternatives_considered: 扩大预检导出到整个 hive（巨大且慢）
    - id: DD-002
      decision: 绝不自动调用 Restore-Computer
      rationale: 它是整机回滚，会一并抹掉还原点之后用户的所有无关更改，且强制重启，无法在进程内完成
      alternatives_considered: 自动整机还原（会自行造成数据损失）；完全不建还原点（更糟）
    - id: DD-003
      decision: 启动项 value 精确备份：对该 value 所在的 Run/RunOnce 键执行 reg export 得到 .reg，再由一个**纯函数**（入参为 .reg 文本，返回最小 .reg 文本；不做 IO，因此可单测）裁剪为「只含目标 value」的最小 .reg。**裁剪输出必须恰好包含一个 value 定义（目标 value）+ 必要的父键行，兄弟 value 一律不得保留**——这是该函数的契约，由 AC-002 断言；REQ-024 的比较因此只需处理单 value。文件读写由调用方负责，裁剪抛错/产出不可解析时由调用方按导出失败处理。绝不删除或整键重导共享的 Run/RunOnce 键
      rationale: 删除共享 Run 键是被明令禁止的（clean-residuals.ps1:475-477）；reg export 无 value 粒度，因此用「导出父键 → 裁剪到单 value」实现 value 级备份。裁剪逻辑是纯函数，可单测（AC-002）
      alternatives_considered: 整键删除重建（灾难性）；完全跳过 value 备份（失去可恢复性）；直接导入父键 .reg（会把该键其它程序的启动项一并覆盖）
    - id: DD-004
      decision: 日志绑定 run_id 与 cleanup-log 时间戳，拒绝陈旧日志
      rationale: 防止回滚错的那一轮
      alternatives_considered: 固定单一文件名（跨轮次歧义）
    - id: DD-005
      decision: 自动回滚默认开启，提供 -NoAutoRollback
      rationale: 用户明确选择了“全自动”
      alternatives_considered: 默认关闭（与用户选择矛盾）
    - id: DD-006
      decision: 文件/服务/任务删除一律记为 not_restorable 并给出原因
      rationale: 防止工具谎称已撤销；诚实报告是安全的前提
      alternatives_considered: 静默忽略（不诚实）
    - id: DD-007
      decision: 建立在 ADR-001 的 [ref]$ExitCode 契约之上
      rationale: 10 个脚本已统一使用，hermeticity 测试与门禁共同强制
      alternatives_considered: 在 Main 内重新引入 exit（ADR-001 明令禁止）
    - id: DD-008
      decision: 每次运行一次性捕获 Machine PATH 逐字原值并写入日志
      rationale: 现状无任何备份即整体重写，且同一轮内多次读-改-写存在竞争
      alternatives_considered: 逐项保存（值相同，浪费）；不保存（不可恢复）
    - id: DD-009
      decision: path_deleted 记录真实结果（deleted / renamed:<newname>）
      rationale: Tier-4 重命名当前被谎报为成功删除，且映射无处记录
      alternatives_considered: 保持误导性日志；把所有重命名都当失败
    - id: DD-010
      decision: 前置条件校验备份真实有效；create-restore-point.ps1 保护失败时大声失败
      rationale: 现状门禁只看目录是否存在，且备份脚本在完全失败时仍退出 0
      alternatives_considered: 保持 fail-open（对一个以可恢复性为承诺的工具不可接受）
    - id: DD-011
      decision: CleanupPanel.tsx 的备份承诺改为按真实状态条件渲染
      rationale: 当前无条件宣称已有还原点备份，恰在用户未受保护时误导用户
      alternatives_considered: 保留原文案（构成主动误导）
    - id: DD-012
      decision: clean-residuals.ps1 在 summary.failed > 0 时返回可区分的非零码
      rationale: 现状恒为 0，导致 UI 与任何调用方都无法识别部分失败
      alternatives_considered: 保持 0 并要求所有调用方解析日志
    - id: DD-013
      decision: 退出码矩阵固定为 0=成功；1=输入/前置错误；2=权限错误；3=依赖缺失；10=清理部分失败但回滚完全成功；11=清理部分失败且回滚部分/完全失败；12=部分失败但无可回滚记录；13=部分失败且 -NoAutoRollback 已显式关闭回滚；14=上轮日志恢复未完全成功、本轮未开始；15=运行中日志落盘失败（fail-closed，优先报告）
      rationale: 让 UI 能区分「已修复」与「仍受损」，这是 REQ-025 与 UI 诚实呈现的前提；保留 0-3 的既有语义不破坏现有调用方
      alternatives_considered: 单一非零码（UI 无法区分）；把回滚结果塞进退出码高位（难以阅读）
    - id: DD-014
      decision: T3 恢复定位为「下次启动时恢复」而非即时自动回滚
      rationale: 进程崩溃后不存在任何调用者，声称即时自动回滚是过度承诺。改为下次 clean-residuals 启动时消费自证日志，既可实现又诚实
      alternatives_considered: 声称即时自动（不可实现）；完全放弃 T3（丢失崩溃恢复能力）
    - id: DD-015
      decision: 恢复前做冲突检测（注册表/value 与 PATH 对称），目标已存在且不同则拒绝覆盖并报 conflict
      rationale: 清理后到回滚之间目标可能被合法重建；盲目 reg import 会造成数据损失，与 PATH 的既有保护不对称会留下同类风险
      alternatives_considered: 直接 import 覆盖（有数据损失风险）；仅在 PATH 上做保护（不对称）
    - id: DD-019
      decision: 日志回退深度固定为 1 代（`rollback-journal.prev.json`），不做多代链
      rationale: 1 代恰好覆盖「原子替换写入中途崩溃」这一最常见失败模式；更深回退需要链式指针与垃圾回收，复杂度与收益不成比例，且最坏情况下多代链本身也会成为新的不一致来源。两代都不可解析时如实报告「无日志」并交人工，而不是继续猜测
      alternatives_considered: 多代链（复杂度失控）；完全不保留上一代（畸形日志即丢失 T3 恢复能力）
    - id: DD-018
      decision: 承认「当前缺失是否归因于本轮」在超时后不可证明，用「三项目标 + 24 小时窗口」把自动恢复限制在可辩护范围内，窗口外一律转人工
      rationale: Windows 无篡改证据/审计通道，任何 flag 组合都无法排除「本轮删除之后被外部创建又删除」。与其层层加码到无法实现的保证，不如把不确定性显式化：窗口内自动恢复，窗口外报 conflict。这是对用户最诚实的取舍
      alternatives_considered: 继续加 flag（无法收敛，且仍是伪保证）；完全不自动恢复（放弃用户明确要求的全自动，对「刚崩溃」这一最常见场景过于保守）
    - id: DD-017
      decision: 同一 run_id 出现在多个 backup 目录时全部拒绝并要求人工介入；不承诺能拒绝「内容完全自洽的同机副本」
      rationale: 同机完整复制日志+备份+清理日志后，其字段全部自洽，仅凭内容与原件不可区分。与其宣称一个做不到的保证，不如用 run_id 唯一性做可实现的检测，并把无法判定的情形交人工
      alternatives_considered: 宣称可拒绝所有复制（做不到，属于谎报安全）；不检测（可能回放陈旧日志）
    - id: DD-016
      decision: 恢复判定以「目标当前状态 + 状态标记提供的因果证据」为准，规则集中在 REQ-024 一张表
      rationale: 「变更已完成但 mutation_succeeded 未落盘」的崩溃窗口事后不可消除。该窗口现在**明确不自动恢复**：落入 REQ-024 规则 4，报 conflict 并交人工。本决策不宣称能自动救回该窗口，只保证不会误恢复未变更项、也不会静默覆盖用户后续状态
      alternatives_considered: 仅凭状态标记（AC-026 不可实现）；对该窗口自动恢复（会复活用户主动删除的内容）
