# create-restore-point.ps1
# 创建系统还原点 + 注册表备份

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

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
$backupDir = "$PSScriptRoot\..\backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
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
