---
name: windows-residual-cleaner
description: "Scan and clean up residual files, registry entries, ghost services, scheduled tasks, COM extensions, and shell context menu handlers from uninstalled software on Windows. Use when users mention 'cleanup residuals', 'clean uninstalled software', 'registry cleanup', 'ghost services', 'empty directories cleanup', 'system cleanup after uninstall', 'clean up leftover files', or 'remove software traces'. Requires Administrator privileges. Agent-driven workflow: user expresses intent in natural language, agent auto-scans and presents itemized list, user selects specific items to clean, agent executes with mandatory confirmation gates."
---

# Windows Residual Cleaner

Scan and clean up residuals left by uninstalled software on Windows systems.

## Compatibility
- **Platform:** Windows 10/11
- **Requires:** PowerShell 5.1, Administrator privileges
- **Execution Mode:** Agent-driven — user expresses intent, agent handles everything, user only confirms which items to clean

## Agent-Driven Workflow

When the user says anything like "帮我清理卸载残留", "清理下卸载软件的垃圾", "remove leftover files", the agent **MUST** follow this flow exactly. Do NOT ask the user to choose modes or parameters.

### Phase 1: Auto-Scan (Agent executes silently)
1. Create system restore point + backup registry
2. Build installed-software index (baseline from 6 sources)
3. Scan uninstalled software registry entries
4. Scan filesystem for empty/orphan directories
5. Scan registry, services, tasks, COM extensions, shell handlers, PATH for residuals
6. Generate JSON report with risk classification (Safe/Caution/Danger) and unique IDs

**Agent behavior:** Execute all scripts sequentially. If any script fails, stop and report the error to the user. Do NOT proceed with partial results.

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
> 确认执行实际清理吗？（此操作不可逆，但可通过还原点恢复）"

**Mandatory rule:** Agent MUST NOT skip DryRun. User MUST explicitly confirm after seeing DryRun results.

### Phase 6: Execute Cleanup

After user confirms DryRun, agent executes:
```bash
powershell -ExecutionPolicy Bypass -File "references/scripts/clean-residuals.ps1" -ConfirmFile confirmed-ids.json
```

Then report results:
> "清理完成：
> - 成功：14 项
> - 失败：1 项（fs_003 Bonjour mdnsNSP.dll 被服务锁定，已重命名为 ~mdnsNSP.dll.deleted，重启后自动删除）
> - 跳过：0 项
> - 实际释放：11.8GB
>
> 如需回滚，可使用还原点：backup-2026-05-06-xxx"

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
2. Agent MUST mention that successful items are already cleaned
3. Agent MUST remind user of restore point for rollback

## What User Never Needs to Know

The agent MUST NOT expose these technical details to the user:
- PowerShell parameters (`-NonInteractive`, `-AutoSelect`, `-SelectIds`)
- File names like `confirm-cleanup.ps1` or `clean-residuals.ps1`
- Risk level terminology unless explaining item details
- JSON file names or ID formats (unless user asks)
- Mode letters (A/B/C/D)

The user only needs to express intent in natural language and confirm selections.

## Legacy: Direct Script Invocation

If a developer or advanced user wants to run scripts directly without agent orchestration:

```bash
# Step 1: Create restore point (MUST run first)
powershell -ExecutionPolicy Bypass -File "references/scripts/create-restore-point.ps1"

# Step 2-6: Build index + scan all sources + generate report
powershell -ExecutionPolicy Bypass -File "references/scripts/build-installed-index.ps1"
powershell -ExecutionPolicy Bypass -File "references/scripts/scan-uninstalled.ps1"
powershell -ExecutionPolicy Bypass -File "references/scripts/scan-filesystem-residuals.ps1"
powershell -ExecutionPolicy Bypass -File "references/scripts/scan-residuals.ps1"
powershell -ExecutionPolicy Bypass -File "references/scripts/generate-report.ps1"

# Step 7: Non-interactive export by risk level
powershell -ExecutionPolicy Bypass -File "references/scripts/confirm-cleanup.ps1" -NonInteractive -AutoSelect safe

# Step 8: Cleanup with DryRun preview
powershell -ExecutionPolicy Bypass -File "references/scripts/clean-residuals.ps1" -ConfirmFile confirmed-ids.json -DryRun
```

**Output convention:** All JSON files output to skill root directory (`windows-residual-cleaner/`).

**Important:**
- All scripts require Administrator privileges
- Scripts MUST be run in order (dependencies exist)
- Steps 4 and 5 can run in parallel after Step 3 completes
