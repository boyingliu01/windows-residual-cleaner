# Teardown: remove every artefact the drill may have created. Idempotent.
$repoRoot  = 'D:\Study\LLM\windows-residual-cleaner'
$drillRoot = Join-Path $repoRoot 'wrc-drill'

Write-Host "=== Tearing down drill artefacts ==="

foreach ($tn in @('WRCDrillGhostTask','WRCDrillGhostTask2')) {
    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "  removed task $tn" }
}

foreach ($k in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WRC-DRILL-GhostApp',
    'HKCU:\Software\WRC-DRILL-Vendor'
)) {
    if (Test-Path $k) { Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "  removed key $k" }
}

foreach ($d in @('WRC-DRILL-AppFolder','WRC-DRILL-AppFolder2')) {
    $p = Join-Path $drillRoot $d
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "  removed dir $p" }
}

foreach ($sf in @('drill-report.json','drill-confirm.json','drill3-report.json','drill3-confirm.json',
                  'drill3-log.json','real-cleanup-log.json','dryrun.txt','dryrun-err.txt',
                  'dryrun-log.json','real-cleanup-output.txt')) {
    $p = Join-Path $drillRoot $sf
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Write-Host "  removed file $sf" }
}

$strayLog = Join-Path $repoRoot 'cleanup-log.json'
if (Test-Path $strayLog) { Remove-Item $strayLog -Force; Write-Host "  removed stray cleanup-log.json (drill artifact)" }

Write-Host ""
Write-Host "=== Verification: nothing left behind ==="
$tasks = @(Get-ScheduledTask -TaskName 'WRCDrill*' -ErrorAction SilentlyContinue)
$keys  = @(Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'WRC' })
$unin  = Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WRC-DRILL-GhostApp'
Write-Host "  scheduled tasks   : $($tasks.Count)  (expect 0)"
Write-Host "  HKCU WRC* keys    : $($keys.Count)  (expect 0)"
Write-Host "  uninstall key     : $unin  (expect False)"
Write-Host "  drill dir exists  : $(Test-Path $drillRoot)"
Write-Host ""
if ($tasks.Count -eq 0 -and $keys.Count -eq 0 -and -not $unin) {
    Write-Host "TEARDOWN CLEAN" -ForegroundColor Green
} else {
    Write-Host "TEARDOWN INCOMPLETE" -ForegroundColor Yellow
}
