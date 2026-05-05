# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0.0] - 2026-05-06

### Changed
- **SKILL.md**: Completely rewritten agent workflow — zero cognitive burden for users
  - Agent auto-triggers on semantic intent, no modes/parameters exposed
  - Agent auto-executes scan pipeline, user only sees results
  - Per-item/per-category selection confirmation (not just all/nothing)
  - Three mandatory confirmation gates (scan→select→DryRun→execute)
  - Natural language selection support ("腾讯会议的清理", "1-5项", "Safe全清")
  - RFC 2119 keywords (MUST/MUST NOT) enforce agent behavior

### Added
- Delphi Review configuration: `.delphi-config.json` with GLM-5.1, Kimi-k2.6, MiniMax experts
- OpenCode agent definitions for `delphi-reviewer-architecture`, `delphi-reviewer-technical`, `delphi-reviewer-feasibility`

### Fixed
- xgate issue #48: Documented missing `.delphi-config.json` initialization step

## [1.2.0.0] - 2026-05-05

### Added
- `confirm-cleanup.ps1` non-interactive mode: `-NonInteractive`, `-AutoSelect <safe|caution|all>`, `-SelectIds '[...]'` for AI agent dialog workflow
- Dialog-based cleanup workflow in SKILL.md: agent presents summary, user confirms via conversation, no window switching required

### Fixed
- `confirm-cleanup.ps1`: `[Environment]::UserInteractive` check no longer blocks `-NonInteractive` mode
- Unit tests: fixed Pester v5 variable scoping in `Script Syntax Validation` (foreach → -TestCases)

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
