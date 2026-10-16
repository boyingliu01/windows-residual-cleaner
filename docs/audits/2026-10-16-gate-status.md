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
