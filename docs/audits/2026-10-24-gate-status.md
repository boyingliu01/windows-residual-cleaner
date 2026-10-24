# 2026-10-24 门禁真生效审计

> 承接 `2026-10-16-gate-status.md`。那份审计记录了「官方 13 道门禁里 3 道对
> PowerShell 零覆盖」，本份记录**后续做了什么、实测证据是什么、还剩什么**。
>
> 判定方法只有一条：**只改 `.ps1` 的提交，逐门看它到底跑了什么**，不看报告
> 怎么写自己。报告说 PASS 不算数，`SKIP` 与 `PASS` 必须能分开读出来。

---

## 1. 起因：一句「通过」背后什么都没跑

一次只改 `.ps1`（产品和测试都在内）的提交，钩子给出的报告是：

```
Gate 1: PASS   Gate 2: SKIP   Gate 3: SKIP   Gate 4: SKIP   Gate 5: PASS
Gate 6: PASS   Gate 9: SKIP   Gate 10: SKIP  Gate 11: PASS  Gate 12: PASS
Overall Score: 10.0/10 | verdict: PASS
```

`10.0/10` 与「verdict: PASS」在算术上是自洽的——SKIP 被排除在有效分母之外。
问题在于**这张表无法回答「哪道门真的检查了我的代码」**：

| 门 | 报告 | 实际发生的事 |
|----|------|--------------|
| Gate 3 复杂度 | SKIP | 没有 PowerShell 复杂度工具，从未测量过任何 `.ps1` |
| Gate 4 安全 | SKIP | 发现谓词只认 TS/JS |
| Gate 10 SAST | SKIP | 谓词其实接受 `.ps1`，本次提交的文件不在其判定集合内 |
| Gate 11 Sprint | **PASS** | sprint 已过期 21 天，`.sprint-state/` 被 gitignore，**什么都没检查** |
| Gate 5c 对齐 | （无此行） | `req-ids.json` 缺席 → 整段短路，**零输出**，连 SKIP 都不是 |

后面两条是本次的主要目标：**它们不是「没跑」，而是「没跑却显示成跑了 / 显示成什么都没发生」**。

---

## 2. 逐门实测结论

### Gate 0 / Gate 1（静态分析、PSScriptAnalyzer）

- Gate 1 已真跑：`Running PSScriptAnalyzer static analysis… ✅ PASSED - PowerShell code quality`。
- 范围由 `.xp-gate-powershell-analysis-paths` 收敛到 `references/scripts` + `setup.ps1`
  （产品源 18 个文件），**实测 0 findings**。
- 全仓裸跑 PSSA 会有 827 条告警，其中绝大多数是 Pester 执行模型（`$PSScriptRoot` 注入、
  `Describe/It` 不调用等）在测试文件上的规则误报——收范围而非放宽规则，与 10-16 审计一致。
- fail-closed 已就位：`XP_G1_REASON` 的 `analysis-path-missing` / `analysis-paths-empty` /
  `analysis-settings-missing` / `module-missing` 四种失配都会 WARN 计入分母，不静默 PASS。

### Gate 2（重复代码）/ Gate 3（复杂度）/ Gate 4（安全）

- **对 PowerShell 仍然是零覆盖**，这是上游能力缺口而非配置问题：jscpd 有 PowerShell 支持但
  未被适配器调用；复杂度工具（`ccn-ratchet.sh` 等）只处理 JS/TS。
- 结论：**如实保持 SKIP**。不伪造测量，也不把「没测」写成「通过」。
- 已向 xp-gate 提交 #537（Gate 3/4/6 对 PowerShell 零覆盖，本次审计未新增信息，仅确认仍成立）。

### Gate 5（测试 + 覆盖率）—— 本次投入最大的一门

原判「Gate 5 对 PowerShell 是空转」**是错的**：Stage-2 的 PowerShell 分支确实存在
（解析 `coverage.xml` 的 LINE counter，`<80%` → BLOCK），并且适配器会真跑 Pester
（实测 `Starting discovery in 20 files. Discovery found 757 tests`）。

真正的问题是**产物可信性**，实测踩到两种污染形态：

1. **23 个 sourcefile / 79.63%**：一次用默认 CodeCoverage 配置的会话把 `.workbuddy/`（3 文件）
   与根目录本地脚本混进了报告，顶层 counter 随之失真；
2. **2 字节 / 0 个 sourcefile**：产物被整个写成空文档，`COVERAGE_PERCENT` 解析不出数字。

而 `coverage.xml` **不是**「低覆盖率」时被拦，而是「0 或解析不出」时被**放行**——
因为门禁写的是 `-gt 0`，于是「什么都没测」被当成「无法判定，算了」（上游 #570）。

**下游修法（vendored + live 双写）**：

- `-gt 0` → `-ge 0`：**0% 是数据，不是缺失**。一个一行产品代码都没测到的套件必须被拦。
- 新增 **coverage report integrity** 检查：把适配器发现到的 `*.ps1`（去掉 `*.Tests.ps1`）
  与 `coverage.xml` 里的 `<sourcefile name="...">` 求差。
  - 报告里 **0 个** sourcefile → **BLOCK**，因为「上面那个百分比描述的是一份空报告」；
  - 部分缺失 → 打印 `ℹ️ Coverage denominator delta: N 个在报告里 vs M 个被发现` 加未入报告的清单；
  - 全齐 → `✅ Coverage report integrity: N/M discovered source files present`。
  - 设计取舍：分母用**适配器的发现**，不从 ignore 文件减扣——「缺席的文件」是本检查能看见的
    算术，「被错误排除的文件」则是看不见的。
- 权威口径仍是 **18 个 sourcefile（`references/scripts` 17 + `setup.ps1`）**，
  与 AGENTS.md「coverage.xml 的口径与污染」条目一致。

### Gate 5c（Spec/Test Alignment）—— 从「没有这回事」变成真的会拦

实测缺口有三层，逐层都静默：

1. `req-ids.json` 缺席（`.sprint-state/` 被 gitignore，`check-alignment` 从未跑过）→ 整段短路；
2. `jq` 不在钩子的 PATH 上 → 同一段再短路一次；
3. 测试文件发现只认 `*.test.ts` / `*.spec.ts` 一类命名，**Pester 的 `*.Tests.ps1` 一个都匹配不上**。

**下游修法**：

- 仓库内新增 `.xp-gate-req-ids`（135 个 id：35 REQ + 100 AC），版本控制内、单一真相源，
  由 `.xp-gate-req-ids.cjs` 从 `specification.yaml` 生成；
- `platform-hygiene.Tests.ps1` 新增一组用例守着**双向一致**（spec 有的清单必须有、
  清单有的 spec 必须还有）+ BOM 检查 + 生成器可跑；
- hook 内新增 `Gate 5c-ps` 块：staged 的 `*.Tests.ps1` 里每个 `@test AC-xxx` / `@test REQ-xxx`
  必须能在清单里找到，否则 **BLOCK**——「注解指向了已被删除的需求」= 一个永远无法为它失败的测试。
- 实测：`✅ Gate 5c-ps: 51 Pester annotation(s) match .xp-gate-req-ids`（本次提交的测试文件范围内）。

**语义对齐的实际产出**：用 `.workbuddy/align.cjs` 把 696 个 `It` 块逐条对 135 个 spec id
打分（字符 3-gram + IDF，按候选自身权重归一化），人工复核后给 **81 个用例**加上了注解，
覆盖 **33 个 id**。过程中发现两类真实缺口：

- `create-restore-point.ps1` 的还原点相关 bUnit 用例实际只断言了「返回值/告警」，
  AC-013 的「UI 文案不出现『已通过系统还原点备份』」在 Pester 侧无证据（属 UI 侧，见 `ui/`）；
- 评分器把同族用例整批指向同一个 id（所有 `fail-closed` 用例都像 AC-022），
  因此**每一步都人工复核**，未采纳的提案保留了理由。

仍未有任何证据的条目见报告末尾清单——**不自动下结论**，形如「只有 UI 侧证据 / 属管理员演练范围」
与「真的没有断言」需要区分，这需要逐条判断。

### Gate 6（架构）

- `architecture.yaml`（8 层）与 `.architecture-baseline.json` 已入库，`archlint diff` 实测
  `✓ No architectural changes detected.`（baseline 内 5 High Cyclomatic / 13 Dead Code /
  3 High Cognitive / 2 Vendor Coupling 为存量如实记录）。
- **但对 PowerShell 仍不生效**：hook 的 PowerShell 分支在 Gate 6 处是硬编码跳过（见 #537）。
  也就是说 `architecture.yaml` 描述的那 8 层，目前只对 `ui/` 的 TS 代码有约束力。
  这是「配置存在但不承重」的典型形态，已并入 #537。

### Gate 9 / Gate 10 / Gate 12

- Gate 9（构建完整性）对非 TS 项目如实 SKIP。
- Gate 10 的 `SEMGREP_FILES` 谓词**已经**包含 `ps1|psm1`（实测确认），本次只改文档的提交
  因「无受支持文件」而 SKIP 是正确的。semgrep 1.171.0 就位后，含 `.ps1` 的提交会真扫描。
- Gate 12（工作区卫生）正常。

### Gate 11（Sprint Flow）—— 从「永远恰好跳到 PASS」到三种状态可区分

这一条比最初判断的更有意思：**存在两个独立缺陷，而且它们互相掩盖**。

#### 缺陷 A：JSON 解析器够不着，门禁被降级成「什么都没读」

`sprint-gate.sh` 需要 `jq` 或 `node` 才能解析 `.sprint-state/sprint-state.json`。
`jq` 本机没装，`node` 装在 `C:\Program Files\nodejs`，但 **git-bash 不继承**调用方
在 Windows 侧追加的 `PATH` 条目。于是实测输出是：

```
{"decision":"skip","warning":"sprint-state.json is not valid JSON or no JSON parser available (install jq or node), allowing commit"}
```

**恰好在本仓库，这个降级路径给出的 `skip` 是正确的**——所以缺陷 A 单独存在时
不会被注意到，它是一种「用错误理由得到正确结果」的假绿。

#### 缺陷 B：`allow` 不区分「验证通过」与「读不到所以放行」

把 `node` 摆到门禁能看见的位置后，真实输出变成：

```
{"decision":"allow","message":"delphi-review APPROVED, sprint phase 6 validated (sprint open 21 day(s), staleness threshold 14)"}
```

也就是说 sprint 状态**是**有效的（`phase=6`、delphi `APPROVED`），只是已开 21 天
超过 14 天阈值——而 `sprint-gate.sh` 对过期 sprint 的处理是**照样 allow**。
它把「过期」写进了 message，但 `decision` 字段仍然是 `allow`，于是 hook 映射成 **PASS**。

两种形态的共性：`decision` 只有三态，**「验证过并通过」与「没法验证但放行」不可区分**。

#### 下游修法（vendored + live 双写）

1. **让解析器够得着**：Gate 11 调用 `sprint-gate.sh` 前探测标准安装位置
   （`/c/Program Files/nodejs`、`/c/Program Files (x86)/nodejs`、`$HOME/node_modules/.bin`、
   `/usr/bin`、`/usr/local/bin`）并前置到该子进程的 `PATH`。这样「没有解析器」才真的
   意味着「整机没有」，而不是「这个 shell 的 PATH 上没有」。
2. **区分降级与通过**：从 `sprint-gate.sh` 自己的措辞里识别降级
   （`no JSON parser` / `not valid JSON` / `install jq`），命中时把
   `GATE_11_STATUS` 置为 **WARN** 并打印
   `⚠️ DEGRADED - Gate 11: Sprint Flow (allowed without verifying: …)`，
   **不再计入 PASS**（因此不进 `PASSED_COUNT`，也不抬高 `score`）。
3. `*`（无法识别的 decision）也从 PASS 改为 **WARN**——一个没人能解析的裁决
   不是「检查过」的证据。

#### 绕行 vs 如实

本仓库**不**伪造 `.sprint-state/` 产物来「让门禁通过」（那正是本次要消除的行为）。
sprint 过期这件事是事实，现在它如实显示为：

```
✅ PASSED - Gate 11: Sprint Flow (delphi-review APPROVED, sprint phase 6 validated (sprint open 21 day(s), staleness threshold 14))
```

——「验证通过」与「已开 21 天」同时可见，读者能自己判断该不该收尾这个 sprint。

已提交上游 **#584**（`decision` 需要携带理由，把「不适用/降级」映射到 SKIP/DEGRADED）。

---

## 3. 本仓库现在能自证的东西

| 证据 | 命令 | 实测 |
|------|------|------|
| 双引擎 Pester 全绿 | `powershell -File .workbuddy/run-pester.ps1 -Engine PS5.1` / `pwsh … -Engine pwsh7` | 760/760（PS 5.1） |
| 产品源静态分析 0 findings | `Invoke-ScriptAnalyzer -Path references/scripts -Recurse -Settings PSScriptAnalyzerSettings.psd1` | 0 |
| UI 单测 | `cd ui && npx vitest run` | 71/71 |
| 根 vitest（Gate 5 的服务端范围） | `npx vitest run` | 22/22 |
| 类型检查 / lint | `cd ui && npx tsc -b` / `npx eslint .` | 均 0 |
| 架构 diff | `npx archlint diff … --fail-on high` | 0 |
| 钩子与 vendored 副本一致 | `platform-hygiene.Tests.ps1`「钩子安装与 vendored 副本一致」 | 3/3 SHA256 MATCH |
| REQ-ID 清单不腐烂 | 同文件「需求 ID 单一真相源」 | 3/3 |

---

## 4. 交付给上游的缺陷

本批次共 3 个 issue（另 10-16 批次的 #535–#538 已在上份审计中记录）：

| issue | 内容 |
|-------|------|
| #583 | hook deploy **静默覆盖**下游硬化补丁，且回退了已修好的 #570；无备份、无版本边界、无日志（24 小时内发生三次） |
| #584 | Gate 11 把「sprint 已过期 / 相位未到」映射成 **PASS**，一道什么都没检查的门在提高评分 |
| #585 | Gate 5c 在 `req-ids.json` / `jq` 缺席时**零输出**；测试发现只认 JS/TS，Pester 永远匹配不到 |

---

## 5. 一条贯穿全篇的根因：Windows + git-bash 下「PATH 里没有」≠「没安装」

修完 Gate 11 后，同一个缺陷又在 Gate 2、Gate 6 各出现一次，值得单独记：

| 门禁 | 报出的错误 | 实际情况 |
|------|-----------|---------|
| Gate 11 | `decision: skip` + "no JSON parser available (install jq or node)" | `node` 装在 `C:\Program Files\nodejs`，只是没进 git-bash 的 PATH |
| Gate 6 | `❌ BLOCKED - archlint not installed` | `@archlinter/cli@0.16.0` 全局装好，npm 全局 bin（`%APPDATA%/npm`）不在 PATH |
| Gate 6 | `❌ BLOCKED - Architecture violations detected` | 其实是 npm shim 的 `exec: node: not found`（exit 127）被当成违规 |
| Gate 2 | `❌ BLOCKED - Required tool 'jscpd' not available` | `jscpd@5.2.0` 装在 `ui/node_modules/.bin`，而 `npx --no-install` 从仓库根解析 |

四种形态、三个门禁，同一个根因：**工具链探测只查了「当前 shell 的 PATH」**，
而 Windows 上 npm 全局 bin 与子项目 `node_modules/.bin` 都不在那里面。
更糟的是后果形态各异——有的是 BLOCK（拦住），有的是「降级后放行」（假绿），
还有的是把工具链损坏读成代码缺陷。

修法收敛到两处（不是逐个打补丁）：
1. `hooks/pre-commit` 启动段的 `_ensure_node_toolchain_path()`：把 node 目录与 npm
   全局 bin **追加**到 PATH（仅缺席时追加，调用方 precedence 不变）。所有 shell out
   到 node 工具的门禁一次性受益，含 npm shim 里的 `exec node ...`。
2. `adapters/adapter-common.sh` 的 `require_tool()`：探测清单加入 `%APPDATA%/npm`、
   `~/.npm-global/bin`、`~/.local/bin` 与子项目 `node_modules/.bin`；BLOCKED 行
   现在会列出搜索过的全部位置。「工具缺失 = BLOCK 而非 SKIP」的政策**未改**。

`adapter-common.sh` 一并纳入 vendored 一致性白名单（原来只有 powershell.sh /
gate-10.sh / pre-commit，这层补丁被回退时不会变红）。

## 6. 覆盖率超时预算：一个「健康套件被预算杀掉」的缺陷

覆盖率运行与普通测试运行**共用** `XP_GATE_POWERSHELL_TEST_TIMEOUT_S`（默认 300s）。
本仓库 762 个用例的普通运行约 285s，**插桩运行更慢**，于是覆盖率每次都在 300s 被杀：

```
⚠️  Pester coverage TIMED OUT after 300s (may be hanging).
❌ BLOCKED - Coverage check FAILED
```

这条错误的误导性是重点：它说「测试可能挂住」，而真相是**预算不够**。
排查时先去找挂住的测试会一无所获（实测套件 762/762 全绿、EXIT=0）。

修法：拆成两个预算——普通运行 900s、覆盖率运行 1800s
（`XP_GATE_POWERSHELL_TEST_TIMEOUT_S` / `XP_GATE_POWERSHELL_COVERAGE_TIMEOUT_S`），
`run_coverage` 改用 `_pester_coverage_timeout`。超时是**挂住测试的兜底**，不是性能预算。
`platform-hygiene` 新增两条用例：覆盖率预算必须存在且 ≥ 普通预算、且 `run_coverage`
必须真的用了它（否则「加了独立预算」会变成没人调用的死代码）。

## 7. 两条被截断的错误信息

`run_tests` 与 `run_coverage` 的输出都用 `head -50` / `head -30` 截断，而失败信息在**尾部**：

- Gate 5 报 `❌ BLOCKED - Tests FAILED` 时，用户看不到是哪个测试失败、也看不到退出码
  （实测真因是 vendored/live 钩子哈希不一致——而这条恰好是我刚加的一致性用例抓到的）。
- 覆盖率 BLOCK 时同理，真因（TIMED OUT）被截掉了。

两处都已补打印 `exit code` 与「runner 输出的尾部」。**一条说不出原因的 BLOCK
只能靠猜**，而本次两次都被截断信息耽误了排查。

---

## 8. 仍然存在的问题（如实记录）

1. **Gate 2/3/4/6 对 PowerShell 依旧零覆盖**（#537 仍开）。复杂度与架构两条尤其遗憾：
   本仓库的 `architecture.yaml` 写得比多数仓库都细，但它目前只约束 `ui/`。
   Gate 2 的 jscpd 与 Gate 6 的 archlint 现在**能真跑**了，但都只看 TS/JS。
2. **Hook 覆写是持续风险**（#583）。下游只能靠一致性测试发现，靠手工重打补丁恢复。
   本次重打补丁时因为插入点算错，一度产生 `syntax error near unexpected token ';;'`——
   **语法错的 hook 比没有 hook 更糟**（它会在某个 gate 之后静默停住全部门禁，参见 #579）。
   因此每次重打后都必须 `bash -n` + 重跑一致性测试，这两步不能省。
   本次新增 `adapter-common.sh` 到白名单后，一致性测试覆盖 4 个文件。
3. **99 个 spec id 没有任何高置信测试证据**（详见 `.workbuddy/alignment-report.md`）。
   其中相当一部分只能由 UI 侧的 71 个 vitest 用例或管理员演练覆盖（AGENTS.md 已把
   `clean-residuals.ps1` 的 HKLM/PATH 写入分支划给管理员环境集成演练）。
   这批条目需要逐条判定，**本轮不伪造覆盖**。
4. **Gate 5 覆盖率的分母仍取决于发现结果**。integrity 检查能抓出「报告与发现不符」，
   抓不出「发现本身漏了文件」——后者由 `platform-hygiene` 的
   「analysis-paths 覆盖全部 tracked 产品源」用例守。
5. `docs/audits/2026-10-16-gate-status.md` 里「Gate 5 对 PowerShell 空转」的结论**本次已证伪**，
   该文档已在相关条目上标注更正指向本文。
6. **sprint 已开 21 天**（阈值 14）。Gate 11 现在会如实把这件事印在 PASS 那一行里，
   但「是否收尾这个 sprint」是人做的决定，门禁只负责呈现，不代做决定。
