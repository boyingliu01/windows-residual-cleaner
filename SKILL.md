---
name: windows-residual-cleaner
description: Scan and clean up residual files, registry entries, ghost services, scheduled tasks, COM extensions, and shell context menu handlers from uninstalled software on Windows. Use when users mention "cleanup residuals", "clean uninstalled software", "registry cleanup", "ghost services", "empty directories cleanup", "system cleanup after uninstall", "clean up leftover files", or "remove software traces". Requires Administrator privileges. Two-phase: scan→report→confirm→clean.
---

# Windows Residual Cleaner

Scan and clean up residuals left by uninstalled software on Windows systems.

## Compatibility
- **Platform:** Windows 10/11
- **Requires:** PowerShell 5.1, Administrator privileges
- **Execution Mode:** Interactive - scan first, report, then user confirms cleanup

## Workflow

1. Create system restore point + backup registry
2. Build installed-software index (baseline from 6 sources: registry, winget, scoop, chocolatey, MSI, UWP)
3. Scan uninstalled software registry entries (cross-validation with index + filesystem reverse lookup)
4. Scan filesystem for empty/orphan directories
5. Scan registry, services, tasks, COM extensions, shell handlers, PATH for residuals
6. Generate JSON report with risk classification (Safe/Caution/Danger) and unique IDs
7. **Dialog-based confirmation** (within this conversation — no window switching):
   - Agent reads `final-report.json` and presents a summary table (by category and risk)
   - Agent asks user: "Safe: X items (~Y GB), Caution: Z items. Choose: (1) Clean all Safe (2) Review Caution by category (3) DryRun preview (4) Skip"
   - User replies with choice (e.g., "clean all safe", "preview first", "also clean caution filesystem items")
   - Agent translates intent into parameters and runs `confirm-cleanup.ps1 -NonInteractive -AutoSelect <safe|caution|all>`
   - Agent runs `clean-residuals.ps1 -ConfirmFile confirmed-ids.json -DryRun` to preview
   - User confirms, then agent runs `clean-residuals.ps1 -ConfirmFile confirmed-ids.json` to execute
8. **Legacy interactive mode** (standalone Windows Terminal only):
   - If user prefers TUI: `confirm-cleanup.ps1` (paginated, `Read-Host` based)
   - Then `clean-residuals.ps1 -ConfirmFile confirmed-ids.json`

## Safety First

- Before ANY cleanup: System restore point must be created (or user explicitly opted out)
- Cleanup script checks for restore point existence before proceeding
- Never delete: Items matching whitelist patterns in `references/config/whitelist.json`
- Risk levels: Safe (auto-clean) / Caution (confirm) / Danger (report only)
- All PATH residuals classified as Danger by default
- Defense-in-Depth: whitelist re-checked at cleanup time

## User Confirmation Flow

### Primary: Dialog-based confirmation (recommended, no window switching)
1. **Scan phase**: Generate comprehensive report with risk classification
2. **Agent presents summary**: Reads `final-report.json`, shows count/size by category and risk
3. **User chooses via conversation**:
   - "Clean all Safe items" → agent runs `confirm-cleanup.ps1 -NonInteractive -AutoSelect safe`
   - "Also clean Caution filesystem items" → agent runs with `-AutoSelect caution` or `-SelectIds '[...]'`
   - "Preview first" → agent runs `clean-residuals.ps1 -ConfirmFile confirmed-ids.json -DryRun`
   - "Skip" → no cleanup performed
4. **Cleanup phase** (`clean-residuals.ps1 -ConfirmFile confirmed-ids.json`):
   - Only confirmed IDs are processed
   - Danger items never cleaned even if accidentally confirmed
   - Four-tier deletion fallback for locked files

### Legacy: Interactive TUI (requires standalone Windows Terminal)
- `confirm-cleanup.ps1` (without `-NonInteractive`): paginated `Read-Host` based UI
- Suitable when user prefers direct terminal interaction
- Not compatible with OpenCode built-in terminal (Read-Host flash-crashes)

### Legacy modes (direct cleanup without confirmation):
- Option A: Auto-clean all Safe items
- Option B: Auto-clean Safe items, Caution items require manual review
- Option C: Full review mode (confirm each item)
- Option D: View report only, no cleanup

## AI Agent Usage

All scripts MUST be invoked via `bash` calling PowerShell with `-ExecutionPolicy Bypass`:

```bash
# Step 1: Create restore point (MUST run first)
powershell -ExecutionPolicy Bypass -File "references/scripts/create-restore-point.ps1"

# Step 2: Build installed software index
powershell -ExecutionPolicy Bypass -File "references/scripts/build-installed-index.ps1"

# Step 3: Scan uninstalled software
powershell -ExecutionPolicy Bypass -File "references/scripts/scan-uninstalled.ps1"

# Step 4: Scan filesystem residuals
powershell -ExecutionPolicy Bypass -File "references/scripts/scan-filesystem-residuals.ps1"

# Step 5: Scan registry/services/tasks/COM residuals
powershell -ExecutionPolicy Bypass -File "references/scripts/scan-residuals.ps1"

# Step 6: Generate consolidated report
powershell -ExecutionPolicy Bypass -File "references/scripts/generate-report.ps1"

# Step 7: Dialog-based confirmation (agent handles interaction, no window switching)
# Agent presents summary, user replies with choice, agent exports confirmed IDs
# Example: user says "clean all safe items" → agent runs:
powershell -ExecutionPolicy Bypass -File "references/scripts/confirm-cleanup.ps1" -NonInteractive -AutoSelect safe

# Step 8: Preview and execute cleanup
# DryRun preview first (recommended):
powershell -ExecutionPolicy Bypass -File "references/scripts/clean-residuals.ps1" -ConfirmFile confirmed-ids.json -DryRun
# After user confirms preview, execute for real:
powershell -ExecutionPolicy Bypass -File "references/scripts/clean-residuals.ps1" -ConfirmFile confirmed-ids.json

# Step 9: If needed, show rollback instructions
powershell -ExecutionPolicy Bypass -File "references/scripts/rollback.ps1"
```

**Output convention:** All JSON files output to skill root directory (`windows-residual-cleaner/`).

**Important:**
- All scripts require Administrator privileges
- Scripts MUST be run in the order shown above (dependencies exist)
- Steps 4 and 5 can run in parallel after Step 3 completes
- Always read the generated `final-report.json` and present a summary to the user before cleanup
- The `-DryRun` flag is recommended for first-time users to preview changes
