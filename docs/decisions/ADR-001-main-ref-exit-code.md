# ADR-001: `Main` 通过 `[ref]` 回传退出码，不得 `exit`，也不得 `return <code>`

- **状态**: 已接受（v2，取代 v1 的「`Main` 返回退出码」方案）
- **日期**: 2026-10-01
- **决策者**: Sprint 2026-10-01-01
- **相关**: AGENTS.md「脚本架构规范 ↑ 退出码规范」、陷阱 #7、CHANGELOG 1.4.1.0

## 背景

`AGENTS.md` 的架构规范早已写明：

> `exit 0` 放在执行守卫处（`Main` 调用之后），**不在 `Main` 内部**，以避免 dot-source 测试时终止 Pester。

但 8 个脚本违反了这条规范，`clean-residuals.ps1` 与 `confirm-cleanup.ps1` 尤其严重
（分别 5 处 + 12 处 `exit` 在 `Main` 内）。它们在 AGENTS.md「已知限制」里只被部分点名过，
`clean-residuals.ps1` 同样中招这件事**此前无人意识到**。

### 触发条件（实测）

测试用 `dot-source + 进程内调用 Main` 获得覆盖率插桩（CHANGELOG 1.4.1.0 特意改成的写法）。
当测试环境满足以下条件时，`Main` 走进某条 `exit` 分支：

- `clean-residuals.ps1` Main：`Get-ChildItem "$PSScriptRoot\..\..\backup-*"`
- `backup-*` 是 **gitignored** 的运行时目录
- **新克隆 / CI / git worktree 里必然不存在** → 命中 `exit 1`

### 后果（比"测试失败"更糟）

`exit` 在 Pester 宿主内触发后，Pester 5.7.1 在**收尾阶段**崩溃：

```
System.Management.Automation.MethodException:
  Cannot find an overload for "Add" and the argument count: "1".
   at Pester.psm1: line 4984    $run.Containers.Add($i)
```

结果是**整个套件静默塌掉**（`Passed= Failed= Total=` 全为空），呈现为"绿"：

| 环境 | 结果 |
|------|------|
| 主仓（有遗留 `backup-20260826-094144/`） | 141/141 假绿 |
| 干净 worktree（无 `backup-*`） | 套件塌掉，`Passed= Failed= Total=` 全空 |
| 干净 worktree + 空 `backup-*` 目录 | 141/141 |

这既是**假绿**（CI 上会静默失去全部断言），也是**不可复现**的测试基线。

## 决策

**`Main` 一律通过 `[ref]` 参数回传退出码，函数体内既不得 `exit`，也不得 `return <数字>`。**

```powershell
function Main {
    param([ref]$ExitCode)
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    if (-not (Test-AdminPrivilege -Mandatory)) { & $setRc 2; return }
    # ... 错误路径： & $setRc 1; return
    # ... 成功路径： & $setRc 0
}

# 执行守卫
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
```

## 为什么不是「`Main` 返回退出码」

v1 曾采用 `return 1` + 守卫 `exit (Main)`。实测证明**两个写法都不可用**：

### 1. `return <数字>` 会把整数写进输出流

PowerShell 的函数返回值走**输出流**。`return 1` 会把 `1` 作为管道对象写出，
调用方 `$output = (Main 2>&1) -join "\`n"` 会拿到 `"...日志... 1"`，污染所有输出断言。

实测：

```powershell
function Main { Write-Output 'alpha'; return 5 }
$o = & { Main } 2>&1      # $o = 'alpha', 5   <-- 5 混进来了
```

### 2. `exit (Main)` 会吞掉 `Main` 的全部输出

PowerShell 必须先**求值** `exit` 的参数。`Main` 的输出被吃进这个参数表达式，
宿主随即退出，此前的 `Write-Output` **全部丢失**。

实测（同样的 Main）：

| 守卫写法 | 捕获到的输出 | 退出码 |
|----------|--------------|--------|
| `Main` + `exit 0` | `alpha│beta│0` | 0 |
| `exit (Main)` | **（空）** | 0 |
| `$c = Main; exit $c` | **（空）** | 0 |

`clean-residuals.ps1` 换成 `exit (Main)` 后，真实子进程调用 `confirm-cleanup.ps1`
捕获到的输出行数从 9 掉到 0 —— 而退出码仍然正确，所以**只有输出断言会发现**。

### 3. `exit` 在 dot-source / 进程内调用时杀死宿主

这是最初的 blocker：Pester 收尾崩溃、整份套件静默消失。

`[ref]` 同时解决三者：输出流干净、进程内调用安全、退出码可靠回传。

> **AGENTS.md 陷阱 #1 不适用**：该陷阱（`[ref]` + `[CmdletBinding]` 失效）需要
> `[CmdletBinding()]` 注解；本项目所有 `Main` 均无该注解。`Test-AdminPrivilege` 有
> 该注解，但它只 `return $bool`（不使用 `[ref]`），不受影响。

## 陷阱：嵌套函数的返回值同样会污染管道

`run-all.ps1` 的 `Invoke-Step` 既写日志又要回传子进程退出码。用 `return $code`
时，日志文本与码一起进入管道，调用方拿到 `Object[]`，绑定到 `[int]` 参数即报：

```
Cannot process argument transformation on parameter 'v'.
Cannot convert the "System.Object[]" value of type "System.Object[]" to type "System.Int32".
```

**因此每个"既要输出又要回传码"的函数都必须用 `[ref]`。** `run-all.ps1` 的
`Invoke-Step` 与 `Invoke-StepChecked` 都已改为 `[ref]` 形式。

## 被否决的替代方案

| 方案 | 否决理由 |
|------|----------|
| 只在测试里造一个假 `backup-*` 目录 | 治标：`exit` 仍在，任何其它错误路径（缺 ConfirmFile、报告解析失败）都会再次杀死宿主 |
| Mock 掉 `exit` | 做不到：`exit` 是语言关键字，不是可 mock 的 cmdlet |
| 改成抛异常，由调用方 `try/catch` 转成退出码 | 破坏既有退出码契约（0/1/2/3），且异常在 `-File` 子进程下会打印堆栈噪声 |
| 只修 `backup-*` 那一处 `exit` | 治标：其余 16 处仍是地雷；且 `confirm-cleanup.ps1` 的 TUI 路径会用 `exit` 直接退出 |
| `$Main` 返回码但用 `Out-Null` 包住调用 | 调用方仍拿不到码；且 `exit (Main)` 的吞输出问题依旧 |

## 影响

- 8 个脚本的 `Main` 全部改为 `[ref]` 形式，守卫统一为
  `$exitCode = 0; Main -ExitCode ([ref]$exitCode); exit $exitCode`
- `Test-AdminPrivilege -Mandatory` 不再 `exit 2`，改为 `return $false`，由调用方决定退出码
- 全部 `Main` 现可在 Pester 进程内安全调用 —— 覆盖率插桩不再有"执行一行都不计入"的盲区
- 新增 `tests/unit/hermeticity.Tests.ps1`（AST 静态断言 + 行为断言）防止回归
- `tests/unit/scripts.Tests.ps1` 的 `sc.exe` 测试组补上自建自清的 `backup-*` fixture
  （此前靠主仓遗留目录"碰巧通过"）
- 实测：干净 worktree（**无** `backup-*`）下 **150/150 通过**，退出码契约
  2/2/1/3/3 全部符合，且 stdout 未被吞（9 行）
