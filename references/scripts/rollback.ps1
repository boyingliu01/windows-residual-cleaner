# rollback.ps1
# 输出可用还原点和回滚指引（B-m4 增强版）
param(
    [string]$CleanupLogPath = "$PSScriptRoot\..\..\cleanup-log.json",
    [string]$BackupRoot = "$PSScriptRoot\..\.."
)

$script:DefaultCleanupLogPath = $CleanupLogPath
$script:DefaultBackupRoot = $BackupRoot

function Get-BackupDirectory {
    <#
    .SYNOPSIS
        列出备份目录，最新的在前（按名称降序）。
    .DESCRIPTION
        backup-* 是运行时目录（gitignored）。抽成函数以便用 fixture 单测，
        且让 BackupRoot 可注入 —— 否则测试只能依赖仓里遗留的 backup-*。
    #>
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path $Root)) { return @() }
    return @(
        Get-ChildItem -Path $Root -Filter 'backup-*' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
    )
}

function Get-RegistryBackupFile {
    <#
    .SYNOPSIS
        列出某备份目录下的 reg-*.reg 文件。
    #>
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-Path $Directory)) { return @() }
    return @(Get-ChildItem -Path $Directory -Filter 'reg-*.reg' -ErrorAction SilentlyContinue)
}

function Get-MatchingRestorePoint {
    <#
    .SYNOPSIS
        找出清理时间前后 ±5 分钟内的还原点。
    #>
    param(
        [AllowEmptyCollection()][object[]]$RestorePoints = @(),
        [Parameter(Mandatory)][datetime]$MatchTime,
        [int]$WindowMinutes = 5
    )

    if (-not $RestorePoints) { return @() }
    return @(
        $RestorePoints | Where-Object {
            $_.CreationTime -ge $MatchTime.AddMinutes(-$WindowMinutes) -and
            $_.CreationTime -le $MatchTime.AddMinutes($WindowMinutes)
        }
    )
}

function Main {
    # ADR-001: 用 [ref] 回传退出码；不得 exit（会杀死测试宿主）
    param(
        [ref]$ExitCode,
        [string]$CleanupLogPathOverride,
        [string]$BackupRootOverride
    )
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    if (-not [string]::IsNullOrWhiteSpace($CleanupLogPathOverride)) {
        $CleanupLogPath = $CleanupLogPathOverride
    } elseif ([string]::IsNullOrWhiteSpace($CleanupLogPath)) {
        $CleanupLogPath = $script:DefaultCleanupLogPath
    }
    if (-not [string]::IsNullOrWhiteSpace($BackupRootOverride)) {
        $BackupRoot = $BackupRootOverride
    } elseif ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = $script:DefaultBackupRoot
    }

    # Admin privilege check (warning only for read-only operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning "Running without admin. Restore points may not be enumerable."
    }

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
        try {
            $matchTime = [DateTime]::Parse($cleanupTime)
            # 必须 @(...) 包住返回值：函数只匹配到 1 个还原点时，PowerShell 会把
            # 单元素数组**解包**成标量，`$matched.Count` 于是为 $null，打印出
            # 「Found  restore point(s)」这种缺数字的句子（AGENTS.md 陷阱第 3 条的同一族问题）。
            $matched = @(Get-MatchingRestorePoint -RestorePoints @($restorePoints) -MatchTime $matchTime)
            if ($matched.Count -gt 0) {
                Write-Output "Found $($matched.Count) restore point(s) created near cleanup time:"
                foreach ($m in $matched) {
                    Write-Output "  #$($m.SequenceNumber): $($m.Description) - $($m.CreationTime)"
                }
            } else {
                Write-Output "No restore points found near cleanup time."
            }
        } catch {
            Write-Verbose "Cannot parse cleanup timestamp '$cleanupTime': $_"
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

    # List registry backup files from most recent backup directory
    Write-Output ""
    Write-Output "=== Registry Backup Files ==="
    $backupDirs = @(Get-BackupDirectory -Root $BackupRoot)
    if ($backupDirs.Count -gt 0) {
        $latestDir = $backupDirs[0]
        Write-Output "Most recent backup: $($latestDir.Name)"
        $regFiles = @(Get-RegistryBackupFile -Directory $latestDir.FullName)
        if ($regFiles.Count -gt 0) {
            foreach ($f in $regFiles) {
                Write-Output "  $($f.Name) ($([math]::Round($f.Length / 1KB, 1)) KB)"
            }
        } else {
            Write-Output "  No registry backup files found."
        }

        # Show restore status if available
        $statusFile = Join-Path $latestDir.FullName "restore-status.json"
        if (Test-Path $statusFile) {
            try {
                $status = Get-Content $statusFile -Raw | ConvertFrom-Json
                Write-Output ""
                Write-Output "Restore point: $($status.restore_point_description)"
            } catch {
                Write-Verbose "Cannot parse restore-status.json: $_"
            }
        }
    } else {
        Write-Output "  No backup directories found."
    }

    Write-Output ""
    Write-Output "NOTE: Automatic rollback feature is under development."
    Write-Output "To manually restore, use System Restore from Windows Recovery."
    Write-Output "You can also manually merge .reg files if you only need to restore specific keys."

    & $setRc 0
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
