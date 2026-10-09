# =============================================================================
# WRC ADMIN DRILL - Stage 3: service + HKLM paths (REQUIRES ADMINISTRATOR)
# =============================================================================
# This is the last uncovered slice. Runs only the two paths that need elevation:
#   1. service stop + delete  (the sc.exe code path fixed in a386132)
#   2. HKLM registry key delete
#
# SAFETY DESIGN (read before running):
#   * Creates ONLY objects named WRC-DRILL-* / WRCDrill*. Nothing else is touched.
#   * The service's binary is cmd.exe (a system binary we never delete), and the
#     service is never started - only created, stopped (no-op), and deleted.
#   * The HKLM key is created by this script under HKLM\SOFTWARE\WRC-DRILL-*.
#     It is NOT an existing system key.
#   * Cleanup runs in a `finally` block, so artefacts are removed even on failure.
#   * clean-residuals.ps1 is driven through a purpose-built report + ConfirmFile
#     containing ONLY the drill IDs, so it cannot touch anything else.
#   * If you want a dry pass first:  -DryRun
#
# USE:
#   Start an ADMIN PowerShell, then:
#     powershell -ExecutionPolicy Bypass -File wrc-drill\drill4-admin.ps1
#     powershell -ExecutionPolicy Bypass -File wrc-drill\drill4-admin.ps1 -DryRun
# =============================================================================
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$sep = ('=' * 78)
$results = [System.Collections.Generic.List[object]]::new()
function Record([string]$n, [string]$s, [string]$d) {
    $results.Add([pscustomobject]@{ Check=$n; Status=$s; Detail=$d })
    $c = switch ($s) { 'PASS' {'Green'} 'FAIL' {'Red'} 'SKIP' {'Yellow'} default {'Gray'} }
    Write-Host ("  [{0,-5}] {1}" -f $s, $n) -ForegroundColor $c
    if ($d) { Write-Host "          $d" -ForegroundColor DarkGray }
}

$repoRoot  = Split-Path $PSScriptRoot -Parent
$drillRoot = $PSScriptRoot
$svcName   = 'WRCDrillGhostSvc'
$regSubKey = 'SOFTWARE\WRC-DRILL-AdminGhost'
$whitelist = Join-Path $repoRoot 'references\config\whitelist.json'
$script    = Join-Path $repoRoot 'references\scripts\clean-residuals.ps1'

Write-Host $sep
Write-Host "ADMIN DRILL: service + HKLM cleanup paths" -ForegroundColor Cyan
if ($DryRun) { Write-Host "MODE: DryRun (no changes)" -ForegroundColor Yellow }
Write-Host $sep

# --- Precondition: must be admin ---------------------------------------------
$isAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Record 'Running elevated' $(if ($isAdmin) { 'PASS' } else { 'FAIL' }) "IsAdmin=$isAdmin"
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "This drill MUST run from an Administrator PowerShell." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as administrator', then re-run." -ForegroundColor Red
    exit 2
}
Write-Host ""

# --- A backup must exist: clean-residuals refuses to delete without one -------
$backups = @(Get-ChildItem -Path (Join-Path $repoRoot 'backup-*') -Directory -ErrorAction SilentlyContinue)
if (-not $backups) {
    Write-Host "No backup-* directory found. Creating one first..." -ForegroundColor Yellow
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $repoRoot 'references\scripts\create-restore-point.ps1')
}

try {
    # -------------------------------------------------------------------------
    Write-Host "PHASE 1: Create the ghost service" -ForegroundColor Cyan
    # -------------------------------------------------------------------------
    # binPath points at a SYSTEM binary that we never delete, and the service is
    # created DISABLED so it can never auto-start. We also never call `sc start`,
    # so this service is only ever created and deleted - the ghost-service cleanup
    # path does `sc stop` (harmless no-op on a stopped service) then `sc delete`.
    $sysBin = Join-Path $env:SystemRoot 'System32\cmd.exe'
    & sc.exe create $svcName binPath= $sysBin start= disabled 2>&1 | Out-Null
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    Record 'Create ghost service' $(if ($svc) { 'PASS' } else { 'FAIL' }) "$svcName (binPath=$sysBin, start=disabled, never started)"

    Write-Host ""
    Write-Host "PHASE 2: Create the HKLM residual key" -ForegroundColor Cyan
    $hklmPath = "HKLM:\$regSubKey"
    New-Item -Path $hklmPath -Force | Out-Null
    New-ItemProperty -Path $hklmPath -Name 'Probe' -Value 'wrc-drill' -Force | Out-Null
    Record 'Create HKLM residual key' $(if (Test-Path $hklmPath) { 'PASS' } else { 'FAIL' }) "HKLM\$regSubKey"

    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "PHASE 3: Build report + ConfirmFile (ONLY drill IDs)" -ForegroundColor Cyan
    # -------------------------------------------------------------------------
    # ghost_service schema per scan-residuals.ps1: type/name/binary_path/risk/reason
    $report = [ordered]@{
        scan_time = (Get-Date).ToString('s')
        summary = [ordered]@{ total_residuals=2; safe=0; caution=2; danger=0; estimated_space_recoverable_mb=0 }
        filesystem_residuals = @()
        registry_residuals = @([ordered]@{ id='reg_950'; key="HKLM\$regSubKey"; name='WRC-DRILL-AdminGhost';
            type='vendor_key'; subkey_count=0; risk='caution'; reason='drill' })
        ghost_services = @([ordered]@{ id='svc_950'; name=$svcName; binary_path='C:\Windows\System32\cmd.exe';
            type='ghost_service'; risk='caution'; reason='drill' })
        ghost_tasks=@(); startup_residuals=@(); shell_residuals=@(); path_residuals=@(); uninstalled_software=@()
    }
    $rPath = Join-Path $drillRoot 'admin-report.json'
    $cPath = Join-Path $drillRoot 'admin-confirm.json'
    [IO.File]::WriteAllText($rPath, ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($cPath, '["svc_950","reg_950"]', [Text.UTF8Encoding]::new($false))
    Record 'Build drill report + ConfirmFile' 'PASS' "2 IDs: svc_950, reg_950"

    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "PHASE 4: Run the REAL clean-residuals.ps1" -ForegroundColor Cyan
    # -------------------------------------------------------------------------
    # Quote path elements explicitly: Start-Process -ArgumentList does NOT
    # quote array elements, and paths with spaces would split into fragments.
    $psiArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $script),
              '-ReportPath', ('"{0}"' -f $rPath), '-ConfirmFile', ('"{0}"' -f $cPath), '-Mode', 'A', '-WhitelistPath', ('"{0}"' -f $whitelist))
    if ($DryRun) { $psiArgs += '-DryRun' }
    $o = Join-Path $drillRoot 'admin-out.txt'; $e = Join-Path $drillRoot 'admin-err.txt'
    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $psiArgs -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $o -RedirectStandardError $e
    $text = (Get-Content $o -Raw -EA SilentlyContinue) + (Get-Content $e -Raw -EA SilentlyContinue)
    Write-Host "    (exit $($p.ExitCode))" -ForegroundColor DarkGray
    ($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 22) | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "PHASE 5: Verify outcomes" -ForegroundColor Cyan
    # -------------------------------------------------------------------------
    $svcGone  = (Get-Service -Name $svcName -ErrorAction SilentlyContinue) -eq $null
    $regGone  = -not (Test-Path $hklmPath)
    if ($DryRun) {
        Record 'DryRun left service intact'  $(if (-not $svcGone) { 'PASS' } else { 'FAIL' }) "exists=$(-not $svcGone)"
        Record 'DryRun left HKLM key intact' $(if (-not $regGone) { 'PASS' } else { 'FAIL' }) "exists=$(-not $regGone)"
    } else {
        Record 'REAL: service deleted (sc.exe path)' $(if ($svcGone) { 'PASS' } else { 'FAIL' }) "sc query returns 1060? gone=$svcGone"
        Record 'REAL: HKLM key deleted'              $(if ($regGone) { 'PASS' } else { 'FAIL' }) "gone=$regGone"
    }
    $log = Join-Path $repoRoot 'cleanup-log.json'
    if (Test-Path $log) {
        $lj = Get-Content $log -Raw | ConvertFrom-Json
        Record 'Cleanup log' 'PASS' "processed=$($lj.summary.total_processed) ok=$($lj.summary.succeeded) failed=$($lj.summary.failed)"
        @($lj.entries) | ForEach-Object { Write-Host "      id=$($_.id) action=$($_.action) success=$($_.success)" -ForegroundColor DarkGray }
        if ($lj.summary.failed -gt 0) {
            @($lj.entries | Where-Object { -not $_.success }) | ForEach-Object {
                Write-Host "      FAILED: id=$($_.id) error=$($_.error)" -ForegroundColor Yellow }
        }
    }
}
finally {
    Write-Host ""
    Write-Host "CLEANUP: removing drill artefacts" -ForegroundColor Yellow
    # Service first (stop is a no-op since we never started it)
    & sc.exe stop $svcName 2>&1 | Out-Null
    & sc.exe delete $svcName 2>&1 | Out-Null
    if (Test-Path "HKLM:\$regSubKey") { Remove-Item "HKLM:\$regSubKey" -Recurse -Force -EA SilentlyContinue }
    foreach ($f in @('admin-report.json','admin-confirm.json','admin-out.txt','admin-err.txt')) {
        $fp = Join-Path $drillRoot $f
        if (Test-Path $fp) { Remove-Item $fp -Force -EA SilentlyContinue }
    }
    $svcLeft = (Get-Service -Name $svcName -ErrorAction SilentlyContinue) -ne $null
    $regLeft = Test-Path "HKLM:\$regSubKey"
    Write-Host "  service left: $svcLeft (expect False)"
    Write-Host "  HKLM key left: $regLeft (expect False)"
    if (-not $svcLeft -and -not $regLeft) { Write-Host "  DRILL CLEAN" -ForegroundColor Green }
    else { Write-Host "  INCOMPLETE - remove manually" -ForegroundColor Red }
}

Write-Host ""
Write-Host $sep
$pass = @($results | Where-Object Status -eq 'PASS').Count
$fail = @($results | Where-Object Status -eq 'FAIL').Count
Write-Host "ADMIN DRILL RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail) {'Red'} else {'Green'})
Write-Host $sep
$results | Format-Table -AutoSize
