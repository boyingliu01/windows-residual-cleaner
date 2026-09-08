# run-all.ps1
# Unified scan pipeline: restore point → index → scan → report
# Responsibility: SCAN ONLY. Does not perform confirmation or cleanup.
param(
    [switch]$SkipRestorePoint = $false,
    [switch]$Verbose = $false
)

# Admin privilege check (mandatory — includes create-restore-point)
function Test-AdminPrivilege {
    [CmdletBinding()]
    param([switch]$Mandatory)
    $isAdmin = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if ($Mandatory) {
            Write-Error "Administrator privileges required. Please run PowerShell as Administrator."
            exit 2
        } else {
            Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
        }
    }
    return $isAdmin
}

function Main {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    [void](Test-AdminPrivilege -Mandatory)

    $scriptDir = $PSScriptRoot
    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Delphi R1 M1 fix: use List[Hashtable] for reference semantics (+= creates local copy in nested functions)
    $stepResults = [System.Collections.Generic.List[Hashtable]]::new()

    # Delphi R2 修复 [M5]: PS executable detection strategy
    # 优先使用 pwsh (PS Core 7+)，fallback 到 PS 5.1 的绝对路径
    # 项目声明 Tech Stack 为 PS 5.1，但 pwsh 7 也兼容
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        $psExe = 'pwsh'
    } else {
        $psExe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    function Invoke-Step {
        param([string]$Name, [string]$ScriptPath)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Output "`n=== Step: $Name ==="
        # Delphi R1 C1 fix: proper ArgumentList construction
        $argList = @('-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
        $process = Start-Process -FilePath $psExe -ArgumentList $argList -Wait -PassThru -NoNewWindow
        $sw.Stop()
        $result = @{ name = $Name; exit_code = $process.ExitCode; duration_seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        if ($process.ExitCode -ne 0) {
            Write-Error "Step '$Name' failed with exit code $($process.ExitCode) ($($result.duration_seconds)s)"
            $stepResults.Add($result)
            Write-Output "`nPipeline FAILED at step: $Name"
            exit $process.ExitCode
        }
        Write-Output "  → Completed in $($result.duration_seconds)s"
        $stepResults.Add($result)
    }

    # Step 1: Create restore point (optional)
    if (-not $SkipRestorePoint) {
        Invoke-Step -Name 'Create Restore Point' -ScriptPath "$scriptDir\create-restore-point.ps1"
    } else {
        # 业务日志用 Write-Output（Pester 拦截 warning 流导致测试无法通过 2>&1 捕获）
        Write-Output "Skipping restore point creation. Cleanup will NOT be recoverable."
    }

    # Step 2: Build installed software index
    Invoke-Step -Name 'Build Installed Index' -ScriptPath "$scriptDir\build-installed-index.ps1"

    # Step 3: Scan uninstalled residuals
    Invoke-Step -Name 'Scan Uninstalled' -ScriptPath "$scriptDir\scan-uninstalled.ps1"

    # Step 4: Scan filesystem residuals
    Invoke-Step -Name 'Scan Filesystem' -ScriptPath "$scriptDir\scan-filesystem-residuals.ps1"

    # Step 5: Scan registry/service/task residuals
    Invoke-Step -Name 'Scan Residuals' -ScriptPath "$scriptDir\scan-residuals.ps1"

    # Step 6: Generate final report
    Invoke-Step -Name 'Generate Report' -ScriptPath "$scriptDir\generate-report.ps1"

    $totalStopwatch.Stop()
    Write-Output "`n=== Pipeline Complete ==="
    Write-Output "Total time: $([math]::Round($totalStopwatch.Elapsed.TotalSeconds, 1))s"
    foreach ($r in $stepResults) {
        Write-Output "  $($r.name): $($r.duration_seconds)s"
    }
    Write-Output "`nNext: Agent should present final-report.json to user and await selection."
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
    exit 0
}
