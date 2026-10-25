---
name: windows-residual-cleaner
description: "Scan and clean up residual files, registry entries, ghost services, scheduled tasks, COM extensions, and shell context menu handlers from uninstalled software on Windows. Use when users mention 'cleanup residuals', 'clean uninstalled software', 'registry cleanup', 'ghost services', 'empty directories cleanup', 'system cleanup after uninstall', 'clean up leftover files', or 'remove software traces'. Requires Administrator privileges for deletion; scanning alone does not. Agent-driven workflow: user expresses intent in natural language, agent auto-scans and presents itemized list, user selects specific items to clean, agent executes with mandatory confirmation gates and automatic rollback."
---

# Windows Residual Cleaner

Scan and clean up residuals left by uninstalled software on Windows systems.

## Compatibility

- **Platform:** Windows 10/11
- **Requires:** PowerShell 5.1 (also runs on PowerShell 7), Administrator privileges **for deletion only**
- **Execution Mode:** Agent-driven — user expresses intent, agent handles everything, user only confirms which items to clean

## Privilege model (read before running anything)

**The orchestrator requires Administrator; the individual read-only scans do not.**

This distinction matters because the common guidance ("scan first, elevate later") only
works if you call the scan scripts individually — `run-all.ps1` gates on admin
**unconditionally**, before it even looks at `-SkipRestorePoint`, because step 1 of the
pipeline creates a restore point.

| Stage | Scripts | Admin needed |
|-------|---------|--------------|
| Full pipeline | `run-all.ps1` | **Yes** — aborts with exit code `2` otherwise. `-SkipRestorePoint` does **not** bypass this |
| Individual scans | `build-installed-index.ps1`, `scan-uninstalled.ps1`, `scan-filesystem-residuals.ps1`, `scan-residuals.ps1`, `generate-report.ps1` | **No** — these only `Write-Warning` when unelevated |
| Confirm | `confirm-cleanup.ps1` | No |
| Delete | `clean-residuals.ps1`, `create-restore-point.ps1` | **Yes** — abort with exit code `2` |

So the honest shape is:

- **Normal use:** run `run-all.ps1` **elevated** — you want the restore point, and that is the
  single strongest safety net available. Elevation here is expected, not incidental.
- **Preview without elevating:** call the individual `scan-*.ps1` scripts in order, then
  `generate-report.ps1`. Results are equivalent for reporting; you simply will not have a
  restore point, so do **not** proceed to deletion from this session — re-run elevated.


## Agent-Driven Workflow

When the user says anything like "帮我清理卸载残留", "清理下卸载软件的垃圾", "remove leftover files", the agent **MUST** follow this flow exactly. Do NOT ask the user to choose modes or parameters.

### Phase 1: Auto-Scan (Agent executes silently)

```bash
powershell -ExecutionPolicy Bypass -File "references/scripts/run-all.ps1"
```

The pipeline runs these steps in order:
1. Create system restore point + backup registry
2. Build installed-software index (baseline from 6 sources)
3. Scan uninstalled software registry entries
4. Scan filesystem for empty/orphan directories
5. Scan registry, services, tasks, COM extensions, shell handlers, PATH for residuals
6. Generate JSON report with risk classification (Safe/Caution/Danger) and unique IDs

**Agent behavior:** `run-all.ps1` scans only — it never asks for confirmation and never cleans anything. If it exits non-zero, stop and report which step failed; do NOT proceed with partial results. Pass `-SkipRestorePoint` only when the user explicitly declines a restore point, and tell them cleanup is then unrecoverable.

### Phase 2: Present Itemized List (Agent shows, user selects)

After scan completes, the agent **MUST** read `final-report.json` and present a **grouped table** to the user:

```
=== 扫描结果 ===

【已卸载软件】2 项
  1. foobar2000 汉化版 | 风险: Safe | 残留: 注册表项 + 空目录
  2. Minisoft Toolbox   | 风险: Safe | 残留: 注册表项

【文件系统残留】163 项 (约 12GB)
  1. fs_001 | C:\ProgramData\Tencent\QQBrowser | Safe | 空目录 | 0MB
  2. fs_002 | C:\Users\AppData\Local\Temp\setup_xxx | Safe | 孤儿文件 | 45MB
  3. fs_003 | C:\Program Files\Bonjour | Caution | 服务DLL锁定 | 2MB
  ... (分页展示，每页 20 项)

【注册表残留】... 项
【计划任务】... 项
【PATH 残留】... 项 (Danger，仅展示不清理)

Danger 级别 5 项已列出但不可选择清理，仅作报告。
```

Then the agent **MUST** ask:
> "以上是我扫描到的残留项。请告诉我哪些确定可以清理？你可以说：
> - 编号：'1、3、5 项清理'
> - 名称：'腾讯会议相关的都清理'
> - 风险级别：'Safe 的全部清理'
> - 混合：'Safe 全清，Caution 的让我再看看'
> - 或者：'先 DryRun 预览一下 Safe 级别的'"

**Mandatory rules for Phase 2:**
- Agent MUST NOT auto-select any items. Wait for user input.
- Agent MUST present items in a readable format (table or grouped list).
- Danger items MUST be shown but clearly marked as "不可清理".
- If there are >20 items, agent MUST paginate or group by category.

### Phase 3: Parse User Selection (Agent translates natural language to IDs)

The user may respond in various ways. The agent **MUST** parse and map to item IDs:

| User says | Agent action |
|-----------|-------------|
| "1、3、5 项清理" | Map to fs_001, fs_003, fs_005 |
| "腾讯会议相关的都清理" | Match items where name/path contains "Tencent" or "QQ" |
| "Safe 的全部清理" | Select all items with risk='safe' |
| "除了第2项都清理" | Select all except item #2 |
| "先预览 Safe 级别" | Run DryRun on all safe items |
| "再看看 Caution 的" | Present Caution items separately |
| "不了，先不清理" | Stop workflow, report only |

**Agent MUST** after parsing, present the matched items back to the user for confirmation:
> "我理解了：你要清理以下 15 项（12 项 Safe + 3 项 Caution）：
> - fs_001: C:\...\Tencent (Safe)
> - fs_003: C:\...\Bonjour (Caution)
> ...
> 确认吗？"

**Mandatory rule:** Agent MUST NOT proceed to export or cleanup without this confirmation.

### Phase 4: Export Confirmed IDs (Agent internal step)

After user confirms selection, agent runs:
```bash
powershell -ExecutionPolicy Bypass -File "references/scripts/confirm-cleanup.ps1" -NonInteractive -SelectIds '["fs_001","fs_003",...]'
```

This generates `confirmed-ids.json`.

### Phase 5: DryRun Preview (Mandatory before actual cleanup)

Agent **MUST** run DryRun first:
```bash
powershell -ExecutionPolicy Bypass -File "references/scripts/clean-residuals.ps1" -ConfirmFile confirmed-ids.json -DryRun
```

Then present DryRun results:
> "DryRun 预览完成：
> - 将删除 15 个目录/文件
> - 将删除 3 个注册表项
> - 将停止并删除 1 个服务
> - 预计释放 12.5GB
>
> 确认执行实际清理吗？（此操作不可逆，但可自动回滚）"

**Mandatory rule:** Agent MUST NOT skip DryRun. User MUST explicitly confirm after seeing DryRun results.

### Phase 6: Execute Cleanup

After user confirms DryRun, agent executes (in an **elevated** session):
```bash
powershell -ExecutionPolicy Bypass -File "references/scripts/clean-residuals.ps1" -ConfirmFile confirmed-ids.json
```

Then report results, **including rollback status**:
> "清理完成：
> - 成功：14 项
> - 失败：1 项（fs_003 Bonjour mdnsNSP.dll 被服务锁定，已改名为 `~mdnsNSP.dll.deleted`，
>   **文件仍在磁盘上**，重启后自动删除）
> - 跳过：0 项
> - 实际释放：11.8GB
> - 自动回滚：已触发并完全成功（退出码 10）"

## Safety & Confirmation Gates

### Gate 1: After scan summary (Phase 2 → Phase 3)
- **Trigger:** Agent presents itemized list
- **Action:** Agent MUST wait for user to specify which items to clean
- **Skip consequence:** CRITICAL — agent MUST NOT auto-select or proceed

### Gate 2: After user selection parsing (Phase 3 → Phase 4)
- **Trigger:** Agent parsed user intent into item list
- **Action:** Agent MUST re-present matched items and ask "确认吗？"
- **Skip consequence:** CRITICAL — agent MUST NOT export IDs without explicit confirmation

### Gate 3: After DryRun preview (Phase 5 → Phase 6)
- **Trigger:** DryRun results displayed
- **Action:** Agent MUST wait for user to confirm actual execution
- **Skip consequence:** CRITICAL — agent MUST NOT execute real cleanup without this confirmation

## What "deleted" actually means — and what it does not

Deletion goes through a **four-tier fallback** per item. Two of the tiers do **not** delete,
and the agent MUST report them honestly rather than summarising them as "cleaned":

| Tier | Attempt | Result |
|------|---------|--------|
| 1 | Standard delete | `deleted` — gone |
| 2 | `takeown` + `icacls`, then delete | `deleted` — gone |
| 3 | `cmd /c rd /s /q` | `deleted` — gone |
| 4 | **Rename** to `~<name>.deleted` | `renamed:<newname>` — **NOT deleted** |

**Tier 4 is a rename, not a deletion (REQ-002).** The content is still on disk under a new
name; a `MoveFileEx(...MOVEFILE_DELAY_UNTIL_REBOOT)` is scheduled so Windows removes it on
next restart. If you report it as "deleted", you have told the user something untrue about
their disk. Always say: renamed, still occupies space, removed on reboot.

A count summary MUST distinguish `deleted` / `renamed` / `failed` — never fold `renamed`
into the success count.

Practical caveat, measured: under normal Windows semantics the tier-4 success window is
nearly empty — if a file is locked hard enough to defeat tiers 1–3, the rename is usually
rejected too. Treat tier 4 as an honest last attempt, **not** as a guaranteed fallback.

## Automatic rollback

Every cleanup writes a journal before mutating anything. If some items fail, the run
**automatically rolls back** the changes it already made, and the exit code tells you how
that went. The agent MUST read the exit code and relay the rollback outcome, not just
"部分失败".

### Exit codes

| Code | Meaning | What the agent should say |
|------|---------|---------------------------|
| `0` | No failures | Done |
| `1` | General error (bad input, file not found) | Report the specific error |
| `2` | Permission denied (not elevated) | "需要管理员权限" and offer to re-run elevated |
| `3` | Required input JSON missing | Tell the user to run the scan first |
| `10` | Some items failed, **rollback fully succeeded** | Everything was undone; investigation still worth it |
| `11` | Some items failed, **rollback did NOT fully succeed** | ⚠️ Some changes are still applied — point at `rollback-result.json` |
| `12` | Some items failed, rollback journal missing/unreadable | ⚠️ Cannot confirm rollback; treat disk state as unknown |
| `13` | Some items failed, rollback was explicitly skipped (`-NoAutoRollback`) | ⚠️ Changes are permanent; that was the user's choice |
| `14` | **Previous** cleanup's journal could not be safely consumed — this run **never started** | Nothing was changed this run; previous run needs attention |
| `15` | Failed to persist the journal / unfixed list / completion marker | ⚠️ Recovery record may be incomplete — treat as unknown |

Priority when several apply: `14 > 15 > 0 > 13 > 12 > 1 > 11 > 10`.
Codes `14` and `15` are about *bookkeeping integrity*, not about whether the deletions
worked — do not report them as "cleanup failed".

### Auto-rollback CLI

`rollback.ps1` is the recovery entry point (not merely a report printer):

```bash
# Print available restore points and registry backups
powershell -ExecutionPolicy Bypass -File "references/scripts/rollback.ps1"

# Automatically roll back the last cleanup per the journal consumption protocol
powershell -ExecutionPolicy Bypass -File "references/scripts/rollback.ps1" -Auto

# Human exit for entries flagged as conflicts (external change detected)
powershell -ExecutionPolicy Bypass -File "references/scripts/rollback.ps1" -Auto -AcknowledgeConflicts
```

- `-Auto` maps journal outcomes onto the same `0/10–15` vocabulary; an **unknown** outcome
  maps to `14` (fail closed — a mapping table that was not updated must never declare success).
- `-AcknowledgeConflicts` is the explicit human exit for entries where the system changed
  underneath the journal. **Never pass it on the user's behalf without showing them the
  conflicting evidence first** — that is the whole point of the flag.
- `-NoAutoRollback` (on `clean-residuals.ps1`) skips *this run's* rollback only. The journal
  is still written and the next startup still tries to recover. Use it only when the user
  explicitly asks not to be rolled back.

## Optional: local browser UI

`ui/` contains a React UI plus a **local Express server** (`ui/server/`) that exposes
`/api/scan`, `/api/confirm`, `/api/cleanup`, `/api/restore-point` and friends.

**Read this before enabling it.** That server **spawns administrator-privileged, destructive
PowerShell**. It is designed accordingly — bound to loopback only (`127.0.0.1`, default port
`3456`), with an origin guard, a loopback-only `Host` check (defeats DNS rebinding), and
strict item-ID validation on `/api/confirm`. None of that makes it safe to expose: loopback
does **not** stop a browser, so any page the user has open can POST to it. The origin guard
exists precisely because of that.

- Do **not** change `HOST` away from `127.0.0.1`.
- Do **not** port-forward it, put it behind a reverse proxy, or run it on a shared machine.
- It is a convenience wrapper over the same scripts — the CLI flow above is the
  authoritative path. If you only need cleanup, you never need the server.

## Natural Language Triggers

The agent MUST recognize these intents and auto-start the workflow:
- "帮我清理卸载残留"
- "清理下卸载软件的垃圾"
- "remove leftover files from uninstalled software"
- "registry cleanup"
- "系统清理"
- "clean up residuals"

## Error Handling

If any scan script fails:
1. Agent MUST stop the workflow
2. Agent MUST report which script failed and why
3. Agent MUST NOT present partial results as if scan succeeded
4. Agent MUST suggest fix or retry

If cleanup script fails:
1. Agent MUST report which items failed and why
2. Agent MUST report the **rollback outcome** from the exit code (see table above)
3. Agent MUST NOT describe `renamed` items as deleted
4. Agent MUST remind the user of restore point / `rollback.ps1 -Auto` for recovery

## What User Never Needs to Know

The agent MUST NOT expose these technical details to the user:
- PowerShell parameters (`-NonInteractive`, `-AutoSelect`, `-SelectIds`, `-AcknowledgeConflicts`)
- File names like `confirm-cleanup.ps1` or `clean-residuals.ps1`
- Risk level terminology unless explaining item details
- JSON file names or ID formats (unless user asks)
- Mode letters (A/B/C/D)

The user only needs to express intent in natural language and confirm selections.

**Exception:** exit-code severity (`11`/`12`/`13`/`15` — "changes are still applied" or "state
unknown") is a *finding*, not an implementation detail. Translate it into plain language and
always surface it.

## Legacy: Direct Script Invocation

If a developer or advanced user wants to run scripts directly without agent orchestration:

```bash
# Step 1: Restore point + index + all scans + report (scan only, no cleanup)
powershell -ExecutionPolicy Bypass -File "references/scripts/run-all.ps1"

# Step 2: Non-interactive export by risk level
powershell -ExecutionPolicy Bypass -File "references/scripts/confirm-cleanup.ps1" -NonInteractive -AutoSelect safe

# Step 3: Cleanup with DryRun preview
powershell -ExecutionPolicy Bypass -File "references/scripts/clean-residuals.ps1" -ConfirmFile confirmed-ids.json -DryRun
```

**Output convention:** All JSON artifacts (`installed-software-index.json`, `final-report.json`,
`confirmed-ids.json`, `cleanup-log.json`, `backup-*`) are written to the **package root** —
i.e. two levels above `references/scripts/`, because every script resolves its default paths as
`$PSScriptRoot\..\..`.

This makes the layout load-bearing: **the scripts must stay at `<root>/references/scripts/`.**
If an installer flattens them into a single directory, `..\..` escapes the package and outputs
land in the parent — possibly another application's folder. If you must relocate them, pass
`-ReportPath` / `-OutputPath` / `-ConfirmFile` explicitly rather than moving
the tree.

Run commands from the package root so the documented relative paths resolve:

```bash
cd windows-residual-cleaner
powershell -ExecutionPolicy Bypass -File "references/scripts/run-all.ps1"
```

**Important:**
- Write scripts (`clean-residuals.ps1`, `create-restore-point.ps1`, `run-all.ps1`) abort with exit code 2 when not elevated; read-only scan scripts only warn.
- Exit codes: see the table above (`0/1/2/3` plus the `10–15` rollback codes).
- Scan scripts depend on each other's output, so invoke them through `run-all.ps1` unless you know why you are calling one directly.
- `rollback.ps1 -Auto` is the recovery path after a cleanup; run it without `-Auto` to just inspect available restore points and registry backups.

## Known limitations

- `confirm-cleanup.ps1`'s interactive TUI may exit immediately in some embedded terminals
  (it needs a real console for `Read-Host`). Use `-NonInteractive -SelectIds` instead.
- Cleaning HKLM values and the machine PATH requires an elevated session and cannot be
  exercised in ordinary CI; those branches are covered only by administrator-run drills.
- The drill scripts that create real services/registry objects are **not** distributed with
  this skill.
