# Pain Document - 清理前用户交互确认

## 生成日期
2026-05-04

## 需求现实
- 用户在查看扫描报告时，发现部分残留项确实是已卸载软件的残留（如空目录 Adobe、EaseUS），但也有大量项无法确认是否应该清理
- 当前 `clean-residuals.ps1` 只有 4 种粗粒度模式（A/B/C/D），缺乏逐项确认能力
- 用户需要一个"挑着删"而非"一刀切"的交互式流程

## 当前状态
- `clean-residuals.ps1` 支持通过 `-ItemsToClean` 参数传入 JSON ID 数组，但：
  - 用户需要手动编辑 JSON 字符串，体验极差
  - 没有按分类/风险级别分组浏览的能力
  - 没有交互式选择界面
  - 不支持"全选 Safe"、"跳过 Danger"等快捷操作

## 绝望的具体性
- 用户面对 520 项残留报告，想清理但又怕误删
- 212 个 Safe 项大概率可以清，197 个 Caution 需要逐个看，5 个 Danger 绝对不动
- 但 Safe 里也可能有误判（如 Windows 系统空目录 `WindowsApps`、`PackageManagement`），用户想对每一类都有最终决定权

## 最窄切入点
- 新增一个 `confirm-cleanup.ps1` 脚本，读取 `final-report.json`，生成交互式选择界面
- 输出一个用户确认的 ID 列表文件 `confirmed-ids.json`
- `clean-residuals.ps1` 读取此文件执行清理
- 不改动现有脚本的核心逻辑，只加一层交互

## 观察证据
- 用户明确说"还有一部分是我不能确认的，希望让用户选择哪些是已经确认可以清理的，存疑的先保留"
- 真实环境扫描测试发现大量误判（Common Files、Internet Explorer 等 Windows 系统目录被标记为残留），用户交互确认是必须的安全兜底

## 未来适配
- Windows 残留清理是长期需求，软件安装/卸载是日常操作
- 交互式确认流程是任何清理工具的标配（CCleaner、Revo Uninstaller 都有此功能）

## Pain Statement (一句话痛点)
用户面对 520 项残留报告无法安全地做出清理决策，缺乏交互式逐项确认机制。

## Proposed Solution (建议方案)
1. 新增 `confirm-cleanup.ps1`：读取 final-report.json → 按分类分组展示 → 用户交互选择 → 输出 confirmed-ids.json
2. 修改 `clean-residuals.ps1`：支持从 confirmed-ids.json 读取确认列表
3. 交互方式：PowerShell 5.1 兼容，使用 `Read-Host` + 数字选择 + 快捷键（A=全选/N=全不选/Q=退出）
4. 按 风险级别 > 分类 > 大小 排序展示，Danger 项默认不选但可见
