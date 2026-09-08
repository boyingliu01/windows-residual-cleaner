# Windows Residual Cleaner — 全面发布级改造设计文档 v2

> **Round 1 评审后修订版** — 修复了 4 个 Critical Issues + 6 个 Major Concerns

## 概述

对半完成的 Windows 卸载残留清理 skill 进行全面评估和改造，目标：方便使用、实用、可分享给其他 Qoder AI 用户。

**目标用户**: Qoder AI 用户（通过 AI agent 驱动使用）
**发布标准**: 全面发布级 — 核心工作流 + 测试完善 + CLI 优先 + 文档完整

---

## 需求分析

### 目标用户画像

- 使用 Qoder 的开发者
- 在 Windows 上卸载软件后，用自然语言告诉 AI agent "帮我清理卸载残留"
- AI agent 自动执行扫描 → 展示结果 → 等待用户选择 → 执行清理
- 用户只做简单确认，不需要了解 PowerShell 参数、JSON 文件等内部细节

### 核心使用流程

```
用户说 "清理卸载残留"
  → Agent 执行 run-all.ps1（自动创建还原点 + 扫描 + 生成报告）
  → Agent 展示分组表格给用户
  → 用户用自然语言指定要清理的项
  → Agent 调用 confirm-cleanup.ps1 -NonInteractive -SelectIds [...]
  → Agent 执行 clean-residuals.ps1 -ConfirmFile -DryRun
  → 用户确认
  → Agent 执行 clean-residuals.ps1 -ConfirmFile
  → 报告结果
```

---

## 4 层同心圆架构

### Layer 0: Foundation（测试基础设施 — 所有 Layer 1 修改的前置依赖）

> **Delphi R1 修复 [C3]**: 原 Layer 2 的函数/执行分离被提升为 Layer 0，因为 Layer 1 的所有修改需要测试验证，不先解决测试超时就无法验证 Layer 1 的变更。

#### 0.1 函数/执行分离（修复 scripts.Tests.ps1 超时）

**根因**: 测试通过 dot-source 加载脚本时触发顶层代码执行（`Get-CimInstance`、`Get-ScheduledTask` 等），导致测试超时。

**修改方案**: 使用 `$MyInvocation.InvocationName` 检测（dot-source 时为 `'.'`，直接执行为空字符串）：

```powershell
# 所有脚本底部统一模式：
function Main {
    # 原脚本顶层执行逻辑移入此函数
}

# 仅当脚本被直接执行时运行（dot-source 时跳过）
# $MyInvocation.InvocationName is '.' when dot-sourced, empty when run via -File
if ($MyInvocation.InvocationName -ne '.') {
    Main
}
```

> **Delphi R3 修复 [实施发现]**: 原 R1 选择 `$PSCommandPath -eq $MyInvocation.MyCommand.Path`，但在 `pwsh -Command ". script.ps1"` 场景下两者都等于脚本路径，导致 dot-source 时 Main() 仍被执行。实证验证 `$MyInvocation.InvocationName -ne '.'` 是唯一可靠的检测方式。

**影响范围**:
- `scan-residuals.ps1` — `Get-ExecutablePath`
- `clean-residuals.ps1` — `Remove-ItemRobust`, `Test-Whitelisted`
- `generate-report.ps1` — `Set-Id`
- `scan-filesystem-residuals.ps1` — `Get-EffectiveFileCount`, `Get-DirectorySizeMB`, `Test-AllSubdirsEmpty`
- `scan-uninstalled.ps1` — 顶层扫描逻辑

#### 0.2 修复测试 dot-source 模式

更新 `scripts.Tests.ps1` 的 BeforeAll 块，适配新的函数/执行分离模式。

---

### Layer 1: Core（必须修复的核心问题）

#### 1.1 修复 `scan-uninstalled.ps1` 多条件判断逻辑

**现状**: `$isResidual = $notInIndex -or $installPathMissing -or $uninstallPathMissing`

**问题**: OR 逻辑导致已安装软件可能被误报。即使 `$notInIndex=$false`（软件在索引中），只要 `$installPathMissing=$true`，就会标记为残留。

**修改**: 改为**两阶段加权判断**：

```powershell
# 阶段 1: 不在索引中 — 低门槛判定
if ($notInIndex) {
    # 不在索引中 + 任意辅助证据 → 残留
    $isResidual = $true
    $confidence = if ($installPathMissing -or $uninstallPathMissing) { 'high' } else { 'low' }
}
# 阶段 2: 在索引中 — 需要强证据
else {
    # 在索引中 + 路径和卸载程序都异常 → 残留（高门槛）
    $isResidual = $installPathMissing -and $uninstallPathMissing
}
```

> **Delphi R1 修复 [C1]**: 原方案简单 AND gate 会在以下场景漏报：
> - `$notInIndex=$true` 但 InstallLocation 和 UninstallString 都为空（MSI 安装后卸载，只剩孤儿注册表键）
> - 新方案：`$notInIndex=$true` 时直接标记为残留（低门槛），`$notInIndex=$false` 时才需要强证据

**同时修复**: InstallLocation 环境变量展开（AGENTS.md 已记录但未修复）：
```powershell
$installLocation = [Environment]::ExpandEnvironmentVariables($sub.GetValue('InstallLocation').Trim('"'))
```

**影响范围**: `scan-uninstalled.ps1` 第 73 行 + InstallLocation 处理

#### 1.2 分级权限检查

**现状**: 所有脚本需要管理员权限，但在脚本执行中途才因 `Get-CimInstance` 或注册表写入失败

**修改**: **分级检查**，而非一刀切：

```powershell
# 写入操作脚本：强制管理员权限（fatal error）
# - clean-residuals.ps1
# - create-restore-point.ps1
# - run-all.ps1（包含写入步骤）
if (-not ([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
    Write-Error "需要管理员权限。请以管理员身份运行 PowerShell。"
    exit 2
}

# 只读扫描脚本：警告但不阻断
# - build-installed-index.ps1
# - scan-uninstalled.ps1
# - scan-filesystem-residuals.ps1
# - scan-residuals.ps1
# - generate-report.ps1
# - confirm-cleanup.ps1
if (-not ([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
    Write-Warning "非管理员模式运行，部分 HKLM 注册表可能无法读取。"
}
```

> **Delphi R1 修复 [M3]**: 只读脚本不需要管理员权限，一刀切会阻止企业环境中的非管理员扫描。

**注意**: 权限检查放在 `Main` 函数内部（函数/执行分离后），dot-source 时不会触发。

**影响范围**: 9 个脚本 + run-all.ps1

#### 1.3 创建 `run-all.ps1` 统一入口脚本

**现状**: Agent 需要链式调用 6 个脚本，靠人工记忆执行顺序

**新脚本**: `references/scripts/run-all.ps1`

**职责边界**: run-all.ps1 **只负责扫描阶段**（从还原点到报告），**不参与确认/清理**。Agent 在 run-all.ps1 执行完毕后，必须进入交互确认流程。

> **Delphi R1 修复 [M6]**: 明确 run-all.ps1 的职责边界 — 纯扫描管道，不含任何交互或清理逻辑。

功能:
- Step 0: 管理员权限检查（强制，因为包含 create-restore-point）
- Step 1: 创建还原点 + 注册表备份 (`create-restore-point.ps1`)
- Step 2: 构建已安装软件索引 (`build-installed-index.ps1`)
- Step 3: 扫描已卸载残留 (`scan-uninstalled.ps1`)
- Step 4: 扫描文件系统残留 (`scan-filesystem-residuals.ps1`)
- Step 5: 扫描注册表/服务/任务等残留 (`scan-residuals.ps1`)
- Step 6: 生成最终报告 (`generate-report.ps1`)

特性:
- 每个步骤检测退出码，**失败立即中断**（fail-stop）
- 支持 `-SkipRestorePoint` 跳过还原点（多次扫描时，输出明显警告）
- 支持 `-Verbose` 输出详细日志
- 输出每个步骤的耗时和结果摘要
- **默认串行执行**（步骤 4 和 5 串行，简单可靠）

> **Delphi R1 修复 [M2]**: 步骤 4/5 默认串行，避免注册表/文件系统资源争用。

**输出**: 一次性生成 `final-report.json`

#### 1.4 添加退出码

**现状**: 脚本使用 `Write-Error` 但不设置 `$LASTEXITCODE`，链式调用时无法检测失败

**修改**: 所有 exit 路径添加明确的退出码：
- 0 = 成功
- 1 = 通用错误（文件未找到、解析失败等）
- 2 = 权限错误
- 3 = 依赖缺失（如找不到 JSON 文件）
- 4~255 = 预留扩展空间

> **Delphi R1 修复 [Minor]**: 预留扩展空间，在 AGENTS.md 中记录退出码表。

**影响范围**: 所有脚本的 exit 路径

#### 1.5 修复执行顺序（clean-residuals.ps1）— 三轮批处理

**现状**: 清理逻辑按 `foreach ($item in $cleanupItems)` 逐项处理，每个 item 内按 registry → path → service 顺序。服务二进制可能在目录中，先删目录会导致服务操作失败。

**问题**: 不仅是单 item 内的顺序问题，还有**跨 item 依赖**：
- Item A: 文件系统残留 `C:\Program Files\SomeApp\`
- Item B: 幽灵服务 `someapp_svc` → 二进制在 `C:\Program Files\SomeApp\bin\svc.exe`
- 如果先处理 A（删目录），再处理 B（停止服务），服务操作会因二进制不存在而失败

> **Delphi R1 修复 [C2]**: 改为三轮批处理，而非简单重排 foreach 内的代码块。

**修改**: 将 `foreach` 循环拆分为三轮遍历：

```powershell
# Phase 1: 停止所有服务（仅 stop，不 delete）
foreach ($item in $cleanupItems) {
    if ($item.binary_path) {
        # 停止服务，记录服务名
    }
}

# Phase 2: 删除所有文件/目录 + 删除服务
foreach ($item in $cleanupItems) {
    if ($item.path) {
        # 删除目录/文件
    }
    if ($item.binary_path) {
        # sc.exe delete 删除服务
    }
}

# Phase 3: 清理注册表
foreach ($item in $cleanupItems) {
    if ($item.key) {
        # 删除注册表键
    }
}
```

**影响范围**: `clean-residuals.ps1` 主循环（第 226-303 行）

#### 1.6 修复 `scan-uninstalled.ps1` 数组语义 Bug

**现状**: 第 107 行 `$installedNames.Keys -notmatch [regex]::Escape($dirName)`

**问题**: `-notmatch` 作用于数组时返回所有不匹配元素组成的数组。在 if 条件中，只要至少有一个元素不匹配（几乎总是），整个表达式就是 `$true`。

**修改**:
```powershell
# 修复: 使用 -notcontains 或 Count 判断
$matched = @($installedNames.Keys | Where-Object { $_ -match [regex]::Escape($dirName) })
if ($matched.Count -eq 0) {
    # 无匹配 → 候选残留目录
}
```

> **Delphi R1 修复 [M2-Expert A]**: `-notmatch` 对数组的语义 Bug。

#### 1.7 修复 `candidate_directories` 死代码

**现状**: `scan-uninstalled.ps1` 第 93-116 行扫描文件系统目录反查注册表，结果存入 `candidate_directories`。但 `generate-report.ps1` 只读取 `$uninstalled.uninstalled_software`，完全忽略 `candidate_directories`。

**修改**: 将 `candidate_directories` 合并到 `fs-residuals.json` 的数据流中，使其进入 `generate-report.ps1` 的报告生成。

> **Delphi R1 修复 [M1-Expert A]**: `candidate_directories` 被收集但不被消费。

**影响范围**: `scan-uninstalled.ps1` 输出 + `generate-report.ps1` 输入

#### 1.8 修复 `clean-residuals.ps1` Where-Object .Count 陷阱

**现状**: 第 309-311 行 `($log | Where-Object { $_.success -eq $true }).Count` 在单条结果时返回属性数而非元素数。

**修改**: 添加 `@()` 包装：
```powershell
$succeeded = @($log | Where-Object { $_.success -eq $true }).Count
```

> **Delphi R1 修复 [Minor-Expert A]**: AGENTS.md 已记录此陷阱但代码未修复。

---

### Layer 2: Polish（完善打磨）

#### 2.1 修复 SKILL.md 测试

**现状**: 2 个测试失败：
1. `description:\s+Scan and clean` 正则不匹配带引号的 `description: "Scan and clean..."`
2. 找不到 `Option A/B/C/D`（SKILL.md 已改用 agent-driven workflow）

**修改**: 更新 `tests/unit/config.Tests.ps1` 中的正则和期望值

#### 2.2 补充回归测试矩阵

**OR→AND 修复的回归测试矩阵**（必须覆盖的场景）：

| # | 场景 | notInIndex | installPathMissing | uninstallPathMissing | 期望结果 |
|---|------|:---------:|:-----------------:|:-------------------:|---------|
| 1 | 已安装软件，路径被删 | false | true | false | **不标记**（原 OR 误报） |
| 2 | 已卸载，不在索引，路径缺失 | true | true | false | **标记为残留** |
| 3 | 已卸载，不在索引，路径和卸载程序都健全 | true | false | false | **标记为残留**（低置信度） |
| 4 | MSI 安装，孤儿注册表键 | true | false | false | **标记为残留**（低置信度） |
| 5 | InstallLocation 含引号 | true | true | false | **标记为残留**（Trim 后判断） |
| 6 | InstallLocation 含环境变量 | true | true | false | **标记为残留**（展开后判断） |
| 7 | 已安装软件，一切正常 | false | false | false | **不标记** |

**其他补充测试**:
- `run-all.ps1` 各步骤退出码传播
- 权限检查在 dot-source 时不触发
- 三轮批处理的顺序正确性

> **Delphi R1 修复 [M5]**: 明确回归测试矩阵。

#### 2.3 完善 `rollback.ps1`

**现状**: 只显示还原点信息，不实际执行回滚

**修改**: 仅增强信息输出，**不添加 -Execute 参数**（推迟到后续独立设计）：
- 添加还原点与备份目录的关联信息
- 添加注册表备份文件的 diff 预览
- 明确标注"自动回滚功能开发中"

> **Delphi R1 修复 [M4]**: `rollback.ps1 -Execute` 设计不足，涉及破坏性操作（系统还原、重启），需要独立设计方案。当前只做信息增强。

---

### Layer 3: Release（发布就绪）

#### 3.1 Web UI — CLI 优先策略

**现状**: React/Vite Web UI 存在但状态未知。Node.js 后端执行 PowerShell 脚本需要管理员权限，Windows 下不存在可靠的 non-elevated→elevated RPC 通道。

> **Delphi R1 修复 [C4]**: Web UI 管理员权限传递是架构级问题，当前无法可靠解决。

**修改策略**: **CLI 优先，Web UI 降级为可选展示层**

1. **核心发布以 CLI + Agent 为主** — run-all.ps1 + SKILL.md 是主要使用方式
2. **Web UI 仅作为扫描结果展示** — 不通过 Web UI 执行清理操作
3. **验证范围**:
   - `npm install` + `npm run build` 能通过
   - 前端能正确展示扫描结果
   - 后端能调用只读扫描脚本（不含清理）
4. **如果 Web UI 存在严重问题**: 移除 UI 引用，标记为 "Web UI 开发中"

> **Delphi R1 修复 [M4-Expert C]**: 定义 UI 的 pass/fail 判定标准和降级方案。

#### 3.2 创建环境检查脚本

```powershell
# setup.ps1
功能:
- 检查 PowerShell 版本 (≥5.1)
- 检查管理员权限（信息输出，不阻断）
- 检查 Pester 版本 (≥5.x)
- 检查 Node.js（可选，仅 Web UI 需要）
- 输出系统兼容性报告
```

#### 3.3 完善 AGENTS.md

更新为清晰的项目指南，包含：
- 项目结构和脚本职责
- 退出码表（0-3 + 扩展空间）
- 权限分级说明（写入脚本 vs 只读脚本）
- 已知陷阱和注意事项
- 测试运行说明
- run-all.ps1 的使用方式

#### 3.4 SKILL.md 优化

- 确保描述的准确性和完整性
- 补充常见的 Agent 错误处理场景
- 明确区分 agent internal steps 和 user interaction points

---

## 文件变更清单

### 新增文件
| 文件 | 说明 |
|------|------|
| `references/scripts/run-all.ps1` | 统一入口脚本（纯扫描管道） |
| `setup.ps1` | 环境检查脚本 |

### 修改文件
| 文件 | 变更 |
|------|------|
| `references/scripts/scan-uninstalled.ps1` | 两阶段加权判断、权限警告、退出码、数组 Bug 修复、环境变量展开 |
| `references/scripts/scan-residuals.ps1` | 函数/执行分离（$MyInvocation.InvocationName）、权限警告、退出码 |
| `references/scripts/scan-filesystem-residuals.ps1` | 函数/执行分离、权限警告、退出码 |
| `references/scripts/clean-residuals.ps1` | 三轮批处理、函数/执行分离、强制权限检查、退出码、.Count 修复 |
| `references/scripts/build-installed-index.ps1` | 权限警告、退出码 |
| `references/scripts/confirm-cleanup.ps1` | 退出码 |
| `references/scripts/create-restore-point.ps1` | 强制权限检查、退出码 |
| `references/scripts/generate-report.ps1` | 函数/执行分离、退出码、消费 candidate_directories |
| `references/scripts/rollback.ps1` | 增强信息输出（不含 -Execute） |
| `tests/unit/scripts.Tests.ps1` | 适配函数/执行分离、补充回归测试 |
| `tests/unit/config.Tests.ps1` | 修复 SKILL.md 测试 |
| `SKILL.md` | 优化内容 |
| `AGENTS.md` | 完善项目指南 |

---

## 非功能性需求

### 安全性
- 所有清理操作前必须通过白名单校验
- Danger 级别的项永不被清理（仅报告）
- DryRun 是强制性的前置步骤
- 系统还原点 + 注册表备份双保险

### 兼容性
- Windows 10/11 + PowerShell 5.1
- PowerShell 7.x 也应兼容
- 写入操作需要管理员权限，只读扫描可降级运行

### 性能
- 大数据集下（1000+ installed software），索引构建应 < 30秒
- 主扫描应在 < 5分钟内完成
- run-all.ps1 输出每步骤耗时，便于性能基线建立

---

## 风险评估

| 风险 | 影响 | 概率 | 应对 |
|------|------|------|------|
| 两阶段加权判断的低置信度残留可能噪音较大 | 低 | 中 | Agent 展示时标注置信度 |
| 三轮批处理重构引入回归 | 中 | 低 | 回归测试覆盖 |
| 函数/执行分离可能引入回归 | 中 | 低 | 回归测试覆盖 |
| Web UI 可能无法完全工作 | 低 | 中 | CLI 优先策略，UI 降级为可选 |
| 权限检查可能在非标准环境中误报 | 低 | 低 | 提供 skip 参数 |

---

## 规格自审

- ✅ 无 TBD/TODO 占位符
- ✅ 内部一致性：4 层架构，Layer 0 为 Layer 1 提供测试基础
- ✅ 范围聚焦：全面发布级，CLI 优先，Web UI 降级为可选
- ✅ 无歧义：每项变更都有具体位置和修改方案
- ✅ Delphi R1 所有 Critical Issues 已修复
- ✅ Delphi R1 所有 Major Concerns 已处理

---

## Delphi R1 修复追溯

| Issue | 专家 | 修复位置 | 状态 |
|-------|------|---------|:----:|
| C1: AND gate 漏报 | A, B, C | §1.1 两阶段加权判断 | ✅ 已修复 |
| C2: 执行顺序不可行 | A, C | §1.5 三轮批处理 | ✅ 已修复 |
| C3: 函数分离层级错误 | B, C | §0.1 提升为 Layer 0 + $MyInvocation.InvocationName | ✅ 已修复 |
| C4: Web UI 权限架构 | A, B, C | §3.1 CLI 优先策略 | ✅ 已修复 |
| M1: candidate_directories 死代码 | A | §1.7 合并到报告流 | ✅ 已修复 |
| M2: -notmatch 数组语义 Bug | A | §1.6 改用 Where-Object | ✅ 已修复 |
| M3: 权限检查粒度太粗 | B | §1.2 分级权限检查 | ✅ 已修复 |
| M4: rollback -Execute 设计不足 | B, A | §2.3 推迟到后续设计 | ✅ 已处理 |
| M5: 缺少回归测试矩阵 | C | §2.2 7 场景矩阵 | ✅ 已修复 |
| M6: run-all.ps1 职责边界 | C | §1.3 明确纯扫描管道 | ✅ 已修复 |
