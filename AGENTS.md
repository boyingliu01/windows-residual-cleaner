# AGENTS.md — Windows Residual Cleaner

> AI agent 工作指南。维护者在开发 / 调试 / 扩展此项目前必读。

---

## 项目上下文

这是一个 Windows 系统清理工具，通过 PowerShell 脚本扫描和清理卸载软件残留。
涉及注册表、文件系统、Windows 服务、计划任务、COM 扩展等敏感系统区域。

**运行环境**: Windows 10/11 + PowerShell 5.1 + Administrator 权限
**测试框架**: Pester 5.x — `Invoke-Pester tests/`（当前 710 个测试，PS 5.1 与 pwsh 7 双引擎均通过，目标 0 失败）
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
    if (-not (Test-Path $Path)) { & $setOutcome 'absent'; return $true }

    # Tier 1: 标准 PowerShell 删除
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        & $setOutcome 'deleted'; return $true
    } catch { Write-Warning "  → Standard delete failed: $($_.Exception.Message)" }

    # Tier 2: 夺取所有权 + 修改 ACL（takeown/icacls 走 Start-Process 拿真实退出码）
    try {
        $isDir = (Get-Item $Path).PSIsContainer
        $takeownArgs = if ($isDir) { '/r', '/d', 'Y', '/f', $Path } else { '/f', $Path }
        Start-Process takeown.exe -ArgumentList $takeownArgs -Wait -PassThru -WindowStyle Hidden
        $icaclsArgs = if ($isDir) { $Path, '/grant', 'Administrators:F', '/T', '/C' }
                      else { $Path, '/grant', 'Administrators:F', '/C' }
        Start-Process icacls.exe -ArgumentList $icaclsArgs -Wait -PassThru -WindowStyle Hidden
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        & $setOutcome 'deleted'; return $true
    } catch { Write-Warning "  → Takeown+ACL delete failed: $($_.Exception.Message)" }

    # Tier 3: CMD 强制删除 —— 原生命令输出必须显式 $null = 吞掉（见陷阱 9）
    try {
        $null = cmd /c "rd /s /q `"$Path`"" 2>&1
        if ($LASTEXITCODE -eq 0 -and -not (Test-Path $Path)) { & $setOutcome 'deleted'; return $true }
    } catch { Write-Warning "  → cmd delete failed: $($_.Exception.Message)" }

    # Tier 4: 重命名 + 延迟删除（下次启动时）—— 走 Warning，不得污染成功流
    try {
        $renamed = Join-Path (Split-Path $Path -Parent) "~$(Split-Path $Path -Leaf).deleted"
        Rename-Item -Path $Path -NewName (Split-Path $renamed -Leaf) -Force -ErrorAction Stop
        Write-Warning "  → Renamed (deferred delete - may be in use)"
        # REQ-002: 改名不是删除（内容仍在磁盘上），必须回传 renamed:<新名>
        & $setOutcome ('renamed:' + (Split-Path $renamed -Leaf))
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

- MSI 安装软件的 `UninstallString` 为 `MsiExec.exe /X{GUID}` 格式，当前逻辑已跳过此类条目
- 系统 PATH 损坏（如 `C:\Program Fi;es\Memurai\`）会被如实报告，但不会被自动修复
- 计划任务中的 bare exe 名（如 `sc.exe`）需要 PATH 解析，当前策略是跳过而非解析
- `confirm-cleanup.ps1` 在 OpenCode 内置终端中无法交互（`Read-Host` 闪退），必须在独立 Windows Terminal 中运行
- **`confirm-cleanup.ps1` 的 TUI 命令循环仍难被单测覆盖**：它由 `Read-Host` 驱动，
  6 个纯展示函数已覆盖。**注意**：`Main` 内原有的 12 处 `exit` 已于 2026-10-01 全部改为
  `[ref]` 回传（ADR-001），所以「在 Pester 进程内调用会杀死宿主」这一障碍**已消除**；
  剩下的只是 `Read-Host` 本身需要重定向 stdin 才能驱动。
- ~~任何 `Main` 内含 `exit` 的脚本都不能在 Pester 进程内直接调用~~
  → **已于 2026-10-01 修复（ADR-001）**：全部 8 个含 `Main` 的脚本都不再于 `Main` 内 `exit`，
  改为 `[ref]$ExitCode` 回传。因此「dot-source + 进程内调用 `Main`」对**所有**脚本都可用，
  覆盖率插桩不再有「执行一行都不计入」的盲区。
- `setup.ps1` 仍是例外：它没有 `Main`/`[ref]` 结构，末尾直接 `exit`，因此**结构性不可插桩**，
  已在 `.xp-gate-powershell-coverage-ignore` 中排除；它仍有子进程端到端测试覆盖。
- `references/scripts` 行覆盖率 **83.94%**（2765/3294，16 个脚本，2026-10-07 JaCoCo 实测），
  已超过 pre-commit 门禁的 80% 阈值（ADR-001 前为 70.4%；随后补真实测试到 80.0%；
  自动回滚 Sprint 落地后为 83.94%）。剩余缺口已定位且是**结构性**的，不是「懒得写测试」：
  - `confirm-cleanup.ps1` —— 未覆盖行中绝大多数是 `Read-Host` 交互式 TUI 循环
    （`Show-Page` 之后的命令分发）；只有少量属于可单测范围，已补测。
  - `clean-residuals.ps1` —— 未覆盖行集中在 HKLM/PATH 写入分支与 tier 2-4 的**成功**路径
    （需管理员 + ACL 受限文件；失败路径已由 `WrcRirLock` share=0 独占锁测试覆盖）。
  这两块属于 AGENTS.md 明确划给「管理员环境集成演练」的范围，**不用 Mock 硬拉**。
  达到 80%+ 靠的是把可测逻辑抽成纯函数并补真实测试，**未使用 `--no-verify`、
  未向 `.xp-gate-powershell-coverage-ignore` 添加任何文件**（该文件至今只排除
  `setup.ps1` 一个结构性不可插桩的脚本）。
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
- **本机工具链路径与门禁降级链（2026-10-07 实测）**：`pwsh` 7 位于
  `C:\Users\think\AppData\Local\Microsoft\WindowsApps\pwsh.exe`，`node.exe` 位于
  `C:\Program Files\nodejs\node.exe`——**git-bash 的 PATH 里都没有裸命令名**，`jq` 未安装。
  钩子继承 git 的环境，工具缺席时门禁**静默降级**：Gate 5 → SKIP（跳过测试与覆盖率生成），
  Gate 11 → SKIP（打印 "no JSON parser available"，**放行提交**）。
  需要在钩子里拿到真实 Gate 11 时：`PATH="/c/Program Files/nodejs:$PATH" git commit …`。
  **不要**顺手把 pwsh 加进钩子 PATH——当前文件发现不排除 `.worktrees`（见下下条）。
- **Gate 5 的陈旧 `coverage.xml` 陷阱（2026-10-07 实测）**：hook 适配器在找不到 pwsh 时
  跳过测试与覆盖率**生成**，但 Stage-2 仍会解析仓库根目录**既有的** `coverage.xml`
  （只要 node 在 PATH 上）。于是旧产物会拦新提交（实测：2026-10-01 的 68% 产物拦下了
  2026-10-07 的提交）。**不跑 pwsh 覆盖率就提交时，先手动跑一次覆盖率管线刷新
  `coverage.xml`**（该文件已 gitignore，属于本机门禁工件）。
- **hook 的文件发现不排除 `.worktrees` / `wrc-drill`**：适配器的 `_find_powershell_files`
  只 prune `.git/node_modules/dist/coverage/plugins/*`，因此 `.worktrees/`（sprint 隔离
  worktree 里的整套重复脚本与测试）与 `wrc-drill/` 的演练脚本都会被当作源文件与测试收集
  ——测试重复执行、覆盖率被稀释。补丁（把 `-name .worktrees -o` 加进 prune 列表）位于
  `~/.config/xp-gate` 下、需用户手工执行；补丁落地前别把 pwsh 放进钩子 PATH。
  **补充（2026-10-07 实测）**：适配器的 Gate 1 静态分析是未按目录过滤的
  `Invoke-ScriptAnalyzer -Path . -Recurse`，整仓 Error/Warning 共 **675 条**
  （tests 330 + `.worktrees` 255 + `wrc-drill` 88 + `.sprint-state` 2；root 运行时
  会自动套用仓库根的 `PSScriptAnalyzerSettings.psd1`，故 `references/scripts` 计 0）。
  **即使 `.worktrees` 补丁落地，只要 pwsh 上了钩子 PATH，Gate 1 就会拿这数百条既有
  告警拦下每次提交**——想真正启用 pwsh，必须连同分析范围（排除 `*.Tests.ps1` 与
  prune 目录）一起收敛。
- **测试密闭性**：`backup-*` 是 gitignored 的运行时目录。任何「非 DryRun + 走 ConfirmFile/Mode A-C」
  的清理测试都需要它存在，否则 `Main` 会在备份门提前中止。**测试必须自建自清该 fixture**，
  不得依赖主仓里遗留的 `backup-*`（否则新克隆 / CI 下会出现假绿或假红）。
  见 `tests/unit/hermeticity.Tests.ps1`、`tests/unit/rollback.Tests.ps1`（`BackupRoot` 可注入）
  与 `scripts.Tests.ps1` 的 `backup-svcregress` fixture。**2026-10-07 复查**：主仓
  `backup-*` 目录数为 0，双引擎 710 全绿——隐藏前置依赖确已消除。
- **覆盖率门禁的口径**：`xp-gate` 的 80% 阈值写死在共享 hook 里，唯一受支持的调节手段是
  `.xp-gate-powershell-coverage-ignore`（**按文件**排除）。该文件的注释已明确写下
  「Do NOT add files here merely because they are hard to test」——所以**不要**为了过门禁
  而把 `clean-residuals.ps1` / `confirm-cleanup.ps1` 整文件排除：那会连同已覆盖的
  163/170 行一起丢掉。正确方向是把可测逻辑抽成纯函数（`ConvertFrom-*`、`Get-*Verdict`、
  `Get-MatchingRestorePoint` 等，本次已示范）并补测。

---

## 脚本架构规范

### 函数/执行分离模式

`references/scripts/` 下全部 10 个脚本统一使用函数/执行分离模式，确保可测试性（dot-source 只加载函数定义，不触发任何副作用）：

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
  - `wrc-drill/`（drill3/4/5 + rdlab + teardown）仍为 untracked，去向待定。
