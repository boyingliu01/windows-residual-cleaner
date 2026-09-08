# Windows Residual Cleaner

Scan and clean up residuals left by uninstalled software on Windows systems.

## Features

- **Multi-source installed software index** — Registry, winget, scoop, chocolatey, MSI, UWP (6 sources)
- **Comprehensive residual scanning** — Registry keys, filesystem directories, ghost services, scheduled tasks, COM/Shell extensions, startup entries, PATH entries
- **Risk classification** — Safe / Caution / Danger with unique IDs per item
- **Safety first** — Automatic system restore point + registry backup before cleanup
- **Defense-in-depth** — Whitelist re-checked at cleanup time
- **Four cleanup modes** — Auto-clean Safe (A), Safe+Caution review (B), Full review (C), Report only (D)
- **Dry-run** — Preview what would be deleted without making changes
- **Rollback guidance** — Lists available restore points and backup locations

## Compatibility

- **Platform:** Windows 10/11
- **Requires:** PowerShell 5.1, Administrator privileges
- **Execution Mode:** Interactive — scan first, report, then user confirms cleanup

## Quick Start

```powershell
# 0. Environment check (optional)
powershell -ExecutionPolicy Bypass -File setup.ps1

# 1. Scan: restore point + installed index + all residual scans + consolidated report
powershell -ExecutionPolicy Bypass -File references/scripts/run-all.ps1
#    Skip the restore point (cleanup then becomes unrecoverable):
powershell -ExecutionPolicy Bypass -File references/scripts/run-all.ps1 -SkipRestorePoint
#    Manual equivalent, in order:
#      create-restore-point.ps1 → build-installed-index.ps1 → scan-uninstalled.ps1
#      → scan-filesystem-residuals.ps1 → scan-residuals.ps1 → generate-report.ps1

# 2. Confirmation (choose one)
# 2a. Dialog-based (AI agent handles interaction, no window switching):
#     Agent reads report, asks user, then runs non-interactive export:
powershell -ExecutionPolicy Bypass -File references/scripts/confirm-cleanup.ps1 -NonInteractive -AutoSelect safe
#     Or export specific IDs:
powershell -ExecutionPolicy Bypass -File references/scripts/confirm-cleanup.ps1 -NonInteractive -SelectIds '["fs_001","fs_002"]'
# 2b. Interactive TUI (standalone Windows Terminal only — Read-Host crashes in OpenCode):
powershell -ExecutionPolicy Bypass -File references/scripts/confirm-cleanup.ps1
# → Outputs confirmed-ids.json with user-selected items

# 3. Cleanup confirmed items (use -ConfirmFile from step 2)
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -ConfirmFile confirmed-ids.json
# Dry-run preview (recommended first):
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -ConfirmFile confirmed-ids.json -DryRun
# Legacy mode (without interactive confirmation):
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -Mode D

# 4. If needed, show rollback instructions
powershell -ExecutionPolicy Bypass -File references/scripts/rollback.ps1
```

## Project Structure

```
windows-residual-cleaner/
├── SKILL.md                          # OpenCode skill definition
├── README.md                         # This file
├── LICENSE                           # MIT License
├── setup.ps1                         # Environment compatibility check
├── .gitignore
├── references/
│   ├── config/
│   │   ├── config.json               # Scan thresholds and target directories
│   │   └── whitelist.json            # Protected patterns (never delete)
│   └── scripts/
│       ├── run-all.ps1               # Unified scan pipeline entry point (scan only)
│       ├── build-installed-index.ps1 # Build installed software index
│       ├── create-restore-point.ps1  # Create restore point + registry backup
│       ├── scan-uninstalled.ps1      # Scan uninstalled registry entries
│       ├── scan-filesystem-residuals.ps1 # Scan empty/orphan directories
│       ├── scan-residuals.ps1        # Scan registry/services/tasks/COM/Shell
│       ├── generate-report.ps1       # Consolidate reports with risk IDs
│       ├── confirm-cleanup.ps1     # Interactive cleanup confirmation
│       ├── clean-residuals.ps1       # Execute cleanup (4 modes + DryRun + ConfirmFile)
│       └── rollback.ps1              # Show rollback instructions
└── tests/
    ├── unit/
    │   ├── scripts.Tests.ps1         # Unit tests for pure functions
    │   └── config.Tests.ps1          # Unit tests for config validation
    └── integration/
        ├── main-flow.Tests.ps1       # Per-script Main execution against fixtures
        └── pipeline.Tests.ps1        # End-to-end pipeline tests
```

## Risk Levels

| Level | Behavior | Example |
|-------|----------|---------|
| **Safe** | Auto-cleanable | Empty directory, ghost service with missing binary |
| **Caution** | Requires confirmation | Vendor registry key, COM extension with missing DLL |
| **Danger** | Report only, never auto-delete | PATH entry (may be referenced by other software) |

## Safety

- Before ANY cleanup: System restore point must exist (or user explicitly opted out)
- All registry changes are backed up to `backup-<timestamp>/` directory
- Whitelist patterns are re-checked at cleanup time (defense-in-depth)
- Danger-rated items are never cleaned, even in Mode A

## Running Tests

```powershell
# Install Pester if not present
Install-Module Pester -Force -SkipPublisherCheck

# Run unit tests
Invoke-Pester tests/unit/

# Run integration tests (requires admin)
Invoke-Pester tests/integration/
```

## Code Quality

All scripts pass PSScriptAnalyzer with zero errors and zero warnings:

```powershell
Invoke-ScriptAnalyzer -Path references/scripts -Recurse -Settings PSScriptAnalyzerSettings.psd1
```

The settings file excludes `PSReviewUnusedParameter` only: every script declares its
entry parameters in a top-level `param()` block and consumes them inside `function Main`,
which that rule cannot follow across scopes. The single genuinely unused parameter it
flagged (`run-all.ps1 -Verbose`) was removed instead of suppressed.

## License

MIT License — see [LICENSE](LICENSE).
