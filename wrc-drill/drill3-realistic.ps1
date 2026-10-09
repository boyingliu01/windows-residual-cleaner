# Realistic-fidelity drill: use the EXACT schema the scanner emits.
# Purpose: determine whether the "silent no-op" is reachable with real data.
. 'D:\Study\LLM\windows-residual-cleaner\references\scripts\clean-residuals.ps1'

$drillRoot = 'D:\Study\LLM\windows-residual-cleaner\wrc-drill'
$repoRoot  = 'D:\Study\LLM\windows-residual-cleaner'

# --- Realistic artefacts (schema copied from scan-residuals.ps1) --------------
# ghost_task: {type='ghost_task'; name; execute; expanded_path; risk; reason}
# Ghost task whose executable does NOT exist -> exactly what the scanner flags.
$taskName = 'WRCDrillGhostTask2'
& schtasks /Create /TN $taskName /TR 'C:\nonexistent\wrc-drill-ghost.exe' /SC ONCE /ST 23:59 /F 2>&1 | Out-Null

$fsTarget = Join-Path $drillRoot 'WRC-DRILL-AppFolder2'
New-Item -ItemType Directory -Path $fsTarget -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $fsTarget 'a.dat'), 'x')

# registry: realistic VENDOR key (not an Uninstall subkey), so the whitelist
# pattern .*Microsoft\Windows\CurrentVersion\.* does NOT cover it.
$regSubKey = 'Software\WRC-DRILL-Vendor'
$regPath = "HKCU:\$regSubKey"
New-Item -Path $regPath -Force | Out-Null
New-ItemProperty -Path $regPath -Name 'Probe' -Value '1' -Force | Out-Null

$report = [ordered]@{
    scan_time = (Get-Date).ToString('s')
    summary = [ordered]@{ total_residuals=3; safe=1; caution=2; danger=0; estimated_space_recoverable_mb=0.01 }
    filesystem_residuals = @([ordered]@{ id='fs_901'; path=$fsTarget; name='WRC-DRILL-AppFolder2';
        type='residual_directory'; file_count=1; size_mb=0.01; risk='safe'; reason='drill' })
    registry_residuals = @([ordered]@{ id='reg_901'; key="HKCU\$regSubKey"; name='WRC-DRILL-Vendor';
        type='vendor_key'; subkey_count=0; risk='caution'; reason='drill vendor key' })
    ghost_services = @()
    # SCHEMA-ACCURATE ghost task: includes expanded_path (required by the dispatch)
    ghost_tasks = @([ordered]@{ id='tsk_901'; name=$taskName; execute='C:\nonexistent\wrc-drill-ghost.exe';
        expanded_path='C:\nonexistent\wrc-drill-ghost.exe'; risk='caution'; reason='exe not found' })
    startup_residuals = @(); shell_residuals = @(); path_residuals = @(); uninstalled_software = @()
}

$drillReport = Join-Path $drillRoot 'drill3-report.json'
$drillConfirm = Join-Path $drillRoot 'drill3-confirm.json'
[IO.File]::WriteAllText($drillReport, ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($drillConfirm, '["fs_901","reg_901","tsk_901"]', [Text.UTF8Encoding]::new($false))

# --- Set inputs AFTER dot-source (avoid the param-clobber trap) --------------
$ReportPath  = $drillReport
$ConfirmFile = $drillConfirm
$Mode        = 'A'
$DryRun      = $false
$LogPath     = Join-Path $drillRoot 'drill3-log.json'
$WhitelistPath = Join-Path $repoRoot 'references\config\whitelist.json'

function Test-AdminPrivilege { param([switch]$Mandatory) return $true }

Write-Host "=== BEFORE ==="
Write-Host "  fs dir   exists: $(Test-Path $fsTarget)"
Write-Host "  HKCU key exists: $(Test-Path $regPath)"
Write-Host "  task     exists: $((Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue) -ne $null)"
Write-Host ""

$out = Main 2>&1 | Out-String
Write-Host "=== MAIN OUTPUT ==="
$out
Write-Host "=== AFTER ==="
$fsGone   = -not (Test-Path $fsTarget)
$regGone  = -not (Test-Path $regPath)
$taskGone = (Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue) -eq $null
Write-Host "  fs dir   deleted: $fsGone"
Write-Host "  HKCU key deleted: $regGone"
Write-Host "  task     deleted: $taskGone"
Write-Host ""

$logFile = Join-Path $repoRoot 'cleanup-log.json'
if (Test-Path $logFile) {
    $log = Get-Content $logFile -Raw | ConvertFrom-Json
    Write-Host "=== LOG: processed=$($log.summary.total_processed) ok=$($log.summary.succeeded) failed=$($log.summary.failed) skipped=$($log.summary.skipped) ==="
    @($log.entries) | ForEach-Object { Write-Host "  id=$($_.id) action=$($_.action) success=$($_.success)" }
}
