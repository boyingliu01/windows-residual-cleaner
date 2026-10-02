# run-all.ps1
# Unified scan pipeline: restore point → index → scan → report
# Responsibility: SCAN ONLY. Does not perform confirmation or cleanup.
param(
    [switch]$SkipRestorePoint = $false
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
    param([ref]$ExitCode)
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    if (-not (Test-AdminPrivilege -Mandatory)) { & $setRc 2; return }

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
        param([string]$Name, [string]$ScriptPath, [ref]$StepExitCode)
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
            # ADR-001: 不得 exit（会杀死测试宿主）。退出码用 [ref] 回传。
            # 不能用 `return <code>`：函数的返回值会混进管道，调用方拿到 Object[]
            # （日志文本 + 码），再传给 [int] 参数就报 "Cannot convert Object[] to Int32"。
            if ($null -ne $StepExitCode) { $StepExitCode.Value = $process.ExitCode }
            return
        }
        Write-Output "  → Completed in $($result.duration_seconds)s"
        $stepResults.Add($result)
        if ($null -ne $StepExitCode) { $StepExitCode.Value = 0 }
    }

    # 运行一个步骤，并通过 [ref] 回传它的退出码。
    # 注意：不能用 `return $code` —— Invoke-Step 会向同一管道写日志文本，
    # 调用方拿到的会是 Object[]（日志 + 码），再绑定到 [int] 参数即报
    # "Cannot convert Object[] to Int32"（已实测复现）。
    function Invoke-StepChecked {
        param([string]$Name, [string]$ScriptPath, [ref]$ResultCode)
        $stepRc = 0
        Invoke-Step -Name $Name -ScriptPath $ScriptPath -StepExitCode ([ref]$stepRc)
        if ($null -ne $ResultCode) { $ResultCode.Value = $stepRc }
    }

    # Step 1: Create restore point (optional)
    if (-not $SkipRestorePoint) {
        # ADR-001: 任一子步骤失败即中止（原行为由 Invoke-Step 内 exit 实现，
        # 现改为 [ref] 回传失败码 + 此处显式中止，以保持「不得在 Main 内 exit」的约定）
        $rc = 0
        Invoke-StepChecked -Name 'Create Restore Point' -ScriptPath "$scriptDir\create-restore-point.ps1" -ResultCode ([ref]$rc)
        if ($rc -ne 0) { & $setRc $rc; return }
    } else {
        # 业务日志用 Write-Output（Pester 拦截 warning 流导致测试无法通过 2>&1 捕获）
        Write-Output "Skipping restore point creation. Cleanup will NOT be recoverable."
    }

    # Step 2: Build installed software index
    $rc = 0
    Invoke-StepChecked -Name 'Build Installed Index' -ScriptPath "$scriptDir\build-installed-index.ps1" -ResultCode ([ref]$rc)
    if ($rc -ne 0) { & $setRc $rc; return }

    # Step 3: Scan uninstalled residuals
    $rc = 0
    Invoke-StepChecked -Name 'Scan Uninstalled' -ScriptPath "$scriptDir\scan-uninstalled.ps1" -ResultCode ([ref]$rc)
    if ($rc -ne 0) { & $setRc $rc; return }

    # Step 4: Scan filesystem residuals
    $rc = 0
    Invoke-StepChecked -Name 'Scan Filesystem' -ScriptPath "$scriptDir\scan-filesystem-residuals.ps1" -ResultCode ([ref]$rc)
    if ($rc -ne 0) { & $setRc $rc; return }

    # Step 5: Scan registry/service/task residuals
    $rc = 0
    Invoke-StepChecked -Name 'Scan Residuals' -ScriptPath "$scriptDir\scan-residuals.ps1" -ResultCode ([ref]$rc)
    if ($rc -ne 0) { & $setRc $rc; return }

    # Step 6: Generate final report
    $rc = 0
    Invoke-StepChecked -Name 'Generate Report' -ScriptPath "$scriptDir\generate-report.ps1" -ResultCode ([ref]$rc)
    if ($rc -ne 0) { & $setRc $rc; return }

    $totalStopwatch.Stop()
    Write-Output "`n=== Pipeline Complete ==="
    Write-Output "Total time: $([math]::Round($totalStopwatch.Elapsed.TotalSeconds, 1))s"
    foreach ($r in $stepResults) {
        Write-Output "  $($r.name): $($r.duration_seconds)s"
    }
    Write-Output "`nNext: Agent should present final-report.json to user and await selection."
    & $setRc 0
}

# ADR-001: Main 用 [ref] 回传退出码；不得 exit（会杀死测试宿主），也不得 `return <code>`
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
