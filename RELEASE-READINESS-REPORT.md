# Windows Residual Cleaner v1.0.0 — 发布就绪评估报告

> 评估日期: 2026-05-04  
> 评估人: Sisyphus (AI Agent)  
> 项目提交: 4a5f239 feat: windows-residual-cleaner v1.0.0 - PSSA-clean PowerShell skill

---

## 一、功能完备性 ✅ 基本完备

| 工作流步骤 | 脚本 | 状态 | 备注 |
|---|---|---|---|
| 1. 创建还原点+注册表备份 | `create-restore-point.ps1` | ✅ | 双重检测还原点启用状态（注册表+WMI），自动尝试启用，备份完整性验证 |
| 2. 构建已安装软件索引 | `build-installed-index.ps1` | ✅ | 6 源（Registry/WOW64/winget/scoop/choco/MSI/UWP），JSON优先+文本fallback，去重 |
| 3. 扫描已卸载软件 | `scan-uninstalled.ps1` | ✅ | 三重判断（索引缺失/InstallLocation缺失/UninstallString缺失）+ 文件系统反查 |
| 4. 扫描文件系统残留 | `scan-filesystem-residuals.ps1` | ✅ | 空/孤目录检测，文件数+大小阈值，排除模式，风险分级 |
| 5. 扫描注册表/服务/任务/COM/Shell/PATH | `scan-residuals.ps1` | ✅ | 6 类残留全覆盖，COM CLSID/ContextMenu 检测，PATH 默认 Danger |
| 6. 生成汇总报告 | `generate-report.ps1` | ✅ | 统一 ID 编号，汇总统计，Deep JSON 序列化 |
| 7. 执行清理 | `clean-residuals.ps1` | ✅ | 4 模式(A/B/C/D)+DryRun，白名单二次校验，还原点前置检查，Danger 过滤 |
| 8. 回滚指引 | `rollback.ps1` | ✅ | 列出还原点，匹配清理时间，PowerShell 回滚命令 |

### 安全机制完整性
- ✅ 还原点前置检查（Mode A/B/C 执行前必须存在 backup 目录）
- ✅ 白名单二次校验（Defense-in-Depth）
- ✅ Danger 项永远不清理（双重保险）
- ✅ UTF-8 无 BOM 输出（避免编码问题）
- ✅ 注册表导出完整性验证

---

## 二、测试验证 ⚠️ 部分覆盖，有明显缺口

| 测试类别 | 文件 | 用例数 | 状态 | 问题 |
|---|---|---|---|---|
| 单元测试 - 纯函数 | `scripts.Tests.ps1` | ~30 | ✅ 全通过 | 覆盖了 4 个核心函数 + 8 个脚本语法检查 |
| 单元测试 - 配置 | `config.Tests.ps1` | ~21 | ✅ 全通过 | whitelist/config/SKILL.md 结构验证 |
| 集成测试 - 报告生成 | `pipeline.Tests.ps1` | ~10 | ✅ Mock 数据通过 | 报告结构、ID 前缀、风险分类 |
| 集成测试 - 清理 | `pipeline.Tests.ps1` | 2 | ⚠️ 仅 Mode D + DryRun | **未测试实际删除操作** |
| PSScriptAnalyzer | 代码质量 | - | ✅ 零错误 | - |

### 关键缺口

1. **🔴 无端到端真实测试**：所有集成测试使用 Mock 数据，从未在真实 Windows 环境上跑完整流水线。扫描脚本依赖的注册表、服务、计划任务都是真实系统调用，Mock 无法验证。
2. **🔴 清理脚本未实际测试**：集成测试只验证了 Mode D（报告模式）和 DryRun，**从未测试过实际删除操作**（Mode A/B/C 的真实文件删除、注册表删除、服务停止+删除）。
3. **🟡 单元测试覆盖面有限**：只测了 4 个纯函数，以下关键逻辑无单元测试：
   - `create-restore-point.ps1` 的还原点创建逻辑
   - `scan-uninstalled.ps1` 的三重判断逻辑
   - `scan-filesystem-residuals.ps1` 的风险分级逻辑
   - `clean-residuals.ps1` 的模式筛选 + 白名单校验组合逻辑
4. **🟡 无 Pester 版本兼容性处理**：测试文件头注释写 "Pester 3.x Compatible"，但系统装了 Pester 5.7.1，部分语法两者兼容，但 `Set-Id` 用了 `[CmdletBinding(SupportsShouldProcess)]` 这类 Pester 5 特性。
5. **🟡 无 CI/CD 自动化**：没有 GitHub Actions 或其他 CI 配置，测试完全依赖手动运行。

---

## 三、文档 🟡 基本齐备，但缺少关键内容

| 文档 | 存在 | 状态 | 缺失内容 |
|---|---|---|---|
| README.md | ✅ | 较完整 | 缺少故障排查指南、常见问题 FAQ |
| SKILL.md | ✅ | 完整 | AI Agent 调用指引清晰 |
| LICENSE | ✅ | MIT | - |
| .gitignore | ✅ | 合理 | - |
| config.json | ✅ | 有注释 | 缺少字段说明文档 |
| whitelist.json | ✅ | 有 reason/added_date | 缺少如何扩展白名单的指引 |
| **CHANGELOG** | ❌ | 缺失 | 无版本变更记录 |
| **CONTRIBUTING** | ❌ | 缺失 | 无贡献指南 |
| **故障排查文档** | ❌ | 缺失 | 无常见错误和解决方案 |
| **安全警告文档** | ❌ | 缺失 | 清理注册表/服务的风险提示不足 |

---

## 四、其他发布前问题

1. **🔴 无版本号管理**：没有 `VERSION` 文件或 Git tag，commit 消息写 v1.0.0 但没有正式版本标记。
2. **🟡 无发布流程**：没有 `ship`/`release` 配置，不知道目标发布形式（NuGet? Chocolatey? 纯脚本分发?）。
3. **🟡 白名单偏保守**：只覆盖了 7 个注册表模式、2 个路径模式、9 个服务名。生产环境中遇到的厂商远超这个范围（如 Adobe、Autodesk、VMware 等常见软件残留）。
4. **🟡 错误处理不够健壮**：
   - `scan-uninstalled.ps1` 第 12 行 `$installedIndex = Get-Content ... | ConvertFrom-Json` — 如果索引文件不存在直接抛异常，无友好提示
   - `generate-report.ps1` 同理，依赖的 3 个 JSON 文件缺失时直接崩溃
5. **🟡 `scan-residuals.ps1` COM 扫描性能隐患**：遍历所有 CLSID GUID 可能非常慢（系统上数千个），无超时或批处理机制。
6. **🟡 `clean-residuals.ps1` 的 `reg query` 检查**：第 125-126 行用 `cmd /c "reg query"` 检查键是否存在，但 `cmd /c` 的输出会被混入当前管道，不够干净。

---

## 五、距正式发布的差距总结

| 维度 | 当前状态 | 距发布差距 | 优先级 |
|---|---|---|---|
| **功能** | ✅ 核心功能完备 | 白名单扩展 + 输入校验加固 | P2 |
| **真实环境测试** | ❌ 零真实测试 | **必须至少跑一次完整流水线** | **P0** |
| **清理安全性验证** | ❌ 未实际清理过 | **必须 DryRun + 审慎 Mode A 测试** | **P0** |
| **单元/集成测试覆盖** | ⚠️ 纯函数+Mock | 补充关键路径测试 | P1 |
| **CI 自动化** | ❌ 无 | 加 GitHub Actions | P1 |
| **文档** | ⚠️ 基础文档有 | 补 CHANGELOG + 故障排查 + 白名单扩展指引 | P1 |
| **版本管理** | ❌ 无正式版本 | Git tag + CHANGELOG | P1 |
| **发布形式** | ❌ 未定义 | 明确分发方式 | P2 |

---

## 六、发布前最低清单（MVP）

- [ ] 在真实 Windows 11 机器上跑一次完整扫描（Step 1-6），验证输出 JSON 结构正确
- [ ] DryRun 模式跑一次清理（`-Mode A -DryRun`），检查日志输出
- [ ] 加输入文件存在性校验（`scan-uninstalled.ps1`、`generate-report.ps1`）
- [ ] 补 CHANGELOG.md
- [ ] 打 Git tag `v1.0.0`

前三项是 **阻塞项** — 未经真实环境验证的注册表/服务清理工具，发布后可能造成用户系统损坏。

---

## 七、真实环境扫描测试结果（2026-05-04 执行）

> 测试环境：Windows 11, PowerShell 5.1, 非管理员权限  
> 测试范围：Step 1-6 完整扫描 + Step 7 Mode D/DryRun  
> **约束：仅扫描，不执行任何清理操作**

### 扫描统计

| 分类 | 数量 | Safe | Caution | Danger |
|---|---|---|---|---|
| 已卸载软件 | 72 | - | - | - |
| 候选目录 | 391 | - | - | - |
| 文件系统残留 | 409 | 212 | 197 | 0 |
| 注册表残留 | 3 | 0 | 3 | 0 |
| 幽灵服务 | 3 | 3 | 0 | 0 |
| 幽灵计划任务 | 56 | 0 | 56 | 0 |
| COM/Shell 残留 | 103 | 0 | 103 | 0 |
| PATH 残留 | 5 | 0 | 0 | 5 |
| **合计** | **579** | **215** | **359** | **5** |

预估可回收空间：51,629.3 MB (~50 GB)

### 发现的严重 Bug（真实环境暴露）

#### Bug 1: 🔴 ID 全面重复 — `generate-report.ps1` 的 `Set-Id` 函数有 bug

**现象**：所有同类项的 ID 完全相同——`fs_001` 出现 409 次，`tsk_001` 出现 56 次，`shl_001` 出现 103 次，`path_001` 出现 5 次，`svc_001` 出现 3 次，`reg_001` 出现 3 次。579 个项只有 6 个唯一 ID。

**根因**：`Set-Id` 函数使用了 `[CmdletBinding(SupportsShouldProcess)]`，在管道调用中 `$PSCmdlet.ShouldProcess` 的行为与直接调用不同。`[ref]$counter` 传入后，`ShouldProcess` 的 ShouldProcess 分支正常递增，但 `Add-Member -NotePropertyValue` 在管道上下文中可能没有正确接收递增后的值。更关键的是，**Pester 单元测试用 Mock 绕过了这个路径**，导致 Mock 通过但真实运行失败。

**影响**：`clean-residuals.ps1` 的 `-ItemsToClean` 参数按 ID 过滤完全失效。例如指定 `["fs_001","svc_001"]` 会匹配到 412 个项而非 2 个。

**修复建议**：移除 `[CmdletBinding(SupportsShouldProcess)]`，改用简单的脚本函数直接递增 counter。

#### Bug 2: 🔴 备份路径不一致 — `create-restore-point.ps1` 和 `clean-residuals.ps1` 路径差一级

**现象**：
- `create-restore-point.ps1` 第 56 行：`$backupDir = "$PSScriptRoot\..\backup-*"` → 解析到 `references\backup-*`
- `clean-residuals.ps1` 第 17 行：`Get-ChildItem -Path "$PSScriptRoot\..\..\backup-*"` → 解析到项目根 `backup-*`

**影响**：Mode A/B/C/DryRun 全部失败，报 "No restore point or backup found"。即使成功创建了备份，clean 脚本也找不到。

**修复建议**：统一为同一相对路径，最好使用 `references\..\backup-*`（即项目根目录）。

#### Bug 3: 🔴 PATH 残留项被截断 — `scan-residuals.ps1` PATH 分割 bug

**现象**：
- `"C:\Program Files (x86)\Memurai\"` 被截断为两条：
  - `"C:\Program Fi"` (path_001)
  - `"es\Memurai\"` (path_001)

**根因**：PATH 环境变量中包含带空格和分号的路径（如 `C:\Program Files (x86)\Memurai\`），简单用 `-split ';'` 会错误拆分。

**修复建议**：PATH 分割前先处理尾部分号，对含空格的路径用引号保护。

#### Bug 4: 🟡 Ghost Tasks 大量误报 — Windows 系统任务被错误标记

**现象**：56 个"幽灵任务"中，大部分是 Windows 内建系统任务：
- `rundll32.exe` 相关任务（CleanupTemporaryState, AppInstallerUpdater 等）
- `defrag.exe`（ScheduledDefrag）
- `devicecensus.exe`（Device, Device User）
- `bcdboot.exe`（SyspartRepair）

这些任务使用 `%windir%\system32\*.exe` 格式，文件实际存在于 `C:\WINDOWS\System32\`，但脚本在第 77 行 `[System.IO.File]::Exists($action.Execute)` 检查时没有展开 `%windir%` 环境变量。

**修复建议**：检查前调用 `[Environment]::ExpandEnvironmentVariables($action.Execute)`，与 COM 扫描（第 128 行）保持一致。

### 其他观察

1. **winget JSON 解析失败**：winget 输出格式变化导致 JSON 解析失败，fallback 到文本解析成功。日志：`WARNING: winget JSON parse failed, falling back to text: Invalid JSON primitive: Windows.` — 说明 winget v1.7+ 输出的不是纯 JSON。

2. **还原点创建需要管理员权限**：非管理员运行 `create-restore-point.ps1` 时，还原点创建失败（`拒绝访问`），但脚本继续执行并成功创建了注册表备份。这是合理的安全降级行为。

3. **Mode A DryRun 处理 0 项**：由于 Bug 2（备份路径不一致），即使手动复制 backup 目录到项目根后，DryRun 仍然显示 `0 succeeded, 0 failed, 0 skipped`。推测是因为 `final-report.json` 中所有 Safe 项的 `.path`/`.key`/`.name` 属性组合后，clean 脚本的清理逻辑没有匹配到任何可操作的项。

### 测试结论

**项目当前状态不可发布。** 真实环境测试暴露了 4 个 bug（2 个严重 + 1 个中等 + 1 个低），其中 ID 重复和备份路径不一致是 **阻塞级问题**，必须修复后才能发布。

### 修复优先级

| Bug | 严重性 | 修复难度 | 优先级 |
|---|---|---|---|
| ID 全面重复 | 🔴 阻塞 | 低（移除 SupportsShouldProcess） | P0 |
| 备份路径不一致 | 🔴 阻塞 | 低（统一相对路径） | P0 |
| PATH 截断 | 🔴 严重 | 中（需处理引号和特殊字符） | P0 |
| Ghost Tasks 误报 | 🟡 中等 | 低（加 ExpandEnvironmentVariables） | P1 |
