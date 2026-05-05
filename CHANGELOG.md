# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0.0] - 2026-05-05

### Added
- Interactive cleanup confirmation (`confirm-cleanup.ps1`): paginated item selection, risk filtering, batch select/deselect
- `-ConfirmFile` parameter on `clean-residuals.ps1`: accepts user-confirmed ID list from `confirm-cleanup.ps1` output
- Four-tier robust file deletion fallback (`takeown` → `icacls` → `cmd rd` → `MoveFileEx` deferred delete) for locked/permission-denied files
- Unit tests for `ConfirmFile` integration (filtering + Danger skip)

### Fixed
- `scan-uninstalled.ps1`: eliminated 100% false positives by stripping InstallLocation quotes, skipping MsiExec entries, requiring both conditions
- `generate-report.ps1`: fixed ID duplication bug (520 unique IDs now) by replacing `[ref]` counter with hashtable
- `scan-residuals.ps1`: fixed Ghost Tasks false positives (56→0) with `ExpandEnvironmentVariables` and bare-exe skip
- `clean-residuals.ps1`: fixed PS 5.1 variable type constraint conflict (`$itemsToClean` vs `[string]$ItemsToClean` parameter)
- `clean-residuals.ps1`: fixed `Where-Object` single-item `.Count` returning hashtable key count instead of element count
- `create-restore-point.ps1` / `clean-residuals.ps1`: unified backup path to project root

## [1.0.0.0] - 2026-05-04

### Added
- Initial release: Windows residual cleaner skill
- Multi-source installed software index (Registry, winget, scoop, chocolatey, MSI, UWP)
- Comprehensive residual scanning: registry, filesystem, ghost services, scheduled tasks, COM/Shell extensions, startup entries, PATH entries
- Risk classification (Safe/Caution/Danger) with unique IDs
- Four cleanup modes (A/B/C/D) + DryRun
- System restore point + registry backup before cleanup
- Whitelist defense-in-depth
