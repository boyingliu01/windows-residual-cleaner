# create-restore-point.ps1
# 创建系统还原点 + 注册表备份
param(
    [string]$BackupRoot = "$PSScriptRoot\..\.."
)

# 固化顶层 param 默认值，供 Main 在调用方未提供时回落
$script:DefaultBackupRoot = $BackupRoot

# Admin privilege check (mandatory for write operations)
function Test-AdminPrivilege {
    [CmdletBinding()]
    param([switch]$Mandatory)
    $isAdmin = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if ($Mandatory) {
            Write-Error "Administrator privileges required. Please run PowerShell as Administrator."
            # ADR-001: 不得 exit（会杀死测试宿主）；由调用方据返回值决定退出码
            return $false
        } else {
            Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
        }
    }
    return $isAdmin
}

function Get-SystemRestoreInterval {
    <#
    .SYNOPSIS
        读 HKLM\...\SystemRestore\RPSessionInterval；读不到返回 $null。
    .DESCRIPTION
        抽成函数不是为了好看：REQ-004 / AC-018 要求断言「未能建立保护时返回可区分的
        非零码」，而这个判定原本直接内联读真实注册表——在本机（RPSessionInterval=1）
        上「不可用」分支根本无法构造，测试只能顺带验证当下真机状态。有了这个接缝，
        两条分支都能确定性地驱动。
        不声明任何参数（AGENTS.md 陷阱 8b：函数 param 会无条件遮蔽调用方同名变量）。
    #>
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore')
        if ($key) { return $key.GetValue('RPSessionInterval') }
    } catch { return $null }
    return $null
}

function Test-SystemRestoreEnabled {
    <#
    .SYNOPSIS
        系统还原是否启用（两路交叉验证）。纯只读。
    .DESCRIPTION
        B-C3：Get-ComputerRestorePoint 在还原禁用时返回空而非抛异常，所以这里查
        RPSessionInterval——注册表为主、WMI 为辅。返回值只可能是 $true / $false。
    #>
    $interval = Get-SystemRestoreInterval
    if ($null -ne $interval -and $interval -ne 0) { return $true }

    try {
        # WMI 交叉验证（注册表读不到时的第二路，例如权限受限）
        $srConfig = Get-CimInstance -ClassName SystemRestoreConfig -Namespace root/default -ErrorAction SilentlyContinue
        if ($srConfig -and $srConfig.RPSessionInterval -gt 0) { return $true }
    } catch { Write-Warning "Cannot determine System Restore status: $_" }

    return $false
}

function Main {
    # ADR-001: 用 [ref] 回传退出码；不得 exit（会杀死测试宿主），也不得 `return <code>`
    #
    # $BackupRoot 不声明为参数（会遮蔽调用方作用域的同名变量，见 AGENTS.md 陷阱第 8b 条）；
    # 显式覆盖走 -BackupRootOverride。
    param(
        [ref]$ExitCode,
        [string]$BackupRootOverride,
        [switch]$SkipRestorePoint
    )
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    if (-not [string]::IsNullOrWhiteSpace($BackupRootOverride)) {
        $BackupRoot = $BackupRootOverride
    } elseif ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = $script:DefaultBackupRoot
    }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    if (-not (Test-AdminPrivilege -Mandatory)) { & $setRc 2; return }

    # B-C3 修复：正确检测系统还原是否启用
    # Get-ComputerRestorePoint 在还原禁用时返回空而非抛异常
    #
    # -SkipRestorePoint 必须**真的被消费**。旧代码只在 param() 里声明了它，Main 从不读取，
    # 所以「跳过」从未生效：调用方以为自己不碰还原点，实际却触发了一次 Checkpoint-Computer。
    # 静态分析也抓不到——本项目在 PSScriptAnalyzerSettings.psd1 里排除了
    # PSReviewUnusedParameter（理由见 AGENTS.md），所以「声明未用」是本项目的盲区。
    $restorePointEnabled = $false
    $restorePointAttempted = $false

    if ($SkipRestorePoint) {
        Write-Output "Restore point creation skipped by request (-SkipRestorePoint); the optional layer is knowingly NOT established."
    } else {
        $restorePointAttempted = $true
        $restorePointEnabled = Test-SystemRestoreEnabled

        if (-not $restorePointEnabled) {
            Write-Warning "System Restore is not enabled."
            Write-Output "Attempting to enable System Restore on C: drive..."
            try {
                Enable-ComputerRestore -Drive "C:\" -ErrorAction Stop
                # 重新验证
                $recheck = Get-SystemRestoreInterval
                if ($null -ne $recheck -and $recheck -ne 0) {
                    $restorePointEnabled = $true
                    Write-Output "System Restore enabled."
                }
            } catch {
                Write-Error "Failed to enable System Restore: $_"
            }
        }

        if ($restorePointEnabled) {
            $desc = "Pre-cleanup $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
            Write-Output "Creating system restore point: $desc"
            try {
                Checkpoint-Computer -Description $desc -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
                Write-Output "Restore point created: $desc"
            } catch {
                Write-Warning "Failed to create restore point: $_"
                $restorePointEnabled = $false
            }
        } else {
            Write-Warning "System Restore could not be enabled. Cleanup will proceed WITHOUT backup protection."
        }
    }

    # 2. 注册表备份（B-M6 修复：验证导出完整性）
    $backupDir = "$BackupRoot\backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    mkdir $backupDir -Force | Out-Null

    $regPaths = @(
        "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $backupFiles = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($p in $regPaths) {
        $fname = $p -replace '[\\:]', '_'
        $outFile = "$backupDir\reg-$fname.reg"
        reg export "$p" "$outFile" /y 2>$null
        # 验证导出完整性
        if (Test-Path $outFile) {
            $regContent = Get-Content $outFile -Raw -Encoding Unicode -ErrorAction SilentlyContinue
            if ($regContent -match 'Windows Registry Editor') {
                $backupFiles.Add([PSCustomObject]@{ key=$p; file=$outFile; size=(Get-Item $outFile).Length; valid=$true })
            } else {
                $backupFiles.Add([PSCustomObject]@{ key=$p; file=$outFile; size=0; valid=$false })
                Write-Warning "Registry export may be corrupted: $p"
            }
        }
    }

    Write-Output "Backup saved to: $backupDir ($($backupFiles.Count) exports)"

    # 3. 输出状态 JSON（B-M5 修复：路径调整为 skill root）
    $result = @{
        restore_point_enabled   = $restorePointEnabled
        restore_point_attempted = $restorePointAttempted
        backup_dir              = $backupDir
        timestamp               = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        backup_files            = $backupFiles
    }
    $statusPath = "$backupDir\restore-status.json"
    $jsonContent = $result | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($statusPath, $jsonContent, [System.Text.UTF8Encoding]::new($false))
    Write-Output "Status saved to: $statusPath"

    # REQ-004 / AC-018：可选层「尝试过但没建立」时**绝不**返回 0。
    # 0 会让任何不看 restore-status.json 的调用方（UI、脚本、人）以为保护已就位——
    # 一个以「可恢复性」为承诺的工具不能这样静默 fail-open。
    # 4 = 尽力而为的系统还原点不可用。它**不是**中止条件：REQ-004 明确禁止
    # clean-residuals.ps1 / run-all.ps1 因它停机（强制精准保护才是承担责任的那一层），
    # 所以调用方必须把它与真正的失败（1/2/3）区分开。
    # 显式 -SkipRestorePoint 是知情退出，不算失败，仍返回 0，但状态文件如实写 enabled=false。
    if ($restorePointAttempted -and -not $restorePointEnabled) {
        Write-Warning "Optional protection NOT established - reporting exit code 4 (not success)."
        & $setRc 4
    } else {
        & $setRc 0
    }
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
# $MyInvocation.InvocationName is '.' when dot-sourced, empty when run via -File
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
