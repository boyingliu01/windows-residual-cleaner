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

### 7.4 试金石提交

第三批的全部修复以一次真实 `git commit` 验收：钩子在提交内真跑 PSSA（Gate 1
powershell 分支）+ 全量 Pester + 覆盖率生成与解析（Gate 5）+ semgrep 对暂存 .ps1
扫描（Gate 10）。结果见该提交的质量报告（`.xp-gate/quality-status`）。

### 7.5 R6 走查证实项（2026-10-17，收口补丁）

R6 code-walkthrough Round 1（三专家三模型，commit `a78ac47` 对象）：1 APPROVED /
2 PASS_WITH_CAVEATS，零 Critical。两位专家以临时探针脚本**独立实测复现**同一根因：
analysis-paths 的「硬边界」此前只有散文承诺——scope 条目缺失时钩子静默跳过
（fail-open），根级产品脚本带真告警照样 PASS。证实项当场落实（收口提交）：

| 发现（专家实测） | 落实 |
|---|---|
| scope 条目缺失 → 静默跳过 + PASS（fail-open） | 钩子适配器改为发 `XP_G1_REASON: analysis-path-missing:<路径>`（fail-closed WARN，同 analysis-paths-empty 语义）；超时文案 300 字面量同步改真值 |
| analysis-paths 与覆盖率分母两条边界无交叉校验，可各自腐烂 | 新增「门禁边界一致性」测试组（platform-hygiene.Tests.ps1）：tracked 产品源 ⊆ scope、scope 条目必须存在、coverage-ignore 必须空、prune-dirs 必须含 wrc-drill |
| 发现是 `*.ps1` 端到端，`.psm1` 模块不在三处分母内 | analysis-paths 文件头 R6 note（产品代码保持 .ps1 或扩展机制时三处一起改） |
| ci.yml 硬编码产品清单、引用已清空的 coverage-ignore、标注 727 历史计数 | ci.yml 改读 `.xp-gate-powershell-analysis-paths`（scope 空即 fail），陈旧引用清除 |
| 钩子链在仓库外，新克隆静默降级且 README 未提 | README 新增「Pre-commit quality gates」节（三份 tracked 边界文件 + 一致性测试守卫） |
| wrc-drill/README 仍指向 coverage-ignore | 更正为 prune-dirs 发现阶段剪除口径 |
| drill3 `Test-AdminPrivilege` 桩 `return $true`——非管理员会话静默驱动真实清理 | 改真实管理员检测（WindowsPrincipal），非管理员中止 |
| 「7.2+ 标准实参传递」因果归属被三模式实测否定（三种 PSNativeCommandArgumentPassing 均成功） | 全文更正为「原生实参绑定正确转义（R6 实测三种 passing 模式）」，native-invoke.ps1/测试/CHANGELOG/AGENTS.md 同步 |

R5 钉子中「pwsh 7 期望 exit 0」的引擎行为断言在 R6 复核中保持成立（且与
passing-mode 无关），按原样保留为回归钉。


