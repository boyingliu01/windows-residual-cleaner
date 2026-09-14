# Changelog

All notable changes to this project will be documented in this file.

## [1.4.0.0] - 2026-09-14

v2 演进：将 `sprint/2026-06-04-01` 分支的脚本架构重构与健壮性改进移植到主线，
合并 master 上独立的 ghost_task / 活跃目录误报 / 死 PATH 修复，并纳入 Web UI 源码。

### Added
- **`run-all.ps1`**: 统一扫描流水线入口（还原点 → 索引 → 扫描 → 报告），SCAN ONLY，退出码逐步传播
- **`setup.ps1`**: 运行环境自检脚本（PowerShell 版本 / 管理员权限 / 依赖模块）
- **Web UI 源码入库**：Vite + React + TypeScript 前端与 Express 后端 (`ui/`)，含组件与单测
- **`main-flow.Tests.ps1`** 集成测试套件：每个脚本至少一次真实 `Main` 执行（fixture 驱动 + 真实只读扫描），修复了此前对 `git status` 不可见的问题
- `rollback.ps1`：增强备份文件列表与还原状态输出，补 warning-only 权限检查

### Changed
- **函数/执行分离**：所有脚本顶层执行代码封装进 `function Main` + 点源守卫（`$MyInvocation.InvocationName -eq '.'` 时 `return`），使 dot-source 只加载函数、无副作用
- **标准化退出码**：`0=成功, 1=错误, 2=权限, 3=依赖`
- **分级权限检查**：写操作脚本强制管理员（缺失即 `exit 2`），只读扫描脚本仅告警
- `clean-residuals.ps1`：三阶段批处理（停止服务 → 删除文件/服务 → 删除注册表），并与 master 的 ghost_task / path_entry 清理分支合并
- `generate-report.ps1`：修复 `candidate_directories` 死代码，纳入最终报告
- `AGENTS.md`：移植脚本架构规范、退出码表、权限分级、`run-all.ps1` 用法与执行守卫模式

### Fixed
- `scan-uninstalled.ps1`：环境变量展开、跳过 `MsiExec.exe /X{GUID}`、以两段式加权判定替换原 OR 逻辑（消除已安装软件被误报为已卸载）
- `scan-filesystem-residuals.ps1`：递归统计文件数（修复顶层 0 文件但子目录有内容的活跃程序目录被误判为残留）；`EnumerateFiles` 单次递归同时算计数/大小/空判定（修复大目录超时）；受保护系统目录白名单
- `scan-residuals.ps1`：死 PATH 条目风险由 `danger` 降为 `caution`，使 `confirm-cleanup`/`clean-residuals` 可正常处理
- 单元测试点源完整脚本导致的挂起（winget/scoop/choco 经 `global:` 函数遮蔽）

### Testing & Quality
- Pester 5.x：**98/98 通过**；`references/scripts` 行覆盖率 66.4%
- PSScriptAnalyzer：配合项目 `PSScriptAnalyzerSettings.psd1`（排除 `PSReviewUnusedParameter` 误报）后 0 error / 0 warning；唯一真正死参数 `run-all.ps1 -Verbose` 已删除
- **覆盖率说明**：`references/scripts` 未达 80% 绝对阈值，主要由 `confirm-cleanup.ps1`（34.5%）结构性拖累——其为全屏交互式选择 TUI，绝大部分分页/键盘导航分支在非交互模式下不可执行；可单测的扫描/报告/回滚脚本已达 73–96%。写操作与系统交互分支按 AGENTS.md 测试策略需真实管理员环境做集成验证（已在 2026-09-11 管理员端到端运行通过：exit 0，306 items，Safe 160 / Caution 146 / Danger 0），CI 中不投入脆弱的控制台 mock 强拉覆盖率。

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
