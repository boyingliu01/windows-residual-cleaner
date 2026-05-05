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
# 1. Create restore point (MUST run first)
powershell -ExecutionPolicy Bypass -File references/scripts/create-restore-point.ps1

# 2. Build installed software index
powershell -ExecutionPolicy Bypass -File references/scripts/build-installed-index.ps1

# 3. Scan uninstalled software
powershell -ExecutionPolicy Bypass -File references/scripts/scan-uninstalled.ps1

# 4. Scan filesystem residuals
powershell -ExecutionPolicy Bypass -File references/scripts/scan-filesystem-residuals.ps1

# 5. Scan registry/services/tasks/COM residuals
powershell -ExecutionPolicy Bypass -File references/scripts/scan-residuals.ps1

# 6. Generate consolidated report
powershell -ExecutionPolicy Bypass -File references/scripts/generate-report.ps1

# 7. Interactive confirmation (select items to clean)
powershell -ExecutionPolicy Bypass -File references/scripts/confirm-cleanup.ps1
# → Outputs confirmed-ids.json with user-selected items

# 8. Cleanup confirmed items (use -ConfirmFile from step 7)
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -Mode A -ConfirmFile confirmed-ids.json
# Dry-run preview:
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -Mode A -ConfirmFile confirmed-ids.json -DryRun
# Legacy mode (without interactive confirmation):
powershell -ExecutionPolicy Bypass -File references/scripts/clean-residuals.ps1 -Mode D

# 9. If needed, show rollback instructions
powershell -ExecutionPolicy Bypass -File references/scripts/rollback.ps1
```

## Project Structure

```
windows-residual-cleaner/
├── SKILL.md                          # OpenCode skill definition
├── README.md                         # This file
├── LICENSE                           # MIT License
├── .gitignore
├── references/
│   ├── config/
│   │   ├── config.json               # Scan thresholds and target directories
│   │   └── whitelist.json            # Protected patterns (never delete)
│   └── scripts/
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
Invoke-ScriptAnalyzer -Path references/scripts -Recurse
```

## License

MIT License — see [LICENSE](LICENSE).
