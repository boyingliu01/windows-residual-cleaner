# AGENTS.md — Windows Residual Cleaner

> AI agent 工作指南。维护者在开发 / 调试 / 扩展此项目前必读。

---

## 项目上下文

这是一个 Windows 系统清理工具，通过 PowerShell 脚本扫描和清理卸载软件残留。
涉及注册表、文件系统、Windows 服务、计划任务、COM 扩展等敏感系统区域。

**运行环境**: Windows 10/11 + PowerShell 5.1 + Administrator 权限
**测试框架**: Pester 5.x
**代码质量**: PSScriptAnalyzer (0 error, 0 warning)

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
    param([string]$Path, [switch]$WhatIf)
    if ($WhatIf) { return $true }
    if (-not (Test-Path $Path)) { return $true }

    # Tier 1: 标准 PowerShell 删除
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch { }

    # Tier 2: 夺取所有权 + 修改 ACL
    try {
        takeown /f "$Path" /r /d Y 2>$null
        icacls "$Path" /grant Administrators:F /T /C 2>$null
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch { }

    # Tier 3: CMD 强制删除
    try {
        cmd /c "rd /s /q `"$Path`"" 2>$null
        if (-not (Test-Path $Path)) { return $true }
    } catch { }

    # Tier 4: 重命名 + 延迟删除 (下次启动时)
    try {
        $renamed = Join-Path (Split-Path $Path -Parent) "~$(Split-Path $Path -Leaf).deleted"
        Rename-Item -Path $Path -NewName $renamed -Force
        # MoveFileEx 标记延迟删除 (可选)
        return $true
    } catch { }

    return $false
}
```

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

---

## 变更历史

- 2026-05-05: 从 v1.0.0 → v1.1.0.0 session 中提取并整理
  - 新增 PowerShell 5.1 陷阱清单
  - 新增多条件检测逻辑设计原则
  - 新增四层降级删除策略
  - 新增测试策略（Mock 局限性 + 集成测试要求）
