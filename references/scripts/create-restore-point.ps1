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
    $restorePointEnabled = $false
    try {
        # 方法 1: 检查注册表（最可靠）
        $srKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore')
        $rpsessionInterval = if ($srKey) { $srKey.GetValue('RPSessionInterval') } else { $null }
        if ($srKey -and $rpsessionInterval -ne 0) {
            $restorePointEnabled = $true
        }

        # 方法 2: WMI 交叉验证
        $srConfig = Get-CimInstance -ClassName SystemRestoreConfig -Namespace root/default -ErrorAction SilentlyContinue
        if ($srConfig -and $srConfig.RPSessionInterval -gt 0) {
            $restorePointEnabled = $true
        }
    } catch { Write-Warning "Cannot determine System Restore status: $_" }

    if (-not $restorePointEnabled) {
        Write-Warning "System Restore is not enabled."
        Write-Output "Attempting to enable System Restore on C: drive..."
        try {
            Enable-ComputerRestore -Drive "C:\" -ErrorAction Stop
            # 重新验证
            $checkKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore')
            if ($checkKey -and $checkKey.GetValue('RPSessionInterval') -ne 0) {
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
        restore_point_enabled = $restorePointEnabled
        backup_dir = $backupDir
        timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        backup_files = $backupFiles
    }
    $statusPath = "$backupDir\restore-status.json"
    $jsonContent = $result | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($statusPath, $jsonContent, [System.Text.UTF8Encoding]::new($false))
    Write-Output "Status saved to: $statusPath"

    & $setRc 0
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
# $MyInvocation.InvocationName is '.' when dot-sourced, empty when run via -File
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
