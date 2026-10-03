# Auto-Rollback — Design Document

- **Sprint**: `sprint-2026-10-01-01`
- **Status**: draft — pending HARD-GATE user approval, then R2 delphi-review
- **Depends on**: `requirements-auto-rollback.md` (R1 input)
- **Baseline commit**: `34a0817` (ADR-001 refactor; 287 tests, 80.0% coverage)

---

## 1. The problem, stated precisely

The user asked for **fully automatic rollback**: create a restore point + backups before
cleanup, and roll back automatically if cleanup fails.

Investigation found the current backup machinery **cannot undo the damage cleanup does**.
This is not a nuance — it is the whole design problem:

### 1.1 The existing backup has zero overlap with what cleanup deletes

`create-restore-point.ps1:105-107` exports exactly three trees:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall
HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall
```

`clean-residuals.ps1` deletes (Phase 3, lines 468–509) keys whose shapes come from
`scan-residuals.ps1:66,72,123,162,189`:

| deleted shape | source | under a backed-up tree? |
|---|---|---|
| `HKLM\SOFTWARE\<Vendor>` | scan-residuals.ps1:66 | **no** |
| `HKLM\SOFTWARE\WOW6432Node\<Vendor>` | :72 | **no** |
| `HKCU\Software\<Vendor>` | :72 | **no** |
| `...\CurrentVersion\Run` **value** | :123 | **no** |
| `...\RunOnce` **value** | :123 | **no** |
| `HKLM\SOFTWARE\Classes\CLSID\{guid}\InProcServer32` | :162 | **no** |
| `HKLM\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\<h>` | :189 | **no** |

Verified mechanically (executed, 7/7 `covered=False`). **Zero of the deleted paths are
inside an exported tree.** So today, `.reg` backups provide no registry-recovery ability
for the primary damage path. Fixing this is the core of the feature.

### 1.2 Cleanup never reports failure through its exit code

`clean-residuals.ps1` returns non-zero **only** from pre-flight gates:
`:235` (2, not admin), `:249/271/302/309/314` (1, bad input), `:325` (0, report-only).
The end of a real run is **always `& $setRc 0` (`:530`)**. Per-item failures live only in
`cleanup-log.json` as `{action:'cleanup_failed', success:$false}` and `summary.failed` (`:516`).

**Live evidence on this machine** — `cleanup-log.json` right now:

```json
{"timestamp":"2026-10-02T22:16:06","succeeded":0,"failed":1,"total_processed":1,
 "dry_run":false,"mode":"D"}
```

with entry `{"action":"cleanup_failed","id":"svc_900","error":"sc.exe delete failed with exit code 5: Access is denied."}`
— and the process still exited **0**.

Therefore "cleanup failed" **must** be read from the log, not from `$LASTEXITCODE`.

### 1.3 Four further defects found during this analysis

These were found by reading the code and are **independent of** the auto-rollback feature;
they are all prerequisites for it.

**D-1 — PATH is destructively rewritten with no pre-image** (`:449-453`)

```powershell
$mp = [Environment]::GetEnvironmentVariable('Path','Machine')   # 449
$mpItems = $mp -split ';' | Where-Object { $_.Trim() -and $_.Trim() -ne $target }  # 452
[Environment]::SetEnvironmentVariable('Path', ($mpItems -join ';'), 'Machine')     # 453
```

`SetEnvironmentVariable` replaces the **entire** Machine PATH. The original is never
recorded, so there is nothing to roll back to. Two further consequences:
- it is an unsynchronized read-modify-write: anything another installer writes between
  449 and 453 is **silently lost**;
- the loop runs per item, so a second `path_entry` in the same run reads the
  **already-rewritten** value.

**D-2 — the log lies about Tier-4 deletions** (`:143-167` + `:409`)

`Remove-ItemRobust` tier 4 renames the target to `~<leaf>.deleted<n>` and `return $true`
(`:149`, `:167`). The caller then logs `{action='path_deleted'; path=<original>; success=$true}`
(`:409`) — but the data **still exists under the new name**, and the rename mapping is
recorded **nowhere**. Output at `:150` mentions it in prose only.

Consequence: any rollback driven by this log would look for the original path and conclude
"already gone", while the residue is actually sitting in a `~*.deleted` directory.

**D-3 — the backup gate only checks that a directory exists** (`:243-253`)

The gate accepts *any* `backup-*` directory. It never reads `restore-status.json`, never
checks `restore_point_enabled`, and never checks that the backup is **newer than the last
cleanup**. A leftover directory from months ago satisfies it.

**D-4 — `create-restore-point.ps1` fails open** (`:89-98`, `:110-124`)

If `Checkpoint-Computer` throws (System Protection off, the once-per-24h throttle, or no
elevation) the script only `Write-Warning`s and sets `$restorePointEnabled = $false`, then
proceeds and **exits 0** (`:140`). Likewise the export loop adds nothing when `Test-Path`
is false, and **nothing ever checks `$backupFiles.Count -gt 0`**. So "backup succeeded" is
not verifiable from the exit code.

### 1.4 The UI currently makes a promise the code cannot keep

`ui/src/components/CleanupPanel.tsx`:

- `:297` — "此操作不可逆。" (this operation is irreversible)
- `:305` — "已通过系统还原点备份，如需恢复可使用 `rollback.ps1` 回滚。"
- `:194` — "此操作不可逆，但可通过系统还原点恢复。"

Line 305 is **unconditional**: it is rendered even when `restore_point_enabled` is false and
no usable backup exists. Combined with §1.1 (zero registry overlap) and §1.3 D-4 (silent
fail-open), the UI currently tells the user they are protected at precisely the moments they
are not. This must be corrected as part of the feature (AC-013 / AC-007 in the grill's list).

---

## 2. Candidate approaches

### Option A — Per-item pre-export journal, targeted restore  ✅ **recommended**

Immediately **before** each destructive registry action, export that exact key/value to the
run's backup dir and append a record to `rollback-journal.json`. On failure, restore from
the journal with `reg import`. Restore PATH by string re-insertion.

- Registry restore **works** — proved end-to-end on this machine:
  `reg export` → `reg delete` → `reg import` restored `Marker` and nested `Sub\Nested=0x2a`.
- Targeted: restores **only** what we removed; no collateral damage.
- Honest about the rest (files/services/tasks are reported `not_restorable`).
- Cost: one extra `reg export` per deleted key (cheap; keys are small).

### Option B — Rely solely on the System Restore point, auto-invoke `Restore-Computer`

- **Rejected.** `Restore-Computer` rolls back the **entire system**, destroying any user
  work done after the restore point was taken — **worse** than the residue being cleaned.
  It also **forces a reboot**, so it cannot complete inside a cleanup run.
  Restore points are additionally throttled (Windows default: one per 24h;
  `SystemRestorePointCreationFrequency` is **not set** on this machine, so the throttle
  applies) and can be silently unavailable (`create-restore-point.ps1:92-97` only warns and
  sets `$restorePointEnabled=$false`, leaving exit code 0 — a silent fail-open).

### Option C — File-level archive before deletion (archive `path_deleted` contents)

- Attractive because file/dir deletion is the **only truly unrecoverable** action.
- **Deferred, not adopted.** Archiving arbitrary directories (WindowsApps-sized) is slow and
  disk-hungry, and `Remove-ItemRobust` may rename-then-delay-delete. Recorded as a future
  feature, not part of this sprint.

**Decision: Option A**, with Option B retained strictly as a **manual, documented** path.

---

## 3. Recommended design (Option A)

### 3.1 New artefact: `rollback-journal.json`

Written to the run's `backup-<run_id>` directory (REQ-032 — **not** a timestamp), created
**before the first destructive action** and **flushed after every item** (so a hard kill still
leaves a usable record).

> **Copy this schema exactly — an earlier draft of this example contradicted the spec** and would
> have led an implementer to build the wrong thing: `run_id` was a timestamp instead of a GUID,
> the directory was `backup-<timestamp>` instead of `backup-<run_id>`, the field was named
> `status` instead of `state`, and the initial value was `pending` instead of `planned`.
> `run_id` **must be a GUID**: REQ-027/REQ-032 use it for journal↔cleanup-log binding, the
> duplicate-`run_id` self-validation check, and uniqueness across runs. A timestamp collides on
> two runs started in the same second and silently defeats all three.

> Top-level fields must match REQ-027 **exactly**. Note `created_at` (the journal-creation /
> run-start instant, and the origin of REQ-024's 24h window). An earlier draft named this field
> `started_at`, which is **not** a schema field — use `created_at` or self-validation fails. `machine_fingerprint` and
> `machine_path_original` are required too; omitting them fails self-validation, and on T3 a
> rejected journal means the deletion is never rolled back. The complete required set is:
> `journal_version`, `run_id` (guid), `created_at`, `completed_at`, `machine_fingerprint`,
> **`fingerprint_source`** (exactly `machine_guid` or `hostname_fallback`; any other value is
> rejected), `machine_path_original`, `cleanup_log_path`, `cleanup_log_timestamp`,
> `cleanup_log_sha256` (all-null or all-non-null together), `backup_dir`, `entries`.

```json
{
  "journal_version": 1,
  "run_id": "9f2c1a44-7b30-4e6d-9c11-2a5e8d0b7c31",
  "created_at": "2026-10-02T14:31:07",
  "completed_at": null,
  "machine_fingerprint": "<stable machine id>",
  "fingerprint_source": "machine_guid",
  "machine_path_original": "C:\\Windows\\system32;C:\\Windows;...",
  "cleanup_log_path": "D:\\...\\cleanup-log.json",
  "cleanup_log_timestamp": null,
  "cleanup_log_sha256": null,
  "backup_dir": "D:\\...\\backup-9f2c1a44-7b30-4e6d-9c11-2a5e8d0b7c31",
  "entries": [
    { "id": "reg_950", "item_id": "registry_key:hklm\\software\\acme",
      "kind": "registry_key", "target": "HKLM\\SOFTWARE\\Acme",
      "backup_file": "reg-HKLM_SOFTWARE_Acme.reg", "backup_file_sha256": "<hex>",
      "pre_existing": true, "absent_confirmed_after_mutation": false,
      "parent_baseline": null, "state": "planned" },
    { "id": "str_12",  "item_id": "startup_value:hklm\\...\\run|acmeupdater",
      "kind": "startup_value", "target": "HKLM\\...\\Run", "value_name": "AcmeUpdater",
      "backup_file": "regval-....reg", "backup_file_sha256": "<hex>",
      "pre_existing": true, "absent_confirmed_after_mutation": false,
      "parent_baseline": null, "state": "planned" },
    { "id": "path_7",  "item_id": "path_entry:machine|c:\\program files\\acme\\bin",
      "kind": "path_entry", "target": "C:\\Program Files\\Acme\\bin", "scope": "Machine",
      "backup_file": null, "pre_existing": true,
      "absent_confirmed_after_mutation": false, "parent_baseline": null,
      "state": "planned" },
    { "id": "fs_201",  "item_id": "path_deleted:c:\\program files\\acme",
      "kind": "path_deleted", "target": "C:\\Program Files\\Acme",
      "backup_file": null, "pre_existing": true,
      "absent_confirmed_after_mutation": false, "parent_baseline": null,
      "state": "planned" }
  ]
}
```

`state` follows an explicit state machine (REQ-018):

```
planned ──► backup_created ──► mutation_succeeded
   │               │           └─► (crash before cleanup-log write is still recoverable)
   │               └─────────────► mutation_failed
   │
   └─ path_deleted / path_entry / service / task (backup_file == null, per DD-006):
      planned ──────────────────► mutation_succeeded
              └────────────────────► mutation_failed
      These SKIP backup_created — there is no backup to create, so the state is undefined
      for them otherwise (AC-066). On recovery they are always not_restorable.
   └── crash here: item was NEVER touched. Rollback must NOT restore it.
```

**Rollback only *considers* entries in `mutation_succeeded` — that status is one necessary input, **not** a sufficient condition (§3.5.3 / REQ-024 add `pre_existing`, `absent_confirmed_after_mutation`, the 24h window and the external-change signs). Never restore on status alone: doing so would resurrect content the user deleted after the cleanup..** Restoring a `planned` item would
overwrite untouched state and then report a false success — the exact class of lie this
feature exists to eliminate. Writing `planned` **before** the action is what makes crash
recovery (T3) possible without that hazard.

### 3.1.1 Two tiers of "protection" — must not be conflated (REQ-017)

| tier | what | if unavailable |
|---|---|---|
| **mandatory targeted protection** | rollback journal + per-item registry/PATH backups | **fail-closed**: abort before the first destructive op |
| **optional system restore point** | best-effort last resort | warn prominently (REQ-014), cleanup proceeds |

Conflating these produces one of two bad outcomes: a machine with System Protection disabled
could never clean anything, or cleanup would proceed with no mandatory protection at all.

**Per-item fail-closed (REQ-006/007)**: if an individual `reg export` cannot be created or
verified immediately before its deletion, **that deletion is skipped** and logged as
`cleanup_failed`/`export_failed`. The tool never deletes something it failed to back up.

### 3.2 Changes to `clean-residuals.ps1`

- New switch **`-NoAutoRollback`** (default: auto-rollback **on**, per the user's explicit
  choice of fully-automatic).
- Introduce a journal alongside the existing backup gate at `:243-253` (the
  `$willDelete` / `backup-*` pre-flight check, which already carries
  `-ErrorAction SilentlyContinue` after the ADR-001 fix).
- In Phase 3, immediately before `reg delete`:
  ```powershell
  $exportFile = Export-RegistryKeyBackup -Key $item.key -BackupDir $backupDir
  # NOTE: the field is `state`, initial value `planned` — NOT `status='pending'`.
  # An earlier draft used the wrong names, so a literal implementation would emit entries that
  # fail REQ-027/REQ-018 self-validation; on T3 a rejected journal means the deletion is never
  # rolled back.
  Add-RollbackJournalEntry -JournalPath $journalPath -Entry @{
      id = $item.id; item_id = $item.item_id; kind = $item.kind; target = $item.target
      backup_file = $exportFile
      backup_file_sha256 = (Get-FileHash $exportFile -Algorithm SHA256).Hash
      pre_existing = $true; absent_confirmed_after_mutation = $false
      parent_baseline = $null; state = 'planned' }
  reg delete "$regKey" /f
  ```
  For startup **values**, the approved path is **DD-003**: `reg export` the parent key, then
  run the pure trim function to reduce it to a `.reg` containing **only** the target value,
  then re-import that trimmed file. An earlier draft of this section called
  "export the parent then prune" not acceptable, which directly contradicted DD-003/REQ-007 —
  an implementer reading only §3.2 would have built the wrong thing. The real constraint is
  **not** "never export the parent" but "**never delete or re-import the whole shared key**":
  the trim restricts everything we ever write back to the single value we own, so sibling
  values in a shared `Run`/`RunOnce` key are never touched (deleting that key is forbidden —
  `clean-residuals.ps1:475-477`).
  Two mandatory guards on this path: the trim output is **post-condition checked** to contain
  exactly one value definition (else `export_failed(trim_multivalue)` and the deletion is
  skipped), and the `.reg` must be read/written as **Unicode** (REQ-035) because `reg export`
  emits UTF-16LE with a BOM.
- In Phase 2, record `path_deleted` / `service_deleted` / `task_deleted` as
  `not_restorable` with a reason, so the journal is a complete account.
- After writing `cleanup-log.json`, if `summary.failed -gt 0` **and** rollback is enabled,
  invoke the rollback path in-process (no child process needed).

### 3.3 Changes to `rollback.ps1`

- New `-Auto` mode and `-JournalPath` parameter; keeps today's read-only guidance output
  when `-Auto` is absent (no behaviour change for existing callers/tests).
- `-Auto` logic: read journal → for each entry, restore best-effort → re-query to confirm →
  print a per-item verdict table → write `rollback-result.json`.
- **Must never** call `Restore-Computer` (AC-007). The restore point is reported as a manual
  option only.
- Continues past individual failures; reports partial success (AC-011).
- Re-runnable: an already-present key reports `already_present` (AC-014).

### 3.4 Pure helpers (for testability — the pattern that got us to 80%)

Following this sprint's proven approach, the logic goes into pure, dot-sourceable functions:

| function | purpose |
|---|---|
| `Get-RollbackJournalEntry` | parse + validate a journal (tolerate corruption) |
| `Test-RollbackRestorable` | kind → restorable? + reason |
| `Get-RestorableEntry` | filter a journal to the restorable subset |
| `Resolve-PathEntryScope` | map a PATH entry to Machine/User scope |
| `Get-RollbackVerdict` | build the per-item verdict record |
| `Format-RollbackReport` | render the verdict table |

Side-effecting calls (`reg import`, `reg export`, PATH write) stay in `Main`/thin wrappers.

### 3.5.1 Exit-code matrix (REQ-026 / DD-013)

Existing codes keep their meaning so current callers do not break; new codes cover the
rollback outcome so the UI can distinguish "repaired" from "still damaged".

| code | meaning |
|---|---|
| 0 | success |
| 1 | input / pre-flight error |
| 2 | permission error |
| 3 | missing dependency |
| **10** | cleanup partially failed, **rollback fully succeeded** |
| **11** | cleanup partially failed, **rollback partially or fully failed** |
| **12** | cleanup partially failed, **no rollback record available** (journal missing/unreadable at rollback time) |
| **13** | cleanup partially failed, **`-NoAutoRollback` explicitly disabled rollback** |
| **14** | **previous run's journal could not be safely consumed** — run aborts *before* pre-flight |
| **15** | **persistence-record write failed** (fail-closed, **terminal**) |

Code 13 is required: without it a caller cannot distinguish "we repaired it" from
"you told us not to repair it".

Codes 14 and 15 were missing from this table in earlier drafts, which would have led an
implementer reading only §3.5.1 to omit two mandatory outcomes.

**Code 14 has three branches**, each with its own test case:

| branch | trigger |
|---|---|
| (a) | recovery ran but left `restore_failed` entries |
| (b) | self-validation failed, or a duplicate `run_id` was found (Step 4b) |
| (c) | candidate ambiguity — `created_at` tie, or several unfinished journals |

**Code 15 has three time points**, all meaning "the system was changed but the record is not
reliable", hence one code and one terminal semantics:

| time point | trigger |
|---|---|
| (i) | journal flush failed mid-run (REQ-005) |
| (ii) | rollback finished, but writing the unrepaired list failed (REQ-030) |
| (iii) | rollback finished, but writing the completion marker or a consumption marker failed (REQ-019/REQ-031) |

**14 and 15 must not overlap.** An earlier draft of this table put "both consumption markers
failed to write" in **both** 14(d) and 15(ii), so one event had two valid codes and an
implementer could not decide which to return. The boundary is now a single decidable test —
**did the failure happen inside this run or before it?**

- writing anything in **this** run fails → **15**
- **a previous** run's journal cannot be safely consumed, discovered at startup → **14**

They are mutually exclusive by construction: 14 aborts during the read phase, before any write
is attempted, so a run that returns 14 never reaches a write that could fail. Cleanup for a
double-marker failure is still to write `rollback-consumed.failed.json` first (so later runs do
not silently re-consume and must be confirmed with `-AcknowledgeConflicts`), but that run's exit
code is **15**.

**Precedence.** 15 is terminal and outranks 10/11/12/13 — once persistence has failed we do not
go on to evaluate the rollback outcome. 14 is evaluated at startup, before pre-flight, so it
cannot co-occur with 10-13 in the same run. 12 and 13 cannot both apply: 13 requires the
`-NoAutoRollback` switch, and under that switch we never look for a journal to roll back from;
if the switch is present and the journal is missing, the answer is 13.

### 3.5.1.1 Primitives verified on the real machine, not assumed

The panel was right that several primitives in earlier drafts of this design were assumed
rather than measured. All three below were probed on this machine and are now settled:

**(a) Registry `LastWriteTime` is NOT exposed by any managed API.**
`[Microsoft.Win32.RegistryKey]` exposes only `SubKeyCount, View, Handle, ValueCount, Name` —
no `LastWriteTime` — under **both** PS 5.1 and pwsh 7, and `Get-Item HKCU:\...` likewise. Sign
(ii) was therefore unbuildable as written. It is buildable via P/Invoke, which was verified:

```powershell
# verified working on PS 5.1 (and needed on pwsh 7 for the same reason)
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using Microsoft.Win32;
public static class RegTime {
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  private static extern int RegQueryInfoKey(IntPtr hKey, IntPtr lpClass, IntPtr lpcchClass,
    IntPtr lpReserved, out uint a, out uint b, out uint c, out uint d, out uint e,
    out uint f, out uint g, out long lpftLastWriteTime);
  public static DateTime GetLastWrite(RegistryKey k) {
    uint a,b,c,d,e,f,g; long ft;
    int r = RegQueryInfoKey(k.Handle.DangerousGetHandle(), IntPtr.Zero, IntPtr.Zero,
      IntPtr.Zero, out a,out b,out c,out d,out e,out f,out g, out ft);
    if (r != 0) throw new System.ComponentModel.Win32Exception(r);
    return DateTime.FromFileTimeUtc(ft);
  }
}
"@
```

Two traps found while getting this working, both worth recording: `.Handle` returns a
`SafeRegistryHandle`, **not** an `IntPtr` — passing it directly throws
`MethodArgumentConversionInvalidCastArgument`, so `.Handle.DangerousGetHandle()` is required.
And the PS 5.1 C# compiler rejects `ref`-returning members, so the helper must avoid them.
Measured behaviour: a `SetValue` advanced the parent's timestamp by ~1238 ms, and creating a
subkey advanced it again — so the signal is real and usable. `RegQueryInfoKey` must be given a
`FILETIME` (100-ns since 1601) and converted with `DateTime.FromFileTimeUtc`.

**(b) `[System.IO.File]::Replace` cannot do a first write.** Verified: with the destination
absent it throws. The correct protocol is therefore:

```
first write  (destination absent):  File.Move(tmp, target)      # atomic rename, same volume
subsequent   (destination present): File.Replace(tmp, target, prev)   # atomic + keeps 1 gen
```

This matters because §3.5.1/REQ-005 previously said first write degrades to `File.Move`
*without* saying why that is safe while `Move-Item -Force` is not: `File.Move` is a single
atomic rename and **fails if the destination exists**, whereas `Move-Item -Force` deletes the
destination first and therefore has a window where the journal is missing. The overwrite-
avoidance is the safety property, not the name of the API. Also verified: the backup path does
**not** need to pre-exist (it is created), and `Replace(tmp, target, $null)` **throws**
"The path is not of a legal form" — so a generation must always be named explicitly.

**(c) `reg export` output encoding.** `reg export` writes UTF-16LE with a BOM. Reading it with
PS 5.1's default `Get-Content` yields NUL-interleaved garbage, so the DD-003 trim function must
be fed text obtained with `-Encoding Unicode` (or `[System.IO.File]::ReadAllText($p, [Text.Encoding]::Unicode)`)
and written back as Unicode. This is a real correctness trap, not a style preference.

### 3.5.2 T3 is "recover on next launch", not instant (REQ-016 / DD-014)

After a crash, hard kill, or power loss **there is no process left to invoke rollback**.
Claiming instant automatic recovery would be an over-promise. So T3 is defined honestly as:

> On the **next** `clean-residuals.ps1` run, if a self-validating unfinished rollback journal
> is found, it is **consumed first** (recovery completes) before any new cleanup begins.

The user-facing wording must not claim that a crash is rolled back immediately.

> **Ordering is load-bearing.** In the T3 path the order is: (1) find candidates and filter
> out completed ones; (2) parse; (**2.5**) evaluate completion-marker suppression;
> (**3**) self-validate; then (4a/4b) decide consumption. Step 2.5 must come **before**
> self-validation, because the case it exists for is precisely a journal that fails
> self-validation (its cleanup log is gone); if validation ran first, the suppression would be
> unreachable. Equally, **nothing is marked consumed — no marker written, no `completed_at`
> set — until the candidate has been validated** and REQ-030's ordering is satisfied. A journal
> consumed before validation can never be retried, which turns a recoverable T3 into permanent
> loss of the record.

**Exactly one thing makes a journal "unfinished": `completed_at == null`.** That has a sharp
consequence the earlier drafts of this design missed: if a *successful* run never writes
`completed_at`, the next launch treats a correctly-finished cleanup as unfinished T3 and
**reinstalls everything it just deleted**. So:

- **Every normal exit path writes `completed_at` atomically before exiting** — all-success,
  partial-then-rollback-succeeded, and `-NoAutoRollback` alike (REQ-031 / AC-070).
- **The sole exception is exit code 11** (partial failure, rollback incomplete): the journal
  must stay **unfinished** and the unrepaired list must be persisted, so the next launch
  retries T3 rather than treating a still-damaged system as done (AC-077).
- **Crash between "cleanup succeeded" and "marker written" is the trap.** If `completed_at`
  is null but the cleanup log exists with `summary.failed == 0`, the cleanup *did* finish and
  only the marker was lost — recovery must be **suppressed** and the journal reported as
  "completed (marker missing)" (REQ-031 / AC-076, applied at REQ-019 **Step 2.5**).
  When `summary.failed > 0` the journal is treated as unfinished as usual. The discriminator
  is exactly one bit: whether `summary.failed` is zero.

Note the two orderings that were wrong in earlier drafts: the suppression step must run
**before** self-validation (else a journal whose cleanup log vanished fails Step 3 and never
reaches suppression), and the restore-side sign-(ii) comparison must happen **before any
restore write** (else our own restores look like external changes).

### 3.5.3 The single authoritative restore decision table (REQ-024)

Earlier drafts of this design had **three** places defining when to restore (REQ-018, REQ-024,
REQ-029), and they contradicted each other. The Delphi panel caught it across two rounds.
There is now **one** rule, and everything else defers to it:

| target state | evidence | verdict |
|---|---|---|
| present and identical to backup | — | `already_present` (do not re-restore) |
| present but different | — | `restore_failed(conflict)` — **do not overwrite** |
| **absent** | `mutation_succeeded` **and** `pre_existing` **and** `absent_confirmed_after_mutation` | **restore** |
| **absent** | anything else | `conflict` — **do not auto-restore**, ask the human |

The causal chain needs **all three** flags:

1. `pre_existing` — it existed before cleanup;
2. `mutation_succeeded` — this run deleted it, successfully;
3. `absent_confirmed_after_mutation` — the tool **re-checked immediately after deleting** and
   confirmed it was gone.

Flags 1+2 alone only prove "this run deleted *something*"; they cannot rule out the target being
re-created and deleted again afterwards by something else. Flag 3 (`absent_confirmed_after_mutation`)
closes **that specific** window — the gap between our deletion and our confirmation — and without
it the tool would resurrect content the user deliberately removed later, the exact harm REQ-029
exists to prevent.

**But flag 3 is necessary, not sufficient.** An earlier draft of this section said flag 3 "lets us
attribute the current absence to this run", which is a stronger claim than the mechanism can
support and which §3.5.3.1/REQ-024 explicitly retracts: an external create+delete occurring
*after* our confirmation satisfies all three flags, and Windows offers no tamper-evident channel
to distinguish it. Naming all three flags the "causal chain" overstates what they prove.

The policy is therefore **bounded, not proven**: restore only when the three flags hold **and**
`created_at` is within 24 hours **and** none of the external-change signs (i)-(iii) is present;
otherwise degrade to `conflict` + manual. The state is written as `absent_confirmed_after_mutation`
and the residual risk is recorded as DD-018 — the UI must not claim the tool can always reliably
restore.

This is the third iteration of this rule; the Delphi panel rejected the previous two for exactly
this gap, which is why it is written out in full rather than summarised.

### 3.5.3.1 The limit of this guarantee, stated honestly (DD-018)

The panel pushed a fourth and fifth flag, and it was right to: **no combination of flags can
prove that the *current* absence is attributable to this run.** Between "we deleted it and
confirmed it was gone" and "we are now recovering", something else may have deleted it again.
`parent_baseline` proves only "the parent key has not been written since"; it does **not** prove
"this absence is ours". Windows offers no tamper-evident channel to close that gap.

Two implementation details the panel forced, both of which are easy to get wrong:

- **`parent_baseline` must be persisted per mutation, not at run end.** T3 *is* the case where
  the run never reached its end, so a run-end-only write is missing exactly when it is needed.
  On recovery the baseline is re-derived as the **max** across all entries sharing that parent,
  so a later delete under the same parent cannot invalidate an earlier entry's record.
- **The cleanup-log checks are conditional on `cleanup_log_sha256` being non-null.** In T3 the
  cleanup log is gone by definition; requiring `cleanup_log_path` to exist would contradict
  REQ-021's "recover from the journal alone".

So instead of stacking more unprovable flags, the design **bounds** the claim:

| condition | behaviour |
|---|---|
| all three flags, `created_at` within the last **24 h** | auto-restore |
| outside the window, unconfirmed timing, or any sign of external change | `conflict` — hand to the human |

The 24-hour window is **fixed and NOT configurable** (REQ-024). An earlier draft called it
configurable, which contradicts REQ-024 and would turn a safety boundary into a setting users
disable whenever it is inconvenient. Document it, surface it — never expose it as a knob.

**Its honest consequence, which this design must not hide:** T3's typical case is a user who
restarts *days* after a crash, so the window will usually have expired and **automatic** recovery
will not happen — T3 reports `conflict` instead. The design promises T3 recovery (§3.5.2), yet
this window makes T3 automatic recovery the exception rather than the rule; those two statements
must be reconciled openly rather than left for an implementer to discover.

So T3's real value is **telling the truth about what was deleted plus giving actionable recovery
clues**, not *guaranteeing the machine is put back*. User-facing text must never say "it will be
restored automatically on next launch". Raising the automatic-recovery rate would mean widening
the window, which simultaneously raises the risk of resurrecting content the user deleted
afterwards (DD-018) — so this sprint does not widen it, it states the limit plainly.

**User-facing text must not claim "we can always reliably restore."** This is the honest
trade-off the user approved in spirit when choosing in-process targeted rollback over
whole-system restore.

Registry comparison is structural over the `reg export` scope (subkey set + all
`(name, type, data)` tuples; metadata ignored). PATH comparison is exact string equality.

### 3.5.4 Recovery protocol: target state + causation, not the status marker alone (REQ-018)

The window "mutation completed but `mutation_succeeded` not yet flushed" cannot be eliminated
after the fact. So recovery applies the §3.5.3 table, using the journal's status marker as the
**causal evidence** that this run performed the mutation. A `backup_created`-only entry with a
missing target is treated as *not provably ours* and is reported as a conflict rather than
silently restored.

### 3.5.5 T3 is mandatory even under `-NoAutoRollback` (REQ-030)

`-NoAutoRollback` disables only "roll back **this** run's failures". A leftover, self-validating
journal from a previous interrupted run is still consumed and recovered **before** the new run's
pre-flight checks — otherwise the new run would clean on top of unrepaired damage. If that
prior recovery has any `restore_failed`, the new run aborts (before pre-flight, before creating
a new backup). `not_restorable` items (deleted files/services/tasks) are *not* failures — they are
honest reports — so they warn loudly but do not block.

### 3.5.6 Failure-trigger matrix

| trigger | rollback runs? | rationale |
|---|---|---|
| T1 pre-flight gate non-zero (exit 1/2) | **no** | nothing was modified; running would be noise and could restore unrelated state |
| T2 `summary.failed > 0`, process exited 0 | **yes** | the real case |
| T3 crash / hard kill | **yes, if a journal exists** | journal is the survivor |
| `-DryRun` | **no** | AC-010 |

### 3.6 The honest capability ceiling (must be stated to the user)

The grill's most valuable contribution was forcing this into the open. **"Fully automatic
rollback" cannot mean "the machine is restored to how it was."** It means:

| claim | true? |
|---|---|
| "We record a pre-image of every registry key/value we delete" | **yes** (after DD-001) |
| "...and can restore those automatically" | **only within the bounded window** — the three flags, plus `created_at` under 24h, plus no external-change sign (REQ-024/DD-018). Outside it the answer is `conflict` + manual, so this must never be rendered as an unconditional guarantee |
| "We can restore the PATH entry we removed" | **yes, with the same 24h/window bound** (after DD-008) — and never by blindly overwriting a PATH that drifted |
| "We can un-delete the files and directories we removed" | **no** — no archive exists |
| "We can make a deleted service work again" | **no** — its binary is already gone |
| "We can restore a deleted scheduled task" | **no** |
| "The last line of defence can undo everything via a restore point" | **only manually, only if one was created, and it reverts unrelated changes + needs a reboot** |

**DD-008 (new, required by D-1)**: capture the verbatim Machine PATH **once per run**, before
the first `path_entry` removal, and journal it. This both fixes the missing pre-image and
makes the per-item read-modify-write safe within a run.

**DD-009 (new, required by D-2)**: `path_deleted` must record the *actual* outcome
(`deleted` vs `renamed:<new name>`). Rollback must then report renamed items as
*recoverable in place* by pointing at the `~*.deleted` path, instead of claiming success.

**DD-010**: the cleanup precondition becomes a real check — but on the **registry/file
backup**, not on the system restore point. This distinction is load-bearing and an earlier
draft of this DD got it wrong by making `restore-status.json` a hard precondition, which
contradicts REQ-003/REQ-025 and the approved Q1 decision.

- **Mandatory (blocks cleanup):** the per-item pre-image backup. If we cannot capture a
  pre-image for an item, that item is skipped.
- **Optional (warn, never blocks):** the System Restore point. `System Restore` can be
  disabled by policy and `Checkpoint-Computer` can fail through no fault of ours, so making it
  a gate would let an unrelated machine setting brick the tool. It remains a best-effort
  secondary escape hatch and a **separate, manual** recovery route.

What *is* mandatory is telling the truth about it: `create-restore-point.ps1` must surface a
**distinct non-zero code** when no effective protection was established, and
`restore-status.json` must record `valid=false` — **failing open silently is not acceptable**
for a tool whose promise is recoverability. That is the real fix for D-4: not "make it a gate",
but "stop reporting success when it did not succeed".

**DD-011 (new, required by §1.4)**: `CleanupPanel.tsx:305` becomes conditional on the actual
backup status. Promising a backup that does not exist is the most user-visible defect found.

### 3.7 What "automatic" honestly means here

Because a System Restore is whole-system, reboot-requiring and 24h-throttled (DD-002), the
automatic path is restricted to **targeted, in-process undo of the reversible subset**.
`Restore-Computer` remains a **manually invoked, explicitly consented** escape hatch that
this feature will *arm and document* but never trigger by itself.

This is a deliberate narrowing of the literal request, and it is the safe reading of
"fully automatic": automatic in the sense that the user does not have to take recovery
actions for the reversible damage, **not** automatic in the sense that the tool will reboot
the machine unasked. This is open question Q1 for the approval gate.

---

## 4. Personas and entry points

| persona | entry point | expected behaviour |
|---|---|---|
| Cautious home user | Web UI → `CleanupPanel.tsx` → `/api/cleanup` (`ConfirmFile`) | sees an honest backup-status line (REQ-014); auto-rollback happens in-process; the UI shows the per-item verdict |
| IT admin, unattended | `clean-residuals.ps1 -ConfirmFile` headless | exit code carries the rollback outcome (10/11/12); logs are machine-readable |
| Admin, interactive | `confirm-cleanup.ps1` TUI | same as above, with the verdict rendered |
| Anyone recovering later | `rollback.ps1` (no `-Auto`) | read-only guidance, unchanged from today (AC-012 regression) |
| Anyone forcing recovery | `rollback.ps1 -Auto` | consumes a self-validating journal (used by T3 next-launch recovery) |

## 5. Success criteria

Mapped 1:1 to the acceptance criteria in `requirements-auto-rollback.md` §2.4
(AC-001 … AC-014). The feature is done when all 14 pass, coverage stays ≥ 80%, and the
admin drill (below) succeeds.

**Mandatory real-machine drill before SHIP** (per the user's standing instruction to run
admin drills): create a synthetic vendor key + startup value + PATH entry + directory,
let the tool clean them, force a failure, and verify the automated rollback restores the
registry items and the PATH entry, and honestly reports the file/service items as
`not_restorable`.

---

## 6. Design decisions

| id | decision | rationale | alternatives considered |
|----|----------|-----------|-------------------------|
| DD-001 | Targeted per-item `.reg` export instead of relying on the pre-flight backup | the pre-flight backup has **zero** overlap with deleted paths (§1.1) | extend the pre-flight export to cover whole hives (enormous, slow) |
| DD-002 | Never auto-invoke `Restore-Computer` | whole-system rollback destroys unrelated post-snapshot work and forces a reboot | auto-restore (rejected: dangerous); no restore point at all (worse) |
| DD-003 | Startup **values**: export the parent Run/RunOnce key to a temp `.reg`, record `value_name`; on restore, import then let the recorded value be re-checked | deleting the shared Run key is forbidden (`clean-residuals.ps1:475-477`), and value-scoped `reg export` does not exist | delete/recreate whole Run key (catastrophic); skip value backup (loses restorability) |
| DD-004 | Journal bound to `run_id` + cleanup-log timestamp; stale journals refused | prevents rolling back the wrong run (R-4) | single fixed filename (ambiguous across runs) |
| DD-005 | Auto-rollback **on** by default, with `-NoAutoRollback` | user explicitly chose fully-automatic | off by default (contradicts the request) |
| DD-006 | File/service/task deletions recorded as `not_restorable` with reasons | prevents the tool from lying about undo (R-1) | silently ignore them (dishonest) |
| DD-007 | Build on the ADR-001 `[ref]$ExitCode` contract | all 10 scripts already use it; gate 11 + hermeticity tests enforce it | reintroduce `exit` in `Main` (forbidden by ADR-001) |
| DD-008 | Capture the verbatim Machine PATH once per run, before the first PATH removal | D-1: no pre-image today, and the per-item rewrite is racy | save per item (identical value, wasteful); don't save (unrecoverable) |
| DD-009 | `path_deleted` records the real outcome (`deleted` vs `renamed:<name>`) | D-2: tier-4 renames are logged as successful deletions | keep the misleading log; treat all renames as failures |
| DD-010 | Precondition requires a *valid, fresh* backup, and `create-restore-point.ps1` must fail loudly when it could not protect | D-3/D-4: gate only checks directory existence; backup script exits 0 on total failure | keep fail-open (unacceptable for a recoverability promise) |
| DD-011 | `CleanupPanel.tsx:305` becomes conditional on real backup status | §1.4: the UI promises a backup that may not exist | leave the copy (actively misleading) |
| DD-012 | `clean-residuals.ps1` returns a distinct non-zero code when `summary.failed > 0` | currently always 0 (§1.2), so no caller — UI included — can detect partial failure | keep exit 0 and require log parsing everywhere |

---

## 7. Risks and mitigations

Carried from `requirements-auto-rollback.md` §5; the two critical ones are structurally
addressed above: **R-1** by DD-006 + the pre-cleanup warning (AC-013), **R-2** by DD-002 + AC-007.

Additional risk introduced by this design:

| id | risk | mitigation |
|----|------|------------|
| R-8 | An extra `reg export` per deleted key adds runtime | keys are tiny; measure in the drill; skip export when key is already absent (`clean-residuals.ps1:495` already queries first) |
| R-9 | Journal/backup dir not created when System Restore is unavailable | journal creation is **independent** of restore-point success — this is the whole point |

---

## 8. Open questions for the approval gate

These are the decisions I need from you before BUILD. The first one is the central product
decision in the whole feature.

1. **Q1 — what does "automatic" mean?** I recommend: automatic **in-process targeted undo**
   of the reversible subset (registry + PATH), with `Restore-Computer` available only as a
   manually-invoked, reboot-requiring escape hatch that the tool arms and documents but
   never fires by itself. The alternative — truly unattended whole-system restore — means the
   tool would **reboot your machine and revert unrelated changes**, which I do not think you
   want. Please confirm §3.7.
2. **Q2 — what triggers it?** I recommend `summary.failed > 0` (T2), plus crash-recovery when
   a journal exists (T3), and **never** on pre-flight failures (T1). Note the grill proposed
   a stricter rule (any single failure) and separately warned that rolling back a 300-item
   run because one service had an access-denied error is itself destructive. I lean toward
   T2 **with a per-item** undo rather than an all-or-nothing revert — i.e. we undo exactly
   the items we could not complete plus the ones tied to them, not the whole run.
3. **Q3 — DD-003 startup values**, and **DD-005** (auto-rollback on by default with
   `-NoAutoRollback`).
4. **Q4 — the four extra defects (D-1…D-4, DD-008…DD-012).** They are prerequisites, not
   optional polish: without D-1 there is nothing to restore for PATH; without D-2 the journal
   mis-describes what happened; without D-3/D-4 the tool keeps claiming protection it does not
   have. Fixing them enlarges this sprint beyond "add rollback". **Do you want them inside
   this sprint, or split into a follow-up?** (I recommend inside: rollback built on a lying
   log and a fake backup gate would be worse than none.)
5. **Q5 — AC-013**: a prominent pre-cleanup warning when protection is unavailable, and the
   `CleanupPanel.tsx:305` copy fix.
6. **Q6 — System Restore is unverifiable here** without elevation (the grill flagged this
   honestly: `Get-ComputerRestorePoint` returns access-denied for us). Verifying the
   restore-point path end-to-end needs the admin drill you authorised. Confirm you want that
   drill to include an actual restore-point creation attempt.

---

## 9. Non-goals

Restoring deleted file/dir **contents** (Option C, deferred); cross-run rollback;
functional restoration of services/tasks; any automatic `Restore-Computer`.
