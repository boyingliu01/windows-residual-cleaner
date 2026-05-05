# Pain Document — Sprint 2: Agent-Driven Cleanup Workflow

## Context
windows-residual-cleaner v1.2.0.0 已发布，核心扫描引擎和交互确认机制（`-NonInteractive`）已就位。但 SKILL.md 的工作流描述仍把责任推给用户，不符合实际使用场景。

## The Pain

### Pain 1: 用户负担过重
用户说"帮我清理卸载残留"，agent 不应该反问"你想用模式 A/B/C/D？""你想 AutoSelect safe 还是 caution？"。用户根本不记得这些术语，也不应该知道 PowerShell 参数的存在。

### Pain 2: 流程不连续
当前 SKILL.md 把工作流拆成 9 个独立步骤，agent 执行完扫描就停住，等用户下一条指令。这破坏了对话的连贯性，用户体验像是在操作 CLI 工具而非和 AI 对话。

### Pain 3: 确认机制是建议而非强制
当前文档说"建议先 DryRun"，但 agent 可能跳过确认直接执行。用户明确要求"必须等待用户确认"，这需要在工作流中硬编码为不可跳过的暂停点。

### Pain 4: 自然语言语义触发后无自动执行
用户说"清理卸载残留"，agent 应该自动：扫描 → 展示摘要 → 询问确认 → DryRun → 再次确认 → 执行。而不是展示一堆参数让用户选择。

## Root Cause
SKILL.md 的设计思想是"给用户工具"，而不是"agent 替用户完成任务"。文档把 agent 定位为脚本的调用者，而非流程的主导者。

## Desired State
用户只需自然语言表达意图（"帮我清理下卸载软件的残留"），agent 自动走完完整流程，但在以下节点**强制暂停，等待用户明确回复**：
1. 扫描完成后 → 展示摘要，问"是否继续清理？"
2. DryRun 预览后 → 展示预览结果，问"确认执行删除吗？"

agent 不应暴露技术参数（Safe/Caution/Danger 可以在摘要中解释，但不应作为用户的选择题）。

## Acceptance Criteria
- [ ] SKILL.md 重写：agent 主导流程，自然语言交互
- [ ] 强制确认点硬编码：扫描后暂停、DryRun 后暂停
- [ ] 不暴露 PowerShell 参数给用户
- [ ] 保留底层脚本的调用能力（内部使用 `-NonInteractive`）
- [ ] PSScriptAnalyzer 0 错误 0 警告
- [ ] 单元测试通过
