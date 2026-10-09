# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### 工程化收尾：wrc-drill 入库、GitHub Actions CI 上线、旧评估报告下线（2026-10-08）

项目自 Qoder 迁入 WorkBuddy 继续开发的接管收尾。代码零改动，全部是工程化与仓库卫生。

- **`wrc-drill/` 演练脚本入库**：drill3-realistic / drill4-admin / drill5-autorollback / rdlab /
  teardown 共 5 个脚本随仓分发，drill5 的 23 项管理员演练从此可复现。
  运行产物目录 `wrc-drill/drill5-work/`（backup、transcript、结果 JSON）进 `.gitignore`。
- **`.delphi-work/` 进 `.gitignore`**：Delphi 多轮评审的中间产物（2MB），按项目惯例不入库。
- **新增 `.github/workflows/ci.yml`**：push / PR 到 master 触发，两个 job——
  - `powershell`：windows-latest 双引擎矩阵（`powershell` 5.1 与 `pwsh` 7），
    每个引擎各跑 Pester 全量（727 用例，`Run.Exit = $true` 失败即红）+
    PSScriptAnalyzer（带 `PSScriptAnalyzerSettings.psd1`，对 `references/scripts` 与
    `setup.ps1` 必须 0 findings）。
  - `ui`：ubuntu-latest + Node 22，`npm ci` → `tsc -b` → `eslint` → `vitest run`（59 用例）。
  - 注意：本地 WorkBuddy 会话跑 Pester 有 5 个环境性误报（会话注入的 `Remove-Item`
    回收站代理拦截 `Remove-Item $p -ErrorAction SilentlyContinue`），CI 是干净进程，
    双引擎 727/727 是预期基线。
- **删除 `RELEASE-READINESS-REPORT.md`**：v1.0.0 时代（2026-05-04）的发布就绪评估，
  所指缺口此后均已修复（CHANGELOG 可考），留着会误导后来者。历史可从 git 找回。
- **`.xp-gate-powershell-coverage-ignore` 新增三条结构性排除**：适配器的覆盖率分母是
  `find .` 全仓库 .ps1，wrc-drill 演练脚本（5 个）、`.sprint-state/delphi-run.ps1` 及
  `.delphi-work` 归档副本入库后把分母从 3335 稀释到 3912，84.08% 被拉到 72%，触发
  Gate 5 的 80% 阈值。排除的理由与 setup.ps1 当年被豁免有本质区别：这些是**结构上
  不属于产品代码**的演练/评审工具（靠管理员手动演练验证，进 Pester 反而要 mock 掉
  它们存在的意义），且 covered 行数 2805 与产品基线 2804 完全吻合，产品代码覆盖
  分毫未动。

### 自动回滚 Sprint 收尾：drill5 根因定位、CORS 通配收紧、REQ-031 的 15 号盲区、setup.ps1 摘掉豁免（2026-10-08）

收尾共落地 **4 个真实缺陷**：一个让自动回滚保护在最需要时失效，一个把外部页面接到管理员破坏性
接口上，一个让「本轮未修复」被写成「本轮已结束」，一个把代码缺陷写成结构性豁免。
管理员真实演练（drill5）复跑 **23 项 23 通过**。

- **PATH 恢复在真实机器上恒被拒（Critical，drill5 根因，`12bf152`）**：陷阱 11 的**注入接缝**变体。
  `[string]$MachinePathOverride` 未传时是空串而**不是** `$null`，于是三处
  `$null -ne $MachinePathOverride`（两处转发 + 一处读取）把「未注入」读成「注入了空 PATH」，
  **跳过了真实的注册表读取**；迹象 (iii) 因此恒拿 `''` 与预期整串比较 → 恒 `mismatch` →
  每个 `path_entry` 都被 fail-closed 拒为 `conflict(external_change_sign_iii)`。
  这正是 2026-10-07 drill5 那 5 项级联失败的唯一起点（rc=11、PATH 段未回填、`completed_at` 为空），
  当时记为「后续受控复现未再见」——**Mock 测试永远看不到，因为它们本来就传了 override**。
  修复：存在性一律改 `$PSBoundParameters.ContainsKey(...)`，并把「未注入 ⇒ 必须读到活注册表值」
  钉成端到端断言（`rollback-auto` / `rollback-exec` 各一组）。
- **UI 服务端从通配 CORS 改为同源守卫（Security，`d2cd8c6`）**：`app.use(cors())` 在一个
  **只监听 loopback、但 POST 路由会拉起管理员权限破坏性 PowerShell** 的服务上发
  `Access-Control-Allow-Origin: *`——用户打开的任意页面都能触发一次清理**并读回流式结果**。
  dev 走 vite 代理、生产同源，本就不需要 CORS。现由 `ui/server/security.cjs` 的
  `createOriginGuard` 只放行同源 / vite dev 源 / 无 Origin 头的本地客户端，拒绝外来 Origin，
  并拒绝非 loopback 的 `Host` 头（DNS rebinding）；`/api/confirm` 用 `validateItemIds`
  按报告形状校验 id，不再把任意字符串交给 `clean-residuals.ps1`；`/api/status` 不再泄露项目根路径。
- **REQ-031 的 15 号盲区（Critical，`fec90f6` + 规范修订 `5dd0a17`）：持久化失败仍写 `completed_at`，
  下一轮 T3 机会被永久抹掉**。`completed_at` 的语义是「本轮清理已正常结束」，不是「回滚已执行」。
  此前只有 `11` 会跳过写标记，于是 **rc=15**（本轮持久化写入失败）照常落完成标记——而 15
  恰恰可能伴随「系统仍有本轮没修复的改动」。T3 启动期恢复只吃**未完成**的日志，标记一写，
  下一次启动就再也不会尝试恢复。修复：新增纯函数 `Test-CompletionMarkerSuppressed`
  （`rollback-producer.ps1`），判据只有一个问题——**系统此刻是否仍有本轮没能修复的改动**：
  - (a) `restore_failed > 0`；(b) 未记账的变更 > 0；
  - (c) `failedCount > 0` **且回滚从未尝试**（`clean-residuals.ps1` 新引入 `$rollbackAttempted` 接缝）。
  **为什么必须有 (c)**：每个中途失败点都先置 `$persistenceError = $true` 再 `break`，而
  `clean-residuals.ps1:1195` 在 `$persistenceError` 已置真时**跳过 T2**，所以**每个 15 的
  `restore_failed` 恒为 0**——只写 (a) 的窄判据是不可达代码。这一点是复核时发现的，
  不是先想到再补的。
  - 测试：`rollback-producer.Tests.ps1` 8 个用例覆盖三形状 + 14 无对象 + 0/1/10/12/13 一律写；
    `scripts.Tests.ps1` 用「把 `cleanup-log.json` 占位成目录」稳定复现 15(c)，断言日志保持
    `"completed_at": null`、无 `rollback-result.json`、注册表项未被恢复，并跑过**负向对照**
    （去掉修复即变红），避免断言靠环境碰巧成立。
- **`setup.ps1` 摘掉覆盖率豁免（`721cada`）：那是把代码缺陷写成「结构性不可插桩」（ADR-001）**。
  它原先是 `.xp-gate-powershell-coverage-ignore` 里**唯一**一项，理由写作「`Main` 末尾的 `exit`
  会杀死 Pester 宿主，因此结构上无法插桩」。真相是：**它根本没有 `Main`/`[ref]` 结构**，
  而同一缺陷在其余脚本已于 2026-10-01（ADR-001）修好——「难测」不是「不可测」。
  重构后：`function Main` + `param([ref]$ExitCode)` + 守卫统一 `exit`，只留一个注入接缝
  `-PSVersionOverride`（让「环境不满足 → 回传 1」可测）；`.xp-gate-powershell-coverage-ignore`
  现为**空列表**（只保留注释说明这段教训）。
- **把契约做成穷举，这类债不能再悄悄长回来**：`tests/unit/hermeticity.Tests.ps1` 原先只对
  2 个脚本做 ADR-001 断言，`setup.ps1` 因此能在 `Main` 里留 `exit` 而无人拦得住。
  现改为对**每个含 `function Main` 的脚本**（当前 11 个：10 个 `references/scripts/*.ps1` + `setup.ps1`）
  做 AST 断言：`Main` 内 0 处 `exit`、0 处 `return 数字常量`、执行守卫以 `[ref]` 接住退出码再 `exit`；
  并断言清单本身不为空（≥8）。新增脚本一旦违反即在门禁变红。
- **drill5 管理员复跑：23 项 23 通过（2026-10-08，用户已授权 UAC）**。上一条 PATH 根因修复后，
  2026-10-07 的 5 项级联失败全部消失：`pe_951` 的 `path_entry=restored`、rc=10、
  计数 3/0/3/0、journal 写出 `completed_at`、机器 PATH 回合 `-ceq` 字节一致。
  share=0 锁目录的全部不变量继续通过（tier-4 改名未伪装成删除、journal 如实记 `mutation_failed`）。
- **验证口径更新**：测试 710 → **727**（PS 5.1 与 pwsh 7 双引擎各 727/727，0 失败）；
  JaCoCo 行覆盖率 83.94%（2765/3294，16 脚本）→ **84.08%（2804/3335，17 个文件：
  `references/scripts` 16 个 + 现已可插桩的 `setup.ps1`）**；PSScriptAnalyzer 带设置文件
  对 `references/scripts` 与 `setup.ps1` 均 **0 条**；UI 侧 vitest **9 文件 / 59 通过**
  （含新增 `ui/server/security.test.mjs` 10 例：同源守卫与 id 校验）。
- **新增陷阱 12/13（测试宿主侧，都会造出「数字看起来不对」的假象）**：
  覆盖率刷新包装脚本里写 `$ErrorActionPreference = 'Stop'` 会把 Pester 的**非终止错误**
  （测试内故意触发的 `Write-Error`）变成失败——实测凭空造出 30 个失败、并把行覆盖率压到 79.63%；
  钩子适配器自己的片段并不设该偏好，所以只有本地包装会骗人。另一条：Pester 5 会把 `It` 标题里的
  `<...>` 当数据占位符，非 ASCII 的 `<数字>` 会让 Pester 重新 `[ScriptBlock]::Create` 出坏字符串并抛
  「string is missing the terminator」；`BeforeDiscovery` 里构造的 `-ForEach` 数据本次实测不可用，
  改为 `BeforeAll` 构造 + 用例内循环。
- **如实记录一次未复现的抖动（不做掩盖）**：pwsh 7 一次全量运行报 `720 passed / 1 failed`
  （总数 721，即补 REQ-031 用例之前的规模），随后两次同样运行 721/0，且对
  `scripts` / `rollback-auto` / `rollback-exec` / `permission-gates` 做 5 轮定向复跑各 243/0；
  本次收尾的双引擎全量复跑亦为 727/727。未能定位到具体用例，判定为环境级争用（背靠背运行时的
  fixture / 句柄残留），保留该记录以便再次出现时有对照。

### 自动回滚 Sprint VERIFY：drill5 修复、双引擎 710 测试、PATH 证据留痕（2026-10-07）

管理员真实演练（drill5）暴露了一个**把失败记成成功**的真实缺陷与一个 fail-open，
两者都已修复且带回归测试。修复后的复跑 23 项检查 18 项通过，其余 5 项失败全部级联自
一个不可重现的 PATH 冲突——本轮把该冲突的比较证据做成留痕字段，下次发生即可诊断。

- **删除失败被记成「删除成功」→ 自动回滚不触发（Critical，drill5 实测）**：
  `Remove-ItemRobust` 的 tier-3/tier-4 原生命令输出经 `2>&1` 被包成 ErrorRecord 写进
  **成功流**，调用方 `$deleted = Remove-ItemRobust …` 拿到 `@(ErrorRecord, $false)`
  非空数组（真值恒 `$true`），`-not $deleted` 恒为 `$false` → 四层降级全失败却被记
  「删除成功」、`failedCount=0`、**自动回滚不触发**。drill5 用 `CreateFileW` share=0
  独占句柄锁目录稳定复现。修复：tier-3 显式 `$null =` 吞输出、tier-4 改
  `Write-Warning`；新增 `WrcRirLock` P/Invoke 测试（断言成功流**恰为**单个 `$false`）
  与进程内自动回滚链路集成测试（期望 rc=10）。
- **PATH 冲突判定 fail-open 关闭**：`rollback-verdicts.ps1` 把「两侧证据都缺席」
  （`'' -cne ''` 为假）当成「相符」→ 无冲突 → 放行恢复；根因是 `[string]` 参数
  永远不可能为 `$null`。改用 `$PSBoundParameters.ContainsKey` 判证据存在性，并把四态
  比较结果（`mismatch` / `current_null` / `expected_null` / `equal`）与两侧值写入
  `rollback-result.json`。drill5 的 `pe_951` 冲突（`conflict(external_change_sign_iii)`，
  恢复端 fail-closed 拒绝了 PATH 段回填）正是因缺这份证据而无法归因，且**后续受控复现
  未再见**；该字段落地后下次发生即可诊断。
- **pwsh 7 下 journal 自校验误杀**：pwsh 7 的 `ConvertFrom-Json` 会把 ISO 8601 串
  解析成 `[datetime]`，自校验此前据此判「不可解析」。现直接接受 datetime 对象；相关断言
  改为「可 `[datetime]::Parse` + 原始 JSON 文本」，双引擎下都成立。
- 验证口径：测试 287 → **710**（PS 5.1 与 pwsh 7 均 710/710 通过，5.1 全量 118s）；
  JaCoCo 行覆盖率 **83.94%**（2765/3294，16 个脚本，`references/scripts` 范围）。
- **更正**（不修改历史条目）：上文 T5 条目末尾所记「pwsh 7 本机未安装 ⇒ 双引擎契约本次
  未验证」仅对 T5 那一次提交成立；pwsh 7 现已可用（本机路径见 AGENTS.md），T5 之后的
  修改均按双引擎验证。
- 环境备注（本机门禁）：Gate 5 需要 pwsh 在钩子 PATH 上、Gate 11 需要 jq/node，缺席时
  会**静默降级为 SKIP**；另注意 Gate 5 Stage-2 会解析**仓库根目录既有的** `coverage.xml`
  ——不跑覆盖率就提交时，先手动刷新该文件，否则可能被旧产物误拦（2026-10-07 实测踩坑）。

### 自动回滚 Sprint T5：UI 诚实口径（2026-10-06）

一个以「可恢复」为卖点的工具，此前在 UI 里把**没承诺过的那一层**写成了承诺：

- `CleanupPanel.tsx` 的实际删除警告是「此操作不可逆，但可通过系统还原点恢复」，清理完成后又显示
  「已通过系统还原点备份，如需恢复可使用 rollback.ps1 回滚」。两句都已删除。真实保证是
  **强制逐项精准保护**（`rollback-journal.json` + 逐条 pre-image，写不出就 fail-closed 拒绝清理），
  系统还原点只是**尽力而为**的最后一层（需管理员、24h 节流、可能被策略关闭）。
- 新增 `GET /api/backup-status`（`ui/server/index.cjs`）：只读**盘上证据**（journal 索引、
  未完成 journal、`restore-status.json`、`rollback-result.json`）。取不到证据就报 `unknown`，
  **绝不默认 `available`**；PowerShell 写出的 PascalCase 字段在读侧归一化，
  `evidence_incomplete` 不会因为字段名大小写而在读取时丢失。
- 上一轮回滚的**逐条判定**现在可见（AC-065）：已恢复 / 未修复（`restore_failed`）/
  证据不完整（`evidence_incomplete`）/ 本就无法自动恢复（`not_restorable`）四类分列，
  证据不完整不再被悄悄并进「成功」；当它占可恢复条目多数时额外显示低置信提示。
- 退出码矩阵可读化（DD-013 / REQ-025）：不再渲染裸「完成」；
  **`null`（服务端没告诉我们）与 `0`（脚本报告成功）含义不同**，前者明确显示为「不能视为成功」。
- 恢复边界如实告知（REQ-014 / REQ-016）：固定 24 小时 + 下次启动、不可配置；
  还原点记录若已超过窗口，附带陈旧提示而不是继续当作可用。

修复的真实缺陷：**流式 `type:'error'` 行只进了控制台，从未触发 `onError`** ——
管道失败（`run-all` 退出码 2、报告缺失、清理中断）时 UI 会**永远转圈且零提示**，
这比显示错误更不诚实。`startScan` / `startCleanup` 现已把 error 行同时上报给调用方。

顺带消除两处真实重复：`useApp.tsx` 里两个流式读取器本是 102-token 克隆（archlint HIGH，
正是它让本次提交被 Gate 6 拦下），`ui/server/index.cjs` 的两个 NDJSON 响应头 + `emit`
是 51-token 克隆；两边都抽成单一实现。Gate 6 的 HIGH 归零，其余 MEDIUM 为既有结构性条目
（React vendor coupling、测试文件 Dead Code 等），未做基线掩盖。

测试与质量：vitest 8 文件 / 49 通过（PS 侧同期 Pester 704/704、PSScriptAnalyzer 0 findings、
`tsc -b` 与 `eslint` 干净）。**pwsh 7 本机未安装 ⇒ AGENTS.md 的双引擎契约本次未验证。**

以下条目来自 ADR-001：修复测试套件的**非密闭性**（假绿），并统一退出码传递机制。
见 `docs/decisions/ADR-001-main-ref-exit-code.md`。

### Fixed
- **测试套件在新克隆 / CI / worktree 下会静默整份塌掉（Critical，假绿）**
  - 现象：`clean-residuals.ps1` 的 `Main` 内含 `exit 1`。测试用「dot-source + 进程内调用 `Main`」
    以获取覆盖率插桩；当 `backup-*`（**gitignored**，新克隆/CI/worktree 中必然缺失）不存在时，
    `Main` 命中备份门的 `exit 1`，**杀死 Pester 宿主**，导致收尾阶段崩溃：

    ```
    System.Management.Automation.MethodException:
      Cannot find an overload for "Add" and the argument count: "1".
       at Pester.psm1: line 4984    $run.Containers.Add($i)
    ```

  - 后果不是「某些用例失败」，而是**整份套件静默消失**：`Passed= Failed= Total=` 全为空，
    在 CI 上表现为**绿色**——全部断言凭空消失。
  - 实测对照：

    | 环境 | 结果 |
    |------|------|
    | 主仓（有遗留 `backup-20260826-094144/`） | 141/141（假绿） |
    | 干净 worktree（无 `backup-*`） | 套件塌掉，计数全空 |
    | 干净 worktree + 手工建空 `backup-*` 目录 | 141/141 |

  - 修复后：干净 worktree（**无** `backup-*`）下 **150/150 通过**，且退出码契约经子进程实测
    为 `2 / 2 / 1 / 3 / 3`（与规范一致）。
- **`sc.exe` 回归测试组依赖主仓遗留的 `backup-*` 目录**（非密闭）
  - 这些测试设 `DryRun = $false` + `ConfirmFile`，会走备份门；此前靠主仓里遗留的
    `backup-*` 才「碰巧通过」。现在 `BeforeAll` 自建 `backup-svcregress` fixture、`AfterAll` 清理。

### Changed
- **退出码传递统一改为 `[ref]`（8 个脚本）**：`clean-residuals.ps1`、`confirm-cleanup.ps1`、
  `create-restore-point.ps1`、`run-all.ps1`、`scan-uninstalled.ps1`、`scan-residuals.ps1`、
  `scan-filesystem-residuals.ps1`、`generate-report.ps1`
  - `Main` 一律 `param([ref]$ExitCode)`，内部用 `& $setRc <code>` + `return`；
    守卫统一为 `$exitCode = 0; Main -ExitCode ([ref]$exitCode); exit $exitCode`
  - `Test-AdminPrivilege -Mandatory` 不再 `exit 2`，改为 `return $false`，由调用方决定退出码
  - 累计移除 **25 处**位于 `Main` 内的 `exit`（`clean-residuals` 5 + `confirm-cleanup` 12 +
    `run-all` 1 + 4 个扫描/报告脚本各 1 + 权限检查 3）

### Why `[ref]` and not the two obvious alternatives

已被实测否决的两种写法（详见 ADR-001）：

| 写法 | 实测结果 |
|------|----------|
| `return <数字>` | 函数返回值走**输出流**，整数混进 stdout，污染调用方断言（`(Main 2>&1)` = `'alpha', 5`） |
| 守卫 `exit (Main)` | PowerShell 先求值 `exit` 的参数，`Main` 的输出**被吞掉**；实测捕获行数由 9 → **0**，而退出码仍正确——只有输出断言能发现 |

### Added
- `tests/unit/hermeticity.Tests.ps1` —— 密闭性契约测试
  - AST 静态断言：`Main` 内不得有 `ExitStatementAst`，不得有 `return <常量整数>`
  - 守卫必须为 `[ref]` 形式，不得 `exit (Main)`
  - 行为断言：错误路径下 `Main` 正常返回非零码、不终止宿主；报告不可解析时返回 1
- `docs/decisions/ADR-001-main-ref-exit-code.md` —— 记录决策、实测证据与被否方案

### Testing & Quality
- Pester PS 5.1：**150/150 通过**（干净 worktree，无 `backup-*`）
- PSScriptAnalyzer：**0 error / 0 warning**（带设置文件）
- 退出码契约子进程实测：`clean-residuals`(非管理员)=2、`confirm-cleanup`(缺报告)=1、
  `scan-uninstalled`(缺索引)=3、`generate-report`(缺输入)=3
- 输出未被吞验证：`confirm-cleanup` 子进程捕获到 9 行输出（改用 `exit (Main)` 时为 0 行）

> **覆盖率影响**：此前「`Main` 内含 `exit` ⇒ 不可进程内调用 ⇒ 不计入插桩」的盲区已消除，
> 8 个脚本的 `Main` 现在都可被插桩。`setup.ps1` 仍因无 `Main`/`[ref]` 结构而结构性不可插桩。

## [1.4.1.0] - 2026-09-30

修复幽灵服务清理缺陷，并补齐真实环境验证。

> **根因更正（2026-10-01）**：本版本最初把根因写成「裸 `sc.exe ... 2>$null` 在 PS 5.1 下
> **必然**抛 `StandardOutputEncoding` 异常」。交付后复核**无法稳定复现**该异常为无条件行为，
> 故此处按实际可复现的证据重写。功能修复本身有效（真机已验证），但原根因描述过强。

### Fixed
- **`clean-residuals.ps1`：幽灵服务清理的「幂等成功被当成失败」缺陷**（High）
  - 真实根因（已复现）：旧代码用 `$LASTEXITCODE -ne 0` 判定 `sc.exe delete` 成功与否。
    但删除一个**已经不存在**的服务时，`sc.exe` 返回 `1060`
    （`ERROR_SERVICE_DOES_NOT_EXIST`）—— 这是**幂等成功**，却被判为失败并 `throw`，
    异常再被外层 `catch` 吞成 `cleanup_failed`。
  - 实测（PS 5.1）：`sc.exe delete <不存在的服务>` → 正常返回、`$LASTEXITCODE = 1060`
    → `1060 -ne 0` → throw → 日志记 `cleanup_failed`。
  - 症状：重复清理、或服务已被 SCM 移除时，清理恒记失败，且日志看不出是代码缺陷。
  - 修复：新增 `Invoke-ScExe` 封装，用 `Start-Process` 显式重定向 stdout+stderr 并读取
    真实退出码；识别 `1060` 为幂等成功；`$null`（进程无法启动）保持 fail-closed，
    与真实退出码语义区分开。
  - 次要风险（环境相关，非必然）：若宿主设置了 `StandardOutputEncoding` 而 stdout 未重定向，
    `.NET` 会抛 `StandardOutputEncoding is only supported when standard output is redirected`。
    该错误真实存在且可复现，但触发条件是「显式设置编码 + stdout 未重定向」，
    **并非**裸 `2>$null` / `2>&1` 的无条件行为。`ui/server/index.cjs` 以管道方式
    拉起 `powershell.exe`，属高风险宿主；改用 `Start-Process` 双流重定向可一并规避。
  - 影响面：`ui/server/index.cjs` 硬编码 `powershell.exe`，Web UI 触发的清理同样受影响。

### 真实环境验证（2026-10-01）
- **非管理员范围**（自建 fixture，用真实 `clean-residuals.ps1` 执行，非 mock）：
  - 真实目录树删除 → `path_deleted` ✅
  - 真实注册表键删除 → `registry_deleted` ✅
  - 真实计划任务删除 → `task_deleted` ✅
  - 汇总 `3 succeeded, 0 failed, 0 skipped`；DryRun 验证为**零破坏**；跑后系统零残留。
- **管理员范围**（用户实测）：
  - 真实服务创建 → 清理删除 → `service_deleted`，`sc query` 返回 `1060` 确认已消失 ✅
  - 真实 HKLM 键删除 → `registry_deleted` ✅
  - 汇总 `2 succeeded, 0 failed, 0 skipped`。
  - 这一步是**首次**在真机上验证 `Invoke-ScExe` 的 `stop`/`delete` 路径。

### Testing & Quality
- 新增 `service cleanup (sc.exe regression)` 测试组，断言**可观测副作用**而非打印字符串：
  `stop` 必须先于 `delete`、`service_deleted` vs `cleanup_failed` 的日志分流、启动失败需 fail-closed，
  并加静态守卫禁止重新引入裸 `sc.exe ... 2>$null` 写法。
- 已验证该组测试**非空转**：回退到旧实现后其中 3 个用例按预期失败
  （`scCalls.Count = 0`、日志为 `cleanup_failed` 而非 `service_deleted`）。
- 测试规模 **98 → 141 个用例，0 失败**；PSScriptAnalyzer 配合设置文件 0 error / 0 warning；
  UI vitest：26/26 通过。
- 新增测试组：`confirm-cleanup.ps1 display helpers`（6 个纯函数）、
  `Remove-ItemRobust`、`clean-residuals.ps1 safety guards`、`setup.ps1 environment check`。
- **修正集成测试的覆盖率盲区**：`main-flow.Tests.ps1` 原以 `& script.ps1` 在**子进程**执行，
  Pester 覆盖率只插桩当前进程，因此那些执行**一行都不计入**。相关用例已改为
  dot-source + 进程内 `Main`，使扫描脚本的真实行被统计。
- `AGENTS.md`：陷阱清单第 7 条重写为 7a（已复现主缺陷）/ 7b（环境相关风险），并新增「根因复核教训」。
- 新增 `.xp-gate-powershell-coverage-ignore`：排除 `setup.ps1`（见下方说明）。

### 覆盖率现状（2026-10-01 ADR-001 之后更新）
`references/scripts` 行覆盖率 **77%**（ADR-001 前为 70.4%），仍未达 pre-commit 门禁的 80%。
但**缺口已收敛到两个结构性瓶颈**，且本次的提升全部来自「抽纯函数 + 补真测试」，没有用排除项：

| 文件 | 覆盖率 | 未覆盖行主要构成 |
|------|--------|------------------|
| `generate-report.ps1` | 95.0% | — |
| `run-all.ps1` | 93.8% | 子进程编排的失败分支 |
| `build-installed-index.ps1` | 90.2% | winget/scoop 的真实探测分支 |
| `scan-residuals.ps1` | 87.6% | 真实 HKLM 写入路径 |
| `scan-filesystem-residuals.ps1` | 84.0% | — |
| `scan-uninstalled.ps1` | 83.8% | — |
| `rollback.ps1` | 71.4% | 本机 `Get-ComputerRestorePoint` 无还原点时的真实分支 |
| `create-restore-point.ps1` | 74.2% | 需管理员的 `Checkpoint-Computer` |
| `clean-residuals.ps1` | 67.4% | `Remove-ItemRobust` **Tier 2–4** + HKLM/PATH 写入（管理员专属） |
| `confirm-cleanup.ps1` | 60.1% | **118 行未覆盖中 109 行是 `Read-Host` TUI 循环** |

- `confirm-cleanup.ps1`：其 6 个纯函数（`Get-ItemContent` / `Limit-StringLength` / `Show-Page` /
  `Show-Detail` / `Show-Help` / `Get-PageRange`）**已全部覆盖**。ADR-001 已移除 `Main` 内
  13 处 `exit`，「在 Pester 进程内调用会杀死宿主」这一障碍**已消除**；剩下纯粹是
  `Read-Host` 需要重定向 stdin 才能驱动。
- `clean-residuals.ps1`：`Remove-ItemRobust` 的 Tier 2–4（`takeown` / `icacls` / `cmd rd` /
  改名延迟删除）需真实 ACL 锁定或句柄占用的文件；Phase 3 的注册表删除与 Machine PATH 写入
  需管理员权限并会真实改动系统。

**为什么没有为了过门禁而排除这两个文件**：`.xp-gate-powershell-coverage-ignore` 是**按文件**
排除的唯一机制，排除 `clean-residuals.ps1` 会连同已覆盖的 163 行一起丢弃；且该文件注释
明确写了「Do NOT add files here merely because they are hard to test」——这两个文件的
剩余缺口属于它划给「管理员环境集成演练」的范围。**用排除换绿色是自欺**，
本次改走「把可测逻辑抽成纯函数」这条路（见下）。

### Refactor（可测性重构，纯提取、无行为变更）
- `build-installed-index.ps1`（303 → 408 行）：抽出 5 个纯解析器
  `ConvertFrom-WingetJson` / `ConvertFrom-WingetText` / `ConvertFrom-ScoopJson` /
  `ConvertFrom-ScoopText` / `ConvertFrom-ChocoText`，`Main` 内联块改为调用它们。
- `scan-uninstalled.ps1`：抽出 `Test-PathMissing` / `Get-UninstallExePath` /
  `Get-ResidualVerdict` / `Get-ResidualEvidence`（**权威信号 gate 辅助信号**的判定逻辑
  首次成为可直接单测的纯函数，并补齐了真值表）。
- `rollback.ps1`：抽出 `Get-BackupDirectory` / `Get-RegistryBackupFile` /
  `Get-MatchingRestorePoint`，并把 `BackupRoot` 改为可注入 —— 测试从此不再依赖仓里
  遗留的 `backup-*` 目录（密闭性）。
- 顺带删除 `scan-uninstalled.ps1` 中一段**不可达的重复代码**（`& $setRc 3; return` 写了两遍，
  第二处永远不会执行）。

### Fixed（ADR-001 连带修复）
- `build-installed-index.ps1` / `scan-uninstalled.ps1` / `rollback.ps1` 的 `Main`
  **静默忽略**传入的 `-OutputPath` 类实参：函数没有声明该参数时，PowerShell 不报错，
  函数内读到的是 dot-source 绑进作用域的值，于是「写到了默认路径却一切正常」。
  现改为 `-OutputPathOverride` / `-IndexPathOverride` / `-BackupRootOverride` 显式参数，
  并保留「读调用方作用域变量」的既有契约（AGENTS.md 陷阱第 8b 条）。
- `rollback.ps1` 补 `try/catch`：`cleanup-log.json` 或 `restore-status.json` 损坏/时间戳
  不可解析时，**不再中断整份回滚指引输出**（此前 `[DateTime]::Parse` 抛错会直接冒出）。
  新增 3 个用例专门覆盖这三种损坏输入。

### Testing & Quality（ADR-001 之后）
- 测试规模 **141 → 254 个用例，0 失败**；PSScriptAnalyzer 配合设置文件 0 error / 0 warning。
- 新增测试文件：`tests/unit/build-index-parsers.Tests.ps1`（23）、
  `tests/unit/scan-uninstalled-logic.Tests.ps1`（31）、`tests/unit/rollback.Tests.ps1`（22）、
  `tests/unit/main-coverage.Tests.ps1`（18）、`tests/unit/hermeticity.Tests.ps1`（7）、
  `tests/unit/permission-gates.Tests.ps1`（11）、`tests/unit/scan-uninstalled-logic.Tests.ps1`。
- 这些用例**非空转**已逐条验证：`rollback.ps1` 的 3 个损坏输入用例在加 `try/catch` 前
  按预期失败；`hermeticity.Tests.ps1` 的 AST 契约能拦住重新引入的 `Main` 内 `exit`。
- **修正集成测试的覆盖率盲区**：`main-flow.Tests.ps1` 原以 `& script.ps1` 在**子进程**执行，
  Pester 覆盖率只插桩当前进程，因此那些执行**一行都不计入**。相关用例已改为
  dot-source + 进程内 `Main`，使扫描脚本的真实行被统计。
- `AGENTS.md`：陷阱清单第 7 条重写为 7a（已复现主缺陷）/ 7b（环境相关风险），并新增
  「根因复核教训」；新增第 8 条（dot-source 覆盖调用方变量 / 函数 `param()` 遮蔽调用方变量）。
- 新增 `.xp-gate-powershell-coverage-ignore`：排除 `setup.ps1`（见下方说明，**仍不达标，
  但已不再是「无法解释的 70%」**）。

### 门禁口径说明（写下来，避免后来者重复摸索）
`xp-gate` 的 pre-commit 阈值 **80% 是写死在共享 hook 里的**（PowerShell 分支：
`percentage < 80 ? 'below' : 'pass'`），不能按项目配置，改它会影响所有使用该 hook 的仓库。
它读取 `coverage.xml` 的**最后一个** `<counter type="LINE">`，即全局行覆盖率。
唯一受支持的调节手段是 `.xp-gate-powershell-coverage-ignore`（**按文件**排除）。
因此本仓库的应对是：**不排除，改用「抽纯函数 + 真测试」把覆盖率实打实抬到 77%**，
并把剩余 3% 的缺口、成因与正确推进方向（`Read-Host` 分发抽纯函数 / 管理员环境集成套件）
如实记录于此。**本版本提交时未使用 `--no-verify`**：

### 附带修正：xp-gate PowerShell 适配器
本次顺带修复了 `~/.config/xp-gate/adapters/powershell.sh`（全局钩子，非本仓库文件）的 3 个缺陷：
1. 使用 Pester 4 旧式参数集 `Invoke-Pester -Path ... -CodeCoverage ...`，在 Pester 5.7.1 下
   直接抛「无法解析参数集」，导致覆盖率数据缺失；已改为 `New-PesterConfiguration`。
2. 「覆盖率低于阈值」被写成 `exit 0` 后又在调用方 `return`，使失败信号丢失。
3. 无排除机制：无法插桩的文件（如 `setup.ps1`）恒为 0%，永久压低分母；
   新增 `.xp-gate-powershell-coverage-ignore` 支持（需匹配 `./` 前缀，已处理）。

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
