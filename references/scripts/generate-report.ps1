# generate-report.ps1
# Consolidates all scan outputs into final JSON report with risk classification and unique IDs
param(
    [string]$DataDir = "$PSScriptRoot\..\..",
    [string]$OutputPath = "$PSScriptRoot\..\..\final-report.json"
)

# 修复：直接修改 hashtable 条目，避免 [ref] 对值类型的引用丢失
# PowerShell 的 hashtable 值是 by-value 返回的，[ref]$counters.fs 指向临时拷贝
function Set-Id {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param([hashtable]$counters, [string]$key, [string]$prefix)
    $counters[$key]++
    return "{0}{1:D3}" -f $prefix, $counters[$key]
}

function Main {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # Admin privilege check (warning only for read-only operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
    }

    # Load scan outputs
    $missingFiles = @()
    if (-not (Test-Path "$DataDir\uninstalled-list.json")) { $missingFiles += "uninstalled-list.json" }
    if (-not (Test-Path "$DataDir\fs-residuals.json")) { $missingFiles += "fs-residuals.json" }
    if (-not (Test-Path "$DataDir\other-residuals.json")) { $missingFiles += "other-residuals.json" }
    if ($missingFiles.Count -gt 0) {
        Write-Error "Required input files not found: $($missingFiles -join ', ')"
        exit 3
    }
    $uninstalled = Get-Content "$DataDir\uninstalled-list.json" -Raw | ConvertFrom-Json
    $fs = Get-Content "$DataDir\fs-residuals.json" -Raw | ConvertFrom-Json
    $other = Get-Content "$DataDir\other-residuals.json" -Raw | ConvertFrom-Json

    # ID counters with D3 zero-padding
    # fs_XXX = filesystem, reg_XXX = registry, svc_XXX = ghost_services,
    # tsk_XXX = ghost_tasks, str_XXX = startup_residuals,
    # shl_XXX = shell_residuals (COM/ContextMenu), path_XXX = PATH entries
    $counters = @{fs=0; reg=0; svc=0; tsk=0; str=0; shl=0; path=0}

    # Assign IDs to filesystem residuals
    $fsItems = @()
    foreach ($item in $fs) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'fs' 'fs_')
        $fsItems += $item
    }

    # Assign IDs to registry residuals
    $regItems = @()
    foreach ($item in $other.registry_residuals) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'reg' 'reg_')
        $regItems += $item
    }

    # Assign IDs to ghost services
    $svcItems = @()
    foreach ($item in $other.ghost_services) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'svc' 'svc_')
        $svcItems += $item
    }

    # Assign IDs to ghost tasks
    $tskItems = @()
    foreach ($item in $other.ghost_tasks) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'tsk' 'tsk_')
        $tskItems += $item
    }

    # Assign IDs to startup residuals
    $strItems = @()
    foreach ($item in $other.startup_residuals) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'str' 'str_')
        $strItems += $item
    }

    # Assign IDs to shell residuals (COM/ContextMenu)
    $shlItems = @()
    foreach ($item in $other.shell_residuals) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'shl' 'shl_')
        $shlItems += $item
    }

    # Assign IDs to PATH residuals
    $pathItems = @()
    foreach ($item in $other.path_residuals) {
        $item | Add-Member -NotePropertyName 'id' -NotePropertyValue (Set-Id $counters 'path' 'path_')
        $pathItems += $item
    }

    # Aggregate all items
    $allItems = @($fsItems; $regItems; $svcItems; $tskItems; $strItems; $shlItems; $pathItems) | Where-Object { $_ }

    # Compute summary statistics
    $safeCount = ($allItems | Where-Object { $_.risk -eq 'safe' }).Count
    $cautionCount = ($allItems | Where-Object { $_.risk -eq 'caution' }).Count
    $dangerCount = ($allItems | Where-Object { $_.risk -eq 'danger' }).Count
    $estimatedSpace = [math]::Round(($fsItems | Measure-Object -Property size_mb -Sum -ErrorAction SilentlyContinue).Sum, 1)

    # Generate report
    $report = @{
        scan_time = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        summary = @{
            total_residuals = $allItems.Count
            safe = $safeCount
            caution = $cautionCount
            danger = $dangerCount
            estimated_space_recoverable_mb = $estimatedSpace
        }
        uninstalled_software = $uninstalled.uninstalled_software
        # Include candidate_directories from scan-uninstalled.ps1 (L1-T8 fix)
        candidate_directories = if ($uninstalled.candidate_directories) {
            $uninstalled.candidate_directories
        } else { @() }
        filesystem_residuals = $fsItems
        registry_residuals = $regItems
        ghost_services = $svcItems
        ghost_tasks = $tskItems
        startup_residuals = $strItems
        shell_residuals = $shlItems
        path_residuals = $pathItems
    }

    # Output UTF-8 without BOM
    $jsonContent = $report | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($OutputPath, $jsonContent, [System.Text.UTF8Encoding]::new($false))

    Write-Output "Report generated: $($allItems.Count) items (Safe: $safeCount, Caution: $cautionCount, Danger: $dangerCount)"
    Write-Output "Output: $OutputPath"
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    Main
    exit 0
}
