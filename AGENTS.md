# AGENTS.md — Windows Residual Cleaner

> AI agent 工作指南。维护者在开发 / 调试 / 扩展此项目前必读。

---

## 项目上下文

这是一个 Windows 系统清理工具，通过 PowerShell 脚本扫描和清理卸载软件残留。
涉及注册表、文件系统、Windows 服务、计划任务、COM 扩展等敏感系统区域。

**运行环境**: Windows 10/11 + PowerShell 5.1 + Administrator 权限
**测试框架**: Pester 5.x — `Invoke-Pester tests/`（PS 5.1 与 pwsh 7 双引擎均通过，目标 0 失败）

> 本文**不记录**测试数/覆盖率/sourcefile 数这类每次提交都会变的快照。它们的权威来源是
> 实跑本身（`Invoke-Pester` 的 `PassedCount`、`coverage.xml` 的 LINE counter）。
> 历史变更记录里出现过的数字是**当时的实测值**，不是当前状态——想知道现在多少，去跑。
> 唯一保留的硬数字是**结构数**（哪些目录、哪些脚本），因为它们变了就意味着规则变了，
> 而那正是需要同提交更新本文的事件；这类数字由 `tests/unit/doc-consistency.Tests.ps1` 守着。
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

> **第三变体：`[Nullable[bool]]` 参数的 `.Value` 取不出来（2026-10-26 实测）**。
> 给 `Test-AdminPrivilege` 加 `-IsAdminOverride` 时写的是：

```powershell
# ❌ 错误: 两个分支都走 else，`-IsAdminOverride $true` 效果等于没传
param([System.Nullable[bool]]$IsAdminOverride)
$isAdmin = $null -ne $IsAdminOverride          # 这个判断本身是对的
if ($isAdmin) { $isAdmin = $IsAdminOverride.Value }   # ← .Value 是空串！

# ✅ 正确: 存在性看 PSBoundParameters，取值直接跟 $true 比
if ($PSBoundParameters.ContainsKey('IsAdminOverride')) {
    $isAdmin = ($IsAdminOverride -eq $true)
}
```

> 实测（pwsh 7.7 与 PS 5.1 一致）：参数类型确实是 `System.Nullable\`1[System.Boolean]`，
> `$X -eq $true` 与 `[bool]$X` 都能正确反映传进来的值，但 `$X.HasValue` 与 `$X.Value`
> **都返回空**。所以「用 Nullable 表达三态」在 PowerShell 里并不成立：
> `null`（未传）/ `$false` / `$true` 三态只能靠 `PSBoundParameters` + 值比较拼出来。
> 症状很隐蔽——不传时行为正确，传 `$false` 时也正确，**只有传 `$true` 才错**，
> 于是「默认路径绿、注入路径红」，很容易被当成用例写错。

---

### 12. 跑 Pester 的包装脚本里设 `$ErrorActionPreference = 'Stop'` 会**凭空造出失败**

本项目不少用例**故意**触发非终止错误（`Write-Error` / `-ErrorAction SilentlyContinue` 的失败分支）
再断言其行为。Pester 宿主默认把这类错误记为 Warning 继续跑；一旦外层包装脚本设了 `Stop`，
它们变成**终止错误**，用例即判失败。

```powershell
# ❌ 错误: 本地覆盖率/验证包装脚本里加这一行
$ErrorActionPreference = 'Stop'
Invoke-Pester -Configuration $cfg     # 实测凭空多出 30 个失败，覆盖率被压低一截

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

### 16. `Get-Content -Raw` 在 PS 5.1 下对**无 BOM** 文件按**系统 ANSI 代码页**解码（2026-10-26 CI 实测）

```powershell
# ❌ 错误: 这三份 .md 是无 BOM 的 UTF-8；PS 5.1 会按系统代码页解码
#          （CI 的 windows-latest 是 CP1252，中文系统是 CP936）
$text = Get-Content -LiteralPath 'SKILL.md' -Raw
# 于是 '—' (U+2014) 被读成 'â€”'，比较/生成/回写全部基于错字

# ✅ 正确: 显式 UTF-8 解码，结果与运行机器的代码页无关
$script:Utf8Read = New-Object System.Text.UTF8Encoding($false)
$text = $script:Utf8Read.GetString([System.IO.File]::ReadAllBytes($path))
# 写回也用同一个对象：WriteAllText($path, $text, $script:Utf8Read)
```

**为什么这个坑特别难抓**（2026-10-26 实测代价：两轮 CI 才定位）：

- **字节没坏**。磁盘上的文件是对的，`git` 也不报差异——坏的只是「读进来的那一刻」。
  所以 `git status` 干净、`diff` 无输出、编辑器里看也正常。
- **两侧长度都相同**。CI 打印的是「长度 原=360/新=360，CRLF 原=359/新=359」——
  只有字符不同。任何按长度/行数做的自检都放行。
- **本地会被掩盖而不是不存在**。本机是中文系统，而被读的那段文本当时恰好是纯 ASCII，
  于是 `Get-Content` 与 UTF-8 解码结果一致，`-Check` 一直绿。缺陷取决于
  「运行机器的代码页 × 文件内容是否恰好含非 ASCII」这个叉乘。
- 因此**「本地绿、CI 红」不一定是环境问题**，也可能是代码里的隐式编码假设。

**教训（比修复本身重要）**：先修可观测性，再修缺陷。这次的突破点不是想到了编码，
而是让 `-Check` 失败时打印**首个差异行的两侧原文**——下一个 CI 失败立刻把 `â€”` 摆在
眼前，根因从「猜」变成「读」。**报「不一致」而不报「哪一行、怎么不一致」，等于把
排查成本推给下一个读日志的人。**

**守卫**：`tests/unit/doc-tables.Tests.ps1` 有一条用例断言生成器里不出现
`Get-Content` / `File::ReadAllText`（仅看非注释行），且读文档与探测换行符走**同一份**
`$script:Utf8Read`。反向验证过：改回旧写法立即变红。

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

Windows 文件可能被进程占用或权限锁定，需要逐级降级。**权威来源是
`references/scripts/clean-residuals.ps1` 里的真实实现**；下面只记每层的**契约与判据**，
不复制代码——复制的副本会随实现漂移，而漂移的副本比没有更危险：

| Tier | 手段 | 关键约束 |
|------|------|----------|
| 0 | `-WhatIf` 预演 | 立即回传 `dry_run`，不做任何 IO |
| 1 | `Remove-Item -LiteralPath -Recurse -Force` | 先判 `absent`（已不存在算成功） |
| 2 | `takeown` + `icacls` 夺权后重试 | 走 `Invoke-NativeExe`（引号封装 + 真实超时，见陷阱 14） |
| 3 | `cmd /c rd /s /q`（目录）/ `del /f /q`（文件） | 输出必须 `$null =` 吞掉（见陷阱 9） |
| 4 | 改名 + 预约重启删除 | 路径拆解用 `[System.IO.Path]`（见陷阱 15）；文件另走 `MoveFileEx` |

**每层的成功判据都是「目标真的不在了」**，不是「命令没报错」：
`if ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath $Path))`。

契约：**成功流只允许携带最终布尔返回值**；所有诊断输出走 Warning 流；语义结果经
`[ref]$Outcome` 回传（`dry_run` / `absent` / `deleted` / `renamed:<新名>` / `failed`），
其中 `renamed:` **不得**被记成删除成功（REQ-002，DD-006 规定其不参与自动恢复）。
`$deleted = Remove-ItemRobust …` 拿到的必须是**裸布尔**——任何多余输出都会让它变成
真值恒为 `$true` 的数组（见陷阱 9）。

> **Tier 4 的实证边界**：share=0 独占句柄 / 内存映射文件 / 只读目录属性下，
> 「删除被挡 ⇒ 改名同样被拒」——tier-4 的成功窗口在标准语义下几乎不存在。
> 它是如实的最后尝试，**不是**可依赖的兜底；测试与文档都不应假定它成功。

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

- **xp-gate 的代码不在本仓维护**：钩子、适配器与门禁逻辑一律归 xp-gate 项目；
  本仓**只消费发布版**，不存副本、不打下游补丁。本仓**真正能负责**的那一条是：
  `core.hooksPath` 必须解析到 xp-gate 的 hooks 目录、该目录里有 `pre-commit`
  （`tests/unit/platform-hygiene.Tests.ps1`）——它守的是「门禁链被断开」
  （实测过 `.git/config` 被写入空 `core.hooksPath` → 提交零门禁零输出），
  不是「某个补丁还在不在」。
  门禁的覆盖率口径、Gate 1/3 的坑、本机工具链与适配器行为，全部见
  [`docs/gate-operations.md`](docs/gate-operations.md)。
- **根目录 `package.json` / `package-lock.json` 已入库**（`.gitignore` 用
  `!package.json` / `!package-lock.json` 反忽略）。根清单只承载 Gate 5 根跑所需的最小
  devDeps；`vitest.config.ts` 把范围限定在服务端（`ui/server/**`），与 `ui/package.json`
  的 UI 工具链**职责不重叠**。改依赖请同时提交 `package-lock.json`。
- MSI 安装软件的 `UninstallString` 为 `MsiExec.exe /X{GUID}` 格式，当前逻辑已跳过此类条目
- 系统 PATH 损坏（如 `C:\Program Fi;es\Memurai\`）会被如实报告，但不会被自动修复
- 计划任务中的 bare exe 名（如 `sc.exe`）需要 PATH 解析，当前策略是跳过而非解析
- `confirm-cleanup.ps1` 在 OpenCode 内置终端中无法交互（`Read-Host` 闪退），必须在独立 Windows Terminal 中运行
- **`confirm-cleanup.ps1` 的 TUI 命令循环仍难被单测覆盖**：它由 `Read-Host` 驱动，
  6 个纯展示函数已覆盖。**注意**：`Main` 内原有的 12 处 `exit` 已于 2026-10-01 全部改为
  `[ref]` 回传（ADR-001），所以「在 Pester 进程内调用会杀死宿主」这一障碍**已消除**；
  剩下的只是 `Read-Host` 本身需要重定向 stdin 才能驱动。
- **产品源覆盖率的剩余缺口是结构性的，不是「懒得写测试」**：未覆盖行集中在
  - `confirm-cleanup.ps1` —— `Read-Host` 交互式 TUI 循环（`Show-Page` 之后的命令分发）；
  - `clean-residuals.ps1` —— HKLM/PATH 写入分支与 tier 2-4 的**成功**路径
    （需管理员 + ACL 受限文件；失败路径已由 `WrcRirLock` share=0 独占锁测试覆盖）。
  这两块属于「管理员环境集成演练」范围，**不用 Mock 硬拉**。提高覆盖率靠把可测逻辑抽成
  纯函数并补真实测试，**未使用 `--no-verify`、未向 `.xp-gate-powershell-coverage-ignore`
  添加任何文件**（该文件**不排除任何文件**）。口径、阈值与「数字别背、现跑现读」的理由见
  [`docs/gate-operations.md`](docs/gate-operations.md#一覆盖率怎么看)。
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
- **测试密闭性**：`backup-*` 是 gitignored 的运行时目录。任何「非 DryRun + 走 ConfirmFile/Mode A-C」
  的清理测试都需要它存在，否则 `Main` 会在备份门提前中止。**测试必须自建自清该 fixture**，
  不得依赖主仓里遗留的 `backup-*`（否则新克隆 / CI 下会出现假绿或假红）。
  见 `tests/unit/hermeticity.Tests.ps1`、`tests/unit/rollback.Tests.ps1`（`BackupRoot` 可注入）
  与 `scripts.Tests.ps1` 的 `backup-svcregress` fixture。**复查判据**：从干净工作树
  （`backup-*` 目录数为 0）起跑双引擎，两个引擎都 0 失败——那才证明隐藏前置依赖已消除。
- **`tools/*.ps1` 与 `references/scripts` 一样必须能被 dot-source（2026-10-27）**：
  补 `tools/Update-DocTables.ps1` 的单测时发现做不到——顶层代码会写文档并 `exit`。
  最初用 `[scriptblock]::Create` 重建可解析片段，结果 23 个用例全绿而覆盖率**仍是
  0/138**：**动态 scriptblock 里的代码不被 Pester 插桩**。该脚本已改为 `Main` +
  `[ref]$ExitCode` + 执行守卫（与 ADR-001 同一套结构），dot-source 后覆盖率正常计入。
  判断口径：**「能被 dot-source」与「能被测试覆盖」在本项目是同一件事**。
  hermeticity 契约枚举 `references/scripts/*.ps1` + `tools/*.ps1` + `setup.ps1` 三处
  （见该文件 BeforeAll 的 `$script:HerdCandidates`）；新增脚本无论落在哪个目录，都会被穷举到。

---

## 脚本架构规范

### 函数/执行分离模式

`references/scripts/` 与 `tools/` 下所有含 `Main` 的脚本 + 根目录 `setup.ps1` 统一使用
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

<!-- BEGIN GENERATED: exit-codes -->
| 退出码 | 含义 |
|--------|------|
| 14 | 上一轮日志未能安全消费（本轮未开始即中止）—— 判定点在本轮任何写入之前 |
| 15 | 本轮持久化写入失败（日志落盘 / 未修复清单 / 完成或消费标记） |
| 13 | 部分失败且 -NoAutoRollback |
| 12 | 部分失败但回滚日志缺失/不可读 |
| 11 | 部分失败且回滚未完全成功（存在 restore_failed） |
| 10 | 部分失败且回滚完全成功 |
<!-- END GENERATED: exit-codes -->

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

本文只记**改变了做法或判断口径**的事，逐条的实测细节、缺陷复现与验证过程在
[`CHANGELOG.md`](CHANGELOG.md) 与 [`docs/audits/`](docs/audits/)。写在这里的理由只有一条：
它改变了以后该怎么判断，而不是「那天发生了什么」。

- 2026-09-30: 幽灵服务清理的 `$LASTEXITCODE` 幂等判定缺陷 → 陷阱 7。
  **纪律**：写下「必然/100%」必须附可复现命令；分不清「无条件必然」与「环境相关」时，
  先按后者写。
- 2026-10-01: ADR-001 —— `Main` 内不得 `exit`，退出码走 `[ref]` 回传。
  起因是 `Main` 里的 `exit 1` 会杀死 Pester 宿主，导致整份套件静默塌掉而 CI 显示绿色。
  **判断口径**：测试「全绿」但 `Passed/Failed/Total` 全是空的时候，先怀疑宿主被杀，
  而不是庆祝。
- 2026-10-02: 覆盖率 70.4% → 77% → 80.0%，方式全是补真实测试。
  **口径**：`--no-verify` 与「往忽略列表加文件」是两条被明确否决的捷径——门禁要么名副其实，
  要么它就只是个仪式。
- 2026-10-08: `setup.ps1` 摘掉覆盖率豁免。那条豁免把**代码缺陷**写成了**结构性限制**（违反
  ADR-001），而结构性理由是不该被审计的。
  **判断口径**：某脚本看起来「不可插桩」时，先查它是否违反了 ADR-001，而不是加一行豁免。
- 2026-10-16: 门禁加固三批 + 平台层原语收敛（陷阱 14/15，`native-invoke.ps1`）。
  **最有价值的一条**：引用门禁证据必须读**该门禁段自己的输出行**。报告汇总把
  SKIP / SKIP-as-PASS 和真 PASS 记成同一个 PASS——只看汇总会得出与事实相反的结论
  （那次就先写下了「Gate 1 真扫」，复查后被推翻）。
- 2026-10-17: 钩子回退事故 —— 外部进程把加固过的用户级钩子文件还原成 legacy，且保留旧 mtime。
  **教训**：`.git/config` 里的空 `core.hooksPath` 会让钩子目录回落到 `.git/hooks`，
  提交零门禁零输出。所以「提交必须看得见门禁段输出」本身是一条安全检查。
- 2026-10-20 起: 放弃在仓库里 vendored 一份钩子副本。前提（本仓维护 xp-gate 的下游加固）
  被上游每次发版证明不成立，每次升级都让套件变红且与仓库质量无关。
  **判断口径**：一条断言如果红的原因与仓库质量无关，它就不该存在——那会让本地验证失去意义。
- 2026-10-26: Gate 3 基线四前提（键名 / 测量器 / 路径拼写 / 全集），见
  [`docs/gate-operations.md`](docs/gate-operations.md#22-gate-3-基线四前提)。
  **判断口径**：门禁说「new function」时按 `gate-3.sh` 原逻辑**逐字照抄**复算，
  不要「顺手修正」它的正则——改成正则看起来对了，真实门禁照旧拦人。
- 2026-10-27: 删掉会腐烂的快照，保留不会腐烂的判断口径。正文不再写测试数、覆盖率百分比、
  sourcefile 数与脚本数；权威来源是实跑本身。
  **判据**：**「这个数字三个月后会变成错的吗」**——会变就改写成描述，而不是加进白名单。
  这条由 `tests/unit/doc-consistency.Tests.ps1` 守着，也包括「本文声称的契约范围必须与
  `hermeticity.Tests.ps1` 实际枚举的目录一致」，让文档跟着代码走。
