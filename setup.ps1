# setup.ps1 — Environment compatibility check
function Main {
    Write-Output "=== Windows Residual Cleaner — Environment Check ==="
    $issues = @()

    # PowerShell version
    $psVersion = $PSVersionTable.PSVersion
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
    } else {
        Write-Output "`nEnvironment check FAILED:"
        $issues | ForEach-Object { Write-Output "  - $_" }
        exit 1
    }
    exit 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
