# AGENTS.md — Windows Residual Cleaner

> AI agent 工作指南。维护者在开发 / 调试 / 扩展此项目前必读。

---

## 项目上下文

这是一个 Windows 系统清理工具，通过 PowerShell 脚本扫描和清理卸载软件残留。
涉及注册表、文件系统、Windows 服务、计划任务、COM 扩展等敏感系统区域。

**运行环境**: Windows 10/11 + PowerShell 5.1 + Administrator 权限
**测试框架**: Pester 5.x — `Invoke-Pester tests/`（当前 757 个测试，PS 5.1 与 pwsh 7 双引擎均通过，目标 0 失败）
**代码质量**: PSScriptAnalyzer 0 error / 0 warning，**必须带设置文件运行**：

```powershell
Invoke-ScriptAnalyzer -Path references/scripts -Recurse -Settings PSScriptAnalyzerSettings.psd1
```

> 裸跑会多出 23 条 `PSReviewUnusedParameter`：本项目所有脚本的入口参数在顶层 `param()`
> 声明、在 `function Main` 内消费，该规则不跨作用域追踪，故在设置文件中排除这一条规则。
> 其余规则（含 `PSUseBOMForUnicodeEncodedFile`）均未放宽，告警为 0。

---

## PowerShell 5.1 陷阱清单

### 1. `[ref]` + `[CmdletBinding]` = 计数器失效

在 `[CmdletBinding()]` 函数中使用 `[ref]` 传递值类型计数器时，PowerShell 返回的是临时副本，`[ref]` 指向的是副本而非原变量。

```powershell
# ❌ 错误: $counters.fs 永远不会增加
function Set-Id {
    [CmdletBinding()]
    param([string]$Prefix, [ref]$Counter)
    $Counter.Value++
}
Set-Id -Prefix "fs" -Counter ([ref]$counters.fs)

# ✅ 正确: 直接传 hashtable，函数内部修改
function Set-Id {
    param([hashtable]$Counters, [string]$Prefix)
    $Counters[$Prefix]++
    return "{0}_{1:D3}" -f $Prefix, $Counters[$Prefix]
}
Set-Id -Counters $counters -Prefix "fs"
```

**影响**: `generate-report.ps1` 曾因此导致 520 个 item 只有 6 个 unique ID。

### 2. `[string]` 类型参数约束的大小写不敏感冲突

定义 `[string]$ItemsToClean` 参数后，PowerShell 5.1 的变量名是**大小写不敏感**的。后续代码中的 `$itemsToClean`（小写）会被同一类型约束限制为 `[string]`，导致 `+=` 操作变成字符串拼接而非数组追加。

```powershell
# ❌ 错误: $itemsToClean += $item 变成字符串拼接
param([string]$ItemsToClean = "")
$itemsToClean = @()      # 被约束为 [string]，实际赋值失败或变成字符串
$itemsToClean += $item   # 字符串拼接: "[object]"

# ✅ 正确: 使用完全不同的变量名
param([string]$ItemsToClean = "")
$cleanupItems = @()      # 全新变量名，不受约束
$cleanupItems += $item   # 数组追加
```

**影响**: `clean-residuals.ps1` ConfirmFile 模式因此匹配不到任何 item。

### 3. `Where-Object` 单条结果的 `.Count` 陷阱

`Where-Object` 返回单条结果时，`.Count` 返回的是该对象的属性数量（Hashtable 的 key 数量），而非元素个数。

```powershell
# ❌ 错误: 单条结果时 $filtered.Count = 4 (Hashtable 的 key 数量)
$filtered = $log | Where-Object { $_.success -eq $true }
Write-Output $filtered.Count   # 输出 4，不是 1!

# ✅ 正确: 用 @() 强制数组化
$filtered = @($log | Where-Object { $_.success -eq $true })
Write-Output $filtered.Count   # 输出 1
```

**影响**: `clean-residuals.ps1` 的 summary 因此显示 "4 succeeded" 实际只处理了 1 个 item。

### 4. .NET IO 方法对引号的处理

`[System.IO.File]::Exists()` 和 `[System.IO.Directory]::Exists()` 将引号视为路径的一部分，不会自动去除。

```powershell
# ❌ 错误: 返回 $false，因为引号是字面量
[System.IO.Directory]::Exists('"C:\Program Files\App"')

# ✅ 正确: 先 Trim 引号
$path = '"C:\Program Files\App"'.Trim('"')
[System.IO.Directory]::Exists($path)
```

**影响**: `scan-uninstalled.ps1` 的 `InstallLocation` 含引号时全部判断为路径不存在，导致 100% false positive。

### 5. 环境变量未展开

注册表/计划任务中存储的路径可能包含 `%windir%`、`%ProgramFiles%` 等环境变量，必须展开后再检查。

```powershell
# ❌ 错误: Test-Path 无法识别 %windir%
Test-Path "%windir%\System32\task.exe"

# ✅ 正确: 先展开环境变量
$expanded = [Environment]::ExpandEnvironmentVariables("%windir%\System32\task.exe")
Test-Path $expanded
```

**影响**: `scan-residuals.ps1` 的 Ghost Tasks 扫描因此产生 56 个 false positive。

---

### 6. `ConvertFrom-Json` 不把顶层 JSON 数组展开为管道元素

PowerShell 5.1 的 `ConvertFrom-Json` 将反序列化结果作为**单个** `Object[]` 对象写入输出流。所以 `@(cmd | ConvertFrom-Json)` 包到的是那个数组本身，`Count` 恒为 1，元素才是真正的记录集。

```powershell
# ❌ 错误: $idx.Count 永远是 1（$idx[0] 才是 Object[]）
$idx = @(Get-Content $path -Raw | ConvertFrom-Json)

# ✅ 正确: 先赋值给变量（变量直接拿到 Object[]），再 @() 规整
$doc = Get-Content $path -Raw | ConvertFrom-Json
$idx = @($doc)
```

后续症状都具有迷惑性：`$idx | Where-Object { $_.name -eq 'X' }` 会返回**全部**记录（`$_.name` 在数组上做 `-eq` 变成了数组过滤）；`$ids | Should -Contain 'fs_201'` 报 `Expected 'fs_201' to be found in collection @(fs_201)`。

> **不要改回一行式**: PowerShell 7 起 `ConvertFrom-Json` 已改为逐元素展开，同样的一行式代码在 `pwsh` 下是正确的，容易让人误判此处冗余。本项目运行时基线是 PS 5.1。

**影响**: `main-flow.Tests.ps1` 有 8 个集成测试因此失败（索引条数恒为 1、风险分级断言拿到整表、`-Contain` 匹配不到 id）。产品脚本不受波及，因为它们都先赋值再访问属性。

---

### 7. 幽灵服务清理：裸 `sc.exe` + `$LASTEXITCODE` 判定把「幂等成功」当失败

> **2026-10-01 更正说明**：本条最初（提交 `a386132`）表述为「裸 `sc.exe ... 2>$null`
> 在 PS 5.1 下**必然**抛 `StandardOutputEncoding` 异常」。后续复核**无法稳定复现**该
> 异常为无条件行为，因此下面区分「可复现的主缺陷」与「环境相关的次要风险」。
> 请以本节为准。

#### 7a. 主缺陷（已复现，真实存在）

旧代码（`b08162b`）：

```powershell
sc.exe delete $item.name 2>&1
if ($LASTEXITCODE -ne 0) { throw "sc.exe delete failed with exit code $LASTEXITCODE" }
```

问题在于 **`$LASTEXITCODE` 的语义**：删除一个**已经不存在**的服务，`sc.exe` 返回
`1060`（`ERROR_SERVICE_DOES_NOT_EXIST`）。这是**幂等成功**，但 `1060 -ne 0` 成立，
于是抛异常 → 被外层 `catch` 吞成 `cleanup_failed`。

实测（PS 5.1）：

```
sc.exe delete <不存在的服务>  ->  正常返回，$LASTEXITCODE = 1060
1060 -ne 0                    ->  throw  ->  日志记 cleanup_failed
```

**影响**：重复清理、或服务已被 SCM 移除时，清理恒记失败。**已由 `Invoke-ScExe` 的
`exit_code -eq 1060` 幂等判定修复**（见 `clean-residuals.ps1`）。

#### 7b. 环境相关风险：部分流重定向可能抛异常

若代码设置了 `StandardOutputEncoding` 而 stdout **未**重定向，`.NET` 会抛：

```
StandardOutputEncoding is only supported when standard output is redirected.
```

该错误**真实存在且可复现**，但触发条件是「显式设置 `StandardOutputEncoding` +
stdout 未重定向」，**并非**裸 `2>$null` / `2>&1` 的无条件行为：

```powershell
# 实测：在正常控制台宿主下，下列写法并不会抛该异常
sc.exe query wuauserv 2>$null     # OK，$LASTEXITCODE 正常
sc.exe query wuauserv 2>&1        # OK

# 但下面这种会抛（stdout 未重定向却设了编码）
$psi.RedirectStandardError = $true
$psi.RedirectStandardOutput = $false
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8   # -> THROW
```

宿主不同（stdout 是否为真实控制台句柄、是否被 UI 管道接管）会影响是否命中。
`ui/server/index.cjs` 以管道方式拉起 `powershell.exe`，属于高风险场景。

#### 统一修复方式

```powershell
# ✅ 用 Start-Process 同时重定向「两个」流，拿到真实退出码，并显式处理 1060
$outFile = [System.IO.Path]::GetTempFileName()
$errFile = [System.IO.Path]::GetTempFileName()
$proc = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" `
    -ArgumentList @('delete', $name) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
$exitCode = $proc.ExitCode
if ($exitCode -ne 0 -and $exitCode -ne 1060) { throw "sc.exe delete failed ($exitCode)" }
```

**为何不用 `cmd /c "... 2>&1"` 包裹**: `sc.exe` 的成功输出（`SERVICE_NAME: ...`）不带引号，一旦服务名或路径含空格就会在引号处截断参数。

> **测试设计教训**: 断言「日志里打印了某个字符串」不能证明副作用真的发生。涉及系统交互的分支必须断言**可观测副作用**（调用参数、返回结构、退出码语义），或先封装成可 mock 的接缝再测。旧测试只断言打印了 `Deleting service: X` 并 Mock 掉 `Get-CimInstance`，因此 100% 漏检。

> **根因复核教训**: 报告根因前必须能**稳定复现**，并区分「无条件必然」与「环境相关」。
> 本次一开始把一条环境相关的风险写成了「必然抛异常」，后来在自己环境里复现不出来，
> 只能回头更正提交信息与本文档。写下「必然/100%」时，请附上可复现的命令。

---

### 8. dot-source 会把顶层 `param()` 的默认值绑进调用方作用域（覆盖同名变量）

**两个独立但常一起出现的坑**，都会让测试静默跑错路径：

#### 8a. dot-source 覆盖调用方同名变量

脚本顶层 `param()` 一旦被 dot-source，它声明的**所有**参数名都会在调用方作用域被赋值
（未传参时为默认值）。因此先设 `$IndexPath` 再 dot-source 另一个同名参数脚本，
刚设好的值会被**冲掉**：

```powershell
# ❌ 错误: dot-source 后 $IndexPath 变成脚本默认值
$IndexPath = 'C:\my\index.json'
. other-script.ps1        # 该脚本顶层也是 param([string]$IndexPath = ...)
Main                      # 内部读到的是默认值，不是 C:\my\index.json
```

实测输出（PS 5.1）：

```
before dot-source: IndexPath = C:\Users\...\Temp\wrc-dbg2-idx.json
after  dot-source: IndexPath = ...\references\scripts\..\..\installed-software-index.json
```

**规避**：不要跨脚本复用同名变量名；或在 dot-source **之后**再赋值；或全程用显式实参。

#### 8b. 函数 `param()` 无条件遮蔽调用方变量

在函数里声明一个与调用方变量同名的参数，PowerShell 会**无条件**在当前作用域创建它
（未传值时为空串），**不会**沿作用域链找到调用方的值：

```powershell
function F { param([string]$P); "P='$P'" }
function G { "P='$P'" }        # 无 param，走动态作用域查找到调用方的 $P
$P = 'CALLER'
G    # -> P='CALLER'
F    # -> P=''      ← 不是 CALLER
```

**影响与规避**：`build-installed-index.ps1` / `scan-uninstalled.ps1` / `rollback.ps1` 的既有
调用契约是「在作用域内设 `$OutputPath` 等变量，再调 `Main`」。若把 `$OutputPath` 加进
`Main` 的 `param()`，这些调用**全部静默写去默认路径**（实测一次踩掉 6 个用例）。
现在的写法是：`Main` **不**声明这些名字，改用 `-XxxOverride` 参数显式覆盖，其余情况读作用域变量。

### 9. 原生命令的 stderr 经 `2>&1` 被包成 ErrorRecord 写进**成功流**

```powershell
# ❌ 错误: cmd.exe 的 stderr（如「拒绝访问」）会被包成 ErrorRecord，
#          与 $false 一起进入成功流 → 调用方拿到非空数组，真值恒 $true
$deleted = Remove-ItemRobust -Path $p   # 内部: cmd /c "rd /s /q ..." 2>&1
if (-not $deleted) { $failed++ }        # 永不触发

# ✅ 正确: 显式 `$null =` 吞掉；成功流只允许携带最终布尔返回值
$null = cmd /c "rd /s /q `"$Path`"" 2>&1
```

**影响**: drill5 实测（share=0 独占句柄锁目录）：四层降级全部失败时，`$deleted` 拿到
`@(ErrorRecord, $false)`（Count=2），`-not $deleted` 恒为 `$false` → 被记成「删除成功」→
`failedCount` 保持 0 → **自动回滚不触发**（REQ-002 / AC-016）。修复后用 `WrcRirLock`
P/Invoke（`CreateFileW` share=0）写了可稳定复现的测试：断言成功流**恰好**为单个 `$false`。

### 10. pwsh 7 的 `ConvertFrom-Json` 把 ISO 8601 串解析成 `[datetime]`

PS 5.1 保留原字符串，pwsh 7 会解析为 `[datetime]`（与陷阱 6 同源的引擎差异，方向相反：
那次是数组展开，这次是标量类型）。

```powershell
# ❌ 错误: pwsh 7 下 $v 已是 [datetime]，-isnot [string] 成立 → 合法输入被判「不可解析」
$v = (Get-Content x.json -Raw | ConvertFrom-Json).timestamp
if ($v -isnot [string]) { throw 'unparsable' }

# ✅ 正确: 接受 datetime 对象
if ($null -eq $v -or ($v -isnot [datetime] -and [string]::IsNullOrWhiteSpace([string]$v))) {
    throw 'unparsable'
}
```

**影响**: `rollback-journal.ps1` 的自校验在 pwsh 7 下把合法 journal 判为「不可解析」
（修复：`cleanup_log_timestamp` 直接接受 `[datetime]`）。**测试断言同样不要依赖
`ConvertFrom-Json` 之后的类型**——断言「可 `[datetime]::Parse`」+ 断言原始 JSON 文本。

### 11. `[string]` 参数永远不可能是 `$null`——「未传」与「显式传 null」靠值区分不了

```powershell
function F { param([string]$A)
    if ($null -eq $A) { 'is null' }   # 永不打印
    else { "'$A'" }                    # 缺席与 -A $null 都是 ''
}
F            # -> ''
F -A $null   # -> ''    ← 值完全相同

# ✅ 区分「未传」与「显式传 null」只能查 $PSBoundParameters：
if ($PSBoundParameters.ContainsKey('A')) { 'bound' } else { 'omitted' }
```

实测（PS 5.1 与 pwsh 7 一致）：省略 → `isBound=false`；`-A $null` → `isBound=true`；
两种情况下 `$A -eq ''` 为真、`$null -eq $A` 为假。

**影响**: `rollback-verdicts.ps1` 的 PATH 冲突判定曾把「两侧证据都缺席」
（都空串 → `'' -cne ''` 为假 → 判「相等」→ 无冲突）当成「相符」，fail-open 放行恢复。
现改用 `$PSBoundParameters.ContainsKey` 判断证据存在性，四态
`PathCompare`（mismatch / current_null / expected_null / equal）留痕进 `rollback-result.json`。

> **同一陷阱的「注入接缝」变体（2026-10-08，drill5 根因）**：判断「调用方有没有注入 override」时，
> `$null -ne $XxxOverride` 在 `[string]` 参数上**恒为真**，于是「未注入」被读成「注入了空值」，
> 真实的系统读取分支被整条跳过。这类缺陷**单测永远看不到**——Mock/fixture 用例本来就显式传了
> override，只有真实机器上不传才暴露（drill5 因此每个 `path_entry` 都被拒为
> `conflict(external_change_sign_iii)`，rc=11）。凡有「注入接缝」（可覆盖真实读取的参数），
> 存在性一律用 `$PSBoundParameters.ContainsKey`，且转发层同样要用它（否则上一层的
> `$null -ne` 会把空串继续往下伪装）；并补一条「不传 ⇒ 必须读到活系统值」的端到端断言。

---

### 12. 跑 Pester 的包装脚本里设 `$ErrorActionPreference = 'Stop'` 会**凭空造出失败**

本项目不少用例**故意**触发非终止错误（`Write-Error` / `-ErrorAction SilentlyContinue` 的失败分支）
再断言其行为。Pester 宿主默认把这类错误记为 Warning 继续跑；一旦外层包装脚本设了 `Stop`，
它们变成**终止错误**，用例即判失败。

```powershell
# ❌ 错误: 本地覆盖率/验证包装脚本里加这一行
$ErrorActionPreference = 'Stop'
Invoke-Pester -Configuration $cfg     # 实测凭空 30 个失败，行覆盖率被压到 79.63%

# ✅ 正确: 不设该偏好（钩子适配器的片段同样不设，所以只有本地包装会骗人）
$cfg = New-PesterConfiguration
$cfg.Run.Path = 'tests'
$cfg.Run.PassThru = $true
Invoke-Pester -Configuration $cfg
```

症状是「同一份代码，钩子跑绿、本地跑红（或反之），且失败集合恰好是 error-action 敏感的那一类」
（本项目为 `hermeticity` 契约、`Test-AdminPrivilege`、`run-all` 传播、Mode D）。
**排查顺序**：先看宿主偏好，再怀疑代码。

---

### 13. Pester 5 的 `It` 标题里 `<...>` 是数据占位符；`BeforeDiscovery` 造的 `-ForEach` 数据不可用

```powershell
# ❌ 错误: 标题含非 ASCII 占位符 —— Pester 会对标题做 <> 替换后重新
#          [ScriptBlock]::Create，得到坏字符串并抛
#          "Exception calling "Create" ... The string is missing the terminator"
It '每个 Main 内都没有 return <数字>' -ForEach $cases { ... }

# ❌ 错误: -ForEach 数据在 BeforeDiscovery 里构造
BeforeDiscovery { $script:C = @(...) }
It 'x' -ForEach $script:C { ... }    # 实测拿不到数据（Count=1 / 标题未替换）
```

```powershell
# ✅ 正确: 标题里不写尖括号；数据在 BeforeAll 构造，循环写在用例内部
It '每个 Main 内都没有 return 数字常量' {
    foreach ($c in $script:C) { … accumulate $violations … }
    $violations | Should -BeNullOrEmpty
}
```

**影响**: `tests/unit/hermeticity.Tests.ps1` 把 ADR-001 契约做成穷举时先踩了这两个坑
（12 个失败、标题未替换），改用「`BeforeAll` 造数据 + 用例内循环 + 汇总违规断言」后稳定。
附带好处：失败信息直接列出**全部**违规文件，而不是只报第一个。

---

### 14. Start-Process 三连坑：引号不封装 / PS 5.1 句柄 / `-Wait` 不可超时（2026-10-16）

**14a. `-ArgumentList <数组>` 把元素按空格拼接且不加引号**。含空格的注册表键名、
文件路径、服务名在拼接处碎裂——`sc query "a b"` 碎成三个 token 后返回
1639（Invalid Option），而引号正确时返回 1060（服务不存在，幂等成功语义）；
`takeown` / `icacls` / `reg export` 同理。**行覆盖率 100% 也拦不住**——
用例从不喂含空格的真实形态。修复收敛在 `references/scripts/native-invoke.ps1`：

```powershell
# ✅ 唯一通道：Invoke-NativeExe（元素经 ConvertTo-NativeArgument 显式引号封装）
# ❌ Start-Process -FilePath x -ArgumentList @('a', $spacedPath)   ← 拼接必碎
# 逃生修法（不宜扩展新调用点）：('"{0}"' -f $path) 逐元素包引号（drill4/drill5 现场方案）
```

AST 守卫（`tests/unit/platform-hygiene.Tests.ps1`）钉死：`Start-Process` 只允许出现在
`native-invoke.ps1` 与 `run-all.ps1`；白名单内 `-ArgumentList` 数组字面量禁含裸变量；
产品脚本禁裸 `reg` / `sc` 命令。

**14b. PS 5.1 下 `-PassThru`（无 `-Wait`）必须先触碰 `.Handle`**，否则进程退出后
`$proc.ExitCode` 恒为 `$null`（pwsh 7 无此问题，双引擎行为差异）：

```powershell
$proc = Start-Process ... -PassThru   # 无 -Wait
$null = $proc.Handle                   # 强制取得句柄（5.1 必须；7 无害）
if ($proc.WaitForExit($ms)) { $proc.ExitCode }   # 才拿得到退出码
```

**14c. `Start-Process -Wait` 无法超时**——挂在 `-Wait` 上，`TimeoutSeconds` 只是
写在报错文案里的装饰（本项目旧 `Invoke-ScExe` 的真实形态）。真超时必须
`WaitForExit($ms)` 返回 `$false` 后 `Kill()`。`sc query` 含空格服务名的
1060/1639 判别（14a）即回归断言：`tests/unit/platform-hygiene.Tests.ps1`。

---

### 15. `Split-Path -LiteralPath` 不接受 `-Parent`/`-Leaf`；catch 会把**代码错误**吞成**环境失败**（2026-10-16）

`Split-Path` 的 `-LiteralPath` 参数集只支持 `-Resolve`/`-Credential`——
带 `-Parent` / `-Leaf` / `-Extension` 时在 **PS 5.1 与 pwsh 7 上都抛**
「Parameter set cannot be resolved / 无法使用指定的命名参数解析参数集」。
`-Path` 参数集才支持这些开关，但 `-Path` 有通配符语义（破坏性函数里是注入面）。
**路径拆解在破坏性函数里一律用 `[System.IO.Path]::GetDirectoryName/GetFileName`**。

**更危险的连带教训**：这个死分支藏在 `Remove-ItemRobust` tier-4 的 `catch` 里，
而当时的 locked-fixture 用例**预期 tier-4 失败**——「参数集解析错误」和「真实的
锁拒绝」都表现为 catch 住并落 `failed`，用例照样绿。**预期失败路径上的 catch
会把代码 bug 伪装成环境失败**；对这类路径必须额外断言失败原因的**类别**
（本例：警告流必须含锁拒绝措辞、必须不含参数集错误措辞，
`tests/unit/scripts.Tests.ps1` 的 tier-4 用例）。

> 实证边界（双引擎探测，2026-10-16）：share=0 独占句柄 / 内存映射文件 /
> 只读目录属性下，「删除被挡 ⇒ 改名同样被拒」——tier-4 的成功窗口在标准
> 语义下几乎不存在。它是如实的最后尝试（并 `MoveFileEx` 预约重启删除），
> **不是**可依赖的兜底；文档与测试都不应假定它成功。

---

## 多条件检测逻辑设计原则

### 核心规则: 权威信号必须 gate 辅助信号

扫描器使用多条件判断时，必须指定一个**权威信号**（如索引成员关系），辅助信号只能作为补充证据，不能独立触发。

```powershell
# ❌ 错误: OR 逻辑导致权威信号被覆盖
if (-not $inIndex -or $pathMissing -or $uninstallMissing) {
    # flag as residual
}
# 问题: 即使 $inIndex=$true (软件已安装)，只要 $pathMissing=$true 就会误报

# ✅ 正确: 权威信号 gate 辅助信号
if (-not $inIndex -and ($pathMissing -or $uninstallMissing)) {
    # flag as residual
}
# 逻辑: 不在索引中 AND (路径缺失 OR 卸载字符串异常)
```

**影响**: `scan-uninstalled.ps1` 的 OR 逻辑导致所有已安装软件被误报为已卸载。

---

## Windows 系统交互最佳实践

### 文件删除: 四层降级策略

Windows 文件可能被进程占用或权限锁定，需要逐级降级:

```powershell
function Remove-ItemRobust {
    param([string]$Path, [switch]$WhatIf, [ref]$Outcome)
    $setOutcome = { param($v) if ($null -ne $Outcome) { $Outcome.Value = $v } }

    if ($WhatIf) { & $setOutcome 'dry_run'; return $true }
    # 2026-10-16：破坏性函数内一律 -LiteralPath（见陷阱 14 前的 P2 修复）——
    # -Path 的通配符语义会把含 [ ] 的目录名误判 absent，甚至错删匹配项。
    if (-not (Test-Path -LiteralPath $Path)) { & $setOutcome 'absent'; return $true }

    # Tier 1: 标准 PowerShell 删除
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        & $setOutcome 'deleted'; return $true
    } catch { Write-Warning "  → Standard delete failed: $($_.Exception.Message)" }

    # Tier 2: 夺取所有权 + 修改 ACL（走 Invoke-NativeExe：引号封装 + 真实超时，见陷阱 14）
    try {
        $isDir = (Get-Item -LiteralPath $Path).PSIsContainer
        $takeownArgs = if ($isDir) { '/r', '/d', 'Y', '/f', $Path } else { '/f', $Path }
        $takeown = Invoke-NativeExe -FilePath 'takeown.exe' -Arguments $takeownArgs -TimeoutSeconds 600
        if (-not $takeown.ok) { Write-Warning "  → takeown.exe failed with exit code $($takeown.exit_code)" }
        $icaclsArgs = if ($isDir) { $Path, '/grant', 'Administrators:F', '/T', '/C' }
                      else { $Path, '/grant', 'Administrators:F', '/C' }
        $icacls = Invoke-NativeExe -FilePath 'icacls.exe' -Arguments $icaclsArgs -TimeoutSeconds 600
        if (-not $icacls.ok) { Write-Warning "  → icacls.exe failed with exit code $($icacls.exit_code)" }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        & $setOutcome 'deleted'; return $true
    } catch { Write-Warning "  → Takeown+ACL delete failed: $($_.Exception.Message)" }

    # Tier 3: CMD 强制删除 —— 原生命令输出必须显式 $null = 吞掉（见陷阱 9）
    #   cmd 内建命令（rd/del）只能经 `cmd /c <单串>` 传递，无法按元素加引号，
    #   故**有意**不经 Invoke-NativeExe（AST 守卫只约束 Start-Process 与裸 reg/sc）。
    try {
        $null = cmd /c "rd /s /q `"$Path`"" 2>&1
        if ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $Path)) { & $setOutcome 'deleted'; return $true }
    } catch { Write-Warning "  → cmd delete failed: $($_.Exception.Message)" }

    # Tier 4: 重命名 + 延迟删除（下次启动时）—— 走 Warning，不得污染成功流
    # 注意：路径拆解必须用 [System.IO.Path]，不能用 Split-Path ——
    #   -Path 有通配符语义（同 Tier 0 注入面），而 -LiteralPath 参数集**不接受**
    #   -Parent/-Leaf（两个引擎都抛「Parameter set cannot be resolved」，见陷阱 15）。
    #   拆解已收敛为可单测纯函数 Get-RenameTarget（尾反斜杠归一化 + 盘根拒绝）：
    #   [System.IO.Path]::GetFileName('C:\dir\') 返回**空串**，不归一化会把改名
    #   目标落到 'C:\dir\~.deleted'（Round-2 走查 2026-10-16 严码关 Minor）。
    try {
        $isDir = (Get-Item -LiteralPath $Path).PSIsContainer
        $parts = Get-RenameTarget -Path $Path
        if (-not $parts.ok) { throw $parts.reason }
        $renamed = Join-Path $parts.parent "~$($parts.leaf).deleted"
        $counter = 0
        while (Test-Path -LiteralPath $renamed) {
            $counter++
            $renamed = Join-Path $parts.parent "~$($parts.leaf).deleted$counter"
        }
        Rename-Item -LiteralPath $parts.normalized -NewName ([System.IO.Path]::GetFileName($renamed)) -Force -ErrorAction Stop
        Write-Warning "  → Renamed to $([System.IO.Path]::GetFileName($renamed)) (deferred delete - may be in use)"
        # REQ-002: 改名不是删除（内容仍在磁盘上），必须回传 renamed:<新名>
        & $setOutcome ('renamed:' + [System.IO.Path]::GetFileName($renamed))
        return $true
    } catch { Write-Warning "  → Rename fallback also failed: $($_.Exception.Message)" }

    & $setOutcome 'failed'
    return $false
}
```

契约：**成功流只允许携带最终布尔返回值**；所有诊断输出走 Warning 流；语义结果经
`[ref]$Outcome` 回传（`dry_run` / `absent` / `deleted` / `renamed:<新名>` / `failed`），
其中 `renamed:` **不得**被记成删除成功（REQ-002，DD-006 规定其不参与自动恢复）。
`$deleted = Remove-ItemRobust …` 拿到的必须是**裸布尔**——任何多余输出都会让它变成
真值恒为 `$true` 的数组（见陷阱 9）。

### 注册表路径处理 checklist

1. **Trim 引号**: `$path = $value.Trim('"')`
2. **展开环境变量**: `$path = [Environment]::ExpandEnvironmentVariables($path)`
3. **跳过特殊模式**:
   - `MsiExec.exe /X{GUID}` → MSI 卸载程序，不代表残留
   - bare exe 名 (`sc.exe`, `powershell.exe`) → 系统工具，需要 PATH 解析或跳过
4. **验证路径格式**: `$path -match '^[A-Za-z]:\\'`

### $PSScriptRoot 路径一致性

同一目录下的多个脚本引用相同输出目录时，必须使用相同的相对深度。

```powershell
# ❌ 不一致
# script-a.ps1: $PSScriptRoot\..\..\output   (project root)
# script-b.ps1: $PSScriptRoot\..\output      (references/)

# ✅ 标准化: 统一使用项目根目录
$ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# script-a.ps1 和 script-b.ps1 都使用 $ProjectRoot\output
```

---

## 测试策略

### Mock 测试的局限性

Mock 测试对以下 Windows 系统交互代码**不可靠**，必须通过集成测试验证:

- 注册表读取 (`Get-ItemProperty`)
- 文件系统检测 (`Test-Path`, `[IO.File]::Exists`)
- 服务查询 (`Get-CimInstance Win32_Service`)
- 计划任务解析 (`Get-ScheduledTask`)
- 环境变量展开 (`[Environment]::ExpandEnvironmentVariables`)

**原因**: Mock 返回的人工数据不会包含真实系统的 edge cases（引号、环境变量、 bare exe 名等）。

### 推荐的测试分层

| 层级 | 范围 | 目标 | 示例 |
|------|------|------|------|
| Unit | 纯函数 | 验证算法逻辑 | `Set-Id`, `Test-Whitelisted` |
| Integration | 真实系统数据 | 验证系统交互 | 扫描脚本读取真实注册表 |
| End-to-End | 完整工作流 | 验证数据流 | scan → report → confirm → clean |

### 集成测试最小要求

每个涉及系统交互的脚本，至少需要一个集成测试:

```powershell
It 'Works against real registry data' {
    # 调用真实函数（不使用 Mock）
    $result = & $scriptPath
    
    # 验证不变式
    $result.id | Should -BeUnique
    $result | Where-Object { $_.risk -eq 'danger' } | Should -Not -BeNullOrEmpty
}
```

---

## 已知限制

- **根目录 `package.json` 是有意 local-only**（2026-10-16 走查确认）：它只服务本机
  `npx vitest`（Gate 5 根跑）的 devDeps，**已 gitignore、不进仓**；`ui/package.json`
  才是 UI 工具链的权威依赖清单。不要把根 package.json 「补」进 git——那会引入两份
  依赖源，且 Gate 5 读的是它而非仓库状态。
- MSI 安装软件的 `UninstallString` 为 `MsiExec.exe /X{GUID}` 格式，当前逻辑已跳过此类条目
- 系统 PATH 损坏（如 `C:\Program Fi;es\Memurai\`）会被如实报告，但不会被自动修复
- 计划任务中的 bare exe 名（如 `sc.exe`）需要 PATH 解析，当前策略是跳过而非解析
- `confirm-cleanup.ps1` 在 OpenCode 内置终端中无法交互（`Read-Host` 闪退），必须在独立 Windows Terminal 中运行
- **`confirm-cleanup.ps1` 的 TUI 命令循环仍难被单测覆盖**：它由 `Read-Host` 驱动，
  6 个纯展示函数已覆盖。**注意**：`Main` 内原有的 12 处 `exit` 已于 2026-10-01 全部改为
  `[ref]` 回传（ADR-001），所以「在 Pester 进程内调用会杀死宿主」这一障碍**已消除**；
  剩下的只是 `Read-Host` 本身需要重定向 stdin 才能驱动。
- ~~任何 `Main` 内含 `exit` 的脚本都不能在 Pester 进程内直接调用~~
  → **已于 2026-10-01 修复（ADR-001）**：全部含 `Main` 的脚本（现 **11 个**：`references/scripts` 下
  10 个 + 根目录 `setup.ps1`）都不再于 `Main` 内 `exit`，改为 `[ref]$ExitCode` 回传。
  因此「dot-source + 进程内调用 `Main`」对**所有**脚本都可用，覆盖率插桩不再有
  「执行一行都不计入」的盲区。该契约现为**穷举式 AST 断言**（`tests/unit/hermeticity.Tests.ps1`），
  新增脚本一旦违反即在门禁变红。
- ~~`setup.ps1` 是例外：没有 `Main`/`[ref]` 结构、结构性不可插桩，已在
  `.xp-gate-powershell-coverage-ignore` 中排除~~ → **2026-10-08 修正**：那条豁免**是把代码缺陷
  写成了结构性限制**。`setup.ps1` 现已重构为 `function Main` + `param([ref]$ExitCode)` +
  统一守卫（唯一注入接缝 `-PSVersionOverride`，用于测「环境不满足 → 回传 1」），
  可在 Pester 进程内插桩；`.xp-gate-powershell-coverage-ignore` 现为**空列表**。
  子进程端到端用例仍保留（验证真实 `exit` 码与输出）。
- `references/scripts` + `setup.ps1` 行覆盖率 **84.08%**（2804/3335，**17 个文件**，
  2026-10-08 JaCoCo 实测；**历史值**——native-invoke.ps1 入列后清单变为 **18 个
  sourcefile**、2026-10-16 实测 **84.17%**（2844/3379），权威口径见下方
  「coverage.xml 的口径与污染」条目），已超过 pre-commit 门禁的 80% 阈值（ADR-001 前为 70.4%；
  随后补真实测试到 80.0%；自动回滚 Sprint 落地后为 83.94%（2765/3294，16 个文件）；
  `setup.ps1` 摘掉豁免后为 84.08%）。剩余缺口已定位且是**结构性**的，不是「懒得写测试」：
  - `confirm-cleanup.ps1` —— 未覆盖行中绝大多数是 `Read-Host` 交互式 TUI 循环
    （`Show-Page` 之后的命令分发）；只有少量属于可单测范围，已补测。
  - `clean-residuals.ps1` —— 未覆盖行集中在 HKLM/PATH 写入分支与 tier 2-4 的**成功**路径
    （需管理员 + ACL 受限文件；失败路径已由 `WrcRirLock` share=0 独占锁测试覆盖）。
  这两块属于 AGENTS.md 明确划给「管理员环境集成演练」的范围，**不用 Mock 硬拉**。
  达到 80%+ 靠的是把可测逻辑抽成纯函数并补真实测试，**未使用 `--no-verify`、
  未向 `.xp-gate-powershell-coverage-ignore` 添加任何文件**（该文件现已**不排除任何文件**；
  历史上进过列表的唯一一项 `setup.ps1` 于 2026-10-08 以重构方式解决）。
- **测试与门禁的双引擎要求**：pre-commit 的 Gate 5 用 **`pwsh` 7** 跑 Pester，
  而项目运行时基线是 **PS 5.1**。两者对 `ConvertFrom-Json` 的处理不同
  （见陷阱 6），因此**测试断言必须在两个引擎下都成立**。
  实测踩坑：断言 `restore-status.json` 的 `timestamp` 精确匹配
  `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$`，在 PS 5.1 下通过（保持字符串），
  在 pwsh 7 下失败（被解析成 `[datetime]` 再序列化为 `...T21:39:42.0000000`）。
  **改法**：断言「可被 `[datetime]::Parse` 解析」+ 断言**原始 JSON 文本**里的 ISO 形态，
  不要断言 `ConvertFrom-Json` 之后的类型/格式。
  提交前请两个引擎各跑一次：
  ```powershell
  powershell.exe -NoProfile -Command "Invoke-Pester tests"   # 5.1
  pwsh -NoProfile -Command "Invoke-Pester tests"             # 7（门禁用的引擎）
  ```
- **双引擎 Pester 必须「串行」运行，不可并发（2026-10-16 实测）**：部分测试 fixture 用
  **仓库根固定路径**（`rollback-auto.Tests.ps1` 的 `wrc-auto-projroot`、`scripts.Tests.ps1`
  的 `wrc-robust-fixture`），两个引擎的全量运行同时启动会互相污染：journal 互串把
  `dry_run_ambiguous(2)` 跑成 `(4)`、锁文件互掐报「being used by another process」、
  fixture 被对端 `Remove-Item` 后报「Cannot find a part of the path」。实测一次并发双跑
  两个引擎各出 10 个失败且全部集中在 `rollback-auto.Tests.ps1`；串行复跑该文件
  pwsh 7 与 PS 5.1 均 59/59。上条「提交前两引擎各跑一次」指**先跑完一个再跑另一个**，
  不是并行。UI 侧附带一条：vitest `ItemTable` 用例的 5s 默认超时在高负载下会抖动超时
  （单跑 2.6s 通过），全量偶红时先单文件复测再判回归。
- **本机工具链路径与门禁降级链（2026-10-07 实测；2026-10-16 第三批加固后已改观）**：
  `pwsh` 7 位于 `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`，`node.exe`
  位于 `C:\Program Files\nodejs\node.exe`——git-bash 的 PATH 里没有裸命令名，`jq` 未安装。
  **加固后**：适配器 `_detect_pwsh` 会显式探测 WindowsApps pwsh 与 System32
  powershell.exe 的标准安装位置（PATH 剥离也找得到）；Gate 1 有了 fail-closed 的
  powershell 分支（引擎/PSSA 模块缺席 → WARN 计入分母，绝不静默 PASS）；gate-10.sh
  会兜底探测 `%APPDATA%\Python\*\Scripts\semgrep.exe`。 commit 时仍建议前置
  `C:\Program Files\nodejs`（Gate 10 verdict 解析与 Stage-2 覆盖率解析都依赖 node）。
- **Gate 5 的陈旧 `coverage.xml` 陷阱（2026-10-07 实测）**：hook 适配器在找不到 pwsh 时
  跳过测试与覆盖率**生成**，但 Stage-2 仍会解析仓库根目录**既有的** `coverage.xml`
  （只要 node 在 PATH 上）。于是旧产物会拦新提交（实测：2026-10-01 的 68% 产物拦下了
  2026-10-07 的提交）。**不跑 pwsh 覆盖率就提交时，先手动跑一次覆盖率管线刷新
  `coverage.xml`**（该文件已 gitignore，属于本机门禁工件）。加固后 Gate 5 在 PS-only
  提交上会真跑 Pester 并重新生成 coverage.xml，此陷阱只剩「纯文档提交」时仍适用。
- ~~**hook 的文件发现不排除 `.worktrees` / `wrc-drill`**~~ → **2026-10-16 第三批加固已解决**：
  `_find_powershell_files` 的 prune 列表覆盖 xp-gate 脚手架 dot 目录
  （`.worktrees/.workbuddy/.sprint-state/.delphi-work/.qoder/.vscode/.idea/.xp-gate`），
  项目专属目录经 `.xp-gate-powershell-prune-dirs`（本仓含 `wrc-drill`）注入；
  实测发现结果 = 20 个测试文件 + **18 个产品源文件**（17 脚本 + setup.ps1），wrc-drill
  不再进测试发现与覆盖率分母。Gate 1 的 PSSA 经 `.xp-gate-powershell-analysis-paths`
  收敛到产品范围（references/scripts + setup.ps1），Pester 测试文件按 Pester 执行模型
  产生的数百条规则误报不再进入门禁判据（328 条清单见审计文档；同规则、收范围，
  非放宽规则）。~~想真正启用 pwsh，必须连同分析范围一起收敛~~ → 已落地，pwsh 可安全
  上钩子 PATH。
- **测试密闭性**：`backup-*` 是 gitignored 的运行时目录。任何「非 DryRun + 走 ConfirmFile/Mode A-C」
  的清理测试都需要它存在，否则 `Main` 会在备份门提前中止。**测试必须自建自清该 fixture**，
  不得依赖主仓里遗留的 `backup-*`（否则新克隆 / CI 下会出现假绿或假红）。
  见 `tests/unit/hermeticity.Tests.ps1`、`tests/unit/rollback.Tests.ps1`（`BackupRoot` 可注入）
  与 `scripts.Tests.ps1` 的 `backup-svcregress` fixture。**2026-10-07 复查**：主仓
  `backup-*` 目录数为 0，双引擎 710 全绿——隐藏前置依赖确已消除。
- **覆盖率门禁的口径**：`xp-gate` 的 80% 阈值写死在共享 hook 里。**2026-10-16 第三批
  加固后**，调节分母的正确手段是 `.xp-gate-powershell-prune-dirs`（非产品脚手架目录在
  **发现阶段**整体离场，发现=分母）；`.xp-gate-powershell-coverage-ignore` 保持**空列表**
  （按产物减扣会把真实产品代码静默移出分母，已由 `platform-hygiene.Tests.ps1`
  「门禁边界一致性」守卫）。该文件的注释已明确写下
  「Do NOT add files here merely because they are hard to test」——所以**不要**为了过门禁
  而把 `clean-residuals.ps1` / `confirm-cleanup.ps1` 整文件排除：那会连同已覆盖的
  163/170 行一起丢掉。正确方向是把可测逻辑抽成纯函数（`ConvertFrom-*`、`Get-*Verdict`、
  `Get-MatchingRestorePoint` 等，本次已示范）并补测。
  **判断口径**：若某脚本看起来「结构性不可插桩」，先怀疑它违反了 ADR-001（`Main` 内 `exit`），
  而不是往列表里加一行——`setup.ps1` 正是这样一条被写成豁免的代码缺陷，2026-10-08 已重构消除。
  **R6 补充（2026-10-17）**：`.xp-gate-powershell-analysis-paths` 是 Gate 1 的产品分析
  范围——**新产品脚本必须同提交把路径加进去**，缺失条目现会 fail-closed 发 WARN
  （`XP_G1_REASON: analysis-path-missing:<路径>`，R6 前是静默跳过）；一致性由
  「门禁边界一致性」测试守卫（tracked 产品源必须全被 scope 覆盖 + scope 条目必须真实存在
  + coverage-ignore 必须空 + prune-dirs 必须含 wrc-drill）。注意发现是 `*.ps1` 端到端：
  `.psm1` 模块不在发现/覆盖率/分析三处分母内（见 analysis-paths 文件头 R6 note）。
- **coverage.xml 的口径与污染（2026-10-16 走查实测）**：引用覆盖率数字前先核对产物：
  (1) 本地包装脚本的 `CoveragePercent`（如 80.40%）是 **Pester 命令口径**；
  (2) JaCoCo `coverage.xml` 的 LINE counter 是**行口径**，两者不可互引；Gate 5 读的是后者。
  权威口径 = `references/scripts` **17 脚本**（native-invoke 入列后）+ `setup.ps1` 共
  **18 个 sourcefile**（2026-10-16 JaCoCo 实测 84.17%，2844/3379）；脚本数再变时以
  17 文件清单命令的实数为准。
  (3) 产物会被**任何**用默认 CodeCoverage 配置跑 Pester 的会话覆写污染——实测评审期间
  一次运行把 `.workbuddy/`（3 文件）与根目录本地脚本混进 23 个 sourcefile，顶层 counter
  随之失真；**另一种观测形态（R5 走查实测）**：产物被整个写成 **2 字节空文档
  （0 sourcefile）**。两种形态都会被 sourcefile 计数自检抓出，混入/清空即重跑覆盖率管线。

---

## 脚本架构规范

### 函数/执行分离模式

`references/scripts/` 下全部 10 个含 `Main` 的脚本 + 根目录 `setup.ps1`（共 **11 个**）统一使用
函数/执行分离模式，确保可测试性（dot-source 只加载函数定义，不触发任何副作用）：

```powershell
function Main {
    # 所有执行逻辑在此函数内（编码设置、权限检查、扫描/清理、输出）
    # 退出码用 [ref] 回传 —— 不得 exit，也不得 `return <数字>`
    param([ref]$ExitCode)
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }
    # ... & $setRc 1; return   （错误路径）
    # ... & $setRc 0           （成功路径）
}

# 执行守卫 — 仅当脚本被直接执行时运行
# $MyInvocation.InvocationName 在 dot-source 时为 '.'，-File 调用时为空
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
```

- 需要被单元测试直接调用的辅助函数（`Get-ExecutablePath`、`Remove-ItemRobust`、`Test-Whitelisted`、`Set-Id`、`Test-AdminPrivilege` 等）保留在 **Main 外部**作为顶层函数。
- **新产品脚本 checklist（R6 硬边界，2026-10-17）**：新增 `.ps1` 产品脚本的同一次提交必须
  (1) 把脚本路径（或其目录）加进 `.xp-gate-powershell-analysis-paths`；
  (2) 若在 `references/scripts/` 外，确认 `.xp-gate-powershell-prune-dirs` 未把它剪掉；
  (3) 确认它带 `function Main` + `[ref]$ExitCode` + 执行守卫（hermeticity 契约会穷举）。
  漏做 (1) 时「门禁边界一致性」测试当场变红；漏做且钩子侧为旧版本时 Gate 1 对它失明
  （analysis-path-missing WARN 是 R6 加固后的兜底）。
- 不要用 `$PSCommandPath -eq $MyInvocation.MyCommand.Path` 做守卫，在 `powershell -Command ". script.ps1"` 场景下不可靠。
- 不要使用「顶层代码 + 提前 `return`」的写法：它虽能挡住 dot-source，但 `exit` 语句会散落到文件末尾，与其余脚本不一致。

### 退出码规范

| 退出码 | 含义 | 使用场景 |
|--------|------|----------|
| 0 | 成功 | 脚本正常完成 |
| 1 | 通用错误 | 文件未找到、解析失败 |
| 2 | 权限错误 | 非管理员运行写入脚本 |
| 3 | 依赖缺失 | 必需的 JSON 输入文件不存在 |

**自动回滚扩展码（10–15，`clean-residuals.ps1`）**：由纯函数 `Get-CleanupExitCode`
（`rollback-producer.ps1`）统一判定，优先级 `14 > 15 > 0 > 13 > 12 > 1 > 11 > 10`：

| 退出码 | 含义 |
|--------|------|
| 10 | 部分失败且自动回滚**完全成功** |
| 11 | 部分失败且回滚未完全成功（存在 `restore_failed`） |
| 12 | 部分失败但回滚日志缺失/不可读 |
| 13 | 部分失败且显式 `-NoAutoRollback` |
| 14 | 上一轮日志未能安全消费，本轮**未开始**即中止（判定在本轮任何写入之前） |
| 15 | 本轮持久化写入失败（日志落盘 / 未修复清单 / 完成或消费标记）——**终态** |

「部分失败但本轮没有任何已变更记录」= 1，排在 11/10 **之前**：此时恢复端一条都不会动，
把 0 条恢复当成「回滚完全成功」会虚报保护效果。权限(2)/输入(1)/依赖(3) 由更早的分支直接返回。

`rollback.ps1 -Auto` 用 `Get-AutoRollbackExitCode` 把消费协议 Outcome 映射到同一套编码
（`partial_restore`→11；`no_journal`/`unreadable`→12；`ambiguous`/`needs_acknowledgement`/
`rejected`/`consumed_with_skipped`→14；`persistence_failed`→15；成功态→0；**未知 Outcome 落 14**——
映射表没更新不得宣告成功）。`clean-residuals.ps1` 启动期 T3 的 `Get-StartupRecoveryExitCode`
语义不同：它回答「新一轮清理能不能开始」——完整恢复（`consumed`）在此是**继续**（0），
`persistence_failed`→15，其余未安全消费→14。

**完成标记（`completed_at`）的抑制判定** —— 由纯函数 `Test-CompletionMarkerSuppressed`
（`rollback-producer.ps1`）统一回答，判据只有一个问题：**系统此刻是否仍有本轮没能修复的改动**。
`completed_at` 的语义是「本轮清理已正常结束」，写下去就等于告诉下一次启动「这轮不用再管」，
T3 便永不再尝试恢复。例外只有两类：

| 退出码 | 是否写 `completed_at` | 原因 |
|--------|----------------------|------|
| 11 | **不写** | 回滚跑过但有 `restore_failed` |
| 15 且 (a) `restore_failed > 0` | **不写** | 回滚没修完 |
| 15 且 (b) 未记账变更 > 0 | **不写** | 变更日志落盘失败（AC-052），恢复端一条都看不到 |
| 15 且 (c) `failedCount > 0` 且 `$rollbackAttempted` 为假 | **不写** | 清理有失败，而 T2 因持久化早退**整轮没跑** |
| 15 且本轮无任何失败 | 写（尽力补） | 该轮是干净的，留 `null` 会让下次 T3 把刚清掉的残留**重新装回去**（REQ-024 规则 3） |
| 0 / 1 / 10 / 12 / 13 | 写 | 正常结束的终态 |
| 14 | 不参与 | 本轮未开始即中止，没有本轮日志 |

> **为什么 (c) 不可省略**：每个中途失败点都先置 `$persistenceError = $true` 再 `break`，而
> `clean-residuals.ps1:1195` 在 `$persistenceError` 已置真时**跳过 T2** —— 因此**每个 15 的
> `restore_failed` 恒为 0**。只写「15 且 `restore_failed > 0`」的窄判据是**不可达代码**，
> 会把「有失败但整轮没回滚」这一最常见形状照常标记为完成（2026-10-08 实测盲区，已修）。
> 调用方需为此提供 `$rollbackAttempted` 接缝（`clean-residuals.ps1:1191/1205`），
> 不能靠 `restoreFailed` 反推。

退出码由 `Main` 通过 `[ref]$ExitCode` 回传，**在执行守卫处**统一 `exit`：

```powershell
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
```

**`Main` 内部不得出现 `exit`，也不得出现 `return <数字>`** —— 理由见 ADR-001：
前者在 dot-source + 进程内调用时杀死 Pester 宿主（整份套件静默塌掉），
后者把整数写进输出流污染调用方断言。

### 权限分级

| 脚本类型 | 权限检查 | 脚本 |
|----------|----------|------|
| 写入操作 | 强制 Admin（`Test-AdminPrivilege -Mandatory` → `Main` 回传 2） | `clean-residuals.ps1`、`create-restore-point.ps1`、`run-all.ps1` |
| 只读操作 | 仅警告（`Write-Warning`） | `build-installed-index.ps1`、`scan-uninstalled.ps1`、`scan-filesystem-residuals.ps1`、`scan-residuals.ps1`、`generate-report.ps1`、`confirm-cleanup.ps1`、`rollback.ps1` |

`Test-AdminPrivilege -Mandatory` 不再自行 `exit 2`，而是 `return $false`，由调用方决定退出码。
权限检查放在 `Main` 顶部，因此对独立调用生效、对 dot-source 不可见。经 `run-all.ps1` 调用的子脚本继承父进程权限，检查必然通过——这里的检查是为**用户直接运行单个脚本**兜底的。

### run-all.ps1 统一入口

`run-all.ps1` 是扫描管道的统一入口，**只扫描、不确认、不清理**，按顺序执行：

1. `create-restore-point.ps1` — 创建还原点 + 注册表备份（`-SkipRestorePoint` 可跳过）
2. `build-installed-index.ps1` — 构建已安装软件索引
3. `scan-uninstalled.ps1` — 扫描已卸载软件残留
4. `scan-filesystem-residuals.ps1` — 扫描文件系统残留
5. `scan-residuals.ps1` — 扫描注册表/服务/任务/COM 残留
6. `generate-report.ps1` — 生成 `final-report.json`

子脚本通过 `Start-Process -FilePath $psExe -ArgumentList ... -Wait -PassThru` 调用（`$psExe` 优先 `pwsh`，回退到 PS 5.1 绝对路径），任一步非零退出即中断管道并向上传播退出码。清理阶段仍由 agent 逐条确认后调用 `clean-residuals.ps1`。

---

## 变更历史

- 2026-05-05: 从 v1.0.0 → v1.1.0.0 session 中提取并整理
  - 新增 PowerShell 5.1 陷阱清单
  - 新增多条件检测逻辑设计原则
  - 新增四层降级删除策略
  - 新增测试策略（Mock 局限性 + 集成测试要求）
- 2026-06-04: Sprint 2 发布级改造（sprint 分支）
  - 新增脚本架构规范（函数/执行分离、退出码、权限分级）
  - 新增 run-all.ps1 统一入口说明
  - 修正执行守卫模式（`$MyInvocation.InvocationName`）
- 2026-09-08: Sprint 2 改动移植回主线
  - 陷阱清单新增第 6 条：`ConvertFrom-Json` 数组不展开（PS 5.1）
  - `scan-filesystem-residuals.ps1` 补齐 Main 包装，10 个脚本架构完全统一
  - `rollback.ps1` 补只读权限警告，权限分级覆盖全部脚本
  - 集成测试改为「fixture 驱动 + 真实只读扫描」，98 个测试 0 失败
- 2026-09-30: v1.4.1.0 接管审计
  - 陷阱清单新增第 7 条：幽灵服务清理的 `$LASTEXITCODE` 幂等判定缺陷（+ 部分流重定向的环境相关风险）
  - 修复 `clean-residuals.ps1` 幽灵服务清理（裸 `sc.exe ... 2>&1` + `-ne 0` → `Invoke-ScExe` + 1060 幂等判定）
  - 新增 `service cleanup (sc.exe regression)` 测试组，断言可观测副作用而非打印字符串
  - 测试数 98 → 141，PSScriptAnalyzer 维持 0 error / 0 warning
  - 修正 `main-flow.Tests.ps1` 的覆盖率盲区（`&` 子进程执行不计入插桩 → dot-source + 进程内 `Main`）
  - 记录 `references/scripts` 行覆盖率约 70% 及其结构性原因（见「已知限制」）
  - 真实环境演练：非管理员范围（文件/注册表/计划任务）3/3 通过；管理员范围
    （服务删除 + HKLM）经用户实测 2/2 通过（`cleanup-log.json`: `service_deleted` + `registry_deleted`）
  - **更正**：本条最初把 7b 的 `StandardOutputEncoding` 风险写成「必然抛异常」，
    复核后无法稳定复现，已拆分为 7a（已复现主缺陷）与 7b（环境相关风险）
- 2026-10-01: ADR-001 —— 退出码统一 `[ref]` 回传 + 测试密闭性修复
  - 陷阱清单新增第 8 条：dot-source 覆盖调用方同名变量 / 函数 `param()` 无条件遮蔽调用方变量
  - **Critical**：修复测试套件在干净 worktree / 新克隆 / CI 下**整份静默塌掉**的假绿
    （`Main` 内 `exit 1` 杀死 Pester 宿主 → `Passed= Failed= Total=` 全空 → CI 显示绿色）
  - 8 个脚本的 `Main` 退出码改为 `[ref]$ExitCode` 回传，移除 `Main` 内共 25 处 `exit`
  - `Test-AdminPrivilege -Mandatory` 改为 `return $false`，由调用方决定退出码 2
  - 新增 `tests/unit/hermeticity.Tests.ps1`（AST 契约：`Main` 内不得 `exit`、不得 `return <数字>`）
  - 新增 `docs/decisions/ADR-001-main-ref-exit-code.md`（含三种被实测否决的写法）
  - 可测逻辑抽成纯函数并补测：`ConvertFrom-WingetJson/Text`、`ConvertFrom-ScoopJson/Text`、
    `ConvertFrom-ChocoText`、`Test-PathMissing`、`Get-UninstallExePath`、
    `Get-ResidualVerdict`、`Get-ResidualEvidence`、`Get-BackupDirectory`、
    `Get-RegistryBackupFile`、`Get-MatchingRestorePoint`
  - 顺带修复：`scan-uninstalled.ps1` 里一段**不可达的重复代码**（`& $setRc 3; return` 写了两遍）
  - 顺带修复：`build-installed-index.ps1` / `scan-uninstalled.ps1` / `rollback.ps1` 的
    `Main` 此前**静默忽略** `-OutputPath` 之类的实参（改为 `-XxxOverride` 显式参数）
  - `rollback.ps1` 补 `try/catch`：清理日志或 `restore-status.json` 损坏时不再中断指引输出
  - 测试数 141 → **254**；覆盖率 70.4% → **77%**；PSScriptAnalyzer 维持 0 error / 0 warning
  - 剩余覆盖率缺口为结构性（`Read-Host` TUI 109 行 + 管理员专属 ACL/HKLM 分支），已记录于「已知限制」
- 2026-10-02: 覆盖率补到 80%（真实测试，零 `--no-verify`）+ 又抓到 3 个真实产品缺陷
  - **门禁口径**：用户明确否决「`--no-verify` 先提交」与「向 ignore 文件加文件」两条捷径，
    要求把门禁做成**名副其实**的通过。本次靠补真实测试把覆盖率 77% → **80.0%**
    （1065/1331），**未使用 `--no-verify`，未改 `.xp-gate-powershell-coverage-ignore`**。
  - 测试数 254 → **287**（PS 5.1 与 pwsh 7 双引擎均 287/287 通过）
  - **真实缺陷 1（PS 5.1 哈希表 + 空数组）**：`generate-report.ps1` 里
    `candidate_directories = if (...) { ... } else { @() }` 会让
    `final-report.json` 写出 `"candidate_directories": {}`（**空对象**，不是空数组）。
    根因：`if` 语句**作为表达式**产出空数组时结果是 `$null`，`ConvertTo-Json` 把 `$null`
    渲染成 `{}`。另外 `@($null)` 也不是空数组（Count=1、唯一元素为 `$null`）。
    修复：先判空赋变量再 `[array]` 转型。**注意不能写 `[array]( if ... )`——那是语法错误**
    （`if` 不是表达式），本次先踩了这个坑，且由于脚本加载失败时旧定义仍在作用域内，
    一度产生「改好了」的假象。
  - **真实缺陷 2（辅助函数依赖调用方变量）**：`scan-filesystem-residuals.ps1` 的
    `Get-EffectiveFileCount` / `Get-DirectorySizeMB` 在 `catch` 里调用 `& $setRc 0`，
    但它是**顶层纯函数**，被单测或其它脚本直接调用时 `$setRc` 并不存在 →
    抛 `The expression after '&' ... was not valid`。改为 `return 0`。
  - **真实缺陷 3（不可达重复代码 ×3）**：`generate-report.ps1` / `scan-residuals.ps1` /
    `scan-filesystem-residuals.ps1` 各有一处 `& $setRc 3; return` 被写了两遍，
    第二份永不执行。已删除。
  - **双引擎断言教训**：pre-commit Gate 5 用 **pwsh 7** 跑 Pester，而运行时基线是 PS 5.1。
    `restore-status.json` 的 timestamp 断言在 5.1 下通过、在 pwsh 7 下失败
    （7 会把 ISO 串解析成 `[datetime]` 再序列化出小数秒）。已改为断言
    「可 `[datetime]::Parse`」+ 断言**原始 JSON 文本**。**提交前必须两个引擎各跑一次。**
  - 新增测试文件：`tests/unit/create-restore-point.Tests.ps1`（注册表备份 + 还原点分支）、
    `tests/unit/rollback.Tests.ps1`（备份目录/注册表备份/还原点匹配 + 单条匹配计数回归）
  - `generate-report.ps1` 与 `rollback.ps1` 现已 **100% 行覆盖**
- 2026-10-02: Gate 11（Sprint Flow Enforcement）状态校正
  - `.sprint-state/sprint-state.json` 的 `phase` 由 `1` 改为 `0`：Phase 1 PLAN 尚未产出
    经 delphi 评审的 auto-rollback 设计，此前填 `1` 会让 Gate 11 误以为可以要求
    `.sprint-state/delphi-reviewed.json`。**如实记录相位，不伪造评审产物。**
  - 阻塞项 B1（测试不密闭）标记为 `resolved`，并附复查证据：本 worktree 内
    `backup-*` 目录数为 **0**，而 287 个测试全绿 —— 原先的隐藏前置依赖确已消除。
- 2026-10-07: 自动回滚 Sprint VERIFY —— drill5 修复、双引擎 710 测试、PATH 证据留痕
  - **真实缺陷（drill5 实测命中）**：`Remove-ItemRobust` 的 tier-3/tier-4 原生命令输出经
    `2>&1` 被包成 ErrorRecord 写进**成功流**，调用方 `$deleted` 拿到
    `@(ErrorRecord, $false)` 非空数组（真值恒 `$true`）→ 四层全失败被记「删除成功」→
    `failedCount=0` → **自动回滚不触发**（REQ-002 / AC-016）。修复（`def77d9`）：
    tier-3 显式 `$null =` 吞输出、tier-4 走 `Write-Warning`；新增 `WrcRirLock`
    P/Invoke share=0 独占锁测试（断言成功流**恰为**单个 `$false`）+ 进程内自动回滚
    链路集成测试（期望 rc=10）。见陷阱 9。
  - **PATH 冲突判定 fail-open 关闭（`0d7b658`）**：`rollback-verdicts.ps1` 曾把
    「两侧证据都缺席」（`'' -cne ''` 为假）当「相符」放行恢复。改用
    `$PSBoundParameters.ContainsKey` 判证据存在性，四态 `PathCompare`（mismatch /
    current_null / expected_null / equal）与两侧值留痕进 `rollback-result.json`。
    见陷阱 11。
  - **pwsh 7 兼容修复（`b613d71`）**：journal 自校验把 pwsh 7 反序列化出的合法
    `[datetime]` 判为「不可解析」，现直接接受。见陷阱 10。
  - **管理员真实演练（drill5，2026-10-07 21:41，用户已授权）**：23 项检查 18 项通过。
    share=0 锁目录的不变量全部通过（tier-4 改名未伪装成功、journal 如实记
    `mutation_failed`、清理摘要 6/5/1）。5 项失败全部级联自同一起点：PATH 条目
    `pe_951` 的恢复被自我校验拒绝（`conflict(external_change_sign_iii)`，fail-closed）
    → rc=11（期望 10）、`completed_at` 未写、PATH 段未回填（drill 自身 finally 已把
    PATH 还原为字节一致）。该冲突未能在后续受控复现中重现，且当时的报告未记录比较
    两侧的值——本次落地的证据字段（`0d7b658`）即为让下次发生可诊断。
  - 测试数 287 → **710**（PS 5.1 与 pwsh 7 双引擎均 710/710 通过）；`references/scripts`
    行覆盖率 80.0% → **83.94%**（2765/3294，16 脚本）。
  - 陷阱清单新增第 9/10/11 条；退出码规范补 10–15 自动回滚矩阵。
  - `wrc-drill/`（drill3/4/5 + rdlab + teardown）**按用户决定保持 untracked**（本机管理员演练
    脚手架，会创建真实服务/PATH/注册表对象，不进仓）。
    **2026-10-16 更正**：该目录实际处于 **tracked** 状态（6 个文件已随早期推送入仓，
    `git ls-files wrc-drill` 可复核）——「保持 untracked」的决定并未真正落地。门禁侧已通过
    `.xp-gate-powershell-prune-dirs` 把它隔离出文件发现/覆盖率分母；是否按原决定移出
    git 跟踪留待维护者决策（drill 脚本会创建真实系统对象，克隆者误跑有风险）。
    **2026-10-20 落地**：原决定执行——`git rm -r --cached` 移出跟踪（本地文件保留）+
    `.gitignore` 钉住 `wrc-drill/`；公开仓库不再分发会动真实系统对象的脚本，clone 者只
    得到 README 之外的空目录。门禁三处分母的隔离（prune-dirs）与本决定无关，继续生效。
- 2026-10-08: 自动回滚 Sprint 收尾 —— drill5 根因、CORS 收紧、REQ-031 盲区、setup.ps1 摘豁免
  - **drill5 根因定位（`12bf152`，Critical）**：`$null -ne $MachinePathOverride` 在三处
    （两处转发 + 一处读取）把「未注入」读成「注入了空 PATH」，跳过真实注册表读取 →
    每个 `path_entry` 恒被 fail-closed 拒为 `conflict(external_change_sign_iii)` →
    2026-10-07 那 5 项级联失败（rc=11、PATH 未回填、`completed_at` 为空）由此解释并消除。
    这是陷阱 11 的**注入接缝**变体：Mock 用例本来就传 override，所以单测永远看不到。
    存在性改用 `$PSBoundParameters.ContainsKey`，并钉住「不传 ⇒ 读到活系统值」的端到端断言。
  - **UI CORS 收紧（`d2cd8c6`，Security）**：loopback 服务上的 `app.use(cors())` 发出
    `Access-Control-Allow-Origin: *`，而它的 POST 路由会拉起**管理员权限的破坏性 PowerShell** ——
    用户打开的任意页面都能触发清理并读回结果。改为 `ui/server/security.cjs` 的同源守卫
    （放行同源 / vite dev 源 / 无 Origin 头的本地客户端，拒绝非 loopback `Host` 头以挡 DNS
    rebinding）、`/api/confirm` 按报告形状校验 id、`/api/status` 不再泄露项目根。
  - **REQ-031 的 15 号盲区（`fec90f6` + 规范修订 `5dd0a17`）**：只有 11 会跳过写 `completed_at`，
    于是 rc=15 照常标记「本轮已正常结束」，而 T3 只吃未完成日志 —— 下一轮的恢复机会被永久抹掉。
    新增纯函数 `Test-CompletionMarkerSuppressed`，按「系统此刻是否仍有本轮没能修复的改动」判定，
    覆盖 (a) `restore_failed>0` / (b) 未记账变更>0 / (c) `failedCount>0` 且回滚整轮未跑 三种形状；
    其中 (c) 是必须的，因为 `$persistenceError` 会让 T2 整轮跳过，导致**每个 15 的
    `restore_failed` 恒为 0**（只写 (a) 是不可达代码）。见「退出码规范」的完成标记表。
  - **setup.ps1 摘掉覆盖率豁免（`721cada`）**：`.xp-gate-powershell-coverage-ignore` 里唯一一项
    把「违反 ADR-001」写成了「结构性不可插桩」。现已重构为 `Main` + `[ref]$ExitCode` +
    `-PSVersionOverride` 接缝，该忽略列表为**空**；`hermeticity.Tests.ps1` 的 ADR-001 契约
    改成对**所有含 `function Main` 的脚本**（现 11 个）穷举 AST 断言，防止同类债再长回来。
  - **管理员真实演练复跑（drill5，2026-10-08 09:43，用户已授权 UAC）**：23 项检查 **23 项通过**，
    `pe_951` 的 `path_entry=restored`、rc=10、计数 3/0/3/0、journal 写出 `completed_at`、
    机器 PATH 回合 `-ceq` 字节一致；share=0 锁目录不变量继续通过。
  - 陷阱清单新增第 12/13 条（Pester 宿主偏好会凭空造失败；`It` 标题尖括号 + `BeforeDiscovery`
    的 `-ForEach` 数据不可用）；测试数 710 → **727**（双引擎各 727/727）；行覆盖率
    83.94%（2765/3294，16 脚本）→ **84.08%（2804/3335，17 文件）**（历史值；现口径
    18 sourcefile / 84.17%，见「coverage.xml 的口径与污染」）；PSScriptAnalyzer 维持 0。
  - 未复现抖动如实记录：pwsh 7 一次全量运行报 720/1，随后两次同样运行 721/0、定向 5 轮各 243/0，
    本次收尾双引擎复跑 727/727；未能定位到具体用例，判为环境级争用。
- 2026-10-16: 门禁加固与平台层原语收敛（接管审计第二批）
  - **xp-gate 门禁体检**：官方 13 道门禁逐一对底层工具实测（官方 9 PASS/3 SKIP 多为
    「单文件提交」下的空转），产出 `docs/audits/2026-10-16-gate-status.md`；向
    `boyingliu01/xp-gate` 提交 4 个缺陷 issue（lib source fail-open #535、Gate 10
    工具缺席静默 PASS #536、Gate 3/4/6 对 PowerShell 零覆盖 #537、文件发现不 prune
    演练目录 #538）；semgrep 1.171.0 就位，Gate 10 下次代码提交起为真扫描。
  - **新增 `references/scripts/native-invoke.ps1`**：原生 exe 调用唯一通道
    （ConvertTo-NativeArgument 引号封装 + Invoke-NativeExe 真实超时）。
    `Invoke-ScExe` / `Invoke-RegExe` 收敛为其包装（返回形状不变）；
    `Remove-ItemRobust` Tier2 的 takeown/icacls 改道（含空格路径此前从未真正生效）。
  - **PS 5.1 句柄陷阱（陷阱 14b）**：`-PassThru` 无 `-Wait` 时必须先触碰
    `$proc.Handle`，否则进程退出后 `ExitCode` 恒为 `$null`——双引擎实测差异，
    pwsh 7 无此问题。
  - **`Remove-ItemRobust` 全部路径操作改 `-LiteralPath`**（通配符注入面关闭）；
    `create-restore-point.ps1` 裸 `reg export` 改走 Invoke-NativeExe + 失败落
    `valid=$false` 记录 + 缺库 fail-closed 回传 3。
  - **新增 `tests/unit/platform-hygiene.Tests.ps1`**（22 用例，Round 2 起守卫升级为
    `Remove-*` 名字模式穷举）：引号单测 + 真实进程
    行为（sc 1060/1639 判别、服务名单引号形态、HKCU 含空格/含内嵌引号键导出、
    含空格+尾反斜杠参数、真实超时击杀、run-all 逃生舱形态）+ AST 守卫
    （Start-Process 白名单、数组字面量禁裸变量、`Remove-*` 函数体一律
    -LiteralPath 且禁 Split-Path、禁裸 reg/sc）+ rollback 库清单一致性。
    测试数 727 → **751**（双引擎各 751/751）。
  - **UI**：`ui/server/index.cjs` 可测化（`require.main === module` 守卫 + 导出 app），
    新增 `ui/server/index.test.mjs` 12 用例；测试抓到真实缺陷——带 dist 部署时未知
    `/api` 路由掉进 SPA catch-all 且不回应（浏览器挂起），已补 `/api/*` 404 分支。
    删除孤儿类型 `CategoryInfo` 与 AppPhase 死值 `'selecting'`；vitest 59 → **71**；
    `.architecture-baseline.json` + `architecture.yaml` 入库激活 Gate 6 diff 模式
    （28 smells 存量如实记录）。
  - **delphi code-walkthrough Round 1（三专家三模型）**：其 Critical（Start-Process
    再包引号）经双引擎端到端实证驳回并以真实进程测试钉死；证实项已修——超时
    击杀失败写进 error 字段 + Dispose、clean-residuals 显式加载 native-invoke、
    /api 畸形 JSON 结构化 400、architecture.yaml 入库。
  - **自查抓到自己的回归（陷阱 15）**：上一批把 tier-4 的路径拆解写成
    `Split-Path -LiteralPath X -Parent/-Leaf`（参数集在两个引擎上都无法解析），
    tier-4 整体变成死分支且被 locked-fixture 的预期失败路径吞掉；已改
    `[System.IO.Path]` 字面量方法，新增 tier-4 必须到达 Rename-Item 的行为测试。
    陷阱清单新增第 14/15 条；四层降级示例同步至现状；ui/package.json 补
    `test`/`lint` 脚本。
  - **delphi code-walkthrough Round 2（三专家三模型）**：1 APPROVED / 2
    PASS_WITH_CAVEATS，无 Critical/Major 阻塞，证实项（全部 Minor 级）当场落实：
    `ConvertTo-NativeArgument` 尾反斜杠一律进引号分支（因果口径经 Round 3 复核更正，
    见下）；tier-4 拆解收敛为纯函数 `Get-RenameTarget`（尾反斜杠归一化 + 盘根/
    空白如实拒绝）；备份文件名净化补 `/`；rollback 缺库记录幂等去重；run-all
    逃生舱形态补真实进程回归；AST 守卫升级为 `Remove-*` 名字模式穷举；移除与
    AST 守卫强弱不一致的弱文本守卫；vitest 根配置显式 `reportsDirectory`；
    PROJECT_ROOT 声明为不可环境覆盖的模块契约。
  - **delphi code-walkthrough Round 3（三专家三模型）**：严码关 APPROVED（0.95，
    零发现）；构远图/稳落地 PASS_WITH_CAVEATS，证实项（全部 Minor）当场落实——
    (a) **陷阱 7 纪律的自我适用**：`ConvertTo-NativeArgument` 的注释与 CHANGELOG
    曾把「裸尾反斜杠让 takeown 报 Invalid argument/option」写成 PS 5.1 引擎特有
    缺陷，实测复核为**两引擎共有**失败形态（两引擎裸形态均 exit=1，经
    Invoke-NativeExe 引号+翻倍后两引擎均成功），已按「写下必然/100% 必须附可复现
    命令」的纪律改为诚实口径；**R5 再更正（2026-10-16）**：R3 的「两引擎共有」
    仍只对 **Start-Process 纯拼接**形态成立——`&` 原生绑定形态实为**引擎分歧**
    （PS 5.1 失败 / pwsh 7 的原生实参绑定正确转义——R6 实测三种
    PSNativeCommandArgumentPassing 模式均成功，非 7.2 特性门控），三形态真值已由可执行钉子
    （platform-hygiene「三形态真值钉子」用例）双引擎持续钉住；(b) `create-restore-point.ps1` 的 '/' 净化被指出为
    **不可达预留**（当前 regPaths 三条键名均无 '/'），注释改为如实标注「预留，
    当前不可达，落地 HKCR CLSID 形态时须同步补测」；(c) `Get-RenameTarget` 对无
    目录成分的相对路径先 `GetFullPath` 解析（否则 Join-Path 抛错被 catch 伪装成
    环境失败，陷阱 15 同型）并补测试钉住；(4) coverage.xml 口径与污染实测记录进
    「已知限制」（命令口径 vs 行口径；评审会话用默认 CodeCoverage 跑 Pester 会把
    `.workbuddy/` 等混进 sourcefile，引用前先数 18）。留待后续：rollback-backup
    不写宿主作用域状态、AST 守卫按破坏性语义而非名字模式判定、/api/confirm 落点
    断言、reg 备份文件名两套命名方案的碰撞面。测试数 751 → **752**（双引擎各
    752/752，新增相对路径 Get-RenameTarget 用例）；PSScriptAnalyzer 维持 0。
- 2026-10-16: **门禁真生效加固（接管审计第三批）**——把「SKIP/空转」的 XP 门禁变成
  真跑且 fail-closed（用户点名的重要事项）
  - **背景**：第二批体检结论是 13 道门禁里 PowerShell 侧大量空转——Gate 5 靠旧
    coverage.xml、Gate 10 对 .ps1 零扫描、Gate 1 没有 powershell 分支、文件发现不
    prune 演练目录。本批全部落地修复（钩子层文件在 `~/.config/xp-gate`，仓库外，
    已留 `.bak-gate-harden-20261016` 备份）：
    1. `adapters/powershell.sh`：`_detect_pwsh` 显式回退探测（WindowsApps pwsh →
       System32 powershell.exe，PATH 剥离可复现）；`_find_powershell_files` prune 列表
       补 xp-gate 脚手架 dot 目录 + `.xp-gate-powershell-prune-dirs` 项目注入（实测
       发现 20 测试 + 18 产品源，wrc-drill 出局）；Gate 1 静态分析新增**范围文件
       模式**（`.xp-gate-powershell-analysis-paths`，本仓 = references/scripts +
       setup.ps1）与逐路径 PSSA 循环（`$ErrorActionPreference='Stop'` 防静默；
       PSSA `-Path` 不接受数组的实测坑已绕开）；引擎/PSSA 模块缺席 → WARN 计入
       分母，不再静默 PASS；Pester 超时 300 → 900 秒（752+ 用例 + 覆盖率运行）。
    2. `hooks/pre-commit`：Gate 1 入口正则补 `ps1|psm1` + 新增 fail-closed
       `powershell)` 分支（0 告警 + reason → WARN；非零 → BLOCK exit 1）；
       Gate 10 包装正则补 `ps1|psm1`。
    3. `adapters/gate-10.sh`：SEMGREP_FILES 补 `ps1|psm1`；semgrep 回退探测
       `%APPDATA%\Python\*\Scripts\semgrep.exe`。
  - **仓库侧配套（本提交）**：`.xp-gate-powershell-prune-dirs`（wrc-drill，#538）与
    `.xp-gate-powershell-analysis-paths`（产品范围 + 硬边界：新增产品脚本必须同提交
    加路径）入库；`.xp-gate-powershell-coverage-ignore` 清空（prune 已覆盖其历史条目，
    保留硬边界规则）；AGENTS.md「已知限制」两条门禁降级记录改写为加固后现实。
  - **单元验证（Git bash 直测钩子函数）**：探测在剥离 PATH 下找到 pwsh；发现剪枝
    精确；范围 PSSA 干净 → exit 0；告警探针文件 → exit 1 + PSSA 发现表（真 BLOCK）；
    3 轮重复无抖动；`bash -n` 全部通过。
  - **R5 可执行钉子更正了 R3 的因果口径**：为落实构远图残余项写的
    「三形态真值钉子」用例实测发现——R3 的「裸透传 takeown **两引擎**共有失败」
    只对 **Start-Process 纯拼接**形态成立；`&` 原生绑定形态是**引擎分歧**
    （PS 5.1 失败 / pwsh 7 的原生实参绑定正确转义，R6 实测三种 passing 模式均成功）。已按三形态真值改写
    native-invoke.ps1 注释、测试注释与 CHANGELOG/AGENTS.md 记录。教训入册：
    「两引擎共有」与「引擎分歧」是两个不同的命题，换验证形态即换命题。
  - **测试侧 PSSA 技术债如实入册**：以仓库设置测 tests/ 全量为 328 条告警
    （PSUseDeclaredVarsMoreThanAssignments 164 + PSAvoidGlobalVars 131 +
    PSAvoidOverwritingBuiltInCmdlets 18 + PSUseShouldProcessForStateChangingFunctions 11
    + PSUseApprovedVerbs 3 + PSUseSingularNouns 1），属 Pester 执行模型的误报面；
    门禁按「产品范围」收敛而非放宽规则，测试文件不进 PSSA 判据。
  - 测试数 752 → **753**（三形态真值钉子，双引擎各 753/753）；PSScriptAnalyzer
    产品范围维持 0。
- 2026-10-17: 门禁真生效收口 + R6 走查证实项 + **钩子回退事故**（接管审计第三批续）
  - **试金石提交——结论先错后正（陷阱 7 纪律再次自适用）**：第三批加固以真实
    `git commit`（`a78ac47`）验收时，仅凭报告末尾的 PASS 汇总与 Gate 5 新鲜
    coverage.xml（18 sourcefile，2844/3379 = 84.17%，这一项为真）就写下
    「Gate 1 PSSA 真扫 / Gate 10 首次真扫描」。**R6 Round-2 严码关+稳落地用
    分歧证据（pre-commit 行号 + 文件 mtime）逼出复查，实测推翻**：Gate 1 段
    的实际输出是 `✅ PASSED - No code files changed, skipping lint.`（skip
    谓词不含 .ps1，skip-as-pass 也记 PASS）；Gate 10 的 `files scanned: 2`
    扫的是 2 个无扩展名配置文件而非 .ps1。教训：**引用门禁证据必须读该门禁
    段的输出行，不能只读报告汇总**——汇总把 SKIP/SKIP-as-PASS 与真 PASS 记成
    同一个 PASS。
  - **钩子回退事故（R6 Round-2 发现，本会话实测确认，共三种形态）**：一个外部
    xp-gate 维护进程把 batch-3 硬化的三个用户级文件**全部还原为 legacy 且保留旧
    mtime**（`adapters/powershell.sh` 272 行 2026-10-13、`gate-10.sh`
    2026-10-13、`pre-commit` 谓词无 ps1），`.bak-gate-harden-20261016` 备份
    除 pre-commit 一份（后被证实与 live 同为 legacy）外全部消失。本会话早前
    的 missing-path 探针（12:33 仍能发 `XP_G1_REASON`）证明回退发生在探针与
    专家检查之间。**同一窗口（12:53:28）`.git/config` 被写入空的 repo 级
    `core.hooksPath`**（空值覆盖全局 → 钩子目录回落到无钩子的 `.git/hooks`，
    提交零门禁零输出）——第三种形态，靠「提交必须看到门禁段输出」的核对才
    抓到。这是继 .delphi-config.json 两次改写事故后**第三次实证**的「用户级
    钩子基础设施会被外部进程改写」。
  - **重建 + 防回退（本轮收口提交）**：(1) 三个钩子文件按原设计重打全部补丁
    （`_detect_pwsh` 回退、发现 prune + prune-dirs 注入、范围 PSSA + Stop 纪律、
    fail-closed XP_G1_REASON 族、pre-commit Gate 1 谓词 + `powershell)` 分支 +
    Gate 10 谓词、gate-10 semgrep APPDATA 回退 + ps1|psm1），五探针复测通过
    （发现 20+18 / 干净 PASS / 缺失条目 WARN / scope 内脏文件 BLOCK / 引擎探测）；
    (2) **vendored 进仓库**：`githooks/adapters/powershell.sh` +
    `githooks/adapters/gate-10.sh`（权威副本）+ `githooks/README.md`（安装/同步
    指引），pre-commit 以标记断言覆盖；(3) 一致性测试新增第 4 用例「钩子安装与
    vendored 副本一致」——live 适配器与 vendored 哈希比对 + pre-commit 标记
    断言（本机钩子缺席时 Inconclusive，CI/新克隆不受影响）；(4) 本组用例补
    自有 BeforeAll（过滤单跑不再依赖首个 Describe）、prune 前缀从
    prune-dirs 文件推导（消掉第四份硬编码清单）。
  - **R6 code-walkthrough Round 1（三专家三模型）**：1 APPROVED / 2 PASS_WITH_CAVEATS，
    零 Critical；三位专家各自实测复现了同类根因——**analysis-paths 的「硬边界」此前
    只有散文承诺**：列表条目缺失时钩子静默跳过（fail-open），根级产品脚本带真告警也
    PASS（两位专家以临时探针脚本实证）；coverage 分母与 Gate 1 分析范围是两条
    独立维护的边界，无交叉校验；发现是 `*.ps1` 端到端，`.psm1` 模块不在三处分母内；
    ci.yml 硬编码产品清单并仍引用已清空的 coverage-ignore；R5 的因果归属
    「7.2+ 标准实参传递」被实测否定（三种 PSNativeCommandArgumentPassing 模式均
    成功，非 7.2 特性门控）。drill3 的 `Test-AdminPrivilege` 桩 `return $true`
    让演练在非管理员会话静默驱动真实清理。
  - **R6 Round 3/4（重建复核 + 修复闭环）**：Round 3 三专家独立复测证实重建
    成立（哈希一致/发现 20+18/三态映射正确/WARN 真降 verdict），但以探针抓出
    两处 Critical 并全部落地：(1) **PSSA settings 的 Severity 过滤把 ParseError
    整条丢弃**——语法损坏脚本静默过 Gate 1（实测裸跑 2 条/Error-Warning settings
    0 条），修法 `Severity += 'ParseError'`（IncludeRules 变体实测无效）；
    (2) **防回退闭环缺口**——pre-commit 无恢复源 + live 文件被删除时哈希断言
    静默跳过；修法 pre-commit 完整 vendored + 「目录存在 ⇒ 文件必须存在」 +
    vendored 存在性断言前移。Major 全处理：CRLF 行尾静默降级（适配器剥 CR +
    `.gitattributes` eol=lf 双层）、prune `-name` 任意深度语义对齐注释、
    XP_G1_REASON 多条聚合 + `grep -v || true`、标记断言升级为分支专属符号
    （PS_G1_REASON / GATE_1_DETAIL="powershell:）、`git -C` 钉定、两层防御
    口径澄清。详见审计 7.7。
  - **证实项当场落实**：(1) 钩子适配器缺失条目改为发 `XP_G1_REASON:
    analysis-path-missing:<路径>`（fail-closed WARN，同 analysis-paths-empty 语义）+
    超时文案 300 字面量改用真值；(2) 新增「门禁边界一致性」测试组（tracked 产品源
    必须全被 analysis-paths 覆盖 + scope 条目必须存在 + coverage-ignore 必须空 +
    prune-dirs 必须含 wrc-drill + 钩子与 vendored 一致）——散文边界变成门禁守卫；
    (3) ci.yml 产品清单改读 `.xp-gate-powershell-analysis-paths`（scope 空即 fail），
    移除陈旧 coverage-ignore 引用与 727 历史计数；(4) README 新增
    「Pre-commit quality gates」节（钩子链在仓库外 + 新克隆静默降级的事实 +
    三份 tracked 边界文件）；(5) wrc-drill/README 同步 prune 机制口径；
    (6) drill3 权限桩改真实管理员检测（非管理员中止）；(7) 三形态因果归属全文
    更正为「原生实参绑定正确转义（三种 passing 模式实测）」；(8) analysis-paths
    文件头补 `.psm1` 盲区 note；AGENTS.md 补新产品脚本 checklist。
  - 测试数 753 → **757**（+3 边界一致性 + 1 钩子一致性；双引擎各 757/757）；
    产品范围 PSSA 维持 0。
- 2026-10-20: **第四次改写——xp-gate upstream 更新覆盖硬化（防回退机制首次实战触发）**
  - xp-gate 升级把三个钩子文件整体替换为新 upstream 版（pre-commit 173K→189K）：
    新版吸收 #538 prune 与其余语言修复，但 PowerShell 加固清零（PS_G1_REASON /
    powershell 分支 / ps1 谓词 / semgrep Windows 回退全缺席）——**合法更新与恶意
    回退在内容层不可区分，一致性测试按设计变红**。hooksPath 双写在此次幸存。
  - 恢复流程（审计 7.8）：以 vendored 为基 → diff 合入 upstream 真增量
    （5 条 prune 路径 + #538 注释）→ 新 pre-commit 重打三补丁、gate-10 重打两补丁
    → 重新 vendored → 探针复测（ParseError 拦截 rc=1 / 缺条目 WARN / semgrep 回退）
    → 双引擎 27/27 → 实弹提交。**恢复 ≠ `cp` 回去：必须合并 upstream 增量，否则
    下次更新把本仓独有的 PowerShell 支持再冲掉一次。**
  - **当晚第二波（审计 7.8.1）**：维护者在 `D:\projects\xp-gate` 活跃开发并多次
    部署（部署保留 mtime——live 被覆盖后 mtime 显示旧值是指纹）；适配器（含
    SC2034 disable）被吸收进 upstream（与 vendored 逐字节一致），但 pre-commit
    三补丁未吸收且 live 被部署回滚，一致性测试双引擎各红 1 次（另有本会话校验
    脚本路径替换 bug 自比自的假 match——**哈希核对以测试套件为准**）。恢复：
    重打三补丁于 195K 新基座（顺带获得 upstream 的 Gate 5「没跑不许报 PASS」
    修复）→ vendored 拷回 live → 27/27 → 实弹提交。**upstream 吸收 pre-commit
    三补丁前，每次部署都可能再回滚，信号=一致性测试红，恢复=以 vendored 为权威。**
- 2026-10-22: **xp-gate 重基线到 0.30.5 + 三处 fail-closed 漏洞修复**
  - 用最新版（0.30.5）重新体检本仓，发现 vendored 门禁落后 upstream **两个版本**，
    且 upstream 已独立吸收我们报的 #547/#548（两个 issue 均已 CLOSED），我们的 fork
    反而跑着「旧基座 + 重打补丁」的混合体。**重建**：以 0.30.5 为基（pre-commit
    196176B / powershell.sh 12165B / gate-10.sh 17407B），只重打 upstream 没有的
    三处增量——analysis-paths 作用域、prune-dirs 注入、semgrep 的 `%APPDATA%` 回退。
    upstream 的 CRLF 自检（#546）、单一覆盖率阈值解析器（#555）、`XP_G1_REASON`
    协议、`ps1|psm1` 合并正则全部照收。gate-10 的 APPDATA 计数由 1 归零后再补齐
    （upstream 侧为 0），确认重打无遗漏。
  - **三处 fail-closed 漏洞（真实缺陷，均已实证复现后修复）**：
    (1) **critical**：`analysis-path-missing` 只 echo 了 reason、没有改变返回值。父
    hook 对 reason 行做 `grep -v` 剥离后按键退出码判定，于是「一个有效路径 + 一个
    幽灵路径」实测 `rc=0` → 报 **PASSED**，而产品代码已经逃出作用域。修复：用
    `scope_missing` 计数，分析跑完后 `>0` 强制 `return 3`。**教训：没有配套返回值的
    reason 是装饰品，必须与退出码绑定。**
    (2) **major**：作用域模式下 `PSScriptAnalyzerSettings.psd1` 缺失时仍照跑片段；
    `-Settings` 指向不存在的路径是**非终止错误**，配合 `-ErrorAction
    SilentlyContinue` 结果集为空 → 未分析的树被判 PASS。修复：作用域模式前置校验
    settings 存在（`analysis-settings-missing`），片段改 `-ErrorAction Stop` +
    try/catch → exit 3 → WARN。
    (3) **major**：prune-dirs 条目未校验，`*` 能把发现清空、分隔符能指向产品目录，
    而发现同时供给测试发现/覆盖率分母/分析范围三个口径。修复：只接受裸目录名
    （拒绝 `/`、`\`、`*`、`?`、`[`、`.`、`..`），拒绝项打印通知并忽略，采纳项也
    公告。两个配置读取器同时剥离 UTF-8 BOM 与行尾 CR（PS 5.1 的 `Set-Content
    -Encoding UTF8` 默认写 BOM，会把首个条目和 `#` 注释头一起吃成路径）。
  - 验证：wrc 生产作用域 18 文件 PASS；注入一个幽灵条目 → `rc=3` + reason +
    「1 scope entry(ies) did not exist」；wrc-drill 剪枝仍生效（泄漏 0）；
    `bash -n` 全过、shellcheck CLEAN；Pester 757/757（pwsh 7）。
  - **delphi 三专家 code-walkthrough 实跑两轮**（三模型：g-deepseek-v4-pro /
    s-deepseek-v4.1-flash / doubao-seed-2.0-pro）。Round 1 **REQUEST_CHANGES**
    （1 APPROVED / 2 REQUEST_CHANGES），critical A1 与 major A3/A4 均为真问题、
    已全部按上述修复并补测试；Round 2 复核 APPROVED。**这是本项目第一次由自动化
    评审抓住自己引入的 fail-open**，说明门禁评审流程有效。
  - 提交门禁 12 道全过（含 Gate 5 测试、覆盖率），无 `--no-verify`、未加忽略项。
  - 运维备注：期间 live 钩子被外部 xp-gate 部署覆盖 4 次（198247B 等变体，均不含
    analysis-paths 增量），一致性测试每次如实报红，均以 vendored 同步恢复。


