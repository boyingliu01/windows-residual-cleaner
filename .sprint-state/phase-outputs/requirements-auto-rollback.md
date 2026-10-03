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
