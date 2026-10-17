# githooks/ — 仓库侧的 XP 门禁钩子权威副本（vendored）

> R6 走查实证（2026-10-17）：用户级钩子安装（`~/.config/xp-gate`）会被一个外部
> xp-gate 维护进程**静默回退**——实测一次回退把 batch-3 的三个硬化文件全部还原为
> legacy（且保留旧 mtime，`ls -l` 看不出异常），导致两次实弹提交的 Gate 1 /
> Gate 10 实为 skip-as-pass。本目录是硬化版的**仓库内权威副本**：
> 钩子文件被回退时，`tests/unit/platform-hygiene.Tests.ps1` 的
> 「门禁边界一致性 → 钩子安装与 vendored 副本一致」用例会变红，而不是静默降级。

## 内容

| 文件 | 作用 | 必含标记（一致性测试断言） |
|------|------|--------------------------|
| `adapters/powershell.sh` | Gate 1 powershell 分支的实现：`_detect_pwsh` 回退探测、发现 prune（脚手架 dot 目录 + `.xp-gate-powershell-prune-dirs` 注入）、范围 PSSA（`.xp-gate-powershell-analysis-paths` 逐路径 + Stop 纪律）、fail-closed 语义（engine/module 缺席 → `XP_G1_REASON` → WARN；缺失 scope 条目 → `analysis-path-missing` WARN；发现 → BLOCK） | `analysis-path-missing`、`_detect_pwsh`、`XP_G1_REASON` |
| `adapters/gate-10.sh` | Gate 10 SAST：semgrep `%APPDATA%/Python/*/Scripts` 回退探测；扫描清单含 `.ps1/.psm1` | `AppData/Roaming/Python`、`ps1\|psm1` |

`hooks/pre-commit`（170KB 上游文件）不整体 vendored——一致性测试改为断言 live
文件含三处关键补丁标记（Gate 1 谓词含 ps1、`powershell)` fail-closed 分支、
Gate 10 谓词含 ps1）。

## 安装 / 同步（新机器或回退恢复后）

```bash
# 1) 钩子安装（core.hooksPath 指向用户级 xp-gate；通常已配好）
git config core.hooksPath   # 期望 C:/Users/think/.config/xp-gate/hooks

# 2) 同步 vendored 副本 → 用户级安装（回退恢复）
cp githooks/adapters/powershell.sh ~/.config/xp-gate/adapters/powershell.sh
cp githooks/adapters/gate-10.sh    ~/.config/xp-gate/adapters/gate-10.sh

# 3) 验证（双引擎套件里的一致性用例应当绿）
pwsh -NoProfile -Command "Invoke-Pester tests/unit/platform-hygiene.Tests.ps1"
```

前置：`pwsh`（7.x）、`PSScriptAnalyzer`、`Pester` 5.x、`semgrep`（Gate 10）、
`node`（Gate 10 verdict 解析与 Stage-2 覆盖率解析）。

## 边界

- 本目录是**检测与恢复源**，不是自动安装器：钩子的安装/更新仍由 xp-gate 侧管理。
- 修改产品分析范围用 `.xp-gate-powershell-analysis-paths`；隔离脚手架目录用
  `.xp-gate-powershell-prune-dirs`。两者都有硬边界规则与一致性测试守卫。
