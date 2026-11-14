# Code walkthrough — `fix/hkcr-registry-absent` → `master`

仓库：boyingliu01/windows-residual-cleaner（PowerShell 5.1 系统清理工具 + TS UI）
基线：origin/master = 5fe2f79（v1.4.13.1 发版提交）
分支 HEAD：51d82cb（4 个提交，5 个文件，+80 / -22）

## 1. 变更意图

真实清理演练（2026-11-13）发现：`clean-residuals.ps1` 报告 30 个 HKCR 残留键全部
"清理成功"，但逐条 `reg query` 复验显示**一个都没删**。根因是
`Confirm-RegistryTargetAbsent` 把 `HKCR\...` 转成 `HKCR:\...` 后用 `Test-Path` 判断，
而 PowerShell 默认只注册 `HKCU:` / `HKLM:` 两个 PSDrive；`HKCR:` 等不存在时
`Test-Path` **不抛异常、静默返回 `$false`**，于是"存在的键"被判成"已消失"。
该判定同时是清理前跳过逻辑与 journal `absent_confirmed_after_mutation` 的证据来源——
"没删掉"被记成"已确认消失"，回滚端据此判定，属 fail-open。

本分支修复该缺陷，并顺带修两个门禁/测试问题：
1. 单元测试里 `powershell.exe` 依赖宿主 PATH，CI/钩子环境下假红；
2. `architecture.yaml` 的 TS 分层块用了 Gate 6 解析器不认的 YAML 形状，
   导致所有纯文档提交被 `layer_config_unparsable` 拦死，且 TS 分层从未真正被检查。

## 2. 提交清单

| 提交 | 内容 |
|------|------|
| 92ef3d3 | fix: HKCR/HKU/HKCC 键存在性判定改走 `Registry::`，修清理静默跳过 |
| ae71b3d | test: 显式解析 powershell.exe 绝对路径，避免宿主 PATH 缺目录时假红 |
| 03ed6c1 | fix(gate): architecture.yaml 改用 Gate 6 解析器认的 map 形式，TS 分层从死配置变真检查 |
| 51d82cb | docs: 记录陷阱 17——HKCR/HKU/HKCC 不是 PSDrive，键存在性判定必须用 `Registry::` |

## 3. 逐文件说明与评审关注点

### 3.1 `references/scripts/rollback-backup.ps1`（核心修复）

`Confirm-RegistryTargetAbsent` 改为构造 `Registry::<hive>\<path>` 提供程序限定路径，
与 PSDrive 注册状态无关；返回值契约不变（`@{ Absent; Path; Error? }`）。
评审关注：
- 路径归一化 `-replace '^(HKLM|HKCU|HKCR|HKU|HKCC):?\\', '$1\'` 是否覆盖带冒号/不带冒号两种输入；
- `Test-Path` 抛异常时返回 `Absent = $false`（fail-closed）是否仍是期望语义；
- 调用方（`clean-residuals.ps1` 的 skip 判定与 journal 写入）是否需要同步改动。
  本分支未改调用方：两处都消费同一函数，修复点收敛在一个函数内。

### 3.2 `tests/unit/rollback-backup.Tests.ps1`（新增 4 条）

- HKCR/HKU/HKCC 三个非默认 hive 的真实存在键 → `Absent = $false` 且 `Path` 以 `Registry::` 开头；
- `HKCR:\...` 与 `HKCR\...` 两种写法判定一致。
评审关注：断言是否绑定了机器形态（例如 `.txt` 关联键在所有 Windows 上都存在，但
企业镜像是否可能被策略移除）；若存在脆弱性，应说明更稳的固定键。

### 3.3 `tests/unit/doc-tables.Tests.ps1`（PATH 脆弱性）

`-Check` 用例改为显式解析 `$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`，
找不到才回退裸命令名。评审关注：回退分支是否会让缺陷重新变成"本地绿/钩子红"。

### 3.4 `architecture.yaml`（Gate 6 配置形状）

TS 分层块由 sequence 形式（`- name: x` + `paths:`）改为 map 形式（层名作键 + `patterns:`）。
依据：xp-gate 的 `gate-6-layers.sh` 只解析后者；sequence 形式解析出零层，
被 fail-closed 判为 `layer_config_unparsable`（exit 2）。
评审关注：
- `powershell.layers` 块未改动，`tools/Test-PowerShellArchitecture.ps1` 仍解析它；
- 文件头注释解释了"为什么必须是这个形状"，避免后人"美化"成不支持的写法；
- 是否有其它工具（archlint 以 `--config` 方式、CI 脚本）依赖原 `paths:` 键。已核查：
  Gate 6 调用 archlint 时不传 `--config`，仓库 CI 无 archlint 引用，PowerShell 检查器只读 `powershell:` 块。

### 3.5 `AGENTS.md`（文档）

新增陷阱 17（现象、根因、判据、守卫测试位置）与变更历史一条。无代码影响。

## 4. 验证证据（本机实测）

- 清理演练复验：修复后以管理员重跑 `clean-residuals.ps1`，汇总 `60 succeeded, 0 failed`；
  对 30 个 HKCR 键逐条 `reg query` 复验全部返回 `ERROR: The system was unable to find the specified registry key`（确认已删除）。
- 单元测试：PS 5.1 全量 `Invoke-Pester tests` → 882 passed / 0 failed / 1 inconclusive；
  `architecture-check.Tests.ps1` 7/7；`rollback-backup.Tests.ps1`、`doc-tables.Tests.ps1` 均通过。
- PSScriptAnalyzer：带 `PSScriptAnalyzerSettings.psd1` → 0 error / 0 warning。
- PowerShell 分层检查器：`layers=8 edges=14 violations=0 failing=0`。
- Gate 6 分层检查器（新配置）：9 行分层 / 29 个文件归类 / 0 违规（rc=0）。
- 提交门禁：4 个提交均经 xp-gate pre-commit 13 道门禁，无失败。

## 5. 完整 diff（origin/master..HEAD）

```diff
diff --git a/AGENTS.md b/AGENTS.md
index fc70ed4..3a22619 100644
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -498,6 +498,33 @@ $text = $script:Utf8Read.GetString([System.IO.File]::ReadAllBytes($path))
 
 ---
 
+### 17. `HKCR:` / `HKU:` / `HKCC:` 不是 PSDrive：`Test-Path` 静默返回 `$false`（2026-11-13 实跑）
+
+PowerShell 默认只注册 `HKCU:` 与 `HKLM:` 两个注册表 PSDrive：
+
+```powershell
+Get-PSDrive -PSProvider Registry      # -> HKCU, HKLM
+
+# ❌ 错误: 不抛异常（连非终止错误都没有），静默返回 False → 存在的键被判「已消失」
+Test-Path -LiteralPath 'HKCR:\CLSID\{0119CCC1-8EAC-43E9-AA7D-87F64B44AA4D}\InProcServer32'          # False
+
+# ✅ 正确: 提供程序限定路径，与 PSDrive 注册状态无关
+Test-Path -LiteralPath 'Registry::HKCR\CLSID\{0119CCC1-8EAC-43E9-AA7D-87F64B44AA4D}\InProcServer32' # True
+```
+
+**影响**：`Confirm-RegistryTargetAbsent` 把 `HKCR\...` 转成 `HKCR:\...` 后判断，
+于是真实清理把 30 个 HKCR 残留键**全部记成** `registry_skip / key not found`，
+实际一个都没删，汇总却显示 `0 failed`。同一函数也是 journal 里
+`absent_confirmed_after_mutation` 的证据来源——「没删掉」会被记成「已确认消失」，
+回滚端据此判定，属于 fail-open。
+
+**判据**：用 `Test-Path` 判断注册表键存在性时，路径必须以 `Registry::` 开头；
+单测至少覆盖一个非默认 PSDrive 的 hive（HKCR/HKU/HKCC），只测 HKCU 会漏掉整类缺陷
+（`tests/unit/rollback-backup.Tests.ps1` 已补 4 条）。**「键不存在」与「路径走错提供程序」
+在返回值上不可区分**——写完这种判定，必须在真实存在的键上正反各验一次。
+
+---
+
 ## 多条件检测逻辑设计原则
 
 ### 核心规则: 权威信号必须 gate 辅助信号
@@ -852,3 +879,7 @@ if ($MyInvocation.InvocationName -ne '.') {
   **判据**：**「这个数字三个月后会变成错的吗」**——会变就改写成描述，而不是加进白名单。
   这条由 `tests/unit/doc-consistency.Tests.ps1` 守着，也包括「本文声称的契约范围必须与
   `hermeticity.Tests.ps1` 实际枚举的目录一致」，让文档跟着代码走。
+- 2026-11-13: 真实清理演练暴露 HKCR 判定 fail-open（陷阱 17）：日志「key not found」
+  与「真的没删」在用户视角完全一样，汇总还是 `0 failed`。
+  **判断口径**：删除类操作的「跳过」必须与「执行后复查」用**同一份**存在性判定，
+  且该判定要有真实存在的正例测试；汇总数字只有在逐条复验过之后才能当证据。
diff --git a/architecture.yaml b/architecture.yaml
index 1411771..fca29c5 100644
--- a/architecture.yaml
+++ b/architecture.yaml
@@ -1,38 +1,43 @@
 # Architecture constraints for the Windows Residual Cleaner monorepo.
-# `layers` governs the TypeScript UI (checked by archlint in Gate 6).
+# `layers` governs the TypeScript UI (checked in Gate 6 by gate-6-layers.sh).
 # `powershell.layers` governs the PowerShell pipeline (checked in Gate 6 by
 # tools/Test-PowerShellArchitecture.ps1).
+#
+# The map form (layer name as key) with `patterns:` is the only shape
+# gate-6-layers.sh parses. The sequence form (`- name: x` + `paths:`) and the
+# key `paths:` both parse to zero layers, and a zero-layer config is BLOCKED
+# fail-closed — so a "nicer looking" YAML here silently disables the gate.
 layers:
-  - name: types
-    paths: ["ui/src/types/**"]
+  types:
+    patterns: ["ui/src/types/**"]
     allowed_imports: []
 
-  - name: lib
-    paths: ["ui/src/lib/**"]
+  lib:
+    patterns: ["ui/src/lib/**"]
     allowed_imports: [types]
 
-  - name: hooks
-    paths: ["ui/src/hooks/**"]
+  hooks:
+    patterns: ["ui/src/hooks/**"]
     allowed_imports: [types, lib]
 
-  - name: ui-primitives
-    paths: ["ui/src/components/ui/**"]
+  ui-primitives:
+    patterns: ["ui/src/components/ui/**"]
     allowed_imports: [lib]
 
-  - name: components
-    paths: ["ui/src/components/**"]
+  components:
+    patterns: ["ui/src/components/**"]
     allowed_imports: [ui-primitives, hooks, lib, types]
 
-  - name: app
-    paths: ["ui/src/App.tsx", "ui/src/main.tsx"]
+  app:
+    patterns: ["ui/src/App.tsx", "ui/src/main.tsx"]
     allowed_imports: [components, ui-primitives, hooks, lib, types]
 
-  - name: test-support
-    paths: ["ui/src/test/**"]
+  test-support:
+    patterns: ["ui/src/test/**"]
     allowed_imports: [hooks, lib, types]
 
-  - name: server
-    paths: ["ui/server/**"]
+  server:
+    patterns: ["ui/server/**"]
     allowed_imports: []
 
 # PowerShell layering (2026-10-24).
diff --git a/references/scripts/rollback-backup.ps1 b/references/scripts/rollback-backup.ps1
index c24d371..24d9bf6 100644
--- a/references/scripts/rollback-backup.ps1
+++ b/references/scripts/rollback-backup.ps1
@@ -393,13 +393,13 @@ function Confirm-RegistryTargetAbsent {
         接受 'HKCU\Foo' 或 'HKCU:\Foo' 形态。读取异常按「未确认」处理
         （fail-closed：宁可判 absent=$false 让上层复查，不得把读失败
         说成「目标已消失」）。
+        一律走 Registry:: 提供程序路径：PowerShell 默认只注册 HKCU:/HKLM: 两个
+        PSDrive，'HKCR:\...' 不抛异常而是静默返回 $false，会把存在的 HKCR 键
+        误判成「已消失」（fail-open）。提供程序路径与 PSDrive 注册状态无关。
     #>
     param([Parameter(Mandatory)][string]$Key)
 
-    $psPath = $Key.Trim().Trim('"')
-    if ($psPath -notmatch '^\w+\\:') {
-        $psPath = $psPath -replace '^(HKLM|HKCU|HKCR|HKU|HKCC):?\\', '$1:\'
-    }
+    $psPath = 'Registry::' + ($Key.Trim().Trim('"').Trim() -replace '^(HKLM|HKCU|HKCR|HKU|HKCC):?\\', '$1\')
     try {
         return @{ Absent = (-not (Test-Path -LiteralPath $psPath)); Path = $psPath }
     } catch {
diff --git a/tests/unit/doc-tables.Tests.ps1 b/tests/unit/doc-tables.Tests.ps1
index c069fad..8b50839 100644
--- a/tests/unit/doc-tables.Tests.ps1
+++ b/tests/unit/doc-tables.Tests.ps1
@@ -45,7 +45,11 @@ Describe 'Doc tables: 退出码表单一事实来源（2026-10-25）' {
 
     It '文档中的退出码表与代码一致（运行生成器的 -Check 模式）' {
         # 这是 CI 跑的同一条命令；不一致即红。
-        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Generator -Check 2>&1
+        # 裸 powershell.exe 依赖 PATH：Git Bash 之类的宿主 PATH 里可能只有
+        # System32 而没有 WindowsPowerShell\v1.0，会让这条与代码无关的用例假红。
+        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
+        if (-not (Test-Path -LiteralPath $ps51)) { $ps51 = 'powershell.exe' }
+        $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $script:Generator -Check 2>&1
         $LASTEXITCODE | Should -Be 0 -Because "退出码表漂移：$($out -join ' | ')"
     }
 
diff --git a/tests/unit/rollback-backup.Tests.ps1 b/tests/unit/rollback-backup.Tests.ps1
index 43076c0..d87b73b 100644
--- a/tests/unit/rollback-backup.Tests.ps1
+++ b/tests/unit/rollback-backup.Tests.ps1
@@ -290,6 +290,24 @@ Describe 'Confirm-RegistryTargetAbsent / Confirm-PathEntryRemoved (REQ-024 flag
         $r.Absent | Should -BeFalse
     }
 
+    It '存在的 <Hive> 键 -> Absent=$false（HKCR/HKU/HKCC 不是 PSDrive，必须走 Registry::）' -TestCases @(
+        @{ Hive = 'HKCR'; Key = 'HKCR\.txt' }
+        @{ Hive = 'HKU';  Key = 'HKU\.DEFAULT' }
+        @{ Hive = 'HKCC'; Key = 'HKCC\System\CurrentControlSet' }
+    ) {
+        param($Hive, $Key)
+        $r = Confirm-RegistryTargetAbsent -Key $Key
+        $r.Absent | Should -BeFalse
+        $r.Path | Should -BeLike 'Registry::*'
+    }
+
+    It '带冒号形态等价：HKCR:\\.txt 与 HKCR\\.txt 判定一致' {
+        $a = Confirm-RegistryTargetAbsent -Key 'HKCR\.txt'
+        $b = Confirm-RegistryTargetAbsent -Key 'HKCR:\.txt'
+        $b.Absent | Should -Be $a.Absent
+        $b.Path | Should -Be $a.Path
+    }
+
     It 'PATH 段已移除 -> Absent=$true；仍在 -> Absent=$false（整段、大小写不敏感）' {
         (Confirm-PathEntryRemoved -PathList 'A;C' -Entry 'B').Absent | Should -BeTrue
         (Confirm-PathEntryRemoved -PathList 'A;b' -Entry 'B').Absent | Should -BeFalse

```
