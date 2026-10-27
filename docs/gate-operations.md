# 门禁运维手册（xp-gate 侧的判断口径与坑）

> 本文件从 `AGENTS.md` 拆出（2026-10-27）：这些内容讲的是**本机门禁链怎么跑、
> 怎么判断它给的结论**，不是本项目的功能限制。放在独立文件里既好维护，也让
> `AGENTS.md` 保持能一次读完的长度。
>
> 本仓**不维护** xp-gate 本身。这里只记录「消费发布版时需要注意什么」。

---

## 一、覆盖率怎么看

### 1.1 权威口径与污染判据

引用覆盖率数字前先核对产物：

1. 本地包装脚本打印的 `CoveragePercent` 是 **Pester 命令口径**（与行口径不是一回事）；
2. JaCoCo `coverage.xml` 的 LINE counter 是**行口径**，两者不可互引；Gate 5 读的是后者；
3. 权威口径 = **产品源全集**（`.xp-gate-powershell-analysis-paths` 列出的三个范围：
   `references/scripts/*.ps1` + `tools/*.ps1` + `setup.ps1`），一个不多、一个不少。

**不要背数字**：脚本增删都要同提交改 `analysis-paths`，count 自然变；当前 count 用
`coverage.xml` 里 `<sourcefile>` 的条数现查（正常应与 analysis-paths 发现数相等）。

产物会被**任何**用默认 CodeCoverage 配置跑 Pester 的会话覆写污染——实测评审期间
一次运行把 `.workbuddy/` 下的文件与根目录本地脚本混进了 sourcefile 列表，顶层 counter
随之失真；**另一种观测形态（R5 走查实测）**：产物被整个写成 **2 字节空文档
（0 sourcefile）**。两种形态都会被 sourcefile 计数自检抓出，混入/清空即重跑覆盖率管线。

### 1.2 分母怎么调

`xp-gate` 的 80% 阈值写死在共享 hook 里。调节分母的正确手段是
`.xp-gate-powershell-prune-dirs`（非产品脚手架目录在**发现阶段**整体离场，发现=分母）；
`.xp-gate-powershell-coverage-ignore` 保持**空列表**（按产物减扣会把真实产品代码静默
移出分母，已由 `platform-hygiene.Tests.ps1`「门禁边界一致性」守卫）。

该文件的注释已明确写下「Do NOT add files here merely because they are hard to test」——
所以**不要**为了过门禁而把 `clean-residuals.ps1` / `confirm-cleanup.ps1` 整文件排除：
那会连同已覆盖的 163/170 行一起丢掉。正确方向是把可测逻辑抽成纯函数
（`ConvertFrom-*`、`Get-*Verdict`、`Get-MatchingRestorePoint` 等）并补测。

**判断口径**：若某脚本看起来「结构性不可插桩」，先怀疑它违反了 ADR-001（`Main` 内
`exit`），而不是往列表里加一行——`setup.ps1` 正是这样一条被写成豁免的代码缺陷，
2026-10-08 已重构消除。

### 1.3 「本地绿、CI 红」先看分子分母的方向

两边都只打印 `pct% (covered/total)`，判断依据就在这四个数字里。

- **分子大、分母也大** → 统计**口径**不同，不是少覆盖。去查工具链版本，补测试没用。
  例：CI 报约 79.6%、本机报约 80.3%，而**分母也同时变大**（CI 的 total 比本机大一截）
  ——分子分母同向变化就是口径差异，不是少覆盖。
  真因是 `ci.yml` 的 `Install-Module Pester -MinimumVersion 5.5.0 -Force` ——
  `-MinimumVersion` 是**下限**，PSGallery 最新是 6.2.0 时 CI 就装 6.2.0，而本机是 5.7.1。
  Pester 6 把更多**单语句** `continue`/`break`/`throw` 计为序列点：
  同一份 `confirm-cleanup.ps1` 在 5.7.1 下插桩 282 行、6.2.0 下 294 行。
- **分子小、分母相同** → 真的少覆盖，去补测试。

排查时**三个看起来很像的假设要先用隔离实验否证**，否则会照着假线索改：
① 行尾 CRLF/LF —— 字节差异真实存在（CI 检出 CRLF、本机 LF），但对插桩行集**无影响**
（真实文件双份 × 双引擎 2×2 矩阵实测，行集完全相同）；② 双引擎剖析器不同 ——
CI 两份产物行集**逐行相同**；③ Pester 版本 —— 成立。

**复现方式**：把 CI 同版本的 Pester（`ci.yml` 里实际装到的那个）`Save-Module` 到临时目录，
`Import-Module <临时>/Pester/<版本>/Pester.psd1` 后跑全量覆盖率——分母会与 CI 逐项相同。
这一步本身就是「口径确认」：分母对上就证明差异在工具版本，不必再补测试。

### 1.4 Gate 5 的陈旧 `coverage.xml` 陷阱

hook 适配器在找不到 pwsh 时跳过测试与覆盖率**生成**，但 Stage-2 仍会解析仓库根目录
**既有的** `coverage.xml`（只要 node 在 PATH 上）。于是旧产物会拦新提交（实测：
2026-10-01 的 68% 产物拦下了 2026-10-07 的提交）。**不跑 pwsh 覆盖率就提交时，先手动
跑一次覆盖率管线刷新 `coverage.xml`**（该文件已 gitignore，属于本机门禁工件）。
加固后 Gate 5 在 PS-only 提交上会真跑 Pester 并重新生成 coverage.xml，此陷阱只剩
「纯文档提交」时仍适用。

---

## 二、Gate 1 / Gate 3 的专用坑

### 2.1 analysis-paths 与发现范围（Gate 1）

`.xp-gate-powershell-analysis-paths` 是 Gate 1 的产品分析范围——**新产品脚本必须同提交
把路径加进去**，缺失条目现会 fail-closed 发 WARN
（`XP_G1_REASON: analysis-path-missing:<路径>`，R6 前是静默跳过）；一致性由
「门禁边界一致性」测试守卫（tracked 产品源必须全被 scope 覆盖 + scope 条目必须真实存在
+ coverage-ignore 必须空 + prune-dirs 必须含 wrc-drill）。

注意发现是 `*.ps1` 端到端：`.psm1` 模块不在发现/覆盖率/分析三处分母内
（见 analysis-paths 文件头 R6 note）。

prune 列表覆盖 xp-gate 脚手架 dot 目录
（`.worktrees/.workbuddy/.sprint-state/.delphi-work/.qoder/.vscode/.idea/.xp-gate`），
项目专属目录经 `.xp-gate-powershell-prune-dirs`（本仓含 `wrc-drill`）注入。
发现结果包含全部测试文件 + 全部产品源（`references/scripts/*.ps1` + `setup.ps1` +
`tools/*.ps1`，**具体条数以发现命令实跑为准**），`wrc-drill` 不进测试发现与覆盖率分母。

Gate 1 的 PSSA 经 `.xp-gate-powershell-analysis-paths` 收敛到产品范围
（references/scripts + tools + setup.ps1），Pester 测试文件按 Pester 执行模型产生的数百条
规则误报不再进入门禁判据（328 条清单见 `docs/audits/`；同规则、收范围，非放宽规则）。

### 2.2 Gate 3 基线四前提

任一条件不满足，**每个** CCN > 阈值的函数都被报成「new function at ccn=N」，
而 22 条误报的症状**一字不差**——这正是它连耗三轮的原因。

1. **键名**：`gate-3.sh` L175 读 `e.name`，上游点名的生成器写的是 `function`；
2. **测量器**：门禁用 `<xp-gate>/hooks/lib/Measure-PowerShellComplexity.ps1`（L79），
   **不是**仓库里那份。两者是不同实现，`clean-residuals.ps1` 的 `Main` 算成 **139**
   （仓库版 143）；
3. **路径拼写**：门禁的 `norm()` 在 Windows 上是**空操作**。L179 写的是
   `.replace(/\\\\/g, "/")`，而它在 bash **单引号** `node -e '...'` 里——bash 原样传四个
   反斜杠，JS 收到的正则是 `/\\\\/`，匹配**两个连续反斜杠**。实测
   `norm('<任意绝对路径>')` 原样返回。所以基线必须存**绝对原生反斜杠**路径；
   存正斜杠（"已经规范化"）会原样保留，与测量输出永不相等；
4. **全集**：门禁带 `-List`，会输出 `FUNC` 行覆盖**所有**函数，包括 `ccn=1` 那些永远
   「不大于阈值」的。生成器不带 `-List` 就会漏条目，漏的那条又被报成「新函数」。

所以生成器必须：写 `name` 键 + 用 live 测量器 + `file` 存绝对反斜杠 + 传 `-List`。
**任何一项单独修，回归数都一点不变**（实测 22 → 22 → 22 → 0）。

**判断口径**：门禁说「new function」时，别猜自己的代码变复杂了——按 `gate-3.sh`
L157-208 的原逻辑（**`norm()` 逐字照抄**，别「顺手修正」它的正则）用 `node` 复算一遍
`known` 与实测键的交集。我第一次复现时就是把它改成了 `/\\/g`，于是本地算 0 回归、
真实门禁照旧拦人，白跑一轮。守卫：`tests/unit/complexity-tool.Tests.ps1` 有一条用例
一次钉住这四个前提。基线含本机绝对路径是可接受的（CI 不跑 xp-gate 的 pre-commit），
换机器重跑生成器即重写前缀。**不要**为此改动 xp-gate 或 `~/.config/xp-gate/`。

> **连带后果：CI 上不能用「绝对路径存在」来校验基线。** 基线写的是**作者机器**的前缀，
> 而 CI 跑在 `D:\a\windows-residual-cleaner\...`——直接断言那条绝对路径存在，会在 CI 上
> 对**每一条**都失败（2026-10-26 实测：CI run 40356891173 的红就是这条，
> `Tests Passed` 有 1 条失败，而本地当时全绿）。
> `tests/unit/complexity-tool.Tests.ps1` 因此按**仓库相对尾段**校验：把绝对前缀剥到
> `references\scripts\` / `tools\` / `setup.ps1` 之一，再拼当前 checkout 检查存在性。
> 它守的不变式是「没有死条目」（文件改名/删除没同步基线），与「本机路径能否解析」无关。
> 已用脚本把 168 条全改成 CI 前缀验证过：0 条无法解析。

---

## 三、本机工具链与适配器

### 3.1 工具链路径与降级链

`pwsh` 7 位于 `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`，`node.exe`
位于 `C:\Program Files\nodejs\node.exe`——git-bash 的 PATH 里没有裸命令名，`jq` 未安装。

适配器 `_detect_pwsh` 会显式探测 WindowsApps pwsh 与 System32 powershell.exe 的标准
安装位置（PATH 剥离也找得到）；Gate 1 有 fail-closed 的 powershell 分支（引擎/PSSA 模块
缺席 → WARN 计入分母，绝不静默 PASS）；`gate-10.sh` 会兜底探测
`%APPDATA%\Python\*\Scripts\semgrep.exe`。commit 时仍建议前置
`C:\Program Files\nodejs`（Gate 10 verdict 解析与 Stage-2 覆盖率解析都依赖 node）。

### 3.2 适配器断言只写性质，不钉形状

`powershell.sh` 的覆盖率/超时形态、`gate-10.sh` 的 semgrep 探测，断言对象都是
`~/.config/xp-gate/adapters/*`——即「本机实际跑的那份」。未安装时用例 Inconclusive。

这类断言只应写**性质**（「覆盖率那一步受超时保护」「能探测到 semgrep」），
不钉具体参数排列：0.31.1→0.31.4 期间该函数形状变了三次，钉死任一写法都会让升级本身
变成红。

### 3.3 本仓只消费发布版，不存副本

钩子、适配器与门禁逻辑一律归 xp-gate 项目；本机安装的版本升级由系统管理流程执行。
本仓**只消费发布版**，不存副本、不打下游补丁、不做「live == 仓库副本」的字节比对。

早期（2026-10-17 起）确实 vendored 过一份加固副本并配了一致性哈希断言，前提是「本仓
维护 xp-gate 的下游加固」。这个前提在 2026-10-24～26 的多次上游升级中被反复证伪：
每次发版都整体重写 `~/.config/xp-gate/`，仓库副本随之失配，套件变红的原因与仓库质量
无关——正是「本地验证失去意义」的那类假红。因此 `githooks/` 目录与那条比对已删除。

至于本仓**真正能负责**的那一条（`core.hooksPath` 必须解析到 xp-gate 的 hooks 目录、
该目录里有 `pre-commit`），它的判据与守卫在 `AGENTS.md` 的「已知限制」里，不在这里重复。
