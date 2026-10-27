# docs/ — 索引

本目录的每一份文档都标了**状态**。看文档前先看状态，能省掉「按一份三年前的
设计稿判断现状」这类错误。

## 状态的定义

| 状态 | 含义 | 该怎么读 |
|------|------|---------|
| **current** | 当前权威，代码与门禁都在维护它 | 可以当作事实依据 |
| **historical** | 某个时间点的记录，不会再更新 | 作为证据/考古读，**不要当现状** |
| **superseded** | 已被后续文档取代 | 只读它的推理过程，结论看取代者 |

> 判据：**这份文档里的某个论断，三个月后会不会变成错的？** 会变的写成「现跑现读」，
> 不会变的才写成数字。

---

## 当前权威文档（current）

| 文档 | 内容 | 谁在读它 |
|------|------|---------|
| [`agent-workflow-pattern.md`](agent-workflow-pattern.md) | **让 agent 执行不可逆操作**的设计契约。刻意去掉了清理领域的细节，五个构件 + 自检清单，可直接移植到别的系统 | 想复用这套模式的团队；本项目自己的退出码表就在这里生成 |
| [`decisions/ADR-001-main-ref-exit-code.md`](decisions/ADR-001-main-ref-exit-code.md) | 为什么每个 `Main` 用 `[ref]$ExitCode` 回传而不 `exit`——含三种被实测否决的写法 | 任何改脚本的人；`tests/unit/hermeticity.Tests.ps1` 穷举强制它 |

`agent-workflow-pattern.md` 的**路径被代码钉死**（`tools/Update-DocTables.ps1:327`、
`tests/unit/doc-tables.Tests.ps1` 的多处断言）。改名会让三份文档里的退出码表失配，
必须连同那两个文件一起改。

---

## 历史记录（historical）

按时间倒序。这些是**当时的实测结果**，数字不随仓库变化而更新。

| 文档 | 时间 | 记录了什麼 | 为什么还留着 |
|------|------|-----------|-------------|
| [`audits/2026-10-24-gate-status.md`](audits/2026-10-24-gate-status.md) | 2026-10-24 | 每道门禁**实际**在跑什么、被谁拦住、哪些是假绿 | 它证伪了前一份审计的一处结论，是当前最新的一次门禁体检 |
| [`audits/2026-10-24-skill-open-source-assessment.md`](audits/2026-10-24-skill-open-source-assessment.md) | 2026-10-24 | SKILL.md 对外发布前的评估，3 项阻塞（含 1 项安全） | 3 项已在 1.4.6.0 落地；判断口径仍可复用 |
| [`audits/2026-10-16-gate-status.md`](audits/2026-10-16-gate-status.md) | 2026-10-16 | 首次全门禁体检，13 道 Gate 0–12 | 它的部分结论已被 10-24 那份证伪；**文首有更正横幅，先读横幅** |
| [`plans/2026-10-02-auto-rollback-design.md`](plans/2026-10-02-auto-rollback-design.md) | 2026-10-02 | 自动回滚子系统的设计（REQ/AC 映射） | 功能已在 1.4.2.0–1.4.5.0 落地。读**为什么这样设计**，别读状态行 |
| [`plans/2026-06-04-windows-residual-cleaner-v2.md`](plans/2026-06-04-windows-residual-cleaner-v2.md) | 2026-06-04 | v2.0 的四层实施计划 | 早于整个回滚子系统，且面向已弃用的分发形态 |
| [`specs/2026-06-04-windows-residual-cleaner-release-design.md`](specs/2026-06-04-windows-residual-cleaner-release-design.md) | 2026-06-04 | v2.0 发布改造设计 | 同上；问题分析部分仍有价值 |

---

## 目录结构与命名

```
docs/
├── README.md                    # 本文件
├── agent-workflow-pattern.md    # 路径被代码钉死，勿移动
├── decisions/                   # ADR：可长期引用的决策记录
├── plans/                       # 计划与设计稿
├── specs/                       # 需求/发布规格
└── audits/                      # 一次性体检报告，按日期命名
```

- **`audits/` 用日期命名**，日期本身就是「这是快照」的信号，不需要额外的 archive 目录。
  超过约 6 份再考虑归档。
- **`superpowers/` 目录已删除**（2026-10-27）。它是某个第三方工具的工作流命名空间，
  不是文档分类——文件由谁写的属于头部元数据，不属于路径。两份文件已扁平化到
  `plans/` 与 `specs/`。

---

## 维护约定

- 新增 `audits/` 文档：日期前缀 + 文首写明「一次性评估」与结论是否已落地。
- **改代码导致文档失真时，同一次提交改文档。** `tests/unit/doc-consistency.Tests.ps1`
  会检查 `AGENTS.md` 的结构数与实现一致，但**不会**检查本目录——这里靠人守。
- 引用覆盖率/测试数之类的快照数字时，写「现跑现读」并给出命令，不要抄数字。
