# rollback.ps1
# 输出可用还原点和回滚指引（B-m4 增强版）
param(
    [string]$CleanupLogPath = "$PSScriptRoot\..\..\cleanup-log.json"
)

Write-Output "===== ROLLBACK INSTRUCTIONS ====="
Write-Output ""

# 读取清理日志获取时间
$cleanupTime = $null
if (Test-Path $CleanupLogPath) {
    try {
        $log = Get-Content $CleanupLogPath -Raw | ConvertFrom-Json
        $cleanupTime = $log.summary.timestamp
        Write-Output "Last cleanup: $cleanupTime"
    } catch { Write-Verbose "Rollback operation skipped: $_" }
}

Write-Output ""
Write-Output "Available Restore Points (most recent 10):"
$restorePoints = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Select-Object -Last 10
$restorePoints | Format-Table SequenceNumber, Description, CreationTime -AutoSize

# 尝试匹配清理时间附近的还原点
if ($cleanupTime) {
    Write-Output ""
    Write-Output "--- Matching restore points near cleanup time ---"
    $matchTime = [DateTime]::Parse($cleanupTime)
    $matched = $restorePoints | Where-Object { $_.CreationTime -ge $matchTime.AddMinutes(-5) -and $_.CreationTime -le $matchTime.AddMinutes(5) }
    if ($matched) {
        Write-Output "Found $($matched.Count) restore point(s) created near cleanup time:"
        foreach ($m in $matched) {
            Write-Output "  #$($m.SequenceNumber): $($m.Description) - $($m.CreationTime)"
        }
    } else {
        Write-Output "No restore points found near cleanup time."
    }
}

Write-Output ""
Write-Output "To rollback:"
Write-Output "1. Open System Properties (Win+R → sysdm.cpl → System Protection → System Restore)"
Write-Output "2. Select the 'Pre-cleanup' restore point"
Write-Output "3. Follow the wizard (system will reboot)"
Write-Output ""
Write-Output "Alternatively, via PowerShell (requires reboot):"
Write-Output '  Restore-Computer -RestorePoint [SequenceNumber from above]'
Write-Output ""
Write-Output "Registry backups are in: $PSScriptRoot\..\backup-*"
Write-Output "  You can manually merge .reg files if you only need to restore specific keys."
