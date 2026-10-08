# setup.ps1 — Environment compatibility check
function Main {
    # ADR-001: 退出码用 [ref] 回传；Main 内不得 exit，也不得 `return <数字>`
    # （前者会杀死 dot-source 它的测试宿主 / 覆盖率插桩，后者会把整数漏进输出流）。
    param(
        [ref]$ExitCode,
        # 唯一的注入接缝：让「环境不满足 → 回传 1」这条分支可测
        # （宿主自身的 $PSVersionTable 在测试里改不了）。
        [string]$PSVersionOverride = ''
    )
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    Write-Output "=== Windows Residual Cleaner — Environment Check ==="
    $issues = @()

    # PowerShell version
    if ([string]::IsNullOrWhiteSpace($PSVersionOverride)) {
        $psVersion = $PSVersionTable.PSVersion
    } else {
        $psVersion = [Version]$PSVersionOverride
    }
    Write-Output "PowerShell: $psVersion"
    if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
        $issues += "PowerShell 5.1+ required (found: $psVersion)"
    }

    # Admin status
    $isAdmin = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Output "Administrator: $isAdmin"
    if (-not $isAdmin) {
        Write-Output "  (Warning: Admin required for cleanup operations)"
    }

    # Pester
    $pester = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if ($pester -and $pester.Version.Major -ge 5) {
        Write-Output "Pester: $($pester.Version) (OK)"
    } else {
        Write-Output "Pester: $($pester.Version) (Warning: 5.x+ recommended for tests)"
    }

    # Node.js (optional)
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $nodeVersion = & node --version
        Write-Output "Node.js: $nodeVersion (optional, for Web UI)"
    } else {
        Write-Output "Node.js: not found (optional, for Web UI)"
    }

    # Summary
    if ($issues.Count -eq 0) {
        Write-Output "`nEnvironment check PASSED."
        & $setRc 0
        return
    }
    Write-Output "`nEnvironment check FAILED:"
    $issues | ForEach-Object { Write-Output "  - $_" }
    & $setRc 1
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
