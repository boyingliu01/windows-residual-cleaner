# DESIGN REVIEW PAYLOAD (Round 4) - auto-rollback

You are reviewing a DESIGN document for a Windows residual-cleaner auto-rollback feature.
The R1 requirements review ran 22 rounds WITHOUT reaching consensus and was released with
recorded dissent (see the note at the end). Your job now is to judge the DESIGN document
as an implementation plan: is it buildable, are its decisions justified, does it contradict
itself or the verified facts about Windows?

## VERIFIED FACTS (measured on the real machine - treat as ground truth)

- Runtime baseline is PowerShell 5.1; the pre-commit test gate runs Pester under pwsh 7.
- reg export of the 3 Uninstall trees has ZERO overlap with the 7 path shapes that cleanup
  actually deletes. The existing 'registry backup' therefore protects nothing that gets
  deleted. This is the headline finding that motivates the whole feature.
- A reg export -> reg delete -> reg import round trip was proven by execution to fully
  restore a value including nested subkeys (376-byte .reg).
- Get-ComputerRestorePoint and vssadmin list shadowstorage both fail without elevation;
  SystemRestorePointCreationFrequency is NOT set (default 24h throttle).
- In PS 5.1, Move-Item -Force is delete-then-move, NOT an atomic replace.
- In PS 5.1, ConvertFrom-Json does not unroll a top-level array, so @(x | ConvertFrom-Json)
  has Count 1. Writing @($null) gives Count 1. Writing [array](if ...) is a parse error.
- sc.exe delete on an already-absent service returns 1060 (idempotent success), not 0.
- The current cleanup exits 0 even when items fail (live evidence: summary.failed=1 with
  exit code 0).

## REVIEW TASK

Answer EXACTLY these questions, with concrete reasoning:
1. Is the design implementable as written on PowerShell 5.1? Name any construct that will
   not work, and say what it should be instead.
2. Are the exit codes (0/1/2/3/10/11/12/13/14/15) mutually exclusive and reachable? Name any
   code that cannot be triggered, or any pair that can both apply to one run.
3. Is the T3 (crash-recovery) protocol sound? Specifically: can a run rewrite the same
   journal it is trying to recover, and is the completion marker written on every normal
   exit path?
4. Does the design keep its promise boundary (never claim more safety than it can
   mechanically prove)? Quote any place where it overclaims.
5. What is the single highest-risk part of this design, and what test would falsify it?

Be specific and cite section numbers (e.g. 3.5.3) or REQ/AC ids from the spec below.

---

# DESIGN DOCUMENT

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

```json
{
  "journal_version": 1,
  "run_id": "9f2c1a44-7b30-4e6d-9c11-2a5e8d0b7c31",
  "started_at": "2026-10-02T14:31:07",
  "completed_at": null,
  "cleanup_log_path": "D:\\...\\cleanup-log.json",
  "cleanup_log_sha256": null,
  "cleanup_log_timestamp": null,
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

The 24-hour window is configurable and must be documented. **User-facing text must not claim
"we can always reliably restore."** This is the honest trade-off the user approved in spirit
when choosing in-process targeted rollback over whole-system restore.

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


---

# SPECIFICATION (revision 20, 33 REQ / 96 AC / 19 DD) - for cross-checking

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
        若目标文件尚不存在（首次写入），则退化为「写临时文件 + `[System.IO.File]::Move`」——
        `File.Move` 是**单次原子重命名且目标存在即失败**，因此同样没有「目标缺失」窗口；
        这正是它与 `Move-Item -Force` 的本质区别（后者先删目标再移动）。
        已实测：目标存在时 `File.Replace` 直接抛异常，故首次写入必须走 `File.Move`；
        且 `Replace(tmp, target, $null)` 会抛「The path is not of a legal form」，
        因此每一代备份路径都必须显式命名（`.prev`），不得传 null。
        绝不原地重写 JSON——崩溃在写入中途会留下畸形日志，而 REQ-027 会拒绝畸形日志，
        反而使 T3 恢复不可用。
        **最后一次完好状态的具体协议**：每次成功原子替换后保留上一代副本
        `rollback-journal.prev.json`——由 `File.Replace(tmp, target, prev)` **在同一次原子操作内**
        把旧目标保存为 `.prev`，**不要**手工「先复制当前文件为 `.prev`，再替换」：
        那会多出一次非原子拷贝，既慢又可能把 `.prev` 写成半新内容，
        反而破坏「上一代完好状态」这一保证。当下一次读取
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
             这是为安全付出的代价，必须在设计中写明并让用户可见。
             **时间原点是唯一的**：窗口起点恒为日志的 `created_at`（日志创建时刻），
             终点为**本次恢复尝试时刻**——T2 下即进程内回滚时刻，
             T3 下即**下次启动发现该日志的时刻**。因此「崩溃后超过 24h 才再次启动」
             必然超窗、降级人工，这是有意为之而非缺陷；
             用户必须在 UI 与文档中看到这一限制；
           - **可检测的「外部变更迹象」**（任一命中即降级为 conflict/需人工，**不**自动恢复）：
             (i) 目标当前存在但与备份内容不同（规则 2）；
             (ii) **仅适用于注册表键/value 条目**：备份的**注册表父键**的 LastWriteTime
                  **严格晚于该父键的恢复端聚合基线** `MAX(parent_baseline)`
                  （path/service/task 条目跳过本检查——它们 `parent_baseline` 恒为 null，
                  也没有「注册表父键」语义）。
                  **比较对象只有这一个**：恢复端聚合基线。**不**与「本轮开始时间」比较——
                  因为我们自己的删除**必然**会更新父键 LastWriteTime，
                  用开始时间作比较会让本工具的变更被误判为外部变更，规则 3 将永不成立。
                  **阶段划分（避免与 REQ-027 写入侧混淆）**：`parent_baseline` 由**清理阶段**
                  逐条写入（见 REQ-027/AC-095）；**恢复阶段只读不写**——把该父键所有条目的
                  `parent_baseline` 读出取 MAX，在**对任何条目执行恢复写入之前只比较一次**，
                  然后恢复全部通过判定的条目。故「聚合」是恢复端的**读取**行为，
                  不是恢复端的写入行为。**两个恢复入口都适用**（进程内 T2 与下次启动 T3），
                  只有清理阶段才是逐条写后比较。
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
          **但「证据不完整」不得成为无限容忍**：报告与 UI 必须**显著列出**
          evidence_incomplete 的条目数与 item_id 清单（与未修复清单分开呈现），
          让用户自行决定是否接受；且当**证据不完整的条目占本轮可恢复条目的多数**时，
          判为 `restored_with_low_confidence` 并按需人工确认，
          不得以「0 条 restore_failed」静默宣告完全成功。
          **「多数」而非「全部」**：若要求「全部条目都证据不完整」才算低置信，
          则一份 100 条日志里只要有 1 条证据齐备，其余 99 条不完整也仍算「完全成功」，
          这与「显著列出 evidence_incomplete」的告警意图相矛盾。
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
        **三个分支并列**（AC-036 逐项断言）：(a) 恢复未完全成功（存在 restore_failed）；
        (b) 自证失败或重复 run_id（REQ-019 Step 4b）；
        (c) 候选日志歧义（created_at 平局或多个不同时刻的未完成日志）。
        **unjournaled 条目的处理优先级**（REQ-005 与 REQ-030 在此处必须有明确优先级，
        否则实现者不知该只用 durable 日志还是也该用进程内证据）：
        对**已成功落盘**的条目 —— 一律按日志回滚；
        对**未能落盘的最后一条** —— 优先用**进程内证据**尽力恢复该条（它在落盘失败瞬间
        仍在内存中、且是本轮自己做的变更），并**始终**标记为 `restore_failed(unjournaled)`，
        因为该恢复**没有 durable 保证**、进程崩溃即丢失。
        即：进程内证据**补充**而非**取代** durable 日志；两者都可用，
        但只有 durable 部分能被称为「已记录」。
        15=**本轮持久化记录写入失败**，已按 fail-closed 停止。涵盖三个时点：
        (i) 运行中回滚日志落盘失败（REQ-005）；
        (ii) 回滚已结束、但写未修复清单失败（REQ-030）；
        (iii) 回滚已结束、但写完成标记或消费标记（`rollback-consumed.json`）失败（REQ-019/REQ-031）。
        **注意「本轮写失败」归 15，不归 14**：14 只描述「**上一轮**留下的日志能否被安全消费」，
        且总是在前置检查之前判定。二者的判据是**失败发生在本轮运行之内还是之前**，
        因此互斥、不可能同时成立（14 在读取阶段就中止，走不到任何写入）。
        14 分支 (d) 已删除——它原本与 15(iii) 争抢同一事件，实现者无法判定该返回哪个。
        两个标记都写失败的**善后**仍是先写 `rollback-consumed.failed.json`
        （使此后的运行不自动重复消费、必须 `-AcknowledgeConflicts`），但**本次**退出码是 15。
        AC-036 必须为 15 的三个时点各有一条用例，并断言同一事件**只**得到 15。
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
        日志**顶层字段**必须齐备（否则自证失败）：`journal_version`、`run_id`（guid，
        与该轮清理日志一致）、`created_at`（ISO 8601，**日志创建/本轮开始时刻**，
        REQ-024 的 24h 窗口以此为起点）、`completed_at`（初始 null）、
        `machine_fingerprint`、`machine_path_original`（清理前的 Machine PATH 原值，
        未改 PATH 时为 null）、`cleanup_log_path`、`cleanup_log_timestamp`、
        `cleanup_log_sha256`（三者同 null 或同非 null，见 AC-083）、
        `backup_dir`、`entries`。
        `created_at` 的语义固定为**日志创建时刻**（等价于本轮清理开始时刻），
        不是「清理结束时刻」——它与结束时刻可能相差数十分钟，
        用错会让 24h 窗口判定偏移。
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
        **JSON 读写必须遵守 PS 5.1 的三条陷阱规则**（否则候选计数与条目计数会静默出错，
        且在本机 pwsh 7 下不复现，极易漏检）：
        (a) `ConvertFrom-Json` **不展开顶层数组**——必须写成
        `$doc = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json` 然后
        `$entries = @($doc.entries)`；直接 `@(... | ConvertFrom-Json)` 会让 `Count` 恒为 1，
        于是「多份候选日志」被当成 1 份，REQ-030 的歧义判定永久失效。
        (b) `@($null)` 的 Count 是 **1**——条目列表为空时必须显式判 `$null` 再规整，
        否则「0 个条目」会被读成「1 个条目」。
        (c) 单条结果经 `Where-Object` 后 `.Count` 是该对象的**属性个数**而非元素个数，
        聚合前一律用 `@()` 强制数组化。
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

    - id: REQ-034
      description: |
        REQ-024 迹象 (ii) 依赖注册表父键的 LastWriteTime，但**受管 API 不暴露它**：
        `[Microsoft.Win32.RegistryKey]` 只提供 SubKeyCount/View/Handle/ValueCount/Name，
        在 PS 5.1 与 pwsh 7 下均无 LastWriteTime，`Get-Item HKCU:\...` 同样没有（已实测）。
        因此必须提供顶层辅助函数 `Get-RegistryKeyLastWriteTime`，通过 P/Invoke
        `advapi32!RegQueryInfoKey` 取 FILETIME 并用 `DateTime.FromFileTimeUtc` 转换。
        两个实现约束（均已实测踩坑）：(a) 必须传 `$key.Handle.DangerousGetHandle()`
        ——`.Handle` 返回 `SafeRegistryHandle` 而非 `IntPtr`，直接传会抛类型转换异常；
        (b) 辅助函数不得使用 `ref` 返回成员，PS 5.1 的 C# 编译器不接受。
        该函数在 PS 5.1 与 pwsh 7 下行为必须一致（双引擎测试）。
        若取不到时间戳，迹象 (ii) 按「证据不完整」处理（跳过并标注），
        不得因取不到时间戳而拒绝整份日志。
      priority: high
      addresses: "AC-097, REQ-024, REQ-027"

    - id: REQ-035
      description: |
        DD-003 的裁剪函数入参是 `reg export` 产生的 `.reg` 文本，而 `reg export` 写出的是
        **UTF-16LE + BOM**。PS 5.1 的 `Get-Content` 默认按 ANSI/Default 读取，
        会把内容读成夹 NUL 的乱码，使裁剪必然失败。
        因此规定：读取 `.reg` 必须显式 `-Encoding Unicode`
        （或 `[System.IO.File]::ReadAllText($p, [System.Text.Encoding]::Unicode)`），
        写回同样使用 Unicode；该约束适用于导出、裁剪与导入三处。
      priority: high
      addresses: "AC-098, DD-003"

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
        **逐码明确「正常结束」的判定**（否则实现者无法判断 12/13 要不要写标记）：
        - 0 / 10 / 12 / 13：**正常结束，写 `completed_at`**。
          12 是「没有可用的回滚记录」（日志缺失/不可读）、13 是「用户要求不回滚」——
          两者都是本轮已按预期跑完的终态；日志若存在就必须标记完成，
          否则下次启动会把一个已结束的轮次当成未完成的 T3 反复重试。
          注意 12 下日志可能**根本不存在**：此时属于「无可标记对象」，
          而非「漏写标记」，实现必须区分这两种情况，不得把前者当失败。
        - 11：**唯一例外**，不写 `completed_at`，并必须持久化未修复清单。
        - 1 / 2 / 3：发生于前置检查/输入阶段，**尚未改动系统**；
          若日志已创建则写 `completed_at`，未创建则无对象可标记。
        - 14：在读取上一轮日志阶段中止，**不是本轮的结束**，不写 `completed_at`。
        - 15：持久化已失败，**无法**可靠写标记；尽力而为并在退出信息中说明。
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
          ② 文件**已不存在**：无论 `cleanup_log_sha256` 是 null 还是非 null，
          一律**不**拒绝该候选、也**不**据其抑制（读不到 `summary.failed`，无法判断成败），
          交 Step 3 自证；自证通过则按正常 T3 恢复。
          **为什么合并这两种情况**：实现只能观察到「文件不在」，
          无法从「文件缺失」反推日志里 sha256 字段当初为何取那个值，
          因此区分它们会造出一个不可实现的分支。T3 的合法性由 Step 3 自证负责，
          不由 Step 2.5 承担；**只有 ① 允许抑制**。
          **抑制 ≠ 消费。** Step 2.5 只**判定**「本轮清理其实已完成」这一结论，
          **不得**在此写 `completed_at`、也**不得**写 `rollback-consumed.json`——
          消费动作统一发生在 **Step 3 自证通过之后**（Step 4a）。
          否则一份**解析成功但自证失败**（例如重复 run_id、字段非法）的日志
          会在 Step 3 之前就被标记为已消费，从而**永久绕过** REQ-027 的自证，
          且再也无法重试。抑制结论以标志位在进程内传递到 Step 4a 生效。
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
        **两套信号不一致时的仲裁规则（写进正文，不能只留在 AC 里）**：
        T2 下两套来源都可能存在，若它们推出的预期值**不一致**，
        一律**以回滚日志为准**（它记录的是本轮实际发生的变更）并在报告中标注不一致；
        不得因两者不一致就拒绝恢复，也不得默默择一而不报告。
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
      criteria: .reg 裁剪函数抛异常、产出不可解析的 .reg、**或静默产出含多于一个 value 定义的 .reg（后置校验检出）**时，一律视为导出失败：断言该 value 未被删除（注册表中仍存在）且记为 export_failed(trim_error / trim_multivalue)
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
      criteria: 落盘失败后立即停止后续破坏性操作；对已成功落盘的条目按日志回滚；未记录的变更被明确标记为 restore_failed(unjournaled)（而非静默留下或按规则 4 静默跳过），且只能从**进程内证据**尽力恢复。退出码 15 且不再判定 10/11/12/13。禁止声称「回到上一个落盘点」——进程内没有时间机器、该证据不 durable、崩溃即丢
      test_type: integration
    - id: AC-053
      requirement: REQ-019
      criteria: 完成标记写入失败时不得宣告恢复完成、本轮中止并返回 **15**（不是 14——14 只用于「启动时判定上一轮日志无法安全消费」）；若旁路标记 rollback-consumed.json 写入成功，则下次运行不重复消费该日志。两个标记都写失败时先写 rollback-consumed.failed.json（小型持久失败标记），下次运行不自动重复消费、必须 -AcknowledgeConflicts 确认后才继续。另断言同一次标记写失败只产生 15 一个退出码
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
      criteria: 仅有回滚日志（无清理日志）时，PATH 预期值由 machine_path_original 减去 state=mutation_succeeded 的 path_entry_removed 条目推出；machine_path_original 为 null 且存在**成功的** path_entry_removed 时自证失败并返回 14（无原值不可恢复）；machine_path_original 为 null 且**无成功的** path_entry_removed 时自证通过且跳过 PATH 恢复（本轮未改 PATH）。**两套信号等价性仅对 T2 断言**（清理日志存在时）：清理日志中 `action=path_entry_removed` 且 `success=true` 的条目，与回滚日志中同 `target` 且 `state=mutation_succeeded` 的条目必须一一对应；不一致时以**回滚日志**为准并在报告中标注。**T3 下清理日志不存在（REQ-016），无第二套信号可比对**，故该等价性断言不适用于 T3——若强行断言将永远无法覆盖
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
      criteria: kind 只接受 registry_key/startup_value/path_entry/path_deleted/service/task 六种取值，其它取值自证失败；路径类必须区分 path_deleted（文件/目录删除，not_restorable）与 path_entry（PATH 环境变量条目移除，可经 REQ-021 恢复），二者不得混用；item_id 等于 "<kind>:<规范化 target>"（规范化算法复用 REQ-027 的唯一权威定义），同一 target 在日志与 REQ-030 清单中产生同一 item_id 并可互相回指
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
      criteria: 新写入的 cleanup-log.json 含 run_id 且与该轮回滚日志的 run_id 相同；**该 run_id 绑定只在 Step 2.5 分支 ①（清理日志存在且可读）生效**——T3 下清理日志本就不存在、无 run_id 可比对，走分支 ②（不抑制、交 Step 3 自证）；缺 run_id 的历史清理日志同样走证据不足分支并在报告中说明原因。断言：不存在「要求 T3 下比对 run_id」的用例（那与 REQ-016 对 T3 的定义矛盾）
      test_type: unit
    - id: AC-089
      requirement: REQ-019
      criteria: 两个消费标记都写失败时写入 rollback-consumed.failed.json；下次启动该候选**不**被自动重复消费，必须 -AcknowledgeConflicts 确认后才继续
      test_type: integration
    - id: AC-090
      requirement: REQ-019
      criteria: Step 2.5 的两个分支逐项断言：(a) 文件可读且哈希与 run_id 均匹配→可抑制；(b) 文件不存在（无论 sha256 取值）→不抑制、不拒绝，交 Step 3 自证。另断言 REQ-031 的抑制只发生在分支 (a)
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
      criteria: 证据不完整但通过规则 3/4 的条目判定为 restored(evidence_incomplete)、计入已恢复、不使本轮返回 14；仅 conflict/unjournaled/export_failed 才算 restore_failed。另断言：报告中显著列出 evidence_incomplete 的条目数与 item_id（与未修复清单分开）；全部条目都证据不完整时判为 restored_with_low_confidence 并需人工确认，不得静默宣告完全成功
      test_type: integration
    - id: AC-095
      requirement: REQ-027
      criteria: parent_baseline 与该条目 mutation_succeeded 的日志落盘是同一次原子写（不另开一次写）；断言落盘失败只使**该条目**基线缺失，先前已落盘条目的基线仍存在且可用
      test_type: unit
    - id: AC-096
      requirement: REQ-019
      criteria: 自证失败/不可解析的候选在 Step 4b 下写**候选级**清单（unrepaired 为空数组、顶层 candidate_unparseable=true 与 backup_dir），且该清单先于任何旁路标记写入
      test_type: integration
    - id: AC-097
      requirement: REQ-034
      criteria: Get-RegistryKeyLastWriteTime 在 PS 5.1 与 pwsh 7 下均返回合理时间戳；对可写键执行一次 SetValue 后其父键时间戳严格变大（证明信号可用）；取不到时间戳时迹象 (ii) 退化为「证据不完整」而不拒绝整份日志
      test_type: integration
    - id: AC-098
      requirement: REQ-035
      criteria: 用 -Encoding Unicode 读取 reg export 产物后能正确解析出 value 定义；用默认编码读取同一文件则得到乱码（证明该约束必需而非风格偏好）；导出→裁剪→导入全链路在 Unicode 下成功
      test_type: integration
    - id: AC-099
      requirement: REQ-001
      criteria: reg export 产物首行与父键行不参与 REQ-024 的结构比较；裁剪函数若静默产出含兄弟 value 的 .reg，调用方的后置校验必须检出并改判为 export_failed
      test_type: unit
    - id: AC-100
      requirement: REQ-026
      criteria: 退出码 15 的三个时点各有用例：(i) 运行中回滚日志落盘失败；(ii) 回滚结束后未修复清单写入失败；(iii) 回滚结束后完成标记或消费标记写入失败。三者都返回 15，且 15 优先于 10/11/12/13。另断言 14 与 15 互斥：同一失败事件不得同时对应两个退出码——本轮写入失败→15，上一轮日志无法安全消费→14
      test_type: integration
    - id: AC-071
      requirement: REQ-005
      criteria: 两条写入路径都要断言，且都不得出现「目标不存在」的窗口：(a) 首次写入（目标不存在）用 File.Move（单次原子重命名，目标存在即失败）；(b) 第二次及以后用 File.Replace(tmp, target, prev)，断言目标路径在替换过程中始终存在且上一代副本被保留。另断言未使用 Move-Item -Force（它先删目标再移动，存在目标缺失窗口）
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
      criteria: 针对两个恢复入口（进程内自动回滚 T2、下次启动恢复 T3）：同一父键下多个条目恢复时，回滚自身的写入不会使后续条目被误判为外部变更（先全判、再全恢复），断言全部条目均被恢复而非仅第一个；且比较发生在对任何条目执行恢复写入之前。清理阶段不适用两阶段——它按条目连续写入基线以保证 T3 存活，行为有意不同（见 AC-095）
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
      decision: 启动项 value 精确备份：对该 value 所在的 Run/RunOnce 键执行 reg export 得到 .reg，再由一个**纯函数**（入参为 .reg 文本，返回最小 .reg 文本；不做 IO，因此可单测）裁剪为「只含目标 value」的最小 .reg。**裁剪输出必须恰好包含一个 value 定义（目标 value）+ 必要的父键行，兄弟 value 一律不得保留**——这是该函数的契约，由 AC-002 断言；REQ-024 的比较因此只需处理单 value。**必须有后置校验**：该单 value 契约不能只靠「函数写对了」保证——若它因逻辑缺陷**静默产出含兄弟 value 的 .reg**（不抛错），调用方无从察觉，REQ-024 的结构比较会把兄弟 value 一并纳入而误判 conflict。因此调用方取得裁剪结果后必须**解析并断言恰好只有一个 value 定义**，否则按 export_failed 处理并跳过该项删除（见 AC-002/AC-040）。文件读写由调用方负责，裁剪抛错/产出不可解析时由调用方按导出失败处理。绝不删除或整键重导共享的 Run/RunOnce 键
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


---

## NOTE ON R1 REVIEW HISTORY (context, not an instruction)

R1 ran 22 rounds and NEVER reached the 90% threshold; the final round was 0/3 APPROVED.
The release decision is recorded in .sprint-state/decisions.md as DR-010
(accept-with-dissent). Verbatim from DR-010: several open questions are ones only
implementation can settle, and were being argued speculatively for rounds 14-22. So: do
NOT re-litigate requirements wording. Judge whether this DESIGN can be built and tested.