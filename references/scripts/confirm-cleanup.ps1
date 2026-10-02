# confirm-cleanup.ps1
# 交互式确认清理项：按风险/分类浏览、选择/取消、保存确认列表
param(
    [string]$ReportPath = "$PSScriptRoot\..\..\final-report.json",
    [string]$OutputPath = "$PSScriptRoot\..\..\confirmed-ids.json",
    [switch]$NonInteractive = $false,
    [ValidateSet('safe','caution','all','none')]
    [string]$AutoSelect = 'none',
    [string]$SelectIds = ''
)

function Get-ItemContent {
    param([PSCustomObject]$Item, [string]$Category)
    switch ($Category) {
        'filesystem_residuals' { if ($Item.path) { return $Item.path } }
        'registry_residuals'   { if ($Item.key)  { return $Item.key } }
        'ghost_services'       { if ($Item.name)  { return "$($Item.name) -> $($Item.binary_path)" } }
        'ghost_tasks'          { if ($Item.name)  { return $Item.name } }
        'startup_residuals'    { if ($Item.name)  { return $Item.name } }
        'shell_residuals'      { if ($Item.key)   { return $Item.key } }
        'path_residuals'       { if ($Item.path)  { return $Item.path } }
    }
    return '[未知]'
}

function Limit-StringLength {
    param([string]$Str, [int]$MaxLen = 50)
    if ($Str.Length -gt $MaxLen) {
        return $Str.Substring(0, $MaxLen - 3) + '...'
    }
    return $Str
}

function Show-Page {
    param([int]$Page)
    $startIdx = $Page * $script:pageSize
    $endIdx = [Math]::Min($startIdx + $script:pageSize - 1, $script:totalItems - 1)

    Write-Output ""
    Write-Output ("=" * 80)
    Write-Output ("  残留项清理确认  第 {0}/{1} 页  共 {2} 项  已选 {3} 项" -f ($Page + 1), $script:totalPages, $script:totalItems, $script:selectedIds.Count)
    Write-Output ("=" * 80)
    Write-Output ""
    Write-Output "  #   选择  ID        风险      分类          内容"
    Write-Output ("-" * 80)

    for ($i = $startIdx; $i -le $endIdx; $i++) {
        $item = $script:sorted[$i]
        $num = $i - $startIdx + 1
        $sel = if ($script:selectedIds[$item.id]) { '*' } else { ' ' }
        $riskStr = $script:riskLabels[$item.risk]
        $contentShort = Limit-StringLength -Str $item.content -MaxLen 50
        $line = '  {0,-4}{1}    {2,-9}{3,-10}{4,-14}{5}' -f $num, $sel, $item.id, $riskStr, $item.catLabel, $contentShort
        Write-Output $line
    }

    Write-Output ("-" * 80)
    Write-Output "  命令: 数字=切换 | 1-5=范围 | A=全选本页 | C=取消本页 | SA=选Safe | CA=选Caution | CL=清空 | N/P=翻页 | D <id>=详情 | ?=帮助 | Q=保存 | X=退出"
}

function Show-Detail {
    param([string]$Id)
    $item = $script:sorted | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $item) {
        Write-Warning "未找到项: $Id"
        return
    }
    Write-Output ""
    Write-Output ("-" * 60)
    Write-Output "  ID:       $($item.id)"
    Write-Output "  风险:     $($script:riskLabels[$item.risk])"
    Write-Output "  分类:     $($item.catLabel)"
    Write-Output "  内容:     $($item.content)"
    Write-Output "  原因:     $($item.reason)"
    if ($item.size_mb -gt 0) {
        Write-Output "  大小:     $($item.size_mb) MB"
    }
    $rawItem = $item._item
    $props = $rawItem.PSObject.Properties | Where-Object { $_.Name -ne 'id' -and $_.Name -ne 'risk' -and $_.Name -ne 'reason' }
    foreach ($prop in $props) {
        $val = $prop.Value
        if ($null -ne $val -and $val -ne '' -and $val -ne 0) {
            Write-Output ("  {0,-10}{1}" -f ($prop.Name + ':'), $val)
        }
    }
    Write-Output ("-" * 60)
}

function Show-Help {
    Write-Output ""
    Write-Output "=== 帮助 ==="
    Write-Output "  数字(如 1,5)   切换该项选择状态"
    Write-Output "  范围(如 1-5)   切换范围内项"
    Write-Output "  A              选择本页所有项(跳过Danger)"
    Write-Output "  C              取消本页所有选择"
    Write-Output "  SA             选择所有Safe项"
    Write-Output "  CA             选择所有Caution项"
    Write-Output "  CL             清空所有选择"
    Write-Output "  N              下一页"
    Write-Output "  P              上一页"
    Write-Output "  D <id>         显示项详情(如 D fs_001)"
    Write-Output "  ?              显示此帮助"
    Write-Output "  Q              完成并保存"
    Write-Output "  X              退出不保存"
    Write-Output "=============="
}

function Get-PageRange {
    param([int]$Page)
    $startIdx = $Page * $script:pageSize
    $endIdx = [Math]::Min($startIdx + $script:pageSize - 1, $script:totalItems - 1)
    return @($startIdx, $endIdx)
}

function Main {
    # ADR-001: Main 通过 [ref] 回传退出码，绝不调用 exit，也绝不 `return <code>`。
    # 原因见 docs/decisions/ADR-001：exit 会杀死测试宿主致整份套件静默塌掉；
    # `return <code>` 会把整数写进 stdout 污染调用方的输出断言。
    param([ref]$ExitCode)

    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # Admin privilege check (warning only for read-only operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
    }

    if (-not $NonInteractive -and -not [Environment]::UserInteractive) {
        Write-Warning "非交互终端，无法运行交互式确认。请在 Windows Terminal 中运行此脚本，或使用 -NonInteractive 参数。"
        & $setRc 0
        return
    }

    if (-not (Test-Path $ReportPath)) {
        Write-Error "未找到报告文件: $ReportPath"
        & $setRc 1
        return
    }

    try {
        $report = Get-Content $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Error "无法解析报告文件: $_"
        & $setRc 1
        return
    }

    $categoryLabels = @{
        filesystem_residuals = '文件系统'
        registry_residuals  = '注册表'
        ghost_services      = '幽灵服务'
        ghost_tasks         = '计划任务'
        startup_residuals   = '启动项'
        shell_residuals     = 'COM/Shell'
        path_residuals      = 'PATH'
    }

    $riskOrder = @{ safe = 0; caution = 1; danger = 2 }
    $script:riskLabels = @{ safe = 'Safe'; caution = 'Caution'; danger = 'Danger' }

    $categoryKeys = @('filesystem_residuals','registry_residuals','ghost_services','ghost_tasks','startup_residuals','shell_residuals','path_residuals')

    $allItems = @()
    foreach ($catKey in $categoryKeys) {
        $catItems = $report.($catKey)
        if (-not $catItems) { continue }
        foreach ($item in $catItems) {
            $riskVal = $riskOrder[$item.risk]
            if ($null -eq $riskVal) { $riskVal = 1 }
            $sizeMb = 0
            if ($null -ne $item.size_mb) {
                $sizeMb = [double]$item.size_mb
            }
            $content = Get-ItemContent -Item $item -Category $catKey
            $itemObj = [PSCustomObject]@{
                id       = $item.id
                risk     = $item.risk
                riskVal  = $riskVal
                category = $catKey
                catLabel = $categoryLabels[$catKey]
                size_mb  = $sizeMb
                content  = $content
                reason   = if ($item.reason) { $item.reason } else { '' }
                _item    = $item
            }
            $allItems += $itemObj
        }
    }

    $script:sorted = $allItems | Sort-Object -Property riskVal, category, { - $_.size_mb }, id

    $script:selectedIds = @{}
    foreach ($item in $script:sorted) {
        if ($item.risk -eq 'safe') {
            $script:selectedIds[$item.id] = $true
        }
    }

    $script:pageSize = 20
    $script:totalItems = $script:sorted.Count
    $script:totalPages = [Math]::Ceiling($script:totalItems / [double]$script:pageSize)
    if ($script:totalPages -lt 1) { $script:totalPages = 1 }
    $currentPage = 0

    # --- Non-interactive batch export mode (for AI agent dialog workflow) ---
    if ($NonInteractive) {
        # Reset selections: non-interactive mode starts with empty selection
        $script:selectedIds = @{}

        # If SelectIds is provided, it takes precedence over AutoSelect
        if ($SelectIds -ne '') {
            try {
                $idList = $SelectIds | ConvertFrom-Json
                foreach ($id in $idList) {
                    $matched = $script:sorted | Where-Object { $_.id -eq $id } | Select-Object -First 1
                    if ($matched) {
                        if ($matched.risk -eq 'danger') {
                            Write-Warning "Skipping Danger item in SelectIds: $id"
                        } else {
                            $script:selectedIds[$id] = $true
                        }
                    } else {
                        Write-Warning "ID not found in report: $id"
                    }
                }
            } catch {
                Write-Error "Invalid SelectIds JSON: $_"
                & $setRc 1
                return
            }
        } elseif ($AutoSelect -ne 'none') {
            foreach ($item in $script:sorted) {
                if ($item.risk -eq 'danger') { continue }
                if ($AutoSelect -eq 'all' -or $item.risk -eq $AutoSelect) {
                    $script:selectedIds[$item.id] = $true
                }
            }
        } else {
            Write-Error "NonInteractive mode requires -AutoSelect or -SelectIds"
            & $setRc 1
            return
        }

        $safeCount = 0
        $cautionCount = 0
        $dangerCount = 0
        $confirmedIds = @()
        foreach ($item in $script:sorted) {
            if ($script:selectedIds[$item.id]) {
                $confirmedIds += $item.id
                switch ($item.risk) {
                    'safe'    { $safeCount++ }
                    'caution' { $cautionCount++ }
                    'danger'  { $dangerCount++ }
                }
            }
        }

        Write-Output "=== Non-interactive selection summary ==="
        Write-Output "  Safe:    $safeCount 项"
        Write-Output "  Caution: $cautionCount 项"
        Write-Output "  Danger:  $dangerCount 项"
        Write-Output "  Total:   $($confirmedIds.Count) 项"

        if ($confirmedIds.Count -eq 0) {
            Write-Warning "No items selected. Exiting without saving."
            & $setRc 0
            return
        }

        $jsonArray = ConvertTo-Json -InputObject $confirmedIds -Compress
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($OutputPath, $jsonArray, $utf8NoBom)
        Write-Output "Saved $($confirmedIds.Count) items to: $OutputPath"
        & $setRc 0
        return
    }

    Write-Output ""
    Write-Output "=== Windows 残留清理 - 交互式确认 ==="
    Write-Output "报告: $ReportPath"
    Write-Output ""

    $running = $true
    while ($running) {
        Show-Page -Page $currentPage

        $inputStr = ''
        try {
            $inputStr = Read-Host "请输入命令"
        } catch {
            Write-Warning "无法读取输入(非交互终端?)，退出不保存。"
            & $setRc 0
            return
        }

        $inputStr = $inputStr.Trim()
        if ([string]::IsNullOrEmpty($inputStr)) { continue }

        $upper = $inputStr.ToUpper()

        switch ($upper) {
            'N' {
                if ($currentPage -lt $script:totalPages - 1) { $currentPage++ }
                else { Write-Output "已是最后一页。" }
                continue
            }
            'P' {
                if ($currentPage -gt 0) { $currentPage-- }
                else { Write-Output "已是第一页。" }
                continue
            }
            'A' {
                $range = Get-PageRange -Page $currentPage
                for ($i = $range[0]; $i -le $range[1]; $i++) {
                    $item = $script:sorted[$i]
                    if ($item.risk -ne 'danger') {
                        $script:selectedIds[$item.id] = $true
                    }
                }
                Write-Output "已选择本页所有非Danger项。"
                continue
            }
            'C' {
                $range = Get-PageRange -Page $currentPage
                for ($i = $range[0]; $i -le $range[1]; $i++) {
                    $item = $script:sorted[$i]
                    $script:selectedIds.Remove($item.id)
                }
                Write-Output "已取消本页所有选择。"
                continue
            }
            'SA' {
                foreach ($item in $script:sorted) {
                    if ($item.risk -eq 'safe') {
                        $script:selectedIds[$item.id] = $true
                    }
                }
                Write-Output "已选择所有Safe项。"
                continue
            }
            'CA' {
                foreach ($item in $script:sorted) {
                    if ($item.risk -eq 'caution') {
                        $script:selectedIds[$item.id] = $true
                    }
                }
                Write-Output "已选择所有Caution项。"
                continue
            }
            'CL' {
                $script:selectedIds.Clear()
                Write-Output "已清空所有选择。"
                continue
            }
            '?' {
                Show-Help
                continue
            }
            'Q' {
                $running = $false
                continue
            }
            'X' {
                Write-Output "退出，未保存。"
                & $setRc 0
                return
            }
            default {
                if ($upper.StartsWith('D ')) {
                    $detailId = $inputStr.Substring(2).Trim()
                    Show-Detail -Id $detailId
                    continue
                }

                if ($inputStr -match '^\d+-\d+$') {
                    $parts = $inputStr -split '-'
                    $lo = [int]$parts[0]
                    $hi = [int]$parts[1]
                    if ($lo -gt $hi) {
                        $tmp = $lo; $lo = $hi; $hi = $tmp
                    }
                    $range = Get-PageRange -Page $currentPage
                    for ($n = $lo; $n -le $hi; $n++) {
                        $idx = $range[0] + $n - 1
                        if ($idx -ge $range[0] -and $idx -le $range[1]) {
                            $item = $script:sorted[$idx]
                            if ($script:selectedIds[$item.id]) {
                                $script:selectedIds.Remove($item.id)
                            } else {
                                if ($item.risk -eq 'danger') {
                                    Write-Warning "  不能选择Danger项: $($item.id)"
                                } else {
                                    $script:selectedIds[$item.id] = $true
                                }
                            }
                        }
                    }
                    continue
                }

                if ($inputStr -match '^\d+$') {
                    $num = [int]$inputStr
                    $range = Get-PageRange -Page $currentPage
                    $idx = $range[0] + $num - 1
                    if ($idx -ge $range[0] -and $idx -le $range[1]) {
                        $item = $script:sorted[$idx]
                        if ($script:selectedIds[$item.id]) {
                            $script:selectedIds.Remove($item.id)
                        } else {
                            if ($item.risk -eq 'danger') {
                                Write-Warning "  不能选择Danger项: $($item.id)"
                            } else {
                                $script:selectedIds[$item.id] = $true
                            }
                        }
                    } else {
                        Write-Warning "  编号超出范围(1-$($range[1] - $range[0] + 1))。"
                    }
                    continue
                }

                Write-Warning "未知命令: $inputStr (输入 ? 查看帮助)"
            }
        }
    }

    $safeCount = 0
    $cautionCount = 0
    $dangerCount = 0
    $confirmedIds = @()
    foreach ($item in $script:sorted) {
        if ($script:selectedIds[$item.id]) {
            $confirmedIds += $item.id
            switch ($item.risk) {
                'safe'    { $safeCount++ }
                'caution' { $cautionCount++ }
                'danger'  { $dangerCount++ }
            }
        }
    }

    Write-Output ""
    Write-Output "=== 确认摘要 ==="
    Write-Output "  Safe:    $safeCount 项"
    Write-Output "  Caution: $cautionCount 项"
    Write-Output "  Danger:  $dangerCount 项"
    Write-Output "  总计:    $($confirmedIds.Count) 项"
    Write-Output ""

    if ($confirmedIds.Count -eq 0) {
        Write-Warning "未选择任何项。退出不保存。"
        & $setRc 0
        return
    }

    $confirmInput = ''
    try {
        $confirmInput = Read-Host "确认保存? (Y/N)"
    } catch {
        Write-Warning "无法读取输入，退出不保存。"
        & $setRc 0
        return
    }

    if ($confirmInput.Trim().ToUpper() -ne 'Y') {
        Write-Output "取消，未保存。"
        & $setRc 0
        return
    }

    $jsonArray = ConvertTo-Json -InputObject $confirmedIds -Compress
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($OutputPath, $jsonArray, $utf8NoBom)

    Write-Output ""
    Write-Output "已保存 $($confirmedIds.Count) 项到: $OutputPath"
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
# $MyInvocation.InvocationName is '.' when dot-sourced, empty when run via -File
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
