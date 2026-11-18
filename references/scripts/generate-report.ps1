# generate-report.ps1
# Consolidates all scan outputs into final JSON report with risk classification and unique IDs
param(
    [string]$DataDir = "$PSScriptRoot\..\..",
    [string]$OutputPath = "$PSScriptRoot\..\..\final-report.json"
)

# 修复：直接修改 hashtable 条目，避免 [ref] 对值类型的引用丢失
# PowerShell 的 hashtable 值是 by-value 返回的，[ref]$counters.fs 指向临时拷贝
function Set-Id {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param([hashtable]$counters, [string]$key, [string]$prefix)
    $counters[$key]++
    return "{0}{1:D3}" -f $prefix, $counters[$key]
}

# uninstalled_software 的「可清理」判定（纯函数，issue #12）。
#
# 只有证据强到「这个卸载项背后的东西已经不在了」才允许删注册项：
#   - InstallLocation 非空**且**目录已不存在；
#   - UninstallString 解析出的 exe 非空**且**文件已不存在。
# 两者必须同时成立。索引成员关系（scan-uninstalled 的 confidence=low）不足以单独支撑：
# 「索引里没有」在两个方向上都可能错（索引构建失败、软件名被改写），
# 而删掉一个仍然存在的软件的卸载项会让它永远无法正常卸载。
# 这里重算而不是读 confidence：报告层不该依赖上游字符串的措辞。
function Test-UninstalledActionable {
    param([Parameter(Mandatory)]$Item)

    $installLocation = [string]$Item.install_location
    $installMissing = $false
    if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
        $clean = [Environment]::ExpandEnvironmentVariables($installLocation.Trim('"').Trim("'"))
        $installMissing = (-not [string]::IsNullOrWhiteSpace($clean)) -and (-not [System.IO.Directory]::Exists($clean))
    }

    $uninstallString = [string]$Item.uninstall_string
    # 系统卸载器（MsiExec / rundll32 / regsvr32）永远不在一处固定路径上，
    # 「exe 不存在」对它们不成立；与 scan-uninstalled.ps1 的 Get-UninstallExePath 同一判据。
    $uninstallMissing = $false
    if (-not [string]::IsNullOrWhiteSpace($uninstallString) -and
        $uninstallString -notmatch '^\s*(MsiExec|rundll32|regsvr32)\.exe') {
        $exePath = $null
        if ($uninstallString -match '^"([^"]+?\.exe)"') { $exePath = $Matches[1] }
        elseif ($uninstallString -match '^([^"]+?\.exe)(?:\s|$)') { $exePath = $Matches[1] }
        if (-not [string]::IsNullOrWhiteSpace($exePath)) {
            $exePath = [Environment]::ExpandEnvironmentVariables($exePath)
            $uninstallMissing = -not [System.IO.File]::Exists($exePath)
        }
    }

    if ($installMissing -and $uninstallMissing) {
        return @{ actionable = $true; reason = 'InstallLocation directory missing and uninstaller exe missing' }
    }
    return @{
        actionable = $false
        reason     = 'evidence too weak: InstallLocation directory and uninstaller exe are not both missing'
    }
}

function Main {
    # ADR-001: 用 [ref] 回传退出码；不得 exit（会杀死测试宿主），也不得 `return <code>`
    param([ref]$ExitCode)
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # Admin privilege check (warning only for read-only operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
    }

    # Load scan outputs
    $missingFiles = @()
    if (-not (Test-Path "$DataDir\uninstalled-list.json")) { $missingFiles += "uninstalled-list.json" }
    if (-not (Test-Path "$DataDir\fs-residuals.json")) { $missingFiles += "fs-residuals.json" }
    if (-not (Test-Path "$DataDir\other-residuals.json")) { $missingFiles += "other-residuals.json" }
    if ($missingFiles.Count -gt 0) {
        Write-Error "Required input files not found: $($missingFiles -join ', ')"
        & $setRc 3
        return
    }
    # 上游 JSON 均为无 BOM UTF-8；PS 5.1 下 Get-Content -Raw 按 ANSI 代码页解码，
    # 非 ASCII 环境（如中文 GBK）会吞掉引号/大括号导致 ConvertFrom-Json 失败（陷阱 16）。
    $uninstalled = [System.IO.File]::ReadAllText("$DataDir\uninstalled-list.json", [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $fs = [System.IO.File]::ReadAllText("$DataDir\fs-residuals.json", [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $other = [System.IO.File]::ReadAllText("$DataDir\other-residuals.json", [System.Text.Encoding]::UTF8) | ConvertFrom-Json

    # ID counters with D3 zero-padding
    # fs_XXX = filesystem, reg_XXX = registry, svc_XXX = ghost_services,
    # tsk_XXX = ghost_tasks, str_XXX = startup_residuals,
    # shl_XXX = shell_residuals (COM/ContextMenu), path_XXX = PATH entries,
    # uni_XXX = uninstalled_software (orphan uninstall entries, see Set-UninstalledActionable)
    $counters = @{fs=0; reg=0; svc=0; tsk=0; str=0; shl=0; path=0; uni=0}

    # Assign IDs to filesystem residuals
    $fsItems = @()
    foreach ($item in $fs) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'fs' 'fs_')
        $fsItems += $item
    }

    # Assign IDs to registry residuals
    $regItems = @()
    foreach ($item in $other.registry_residuals) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'reg' 'reg_')
        $regItems += $item
    }

    # Assign IDs to ghost services
    $svcItems = @()
    foreach ($item in $other.ghost_services) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'svc' 'svc_')
        $svcItems += $item
    }

    # Assign IDs to ghost tasks
    $tskItems = @()
    foreach ($item in $other.ghost_tasks) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'tsk' 'tsk_')
        $tskItems += $item
    }

    # Assign IDs to startup residuals
    $strItems = @()
    foreach ($item in $other.startup_residuals) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'str' 'str_')
        $strItems += $item
    }

    # Assign IDs to shell residuals (COM/ContextMenu)
    $shlItems = @()
    foreach ($item in $other.shell_residuals) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'shl' 'shl_')
        $shlItems += $item
    }

    # Assign IDs to PATH residuals
    $pathItems = @()
    foreach ($item in $other.path_residuals) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'path' 'path_')
        $pathItems += $item
    }

    # Aggregate all items
    $allItems = @($fsItems; $regItems; $svcItems; $tskItems; $strItems; $shlItems; $pathItems) | Where-Object { $_ }

    # Compute summary statistics
    $safeCount = ($allItems | Where-Object { $_.risk -eq 'safe' }).Count
    $cautionCount = ($allItems | Where-Object { $_.risk -eq 'caution' }).Count
    $dangerCount = ($allItems | Where-Object { $_.risk -eq 'danger' }).Count
    $estimatedSpace = [math]::Round(($fsItems | Measure-Object -Property size_mb -Sum -ErrorAction SilentlyContinue).Sum, 1)

    # Generate report
    #
    # PS 5.1 陷阱（已实测，会让 final-report.json 的数组字段变成脏数据）：
    #
    #   用 `if` 语句**作为表达式**产出空数组时，结果其实是 $null，而不是 @()：
    #       $x = if ($cond) { @() } else { @() }   # $x 为 $null
    #   把这样的 $null 放进哈希表，ConvertTo-Json 渲染成 `{}`（空对象）而非 `[]`。
    #
    #   `@($null)` 同样不是空数组：它是 Count = 1、唯一元素为 $null 的数组，
    #   序列化成 `[null]`，下游遍历会拿到一个 $null 元素。
    #
    # 正确写法：先判空赋给变量，再用 **[array]** 显式转型（**不能**写成
    # `[array]( if ... )` —— `if` 不是表达式，那样是语法错误）。
    # 实测：`[array]@()` → `[]`；`,@()` 会多套一层变成 `[[]]`；不转型可能得到 `{}`。
    # candidate_directories 只进报告，**没有** id、也**不**计入 total_residuals（issue #12）。
    # 它们「目录在、索引里没有」这一条证据太弱（解包残留、运行时目录、用户自建目录都长这样），
    # 没有文件系统残留那套活性/受保护判定，不允许被选进清理集。actionable=false 是给
    # Phase 2 展示用的显式信号，避免 agent 把它当成「可选但暂时不可点」。
    $candidateDirectories = @()
    if ($null -ne $uninstalled.candidate_directories) {
        foreach ($dir in @($uninstalled.candidate_directories)) {
            $dir | Add-Member -NotePropertyName 'actionable' -NotePropertyValue $false
            $dir | Add-Member -NotePropertyName 'actionable_reason' -NotePropertyValue 'inventory only: weak evidence, no liveness/protected-path gate'
            $candidateDirectories += $dir
        }
    }
    $candidateDirectories = [array]$candidateDirectories

    # uninstalled_software（孤儿卸载注册项）可清理：分配 uni_XXX id，并只把证据足以
    # 支撑删除的条目标成 actionable。其余保留在报告里但不可选——扫描器的两阶段判定
    # 对「索引里没有」且「路径、卸载器都还在」的条目也判 residual(low)，那条证据不足以
    # 删一个仍然存在的卸载项（AGENTS.md「多条件检测」：权威信号 gate 辅助信号）。
    $softwareItems = @()
    foreach ($item in @($uninstalled.uninstalled_software)) {
        if ($null -eq $item) { continue }
        $action = Test-UninstalledActionable -Item $item
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'uni' 'uni_')
        $item | Add-Member -NotePropertyName 'risk' -NotePropertyValue 'caution'
        $item | Add-Member -NotePropertyName 'actionable' -NotePropertyValue ([bool]$action.actionable)
        $item | Add-Member -NotePropertyName 'reason' -NotePropertyValue ([string]$action.reason)
        if ($action.actionable) {
            $item | Add-Member -NotePropertyName 'key' -NotePropertyValue ([string]$item.registry_key)
        }
        $softwareItems += $item
    }
    $softwareList = [array]$softwareItems
    $allItems = @($allItems) + @($softwareItems | Where-Object { $_.actionable })
    # .Count 必须套在 @() 外面：只命中一条时 Where-Object 返回的是单个对象，
    # 它的 .Count 是该对象的**属性数**（PSCustomObject 无该属性 -> $null），不是 1（陷阱 3）。
    $cautionCount = @($allItems | Where-Object { $_.risk -eq 'caution' }).Count

    $report = @{
        scan_time = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        summary = @{
            total_residuals = $allItems.Count
            safe = $safeCount
            caution = $cautionCount
            danger = $dangerCount
            estimated_space_recoverable_mb = $estimatedSpace
        }
        uninstalled_software = $softwareList
        candidate_directories = $candidateDirectories
        filesystem_residuals = $fsItems
        registry_residuals = $regItems
        ghost_services = $svcItems
        ghost_tasks = $tskItems
        startup_residuals = $strItems
        shell_residuals = $shlItems
        path_residuals = $pathItems
    }

    # Output UTF-8 without BOM
    $jsonContent = $report | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($OutputPath, $jsonContent, [System.Text.UTF8Encoding]::new($false))

    Write-Output "Report generated: $($allItems.Count) items (Safe: $safeCount, Caution: $cautionCount, Danger: $dangerCount)"
    Write-Output "Output: $OutputPath"
    & $setRc 0
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
