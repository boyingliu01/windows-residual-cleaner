# wrc-drill — 管理员演练脚本

⚠️ **误跑警示**：`drill4-admin.ps1` 与 `drill5-autorollback.ps1` 面向**管理员真实演练**设计——
它们会创建真实服务、修改 Machine PATH、写 HKLM（靠脚本内 finally 还原）。**不要在生产机或
日常办公机上运行**；只在专用测试机/专用账户环境执行，跑完立即 `teardown.ps1`。

| 脚本 | 用途 | 权限 |
|---|---|---|
| `drill3-realistic.ps1` | 非管理员范围演练（真实 fixture + 清理） | 非管理员 |
| `drill4-admin.ps1` | 管理员范围演练（服务/HKLM 真实删除） | 需管理员 |
| `drill5-autorollback.ps1` | 自动回滚 23 项检查演练（UAC 自提权，PATH/服务/HKLM 真实变更 + 还原） | 需管理员（UAC） |
| `rdlab.ps1` | 演练辅助（锁定文件等复现工具） | 视用法定 |
| `teardown.ps1` | 清理演练产物 | 与被清产物匹配 |

这些脚本**不在** Pester 套件内，也不被 CI 触发；覆盖率分母已通过
`.xp-gate-powershell-coverage-ignore` 排除（理由见该文件注释）。
drill5 的 23 项检查清单与判定记录见 CHANGELOG（2026-10-07/08 条目）。
