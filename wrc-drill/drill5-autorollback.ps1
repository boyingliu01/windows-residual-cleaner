# =============================================================================
# WRC AUTO-ROLLBACK REAL-MACHINE DRILL (REQUIRES ADMINISTRATOR)
# Sprint sprint-2026-10-01-01, design doc section 5 (mandatory before ship)
# -----------------------------------------------------------------------------
# Creates ONLY objects named WRC-DRILL5-* / WRCDrill5*. It drives the REAL
# clean-residuals.ps1 in-process with a ConfirmFile listing ONLY these ids:
#
#   fs_951  plain directory          -> deleted            (not_restorable)
#   fs_952  directory held open:
#           CreateFileW share=0 on the directory itself makes ALL four
#           Remove-ItemRobust tiers fail (incl. tier-4 rename, which needs
#           DELETE access that share=0 denies) -> forces partial failure
#                                                        (not_restorable)
#   svc_951 disabled service, cmd.exe binPath, never started
#                                    -> deleted            (not_restorable)
#   pe_951  synthetic DEAD machine-PATH segment  -> removed (restorable)
#   reg_951 HKCU\Software\WRC-DRILL5-Vendor      -> deleted (restorable)
#   st_951  Run value WRC-DRILL5-Startup         -> deleted (restorable)
#
# Expected outcome (DD-013 exit matrix): code 10 = partial failure AND
# auto-rollback fully successful; the three restorable kinds come back to
# their exact prior state, the three destructive kinds are honestly reported
# as not_restorable (DD-006).
#
# SAFETY DESIGN:
#   * the real Machine PATH is captured to drill5-work\machine-path-original.txt
#     BEFORE any change and restored by this drill itself in the finally block,
#     regardless of what clean-residuals does; the drill asserts the exact
#     round-trip -ceq at the end, so a silent-path-change bug cannot ship.
#   * everything runs against a drill-local project root (drill5-work\):
#     backup-*, cleanup-log.json and the journal never touch the repo root.
#   * the Run key keeps all its other values; the tool's trimmed single-value
#     export/restore (DD-003) is exactly what we are verifying.
#   * UAC: refuses to run non-elevated; self-relaunches via -Verb RunAs.
#
# USE:  powershell -ExecutionPolicy Bypass -File wrc-drill\drill5-autorollback.ps1
# =============================================================================
param([switch]$ElevatedChild)

$ErrorActionPreference = 'Continue'
$sep = ('=' * 78)
$drillRoot = $PSScriptRoot
$repoRoot  = Split-Path $drillRoot -Parent
$work      = Join-Path $drillRoot 'drill5-work'
$logFile   = Join-Path $work 'transcript.txt'
$resultFile= Join-Path $work 'result.json'
$rcFile    = Join-Path $work 'child-rc.txt'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Elevation gate: relaunch elevated once, never loop ----------------------
if (-not (Test-IsAdmin)) {
    if ($ElevatedChild) { Write-Host 'ELEVATION FAILED (child still not admin).'; exit 2 }
    Write-Host 'Not elevated - requesting elevation (UAC prompt)...'
    $null = New-Item -ItemType Directory -Path $work -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $rcFile) { Remove-Item -LiteralPath $rcFile -Force -ErrorAction SilentlyContinue }
    try {
        # Quote the script path: -ArgumentList does not quote elements, and a
        # checkout path containing spaces would split into fragments.
        $null = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $PSCommandPath), '-ElevatedChild')
    } catch {
        Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)"
        exit 2
    }
    if (Test-Path -LiteralPath $rcFile) { exit ([int](Get-Content -LiteralPath $rcFile -Raw)) }
    exit 1
}

$null = New-Item -ItemType Directory -Path $work -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($logFile, '', [Text.UTF8Encoding]::new($false))

function Log([string]$m) {
    Write-Host $m
    try { [IO.File]::AppendAllText($logFile, ($m + [Environment]::NewLine), [Text.UTF8Encoding]::new($false)) } catch { $null = $m }
}

$results = [System.Collections.Generic.List[object]]::new()
function Record([string]$n, [string]$s, [string]$d) {
    $results.Add([pscustomobject]@{ Check=$n; Status=$s; Detail=$d })
    $c = switch ($s) { 'PASS' {'Green'} 'FAIL' {'Red'} 'SKIP' {'Yellow'} default {'Gray'} }
    Log ("  [{0,-5}] {1}" -f $s, $n)
    if ($d) { Log "          $d" }
}

# --- Fixed drill object names ------------------------------------------------
$svcName   = 'WRCDrill5GhostSvc'
$vendorKey = 'HKCU\Software\WRC-DRILL5-Vendor'
$vendorPs  = 'HKCU:\Software\WRC-DRILL5-Vendor'
$runKey    = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
$runPs     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValue  = 'WRC-DRILL5-Startup'
$runData   = 'C:\nonexistent\wrc-drill5.exe'
$plainDir  = Join-Path $work 'AppFolder5'
$lockedDir = Join-Path $work 'LockedFolder5'
$deadSeg   = Join-Path $work 'DeadPath'
$pathFile  = Join-Path $work 'machine-path-original.txt'

$reportF   = Join-Path $work 'report.json'
$confirmF  = Join-Path $work 'confirm.json'
$wlFile    = Join-Path $work 'whitelist-drill.json'

$script:lockHandle = [IntPtr]::Zero
$script:finalRc = 1

Log $sep
Log 'WRC AUTO-ROLLBACK DRILL - section 5 real-machine drill (exit 10 expected)'
Log $sep
Record 'Running elevated' 'PASS' "IsAdmin=True"

# --- Idempotent scrub of any leftovers from a previous run -------------------
try {
    $stale = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($stale) { & "$env:SystemRoot\System32\sc.exe" delete $svcName 2>&1 | Out-Null; Log "  scrubbed stale service $svcName" }
    if (Test-Path $vendorPs) { Remove-Item $vendorPs -Recurse -Force -ErrorAction SilentlyContinue; Log '  scrubbed stale vendor key' }
    if (Test-Path $runPs) {
        $v = Get-ItemProperty -Path $runPs -Name $runValue -ErrorAction SilentlyContinue
        if ($v) { Remove-ItemProperty -Path $runPs -Name $runValue -Force -ErrorAction SilentlyContinue; Log '  scrubbed stale Run value' }
    }
    foreach ($d in @($plainDir, $lockedDir)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    foreach ($d in @(Get-ChildItem -Path $work -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in @('report.json','confirm.json','result.json','child-rc.txt','cleanup-log.json')) {
        $fp = Join-Path $work $f
        if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue }
    }
    # machine PATH: remove a stale segment segment-wise (verbatim otherwise)
    $cur = [Environment]::GetEnvironmentVariable('Path','Machine')
    if ($null -ne $cur) {
        $needle = $deadSeg.Trim().TrimEnd('\').ToLowerInvariant()
        $parts = @($cur -split ';')
        $kept = @()
        $hit = $false
        foreach ($p in $parts) {
            if ($p.Trim().TrimEnd('\').ToLowerInvariant() -eq $needle) { $hit = $true; continue }
            $kept += , $p
        }
        if ($hit) {
            [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'Machine')
            Log '  scrubbed stale machine PATH segment'
        }
    }
} catch { Record 'Scrub previous run' 'FAIL' $_.Exception.Message }

# --- Capture original Machine PATH (the drill's own safety copy) -------------
$p0 = [Environment]::GetEnvironmentVariable('Path','Machine')
if ($null -eq $p0) { Record 'Capture Machine PATH' 'FAIL' 'GetEnvironmentVariable returned null'; $script:finalRc = 3 }
else {
    [IO.File]::WriteAllText($pathFile, $p0, [Text.UTF8Encoding]::new($false))
    Record 'Capture Machine PATH' 'PASS' "saved to $pathFile ($($p0.Length) chars)"
}

$p1 = $p0 + ';' + $deadSeg   # the value the tool must capture and restore
if ($null -eq $p0) {
    # Cannot safely touch Machine PATH without a verified original; bail out
    # before any fixture exists. (Record above already marked the failure.)
    Log 'ABORT: Machine PATH could not be captured; nothing was modified.'
    [IO.File]::WriteAllText($rcFile, '3', [Text.UTF8Encoding]::new($false))
    exit 3
}

$script:lockHandle = [IntPtr]::Zero
try {
    # =========================================================================
    Log ''
    Log 'PHASE 1: create fixtures'
    # =========================================================================
    & "$env:SystemRoot\System32\sc.exe" create $svcName binPath= "$env:SystemRoot\System32\cmd.exe" start= disabled 2>&1 | Out-Null
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    Record 'Create synthetic service' $(if ($svc) { 'PASS' } else { 'FAIL' }) "$svcName (cmd.exe binPath, disabled, never started)"

    New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $plainDir 'a.dat'), 'wrc-drill5')
    New-Item -ItemType Directory -Path $lockedDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $lockedDir 'b.dat'), 'wrc-drill5-locked')

    New-Item -Path $vendorPs -Force | Out-Null
    New-ItemProperty -Path $vendorPs -Name 'Probe' -Value 'v5' -Force | Out-Null

    if (-not (Test-Path $runPs)) { New-Item -Path $runPs -Force | Out-Null }
    New-ItemProperty -Path $runPs -Name $runValue -Value $runData -PropertyType String -Force | Out-Null

    [Environment]::SetEnvironmentVariable('Path', $p1, 'Machine')
    $p1back = [Environment]::GetEnvironmentVariable('Path','Machine')
    Record 'Create fixtures' $(if ((Test-Path $vendorPs) -and (Test-Path $plainDir) -and (Test-Path $lockedDir) -and ($p1back -ceq $p1)) { 'PASS' } else { 'FAIL' }) `
        "vendor key + Run value + 2 dirs + PATH segment appended"

    # --- Fail-injection: exclusive handle on the directory itself -------------
    if (-not ('WrcDrill5Lock' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WrcDrill5Lock {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@
    }
    # GENERIC_READ, share=0 (deny everything), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS.
    # PS 5.1 quirk: the literal 0x80000000 binds as Int32 -2147483648 and fails the
    # UInt32 parameter; cast every argument explicitly.
    $h = [WrcDrill5Lock]::CreateFileW($lockedDir, [uint32]2147483648, [uint32]0, [IntPtr]::Zero, [uint32]3, [uint32]0x02000000, [IntPtr]::Zero)
    $handleOk = ($h -ne [IntPtr]::Zero) -and ($h -ne [IntPtr](-1))
    if (-not $handleOk) {
        Record 'Acquire exclusive dir handle' 'FAIL' 'CreateFileW failed; cannot force a deletion failure'
        $script:finalRc = 3
    } else {
        $script:lockHandle = $h
        # Canary: rename must now be denied too (needs DELETE access; share=0 denies).
        $renameBlocked = $false
        try { [IO.Directory]::Move($lockedDir, ($lockedDir + '_canary')); [IO.Directory]::Move(($lockedDir + '_canary'), $lockedDir) }
        catch { $renameBlocked = $true }
        Record 'Exclusive dir handle blocks rename' $(if ($renameBlocked) { 'PASS' } else { 'FAIL' }) `
            'share=0 -> tier-4 rename (and all delete tiers) must fail'
        if (-not $renameBlocked) { $script:finalRc = 3 }
    }

    if ($script:finalRc -eq 3) {
        Log 'ABORT: fail-injection could not be established; not running clean-residuals.'
    } else {
        # =====================================================================
        Log ''
        Log 'PHASE 2: build report + ConfirmFile (drill ids only) and run the REAL clean-residuals.ps1'
        # =====================================================================
        $report = [ordered]@{
            scan_time = (Get-Date).ToString('s')
            summary = [ordered]@{ total_residuals=6; safe=0; caution=6; danger=0; estimated_space_recoverable_mb=0.01 }
            filesystem_residuals = @(
                [ordered]@{ id='fs_951'; path=$plainDir;  name='WRC-DRILL5-AppFolder';  type='residual_directory'; file_count=1; size_mb=0.01; risk='caution'; reason='drill' },
                [ordered]@{ id='fs_952'; path=$lockedDir; name='WRC-DRILL5-LockedFolder'; type='residual_directory'; file_count=1; size_mb=0.01; risk='caution'; reason='drill (locked)' }
            )
            registry_residuals = @(
                [ordered]@{ id='reg_951'; key=$vendorKey; name='WRC-DRILL5-Vendor'; type='vendor_key'; subkey_count=0; risk='caution'; reason='drill vendor key' }
            )
            ghost_services = @(
                [ordered]@{ id='svc_951'; name=$svcName; binary_path="$env:SystemRoot\System32\cmd.exe"; type='ghost_service'; risk='caution'; reason='drill' }
            )
            ghost_tasks = @()
            startup_residuals = @(
                [ordered]@{ id='st_951'; key=$runKey; value_name=$runValue; value=$runData; type='startup'; risk='caution'; reason='drill startup value' }
            )
            shell_residuals = @()
            path_residuals = @(
                [ordered]@{ id='pe_951'; path=$deadSeg; type='path_entry'; risk='caution'; reason='drill dead PATH entry' }
            )
            uninstalled_software = @()
        }
        [IO.File]::WriteAllText($reportF, ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($confirmF, '["fs_951","fs_952","svc_951","pe_951","reg_951","st_951"]', [Text.UTF8Encoding]::new($false))
        # Drill-local whitelist with EMPTY pattern lists: the bundled whitelist
        # covers .*Microsoft\Windows\CurrentVersion\.* and would silently skip
        # st_951 (startup values are gated on item.key). The drill report
        # contains ONLY drill ids, so an empty whitelist has no blast radius.
        [IO.File]::WriteAllText($wlFile, '{"registry_patterns":[],"path_patterns":[],"service_names":[]}', [Text.UTF8Encoding]::new($false))
        Record 'Build report + ConfirmFile' 'PASS' '6 ids, drill-local whitelist (empty)'

        . (Join-Path $repoRoot 'references\scripts\clean-residuals.ps1')

        # inputs set AFTER dot-source (param-clobber trap, AGENTS.md trap 8a)
        $ReportPath  = $reportF
        $ConfirmFile = $confirmF
        $Mode        = 'A'
        $DryRun      = $false
        $LogPath     = Join-Path $work 'cleanup-log.json'
        $WhitelistPath = $wlFile
        $ProjectRootOverride = $work

        $rc = -999
        Log ''
        Log '=== clean-residuals Main() output begins ==='
        $out = Main -ExitCode ([ref]$rc) *>&1 | Out-String
        Log $out
        Log '=== clean-residuals Main() output ends ==='
        Log "Main rc = $rc"
        Record 'clean-residuals exit code == 10 (DD-013)' $(if ($rc -eq 10) { 'PASS' } else { 'FAIL' }) "rc=$rc (10 = partial failure + rollback fully successful)"

        # =====================================================================
        Log ''
        Log 'PHASE 3: release lock + verify real-machine state'
        # =====================================================================
        if ($script:lockHandle -ne [IntPtr]::Zero) {
            $null = [WrcDrill5Lock]::CloseHandle($script:lockHandle)
            $script:lockHandle = [IntPtr]::Zero
        }

        $vend = Get-ItemProperty -Path $vendorPs -Name 'Probe' -ErrorAction SilentlyContinue
        Record 'Vendor key restored by rollback' $(if ($vend -and $vend.Probe -eq 'v5') { 'PASS' } else { 'FAIL' }) "HKCU\Software\WRC-DRILL5-Vendor\Probe='$($vend.Probe)'"

        $runv = Get-ItemProperty -Path $runPs -Name $runValue -ErrorAction SilentlyContinue
        Record 'Run value restored by rollback' $(if ($runv -and ([string]$runv.$runValue) -eq $runData) { 'PASS' } else { 'FAIL' }) "$runValue='$($runv.$runValue)'"

        $curPath = [Environment]::GetEnvironmentVariable('Path','Machine')
        Record 'Machine PATH restored to exact captured value' $(if ($curPath -ceq $p1) { 'PASS' } else { 'FAIL' }) `
            $(if ($curPath -ceq $p1) { 'segment back; byte-identical to pre-cleanup value' } else { "MISMATCH: len=$($curPath.Length) vs expected $($p1.Length)" })

        Record 'Plain dir deleted (stays gone)' $(if (-not (Test-Path -LiteralPath $plainDir)) { 'PASS' } else { 'FAIL' }) $plainDir
        $renamed = Test-Path -LiteralPath (Join-Path $work '~LockedFolder5.deleted')
        $lockedStill = Test-Path -LiteralPath $lockedDir
        Record 'Locked dir NOT deleted and NOT renamed' $(if ($lockedStill -and -not $renamed) { 'PASS' } else { 'FAIL' }) `
            "dir_present=$lockedStill renamed_present=$renamed (tier-4 rename must not masquerade as success)"
        Record 'Service deleted' $(if (-not (Get-Service -Name $svcName -ErrorAction SilentlyContinue)) { 'PASS' } else { 'FAIL' }) $svcName

        # --- audit the on-disk rollback record ---------------------------------
        $dirs = @(Get-ChildItem -Path $work -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue)
        Record 'Exactly one backup dir created' $(if ($dirs.Count -eq 1) { 'PASS' } else { 'FAIL' }) "count=$($dirs.Count)"
        if ($dirs.Count -ge 1) {
            $bdir = $dirs[0].FullName
            $rr = Join-Path $bdir 'rollback-result.json'
            $jr = Join-Path $bdir 'rollback-journal.json'
            if (Test-Path $rr) {
                $r = Get-Content $rr -Raw -ErrorAction Stop | ConvertFrom-Json
                $c = $r.counts
                $okCounts = ($c.restored -eq 3 -and $c.already_present -eq 0 -and $c.not_restorable -eq 3 -and $c.restore_failed -eq 0)
                Record 'rollback-result counts 3/0/3/0' $(if ($okCounts) { 'PASS' } else { 'FAIL' }) `
                    "restored=$($c.restored) already_present=$($c.already_present) not_restorable=$($c.not_restorable) restore_failed=$($c.restore_failed)"
                Record 'within_window = True' $(if ($r.within_window -eq $true) { 'PASS' } else { 'FAIL' }) "within_window=$($r.within_window)"
                $vm = @{}
                foreach ($v in @($r.verdicts)) { $vm[([string]$v.kind)] = [string]$v.verdict }
                $okVerdicts = ($vm['registry_key'] -eq 'restored' -and $vm['startup_value'] -eq 'restored' -and $vm['path_entry'] -eq 'restored' -and $vm['path_deleted'] -eq 'not_restorable' -and $vm['service'] -eq 'not_restorable')
                Record 'Per-kind verdicts honest' $(if ($okVerdicts) { 'PASS' } else { 'FAIL' }) `
                    ("registry_key={0} startup_value={1} path_entry={2} path_deleted={3} service={4}" -f $vm['registry_key'],$vm['startup_value'],$vm['path_entry'],$vm['path_deleted'],$vm['service'])
            } else { Record 'rollback-result.json present' 'FAIL' $rr }
            if (Test-Path $jr) {
                $j = Get-Content $jr -Raw -ErrorAction Stop | ConvertFrom-Json
                $entries = @($j.entries)
                $statesById = @{}
                foreach ($e in $entries) { $statesById[([string]$e.item_id)] = [string]$e.state }
                # 必须按 item_id 取状态：本轮有两个 path_deleted 条目（fs_951 成功 / fs_952
                # 四层全败），若按 kind 建哈希表，后一条会覆盖前一条、把失败藏起来。
                $okStates = ($entries.Count -eq 6 `
                    -and $statesById["path_deleted:$plainDir"] -eq 'mutation_succeeded' `
                    -and $statesById["path_deleted:$lockedDir"] -eq 'mutation_failed' `
                    -and $statesById["service:$svcName"] -eq 'mutation_succeeded' `
                    -and $statesById["path_entry:$deadSeg"] -eq 'mutation_succeeded' `
                    -and $statesById["registry_key:$vendorKey"] -eq 'mutation_succeeded' `
                    -and $statesById["startup_value:$runKey|$runValue"] -eq 'mutation_succeeded')
                Record 'Journal: 6 entries, states honest (locked=mutation_failed)' $(if ($okStates) { 'PASS' } else { 'FAIL' }) `
                    ("count={0} fs951={1} fs952={2} svc={3} pe={4} reg={5} st={6}" -f $entries.Count, $statesById["path_deleted:$plainDir"], $statesById["path_deleted:$lockedDir"], $statesById["service:$svcName"], $statesById["path_entry:$deadSeg"], $statesById["registry_key:$vendorKey"], $statesById["startup_value:$runKey|$runValue"])
                Record 'Journal marked complete (rc=10)' $(if (-not [string]::IsNullOrWhiteSpace([string]$j.completed_at)) { 'PASS' } else { 'FAIL' }) "completed_at=$($j.completed_at)"
                Record 'Cleanup-log binding present' $(if (-not [string]::IsNullOrWhiteSpace([string]$j.cleanup_log_sha256)) { 'PASS' } else { 'FAIL' }) "sha256=$($j.cleanup_log_sha256)"
            } else { Record 'rollback-journal.json present' 'FAIL' $jr }
        }
        $cl = Join-Path $work 'cleanup-log.json'
        if (Test-Path $cl) {
            $l = Get-Content $cl -Raw -ErrorAction Stop | ConvertFrom-Json
            $s = $l.summary
            Record 'Cleanup summary 6/5/1' $(if ($s.total_processed -eq 6 -and $s.succeeded -eq 5 -and $s.failed -eq 1) { 'PASS' } else { 'FAIL' }) `
                "total=$($s.total_processed) succeeded=$($s.succeeded) failed=$($s.failed)"
        } else { Record 'cleanup-log.json present' 'FAIL' $cl }
    }
}
catch {
    Record 'Drill execution' 'FAIL' $_.Exception.Message
    Log ($_.ScriptStackTrace)
}
finally {
    # =========================================================================
    Log ''
    Log 'PHASE 4: teardown (always runs)'
    # =========================================================================
    if ($script:lockHandle -ne [IntPtr]::Zero) {
        try { $null = [WrcDrill5Lock]::CloseHandle($script:lockHandle) } catch { $null = $script:lockHandle }
        $script:lockHandle = [IntPtr]::Zero
    }
    try { & "$env:SystemRoot\System32\sc.exe" delete $svcName 2>&1 | Out-Null } catch { $null = $svcName }
    try { if (Test-Path $vendorPs) { Remove-Item $vendorPs -Recurse -Force -ErrorAction SilentlyContinue } } catch { $null = $vendorPs }
    try {
        if (Test-Path $runPs) {
            if (Get-ItemProperty -Path $runPs -Name $runValue -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -Path $runPs -Name $runValue -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { $null = $runValue }
    foreach ($d in @($plainDir, $lockedDir, (Join-Path $work '~LockedFolder5.deleted'), (Join-Path $work 'LockedFolder5_canary'))) {
        try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } catch { $null = $d }
    }
    # Restore the drill's OWN capture of machine PATH (never trust the tool alone)
    try {
        if (Test-Path -LiteralPath $pathFile) {
            $orig = [IO.File]::ReadAllText($pathFile)
            [Environment]::SetEnvironmentVariable('Path', $orig, 'Machine')
            $back = [Environment]::GetEnvironmentVariable('Path','Machine')
            Record 'Teardown: Machine PATH restored to original' $(if ($back -ceq $orig) { 'PASS' } else { 'FAIL' }) `
                $(if ($back -ceq $orig) { 'byte-identical to pre-drill value' } else { 'MISMATCH - manual repair needed (see machine-path-original.txt)' })
        }
    } catch { Record 'Teardown: Machine PATH restored to original' 'FAIL' $_.Exception.Message }

    $leftSvc = (Get-Service -Name $svcName -ErrorAction SilentlyContinue) -ne $null
    $leftKey = Test-Path $vendorPs
    $leftVal = $false
    try { $leftVal = ($null -ne (Get-ItemProperty -Path $runPs -Name $runValue -ErrorAction SilentlyContinue)) } catch { $leftVal = $false }
    $leftDir = (Test-Path -LiteralPath $plainDir) -or (Test-Path -LiteralPath $lockedDir)
    Record 'Teardown complete (no drill objects left)' $(if ((-not $leftSvc) -and (-not $leftKey) -and (-not $leftVal) -and (-not $leftDir)) { 'PASS' } else { 'FAIL' }) `
        "svc=$leftSvc key=$leftKey runval=$leftVal dir=$leftDir"
}

# --- Result file + exit code -------------------------------------------------
$pass = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($script:finalRc -eq 3) { $fail++ }
$rc = if ($fail -gt 0) { 1 } else { 0 }
$doc = [ordered]@{
    drill           = 'drill5-autorollback'
    timestamp       = (Get-Date).ToString('s')
    passed          = $pass
    failed          = $fail
    machine_path_ok = (Test-Path -LiteralPath $pathFile)
    checks          = @($results | ForEach-Object { [ordered]@{ check=$_.Check; status=$_.Status; detail=$_.Detail } })
}
[IO.File]::WriteAllText($resultFile, ($doc | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($rcFile, [string]$rc, [Text.UTF8Encoding]::new($false))

Log ''
Log $sep
Log "DRILL5 RESULT: $pass passed, $fail failed $(if ($rc -eq 0) { '- ALL GREEN' } else { '- SEE transcript.txt' })"
Log "Artifacts: $resultFile / $logFile"
Log $sep
exit $rc
