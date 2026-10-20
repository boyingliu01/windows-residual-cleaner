# 2026-10-16 质量门禁全面体检报告

> 范围：xp-gate 全部 13 道门禁（Gate 0–12）在本仓库的真实状况。
> 方法：官方记录（`.xp-gate/quality-status/master.json` + 最近 pre-commit 报告）
> 与当日全仓实测（PSSA / eslint / tsc 构建 / jscpd / gitleaks / 双引擎 Pester / vitest）交叉验证。
> 结论归属：DeepSeek agent 接管审计；行动项见文末。

---

## 一、总览

**官方状态**（提交 `ab43af3`，2026-10-16 12:00Z）：9 PASS / 3 SKIP，score 10.0，verdict PASS。
CI（run #6，`ac970b2`）：双引擎 727 用例全绿、行覆盖 82.89%、PSSA 0 findings、UI 绿。

**但该报告产生于「AGENTS.md 单文件提交」**——多数门禁因"无代码变更"被跳过。
下表「全仓实测」是当日直接运行底层工具得到的地基数据。

| 门禁 | 官方 | 全仓实测 | 判定 |
|---|---|---|---|
| Gate 0 版本一致性 | PASS | VERSION/CHANGELOG 一致 | ✅ 真 PASS |
| Gate 1 静态分析 | PASS | `references/scripts` PSSA **0**；UI eslint **0**；钩子口径全仓 PSSA **827 Warning**（tests 652 + wrc-drill 170 + 产物 5，0 Error） | ⚠️ 名实不符（见 3.8） |
| Gate 2 重复代码 | PASS | **22 克隆 / 205 行（2.68%）** < 5% 阈值；克隆位置与走查 P3 一一对应 | ✅ PASS |
| Gate 3 圈复杂度 | SKIP | archlint（TS 侧）6 条 MEDIUM（`streamNDJSON` 圈复杂度 17、`CleanupPanel` 认知复杂度 30、`LogSummary` 21 等）；**PowerShell 侧零测量** | ⚠️ 半空转 |
| Gate 4 原则检查 | SKIP | 未执行（仅 TS 工具链） | ⚠️ 空转 |
| Gate 5 测试+覆盖率 | PASS(N/A) | 双引擎 **727/727**；行覆盖 **84.08%** 本地 / 82.89% CI（阈值 80%）；UI vitest 59/59 | ✅ 真 PASS，盲区见 3.4 |
| Gate 6 架构 | PASS | zero-tolerance 但 `no baseline found`——无基线可比，6 条 MEDIUM 放行 | ⚠️ 弱 PASS |
| Gate 7 IaC 安全 | PASS | 仓库无 IaC 文件（平凡 PASS） | ✅ |
| Gate 8 密钥扫描 | PASS | gitleaks 8.30.1 实跑 0 泄露；detect-secrets 不可用（降级单工具） | ⚠️ 降级 |
| Gate 9 构建完整性 | SKIP | 手动实测 `tsc -b && vite build` 成功 | ✅ 真 PASS |
| Gate 10 SAST | PASS | **semgrep 本机未安装**，从未真正扫描本仓库代码 | 🔴 空转 |
| Gate 11 Sprint 流程 | PASS | phase 6 completed、delphi APPROVED | ✅ 真 PASS |
| Gate 12 文件卫生 | PASS | BOM 守卫等 | ✅ 真 PASS |

## 二、为什么这么多门禁空跑 / 降级（根因）

1. **语言错配**：xp-gate 的检测矩阵以 TypeScript 为主（archlint、复杂度、原则检查、SAST 规则集），
   而本仓库的产品主体是 PowerShell——3/4/6 对 3.3k 行产品代码零测量。
2. **可选工具未装即静默 PASS**：semgrep（Gate 10）、detect-secrets（Gate 8）缺席时，
   质量报告不区分「扫描了且干净」与「根本没扫」。
3. **钩子降级链设计**：工具缺席 → Gate SKIP → 整体 PASS（fail-open 的报告口径）。
4. **范围不收敛**：Gate 1 若真跑 PowerShell 全仓，827 条历史告警（tests/wrc-drill/产物目录）
   会拦下所有提交——各仓库只能靠"工具不上 PATH"来维持绿色，等于门禁实际不生效。

## 三、门禁盲区与走查发现的对应关系（2026-10-16 深度走查）

走查发现的缺陷**全部**位于门禁覆盖不到的位置——门禁没有失败，是门禁看不见：

1. **P1** `Start-Process -ArgumentList` 不给含空格元素加引号（`Invoke-ScExe` /
   `Invoke-RegExe` / `Remove-ItemRobust` Tier2）：行覆盖 100%，但没有任何用例喂过含空格路径。
2. **P1** `Get-ExecutablePath` 兜底 `Split(' ')[0]` 把未加引号含空格服务路径截断 → 活服务误判
   ghost(safe) → Mode A 自动删除且不可恢复：同上，形态未被用例覆盖。
3. **P1（UI）** Origin 守卫 loopback 判定 `h.startsWith('127.')` 可被 `127.0.0.1.sslip.io` 绕过
   （`security.cjs:34/59`）：`security.test.mjs` 只测了 `attacker.example` 形状。
4. **P2** 扫描/报告侧读 JSON 无损坏保护（fail-open 扩大误报面）、`-ItemsToClean` 非法 JSON
   仅告警、`Remove-ItemRobust` 全程 `-Path`（通配符注入面）、`create-restore-point.ps1:151`
   裸 `reg export` 失败零记录。
5. **P2（UI）** 相位机死状态（无人 dispatch `scanning`/`cleaning`）+ 服务端无互斥；磁盘文件
   未绑定轮次；300s 硬超时 = 对破坏性清理 TerminateProcess。
6. **P3** Mode B ≡ Mode A（jscpd 阈值内放过的逻辑克隆）、`ui/server/index.cjs`（唯一 spawn
   管理员 PowerShell 的层）**零测试**、两端流解析边界不一致、死依赖 `cors`/`tsx`。

## 四、当日加固记录

| 行动 | 状态 |
|---|---|
| semgrep 1.171.0 安装 + Python Scripts 目录确认在用户 PATH → Gate 10 下次代码提交起为真扫描 | ✅ |
| xp-gate 缺陷 issue（见第五节） | ✅ ×4 |
| `references/scripts/native-invoke.ps1`：统一原生调用（`ConvertTo-NativeArgument` 引号封装 + `Invoke-NativeExe` 真实超时），`Invoke-ScExe`/`Invoke-RegExe`/Tier2 收敛到它 | ✅ |
| `Remove-ItemRobust` 函数体全部 `-Path` → `-LiteralPath`（通配符注入面关闭） | ✅ |
| `create-restore-point.ps1`：裸 `reg export` 改走 `Invoke-NativeExe`，导出失败补 else 分支记 `valid=$false` | ✅ |
| 新增 `tests/unit/platform-hygiene.Tests.ps1`：引号封装单测 + 含空格参数行为测试 + 4 条 AST 守卫（Start-Process 白名单、禁裸变量数组字面量进 `-ArgumentList`、破坏性函数禁 `-Path`、禁裸 `reg`/`sc`）+ lib 清单一致性测试 | ✅ |
| UI：`.architecture-baseline.json` 落盘（Gate 6 启用 diff 模式，新违规才拦）、孤儿类型 `CategoryInfo` 清理、`ui/server/index.cjs` 可测化 + 路由测试 | ✅ |
| `architecture.yaml`（archlint 激活前提）纳入跟踪——此前仅本机存在，新克隆/CI 上 Gate 6 会退回 "no architecture config" 弱 PASS（delphi 走查发现） | ✅ |
| delphi code-walkthrough Round 1（三专家三模型）：其 Critical（Start-Process 再包引号）经双引擎端到端实证驳回并以真实进程测试钉死；证实项已修——超时击杀失败写进 error 字段、clean-residuals 显式加载 native-invoke、/api 畸形 JSON 结构化 400 | ✅ |

> 注：第三节表格中的测试数（727/59）是**审计时刻**的实测快照；走查收口（Round 1
> Critical 驳回 + Round 2/3 证实项落实，含 tier-4 死分支回归修复 + 行为测试 +
> 诚实口径更正）后为 Pester **752**（双引擎各 752/752）+ vitest **71**（服务端 12）。

## 五、xp-gate 缺陷 issue

| # | 标题 |
|---|---|
| [#535](https://github.com/boyingliu01/xp-gate/issues/535) | lib source 失败时钩子静默继续（fail-open） |
| [#536](https://github.com/boyingliu01/xp-gate/issues/536) | Gate 10 SAST 在 semgrep 未安装时静默记 PASS |
| [#537](https://github.com/boyingliu01/xp-gate/issues/537) | Gate 3/4/6 对 PowerShell 零覆盖 |
| [#538](https://github.com/boyingliu01/xp-gate/issues/538) | 文件发现不 prune 演练目录，827 条历史告警拦提交 |

## 六、遗留（产品侧，未在本轮处理）

- 走查 P1-2（ghost service 误判）及其余 P2 产品修复按既定顺序推进。
- Gate 3/4 对 PowerShell 的深度测量依赖 xp-gate 侧（#537）。

---

## 七、附录（第三批，2026-10-16）：门禁真生效加固

> 背景：本报告第一～六节诊断出的「空转 / SKIP / 静默降级」已在第三批落地修复。
> 目标是把本仓库 XP 门禁从「官方 9 PASS/3 SKIP 的名义状态」变成「对 PowerShell
> 代码真跑、缺席即 WARN、告警即 BLOCK 的 fail-closed 状态」。

### 7.1 前后矩阵（本仓 PowerShell 侧）

| 门禁 | 加固前（本报告实测） | 加固后（实测） |
|---|---|---|
| Gate 1 静态分析 | 无 powershell 分支；若 pwsh 上 PATH 则整仓 827 条告警全拦 → 事实上被迫空转 | fail-closed `powershell` 分支：PSSA 范围模式（`.xp-gate-powershell-analysis-paths` = references/scripts + setup.ps1）逐路径跑 + `ErrorActionPreference='Stop'`；0 告警→PASS、工具缺席→WARN（进分母）、有告警→BLOCK；干净实跑 exit 0，告警探针 exit 1 + 发现表（3 轮无抖动） |
| Gate 3/4 圈复杂度/原则 | PowerShell 零测量（#537，xp-gate 上游） | 本批未扩（上游 issue 仍开放）；仓库侧把范围文件机制建好，上游支持时零改动接入 |
| Gate 5 测试+覆盖率 | 找不到 pwsh → SKIP，Stage-2 解析陈旧 coverage.xml | `_detect_pwsh` 回退探测（WindowsApps pwsh / System32 powershell.exe）+ `_pester_timeout` 900s → PS-only 提交也真跑 753 用例并重新生成 coverage.xml |
| Gate 10 SAST | semgrep 未装→SKIP；SEMGREP_FILES 不含 .ps1 → 本仓恒空 | semgrep 1.171.0 已装 + `%APPDATA%\Python\*\Scripts` 回退探测 + `.ps1/.psm1` 入扫描清单；实测 setup.ps1/native-invoke.ps1 扫描 0 结果 0 错误；semgrep 缺席 → FAIL(exit 1)+WARN，不再静默 PASS |
| 文件发现 | 不 prune `.worktrees`/`wrc-drill`（#538） | prune 列表 = xp-gate 脚手架 dot 目录 + `.xp-gate-powershell-prune-dirs`（本仓：wrc-drill）；实测发现 = 20 测试 + 18 产品源，与基线完全一致 |
| 覆盖率豁免 | `.xp-gate-powershell-coverage-ignore` 带 3 条历史条目 | **清空**（prune 已让分母即真实产品清单，不再按产物减扣）；硬边界规则保留 |

### 7.2 钩子侧补丁清单（`~/.config/xp-gate`，仓库外，已备份 `.bak-gate-harden-20261016`）

1. `adapters/powershell.sh`：`_detect_pwsh` 回退链；`_find_powershell_files` prune 重建
   （base + dot 目录 + 项目注入）；`run_static_analysis` 重写（模块按退出码探测、范围
   文件模式、逐路径 PSSA、`XP_G1_REASON: powershell-engine-unavailable` /
   `psscriptanalyzer-unavailable` / `analysis-paths-empty` fail-closed 语义）。
2. `hooks/pre-commit`：Gate 1 入口正则 + `ps1|psm1`；新增 `powershell)` fail-closed
   分支（PASS / WARN / BLOCK 三态映射）；Gate 10 包装正则 + `ps1|psm1`。
3. `adapters/gate-10.sh`：semgrep 路径回退；SEMGREP_FILES + `ps1|psm1`。
4. `bash -n` 三文件全过；单元级探测/发现/拦截全部实测（见 7.1 矩阵证据）。

### 7.3 仓库侧配套（随本批提交入库）

- `.xp-gate-powershell-prune-dirs`（wrc-drill，回应 #538 的项目侧落地）。
- `.xp-gate-powershell-analysis-paths`（产品分析范围 + 硬边界：新产品脚本必须同提交
  加路径，否则 Gate 1 以 `analysis-paths-empty`/缺席路径如实降级）。
- `.xp-gate-powershell-coverage-ignore` 清空（见 7.1）。
- `tests/unit/platform-hygiene.Tests.ps1` 新增「三形态真值钉子」（takeown 裸 `&`/
  Start-Process 拼接/包裹三形态双引擎断言）——落实构远图 R5 残余项时**反而更正了
  R3 的因果口径**：`&` 绑定形态是引擎分歧（PS 5.1 失败 / pwsh 7 成功），
  「两引擎共有」仅对 Start-Process 纯拼接成立。752 → **753**（双引擎各 753/753）。
- AGENTS.md 两条门禁降级已知限制改写为加固后现实；第三批变更记录入册。
- **测试侧 PSSA 技术债如实入册**：按仓库设置对 tests/ 全量 PSSA = 328 条告警
  （PSUseDeclaredVarsMoreThanAssignments 164 / PSAvoidGlobalVars 131 /
  PSAvoidOverwritingBuiltInCmdlets 18 / PSUseShouldProcessForStateChangingFunctions 11 /
  PSUseApprovedVerbs 3 / PSUseSingularNouns 1），属 Pester 执行模型误报面；
  门禁按「收产品范围」处理而非放宽规则，测试文件不进判据。

### 7.4 试金石提交（**结论已更正，见 7.6**）

第三批的全部修复原计划以一次真实 `git commit` 验收。`a78ac47` 提交时报告为
全绿 PASS、Gate 5 覆盖率为 commit 时新鲜产物（18 sourcefile，84.17%），当时据此
写下「Gate 1 PSSA 真扫 / Gate 10 首次真扫描」。**R6 Round-2 复查推翻**：Gate 1
实际输出为 `No code files changed, skipping lint`（skip 谓词不含 .ps1，skip-as-pass
也记 PASS），Gate 10 的 `files scanned: 2` 扫的是无扩展名配置文件——**外部维护
进程在提交前已把钩子侧硬化整体回退**（见 7.6）。教训入册：引用门禁证据必须读
该门禁段的输出行，不能只读报告汇总。

### 7.5 R6 走查证实项（2026-10-17，收口补丁）

R6 code-walkthrough Round 1（三专家三模型，commit `a78ac47` 对象）：1 APPROVED /
2 PASS_WITH_CAVEATS，零 Critical。两位专家以临时探针脚本**独立实测复现**同一根因：
analysis-paths 的「硬边界」此前只有散文承诺——scope 条目缺失时钩子静默跳过
（fail-open），根级产品脚本带真告警照样 PASS。证实项当场落实（收口提交）：

| 发现（专家实测） | 落实 |
|---|---|
| scope 条目缺失 → 静默跳过 + PASS（fail-open） | 钩子适配器改为发 `XP_G1_REASON: analysis-path-missing:<路径>`（fail-closed WARN，同 analysis-paths-empty 语义）；超时文案 300 字面量同步改真值。**两层防御**（R6 R3 澄清）：一致性测试先行变红是第一层，钩子 WARN 是纵深第二层 |
| analysis-paths 与覆盖率分母两条边界无交叉校验，可各自腐烂 | 新增「门禁边界一致性」测试组（platform-hygiene.Tests.ps1）：tracked 产品源 ⊆ scope、scope 条目必须存在、coverage-ignore 必须空、prune-dirs 必须含 wrc-drill、**live 钩子与 vendored 副本哈希一致**（第 4 用例，回退即红） |
| 发现是 `*.ps1` 端到端，`.psm1` 模块不在三处分母内 | analysis-paths 文件头 R6 note（产品代码保持 .ps1 或扩展机制时三处一起改） |
| ci.yml 硬编码产品清单、引用已清空的 coverage-ignore、标注 727 历史计数 | ci.yml 改读 `.xp-gate-powershell-analysis-paths`（scope 空即 fail），陈旧引用清除 |
| 钩子链在仓库外，新克隆静默降级且 README 未提 | README 新增「Pre-commit quality gates」节（三份 tracked 边界文件 + 一致性测试守卫） |
| wrc-drill/README 仍指向 coverage-ignore | 更正为 prune-dirs 发现阶段剪除口径 |
| drill3 `Test-AdminPrivilege` 桩 `return $true`——非管理员会话静默驱动真实清理 | 改真实管理员检测（WindowsPrincipal），非管理员中止 |
| 「7.2+ 标准实参传递」因果归属被三模式实测否定（三种 PSNativeCommandArgumentPassing 均成功） | 全文更正为「原生实参绑定正确转义（R6 实测三种 passing 模式）」，native-invoke.ps1/测试/CHANGELOG/AGENTS.md 同步 |

R5 钉子中「pwsh 7 期望 exit 0」的引擎行为断言在 R6 复核中保持成立（且与
passing-mode 无关），按原样保留为回归钉。

### 7.6 钩子回退事故与防回退机制（2026-10-17，R6 Round-2 发现）

**事故**：R6 Round-2 走查中稳落地专家以分歧证据（钩子文件行号/尺寸与补丁描述
不符）提出 BLOCKING CANDIDATE；本会话逐项复核**确认成立**——一个外部 xp-gate
维护进程把 batch-3 硬化的三个用户级钩子文件（`adapters/powershell.sh`、
`adapters/gate-10.sh`、`hooks/pre-commit`）**全部还原为 legacy 且保留旧 mtime**
（适配器回退到 2026-10-13 版本，pre-commit 的 Gate 1 skip 谓词不含 `.ps1`），
`.bak-gate-harden-20261016` 备份除一份被移入 `backup/cleanup-20261017/`（后经
SHA256 比对证实与回退后的 live 同为 legacy）外全部消失。直接后果：
**`a78ac47` 与 `067ae75` 两次实弹提交的 Gate 1 是 skip-as-pass（谓词无 .ps1，
输出 `No code files changed, skipping lint.`），Gate 10 扫的是无扩展名配置文件**
——7.4 的「试金石」结论被推翻。这是继 `.delphi-config.json` 两次改写事故之后
第三次实证「用户级钩子目录会被外部进程改写且 mtime 不可信」。

**根因**：XP 门禁的全部状态都放在仓库外的用户级目录（`~/.config/xp-gate`），
`core.hooksPath` 指向该处；该目录由外部维护进程管理（备份/清理/回退），仓库对
「钩子被改回旧版」没有任何检测手段——静默降级直到下次有人读钩子文件本身。

**防回退机制（本轮收口提交落地）**：
1. **重建**：三个钩子文件按 batch-3 设计全部重打（`_detect_pwsh` 标准安装位
   回退探测、发现 prune + `.xp-gate-powershell-prune-dirs` 注入、范围 PSSA +
   `$ErrorActionPreference='Stop'` 纪律、fail-closed `XP_G1_REASON` 族、
   pre-commit Gate 1 谓词 + `powershell)` fail-closed 分支 + Gate 10 谓词、
   gate-10 semgrep `%APPDATA%` 回退 + `ps1|psm1`）。五探针复测：发现 20 测试
   + 18 产品源且 wrc-drill 零泄漏；干净 scope → exit 0 无 reason；scope 内脏
   文件 → exit 1 + 发现表；缺失 scope 条目 → `XP_G1_REASON:
   analysis-path-missing:<路径>`；引擎探测命中。
2. **vendored 入库**：`githooks/adapters/powershell.sh` +
   `githooks/adapters/gate-10.sh` 成为仓库内权威副本（170KB 的 pre-commit 不
   整体入库，改为标记断言），`githooks/README.md` 写明安装/同步/恢复步骤。
3. **一致性测试**：「门禁边界一致性」新增第 4 用例——本机钩子存在时，
   live 适配器与 vendored 副本 SHA256 必须一致、live pre-commit 必须含
   `powershell)` 分支与 `\.ps1$` 谓词标记、**解析后的 `core.hooksPath` 必须指向
   用户级 xp-gate**（本机钩子缺席时 Inconclusive，新克隆/CI 不受影响）。
   同组用例补自有 BeforeAll、prune 前缀改从 prune-dirs 文件派生。
4. **诚实口径**：7.4 结论更正如上；AGENTS.md 2026-10-17 条目重写。教训入册：
   引用门禁证据必须读该门禁段的输出行（skip/skip-as-pass/真 PASS 在汇总里
   长得一样）；mtime/尺寸不能证明文件内容未被动过（外部进程会保留旧 mtime）。

**事故的第三种形态（同日 13:57 提交前实测发现）**：`.git/config` 被写入**空的
repo 级 `core.hooksPath`**（12:53:28，与适配器回退同一窗口）——空值覆盖全局
配置后钩子目录回落到无钩子的 `.git/hooks`，**提交完全不跑门禁且零输出**。
若不做「提交时必须看到门禁段输出」的核对，这比文件回退更隐蔽。已恢复为
显式指向 xp-gate（repo 级 + 全局双保险），并由第 4 用例的 hooksPath 判据钉住。
防回退判据至此覆盖三层：**链路接通（hooksPath）→ 文件内容（哈希/标记）→
行为语义（探针）**。

### 7.7 R6 Round-3 评审修复（2026-10-17）

Round 3（三专家独立复测，1 APPROVED / 2 PASS_WITH_CAVEATS，共识 0.67 未达阈值）
以实测探针证实两处 Critical 并提出一批 Major/Minor，Round-4 前全部落地：

| 发现（专家实测） | 修复 |
|---|---|
| **ParseError 被 settings 的 `Severity` 过滤整条丢弃**（裸跑 2 条 MissingEndCurlyBrace；带 Error/Warning settings count=0）——语法损坏的脚本静默过 Gate 1，真实 fail-open | `PSScriptAnalyzerSettings.psd1` 的 `Severity` 加 `'ParseError'`（实测 count=2 拦截；`IncludeRules` 变体实测无效，已在 settings 注释记录）；探针复测：scope 内语法损坏文件 rc=1 + 2 findings |
| pre-commit 无恢复源（未 vendored），回退后套件能红但不能从仓库恢复 | `githooks/hooks/pre-commit` **完整 vendored**；README 恢复步骤补第三条 cp；一致性用例升级为三对 live↔vendored 哈希 |
| live 文件被**删除**（而非回退）时哈希断言静默跳过假绿（专家实测 Passed=27 零 Inconclusive） | 目录存在 ⇒ live 文件必须存在（缺席即红）；vendored 存在性断言移到 Inconclusive 早退之前（CI 也守住） |
| scope/prune 文件 CRLF 行尾 → 条目带 `\r` 路径测试失败 → Gate 1 从真分析静默降级为 WARN | 适配器读循环剥 CR（`${line%$'\r'}`）+ 新增 `.gitattributes` 对三份边界文件与 `githooks/**`、`*.sh` 钉 `eol=lf`（双层）；探针复测：CRLF scope 文件下仍真跑、零 reason |
| prune-dirs 注释称「任意深度」但实现是根锚定 `-path "./$dir"`（文实不符，嵌套条目不生效） | 实现改为 `-name "$dir"`（目录名任意深度，与注释、dot 目录语义一致） |
| XP_G1_REASON 只取首条（`head -1`），多条缺失时诊断不全 | 聚合全部 reason（`paste -sd ';'`）进 GATE_1_DETAIL；`grep -v` 补 `\|\| true`（grep 全匹配时退出码 1，set -e 消费者会中止——AGENTS 陷阱 12 同类） |
| pre-commit 标记断言判别力弱（`powershell)`、`\.ps1$` 在上游文件各 2 处，部分回退可绕过） | 改用分支**专属**标记：`PS_G1_REASON`、`GATE_1_DETAIL="powershell:`、`\.psm1$` |
| `git config core.hooksPath` 未用 `-C` 钉定仓库；`*)` 分支 rc=3 时详情误导 | `git -C $script:Root`；`*)` 分支详情优先用 `$PS_G1_REASON` |
| WARN 语义误读面：WARN 使 verdict 降级但 score 仍 10.0（汇总口径陷阱的同类） | 文档写明「读门禁证据看 verdict 与门禁段输出行，不看 score」；探针复现前置条件（scope/prune 文件 LF + 条目存在）入册 |
| analysis-path-missing 被文档表述为主控制（实为纵深第二层：一致性测试先行红） | 7.5/AGENTS 措辞修正为「两层防御」：一致性测试（第一层，前置）+ 钩子 WARN（第二层，纵深） |

Round-3 评审同时确认的成立项（不再改）：live/vendored 哈希一致、发现 20+18
且 wrc-drill 零泄漏、fail-closed 三态映射正确且 WARN 确实使 verdict 降级、
`_powershell_path_array` 对空格/单引号正确转义、防回退机制存放于不同信任域
（tracked 仓库）设计合理。

### 7.8 第四次改写：xp-gate upstream 更新覆盖硬化（2026-10-20）

xp-gate 升级（钩子文件 10-20 09:14 重写，pre-commit 173K→189K）把三个钩子
文件整体替换为新 upstream 版——**一次合法更新同样能清零硬化**：新版吸收了
#538 的 prune 思路与其余语言修复，但 PowerShell 加固全部缺席（upstream 尚未
吸收 #537 的 scope PSSA / fail-closed powershell 分支）：`PS_G1_REASON`=0、
`powershell)`=0、`\.ps1$` 谓词=0、gate-10 无 Windows semgrep 回退且文件清单
无 ps1/psm1。若直接提交，Gate 1 将退回 skip-as-pass、Gate 10 退回不扫
PowerShell。hooksPath 双写（repo+global）在此次更新中幸存——链路层判据有效。

恢复流程（本次实际执行）：
1. vendored 副本为基底（本仓 githooks/ 即权威硬化版）；
2. diff 确认 upstream 实质增量仅 5 条 prune 路径（plugins/*/skills、
   src/npm-package/*）+ #538 注释，全部合入 vendored；
3. 新 pre-commit 重打三补丁（Gate 1 谓词 + powershell fail-closed 分支 +
   Gate 10 谓词）、gate-10.sh 重打两补丁（APPDATA semgrep 回退 + ps1|psm1）；
4. 三份重新 vendored（哈希一致）→ 探针复测（发现 20+18 / ParseError 拦截
   rc=1+2 findings / 缺 scope 条目发 WARN reason / semgrep 回退命中
   APPDATA 路径）→ 双引擎一致性套件 27/27 → 实弹提交。

**教训**：upstream 更新场景下「文件内容（哈希）」判据**必然变红**——这是
设计行为（vendored 是本仓权威）；恢复不是简单 `cp` 回去，而是「以 vendored
为基、diff upstream、合入 upstream 真增量、重打 PowerShell 补丁」。防回退
机制至此经受四种形态检验：内容回退（保 mtime）/ 文件删除 / hooksPath 断链 /
upstream 更新覆盖。


