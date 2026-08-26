# scan-residuals.ps1
# 基于已卸载软件列表，扫描注册表/服务/任务/COM/启动项/Shell 等非文件系统残留
param(
    [string]$UninstalledPath = "$PSScriptRoot\..\..\uninstalled-list.json",
    [string]$OutputPath = "$PSScriptRoot\..\..\other-residuals.json"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 提取可执行文件路径（处理引号和参数，Expert B Critical #1 修复）
function Get-ExecutablePath {
    param([string]$pathName)
    if ([string]::IsNullOrEmpty($pathName)) { return $null }
    if ($pathName -match '^"([^"]+)"') { return $Matches[1] }
    $exeMatch = [regex]::Match($pathName, '^(.+?\.(exe|dll|sys))\s', 'IgnoreCase')
    if ($exeMatch.Success) { return $exeMatch.Groups[1].Value }
    return $pathName.Split(' ')[0].Trim('"')
}

# 点源守卫：当脚本被 dot-source（如单元测试加载函数）时，只加载函数定义，
# 跳过所有副作用代码（文件加载/系统扫描），使 dot-source 完全无副作用。
# 正常执行（& script 或 -File script）时 $MyInvocation.InvocationName != '.', 继续执行。
# 必须位于所有函数定义之后、任何可执行副作用语句之前。
if ($MyInvocation.InvocationName -eq '.') {
    return
}

# 加载已卸载列表
$uninstalled = Get-Content $UninstalledPath -Raw | ConvertFrom-Json
$uninstalledNames = @{}
foreach ($u in $uninstalled.uninstalled_software) { $uninstalledNames[$u.name.ToLower()] = $true }

$registryResiduals = [System.Collections.Generic.List[PSObject]]::new()
$ghostServices = [System.Collections.Generic.List[PSObject]]::new()
$ghostTasks = [System.Collections.Generic.List[PSObject]]::new()
$startupResiduals = [System.Collections.Generic.List[PSObject]]::new()
$shellResiduals = [System.Collections.Generic.List[PSObject]]::new()
$pathResiduals = [System.Collections.Generic.List[PSObject]]::new()

# --- a) Vendor 注册表键残留 ---
$regHives = @(
    @{ Base=[Microsoft.Win32.Registry]::LocalMachine; Path='SOFTWARE'; Label='HKLM\SOFTWARE' },
    @{ Base=[Microsoft.Win32.Registry]::LocalMachine; Path='SOFTWARE\WOW6432Node'; Label='HKLM\SOFTWARE\WOW6432Node' },
    @{ Base=[Microsoft.Win32.Registry]::CurrentUser; Path='Software'; Label='HKCU\Software' }
)
foreach ($hive in $regHives) {
    try {
        $key = $hive.Base.OpenSubKey($hive.Path)
        if (-not $key) { continue }
        foreach ($vendorName in $key.GetSubKeyNames()) {
            $vendorKey = $key.OpenSubKey($vendorName)
            $subKeys = $vendorKey.GetSubKeyNames()
            if ($subKeys.Count -eq 0) {
                # 无子键 Vendor：与已卸载名称匹配
                if ($uninstalledNames.ContainsKey($vendorName.ToLower())) {
                    $registryResiduals.Add([PSCustomObject]@{ type='vendor_key'; key="$($hive.Label)\$vendorName"; name=$vendorName; subkey_count=0; risk='caution'; reason="Vendor key matches uninstalled software" })
                }
            } else {
                # 大 Vendor（如 Tencent/Lenovo）：以子键为单位逐一判断
                foreach ($sk in $subKeys) {
                    if ($uninstalledNames.ContainsKey($sk.ToLower())) {
                        $registryResiduals.Add([PSCustomObject]@{ type='vendor_subkey'; key="$($hive.Label)\$vendorName\$sk"; name=$sk; subkey_count=1; risk='caution'; reason="Subkey matches uninstalled software under vendor $vendorName" })
                    }
                }
            }
        }
    } catch { Write-Warning "Vendor scan failed for $($hive.Label): $_" }
}

# --- b) 幽灵服务 ---
try {
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
        $exePath = Get-ExecutablePath -pathName $_.PathName
        if ($exePath -and -not [System.IO.File]::Exists($exePath)) {
            $ghostServices.Add([PSCustomObject]@{ type='ghost_service'; name=$_.Name; display_name=$_.DisplayName; binary_path=$_.PathName; extracted_path=$exePath; state=$_.State; risk='safe'; reason="Service binary does not exist: $exePath" })
        }
    }
} catch { Write-Warning "Service scan failed: $_" }

# --- c) 计划任务 ---
try {
    Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($action in $_.Actions) {
            if ($action.Execute) {
                # 修复：展开环境变量后再检查文件是否存在
                # 如 %windir%\system32\rundll32.exe → C:\WINDOWS\system32\rundll32.exe
                $expandedExecute = [Environment]::ExpandEnvironmentVariables($action.Execute)
                # 清理双引号（计划任务注册有时产生 ""C:\path"" 格式）
                $cleanExecute = $expandedExecute.Trim('"')
                # 裸可执行文件名（如 powershell.exe, sc.exe）跳过检查——一定在 PATH 中
                if ($cleanExecute -notmatch '[\\/]' -and $cleanExecute -match '\.(exe|dll|sys)$') {
                    # 裸文件名，可通过 PATH 找到，跳过
                    continue
                }
                if (-not [System.IO.File]::Exists($cleanExecute)) {
                    $ghostTasks.Add([PSCustomObject]@{ type='ghost_task'; name=$_.TaskName; execute=$action.Execute; expanded_path=$cleanExecute; risk='caution'; reason="Task executable not found: $cleanExecute" })
                }
            }
        }
    }
} catch { Write-Warning "Scheduled task scan failed (may need admin): $_" }

# --- d) 启动项 ---
$runPaths = @('SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')
foreach ($rp in $runPaths) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($rp)
    if ($key) {
        foreach ($vn in $key.GetValueNames()) {
            $val = $key.GetValue($vn)
            if ($val -and $val -match '\.(exe|dll)') {
                $exePath = Get-ExecutablePath -pathName $val
                if ($exePath -and -not [System.IO.File]::Exists($exePath)) {
                    $startupResiduals.Add([PSCustomObject]@{ type='startup'; key="HKLM\$rp"; value_name=$vn; value=$val; risk='caution'; reason="Startup entry points to non-existent file" })
                }
            }
        }
    }
}

# --- e) 环境变量 PATH（A-C2 修复：安全校验） ---
$pathEntries = [Environment]::GetEnvironmentVariable('PATH', 'Machine') -split ';'
foreach ($entry in $pathEntries) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    if (-not (Test-Path $entry)) {
        # 修复：改为 caution 而非 danger。死 PATH 条目指向不存在的目录，可安全清理。
        # 原逻辑一律标 danger，导致 confirm-cleanup 和 clean-residuals 都拒绝处理。
        $risk = 'caution'
        $reason = "PATH directory does not exist (dead path, safe to remove)"
        $pathResiduals.Add([PSCustomObject]@{ type='path_entry'; path=$entry; risk=$risk; reason=$reason })
    }
}

# --- f) COM/Shell 扩展残留（A-C1 修复：新增） ---
$comScanPaths = @(
    @{ Label='HKCR\CLSID'; Hive=[Microsoft.Win32.Registry]::LocalMachine; Path='SOFTWARE\Classes\CLSID' },
    @{ Label='HKCR\TypeLib'; Hive=[Microsoft.Win32.Registry]::LocalMachine; Path='SOFTWARE\Classes\TypeLib' }
)
foreach ($csp in $comScanPaths) {
    try {
        $key = $csp.Hive.OpenSubKey($csp.Path)
        if (-not $key) { continue }
        foreach ($guid in $key.GetSubKeyNames()) {
            # CLSID: 检查 InProcServer32 指向的 DLL 是否存在
            $inprocKey = $key.OpenSubKey("$guid\InProcServer32")
            if ($inprocKey) {
                $dllPath = $inprocKey.GetValue('')
                if ($dllPath) {
                    # 展开环境变量（如 %ProgramFiles%）
                    $expandedPath = [Environment]::ExpandEnvironmentVariables($dllPath)
                    # 区分原生 COM 和 .NET 程序集 COM（mscoree.dll 加载器）
                    if ($expandedPath -notmatch 'mscoree\.dll$' -and -not [System.IO.File]::Exists($expandedPath)) {
                        $shellResiduals.Add([PSCustomObject]@{ type='com_clsid'; key="$($csp.Label)\$guid\InProcServer32"; path=$expandedPath; risk='caution'; reason="COM InProcServer32 DLL not found" })
                    }
                }
            }
        }
    } catch { Write-Warning "COM scan failed for $($csp.Label): $_" }
}

# ContextMenuHandlers 残留
$cmhPaths = @(
    @{ Label='HKCR\*\shellex\ContextMenuHandlers'; Hive=[Microsoft.Win32.Registry]::LocalMachine; Path='SOFTWARE\Classes\*\shellex\ContextMenuHandlers' },
    @{ Label='HKCR\Directory\shellex\ContextMenuHandlers'; Hive=[Microsoft.Win32.Registry]::LocalMachine; Path='SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers' }
)
foreach ($cmp in $cmhPaths) {
    try {
        $cmhKey = $cmp.Hive.OpenSubKey($cmp.Path)
        if (-not $cmhKey) { continue }
        foreach ($handler in $cmhKey.GetSubKeyNames()) {
            $subKey = $cmhKey.OpenSubKey($handler)
            $clsid = if ($subKey) { $subKey.GetValue('') } else { $null }
            if ($clsid) {
                # 检查 CLSID 对应的 DLL 是否存在
                $clsidSubKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Classes\CLSID\$clsid\InProcServer32")
                if ($clsidSubKey) {
                    $dllPath = $clsidSubKey.GetValue('')
                    $expandedPath = [Environment]::ExpandEnvironmentVariables($dllPath)
                    if ($dllPath -and -not [System.IO.File]::Exists($expandedPath)) {
                        $shellResiduals.Add([PSCustomObject]@{ type='context_menu_handler'; name=$handler; clsid=$clsid; key="$($cmp.Label)\$handler"; risk='caution'; reason="Context menu handler DLL not found" })
                    }
                }
            }
        }
    } catch { Write-Warning "ContextMenu scan failed for $($cmp.Label): $_" }
}

# --- 输出 ---
$output = @{
    registry_residuals = $registryResiduals
    ghost_services = $ghostServices
    ghost_tasks = $ghostTasks
    startup_residuals = $startupResiduals
    shell_residuals = $shellResiduals
    path_residuals = $pathResiduals
}
$jsonContent = $output | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($OutputPath, $jsonContent, [System.Text.UTF8Encoding]::new($false))

Write-Output "Residual scan complete:"
Write-Output "  Registry: $($registryResiduals.Count) | Ghost Services: $($ghostServices.Count)"
Write-Output "  Ghost Tasks: $($ghostTasks.Count) | Startup: $($startupResiduals.Count)"
Write-Output "  COM/Shell: $($shellResiduals.Count) | PATH: $($pathResiduals.Count)"
