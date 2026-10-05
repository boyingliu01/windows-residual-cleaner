# clean-residuals.ps1
# 执行清理：支持四模式确认流程 + 白名单二次校验 + dry-run + Danger 过滤
param(
    [string]$ReportPath = "$PSScriptRoot\..\..\final-report.json",
    [string]$WhitelistPath = "$PSScriptRoot\..\config\whitelist.json",
    [string]$ItemsToClean = "",   # JSON array of IDs, e.g. '["fs_001","svc_001"]'
    [string]$ConfirmFile = "",   # Path to confirmed-ids.json (output of confirm-cleanup.ps1)
    [ValidateSet('A','B','C','D')]
    [string]$Mode = 'D',         # A=Auto-clean Safe, B=Safe auto + Caution confirm, C=Full review, D=Report only
    [switch]$DryRun = $false,    # Dry-run mode: log actions without executing
    [switch]$NoAutoRollback = $false,          # REQ-012: skip THIS run's rollback only (journal still written, T3 still runs)
    [switch]$AcknowledgeConflicts = $false,    # REQ-030: human exit for conflict entries
    [string]$ProjectRootOverride = ""          # 测试注入点：backup-*/output/ 的落点
)

# ─────────────────────────────────────────────────────────────────────────────
# 回滚写入端依赖（REQ-005 / REQ-006 / REQ-024）
#
# dot-source 顺序即依赖顺序：journal（Get-ItemId / 原子写）→ backup（reg 导出与裁剪）
# → verdicts（REQ-024 唯一权威决策表）→ recovery（窗口/标记/未修复清单）
# → exec（探测与恢复执行层）→ producer（写入端记账原语）。
#
# 注意（AGENTS.md 陷阱 8a）：这些库文件**没有**顶层 param()，因此 dot-source 不会
# 把同名参数默认值冲进本作用域；若将来给它们加顶层 param，必须重新检查此处。
# ─────────────────────────────────────────────────────────────────────────────
$rollbackLibOrder = @('rollback-journal.ps1', 'rollback-backup.ps1', 'rollback-verdicts.ps1',
                      'rollback-recovery.ps1', 'rollback-exec.ps1', 'rollback-producer.ps1')
$script:RollbackLibsMissing = @()
foreach ($libName in $rollbackLibOrder) {
    $libPath = Join-Path $PSScriptRoot $libName
    if (-not (Test-Path -LiteralPath $libPath)) {
        $script:RollbackLibsMissing += $libName
        continue
    }
    . $libPath
}
# 库缺失时**不**在此中止（dot-source 发生在顶层，中止会让宿主退出）：
# 由 Main 的前置门禁 fail-closed 返回 3（REQ-026 依赖缺失）。

# 可靠地调用 sc.exe，替代裸 `sc.exe ... 2>$null` 写法。
#
# 背景（PS 5.1 陷阱 #7）: `powershell.exe` 宿主在同时满足「stdout 未重定向」与
# 「stderr 被重定向」时，会抛出
#   StandardOutputEncoding/StandardErrorEncoding is only supported when ... redirected
# 因此 `sc.exe stop X 2>$null` 与 `sc.exe delete X 2>&1` 在本项目基线上**必然抛异常**：
#   - Phase 1 的 stop 永远失败 → 幽灵服务根本不会被停止
#   - Phase 2 的 delete 异常被 catch → 记为 cleanup_failed，且 $LASTEXITCODE 为空
# 干净的 sc.exe 输出不带引号，无法用 `cmd /c "... 2>&1"` 包裹（会在引号处截断参数），
# 故改用 Start-Process 显式重定向两个流：任何流重定向都能规避该 bug。
#
# 注意: Start-Process -Wait 对带 UI 的进程会提前返回，sc.exe 是控制台程序，
# 退出时其子进程已全部结束，因此不需要额外的 Handle 排空逻辑。
function Invoke-ScExe {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    $scPath = Join-Path $env:SystemRoot 'System32\sc.exe'
    if (-not (Test-Path $scPath)) {
        return @{ ok = $false; output = ''; exit_code = $null; error = "sc.exe not found at $scPath" }
    }

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $scPath `
            -ArgumentList $Arguments `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -ErrorAction Stop

        # 文件总是存在（GetTempFileName 已创建），读取仅用于获取进程输出。
        # 用 -ErrorAction SilentlyContinue 而非空 catch 块（PSAvoidUsingEmptyCatchBlock）。
        $stdout = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }

        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) {
            return @{ ok = $false; output = $stdout.Trim(); exit_code = $null; error = "sc.exe returned no exit code (timeout ${TimeoutSeconds}s?)" }
        }

        return @{
            ok        = ($exitCode -eq 0)
            output    = $stdout.Trim()
            exit_code = $exitCode
            error     = if ($exitCode -eq 0) { '' } else { (($stdout + "`n" + $stderr).Trim()) }
        }
    } catch {
        # Start-Process 自身失败（如权限不足 / sc.exe 被安全软件拦截）：
        # exit_code 保持 $null 以区别于"sc.exe 正常运行并返回了退出码"，
        # 调用方必须把 $null 视为失败，不能当成 1060（服务不存在）而静默放过。
        return @{ ok = $false; output = ''; exit_code = $null; error = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# Robust file deletion with fallback strategies for locked/permission-denied files
#
# -Outcome（REQ-002 / AC-016）：布尔返回值只回答「目标路径是否已不可见」，
# 无法区分「真删了」与「Tier-4 改名延迟删除」。调用方据此把真实结果写进日志，
# 否则一份仍躺在磁盘上的 `~X.deleted` 会被报告成「已删除」——而 DD-006 明确
# 规定重命名内容**不**参与自动恢复，谎报会直接让用户失去找回它的时间窗。
# 取值：dry_run / absent / deleted / renamed:<新名> / failed。
function Remove-ItemRobust {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess','')]
    param([string]$Path, [switch]$WhatIf, [ref]$Outcome)

    $setOutcome = { param($v) if ($null -ne $Outcome) { $Outcome.Value = $v } }

    if ($WhatIf) { & $setOutcome 'dry_run'; return $true }
    if (-not (Test-Path $Path)) { & $setOutcome 'absent'; return $true }

    # Strategy 1: Standard PowerShell Remove-Item
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        & $setOutcome 'deleted'
        return $true
    } catch {
        $err1 = $_.Exception.Message
        Write-Warning "  → Standard delete failed: $err1"
    }

    # Strategy 2: Take ownership + grant full access, then retry
    try {
        # takeown /f for files, /r for recursive on directories
        $isDir = (Get-Item $Path).PSIsContainer
        if ($isDir) {
            $takeownArgs = '/r', '/d', 'Y', '/f', $Path
        } else {
            $takeownArgs = '/f', $Path
        }
        $takeown = Start-Process -FilePath 'takeown.exe' -ArgumentList $takeownArgs -Wait -PassThru -WindowStyle Hidden
        if ($takeown.ExitCode -ne 0) {
            Write-Warning "  → takeown.exe failed with exit code $($takeown.ExitCode)"
        }

        # icacls grant Administrators full control
        if ($isDir) {
            $icaclsArgs = $Path, '/grant', 'Administrators:F', '/T', '/C'
        } else {
            $icaclsArgs = $Path, '/grant', 'Administrators:F', '/C'
        }
        $icacls = Start-Process -FilePath 'icacls.exe' -ArgumentList $icaclsArgs -Wait -PassThru -WindowStyle Hidden
        if ($icacls.ExitCode -ne 0) {
            Write-Warning "  → icacls.exe failed with exit code $($icacls.ExitCode)"
        }

        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        & $setOutcome 'deleted'
        return $true
    } catch {
        $err2 = $_.Exception.Message
        Write-Warning "  → Takeown+ACL delete failed: $err2"
    }

    # Strategy 3: cmd rd /s /q (sometimes works where PS fails)
    try {
        $isDir = (Get-Item $Path).PSIsContainer
        if ($isDir) {
            cmd /c "rd /s /q `"$Path`"" 2>&1
            if ($LASTEXITCODE -eq 0 -and -not (Test-Path $Path)) { & $setOutcome 'deleted'; return $true }
        } else {
            cmd /c "del /f /q `"$Path`"" 2>&1
            if ($LASTEXITCODE -eq 0 -and -not (Test-Path $Path)) { & $setOutcome 'deleted'; return $true }
        }
    } catch {
        Write-Warning "  → cmd delete failed: $($_.Exception.Message)"
    }

    # Strategy 4: Rename the file/directory (if deletion is blocked by handle)
    try {
        $isDir = (Get-Item $Path).PSIsContainer
        $parent = Split-Path $Path -Parent
        $leaf = Split-Path $Path -Leaf
        $renamed = Join-Path $parent "~$leaf.deleted"
        $counter = 0
        while (Test-Path $renamed) {
            $counter++
            $renamed = Join-Path $parent "~$leaf.deleted$counter"
        }
        Rename-Item -Path $Path -NewName (Split-Path $renamed -Leaf) -Force -ErrorAction Stop
        Write-Output "  → Renamed to $(Split-Path $renamed -Leaf) (deferred delete - may be in use)"
        # REQ-002：改名不是删除。内容仍在磁盘上（只是换了名字），必须回传 renamed:<新名>，
        # 由调用方如实记录并供人工定位；DD-006 规定这类条目不参与自动恢复。
        & $setOutcome ('renamed:' + (Split-Path $renamed -Leaf))

        # If it's a file, try to schedule it for deletion on next reboot using MoveFileEx
        if (-not $isDir) {
            try {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Delete {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
    public const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;
}
"@ -ErrorAction SilentlyContinue
                [Win32Delete]::MoveFileEx($renamed, $null, [Win32Delete]::MOVEFILE_DELAY_UNTIL_REBOOT) | Out-Null
            } catch { Write-Verbose "MoveFileEx delayed-delete failed for $renamed" }
        }
        return $true
    } catch {
        Write-Warning "  → Rename fallback also failed: $($_.Exception.Message)"
    }

    & $setOutcome 'failed'
    return $false
}

function Test-Whitelisted {
    param([string]$Path, [string]$Key, [string]$ServiceName)
    if (-not $whitelist) { return $false }
    if ($Key -and $whitelist.registry_patterns) {
        foreach ($wp in $whitelist.registry_patterns) {
            if ($Key -match $wp.pattern) { return $true }
        }
    }
    if ($Path -and $whitelist.path_patterns) {
        foreach ($wp in $whitelist.path_patterns) {
            if ($Path -match $wp.pattern) { return $true }
        }
    }
    if ($ServiceName -and $whitelist.service_names -contains $ServiceName) { return $true }
    return $false
}

# Admin privilege check (mandatory for write operations)
function Test-AdminPrivilege {
    [CmdletBinding()]
    param([switch]$Mandatory)
    $isAdmin = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if ($Mandatory) {
            Write-Error "Administrator privileges required. Please run PowerShell as Administrator."
            # 注意：这里**不能** exit。exit 在 Pester 进程内会终止宿主，
            # 导致整份测试套件静默塌掉（见 docs/decisions/ADR-001）。
            # 由调用方检查返回值并决定退出码。
            return $false
        } else {
            Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
        }
    }
    return $isAdmin
}

# ─────────────────────────────────────────────────────────────────────────────
# 回滚写入端接缝（REQ-005 / REQ-017 / REQ-018）
#
# 这三个函数把「记账」与「变更」分开：Main 只决定何时变更，这里决定
# 状态如何推进、以及**每次推进都必须原子落盘**（REQ-005 的崩溃窗口契约）。
# ─────────────────────────────────────────────────────────────────────────────

function Get-OptionalProtectionStatus {
    <#
    .SYNOPSIS
        可选层（系统还原点）的真实状态（REQ-014 / REQ-025 / AC-035）。
    .DESCRIPTION
        **只读**，且**绝不**用作中止条件——那是强制精准保护（REQ-017(a)）的职责。
        create-restore-point.ps1 把 restore-status.json 写在它自己的 backup-<时间戳>
        目录里，所以这里取「最近一次写入」的那份来看。本轮自己创建的
        backup-<run_id> 目录里没有该文件，不会被误判成「还原点已就绪」。
        返回 @{ Enabled; Detail }。
    #>
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $latest = $null
    try {
        $files = @(Get-ChildItem -Path (Join-Path $ProjectRoot 'backup-*') -Filter 'restore-status.json' `
                    -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($files.Count -gt 0) { $latest = $files[0] }
    } catch { $latest = $null }

    if ($null -eq $latest) {
        return @{ Enabled = $false; Detail = 'restore-status.json 不存在（从未运行 create-restore-point.ps1，或该步骤失败）' }
    }
    try {
        $doc = [System.IO.File]::ReadAllText($latest.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        return @{ Enabled = $false; Detail = ("restore-status.json 不可解析: {0}" -f $latest.FullName) }
    }
    $enabled = [bool]$doc.restore_point_enabled
    $detail = ("来源 {0}（restore_point_enabled={1}）" -f $latest.FullName, $enabled)
    return @{ Enabled = $enabled; Detail = $detail }
}

function New-RollbackPlannedEntry {
    <#
    .SYNOPSIS
        为一条破坏性变更登记 state=planned 并**立即落盘**（REQ-005 / REQ-018）。
    .DESCRIPTION
        「变更登记在变更之前」是 T3 能区分「本轮没碰过这项」与「碰过但没记成功」的
        唯一手段：缺了它，恢复端只能按 REQ-024 规则 4 把每个消失的目标都判成
        conflict（无法证明是我们删的），整个自动回滚就退化成人工介入。
        落盘失败返回 Ok=$false + reason，调用方必须停止该条目的后续变更（fail-closed）。
    #>
    # -DryRun 已是本脚本的 WhatIf 等价物，且经 UI/管道宿主非交互拉起，ShouldProcess 提示会挂死管道。
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$Journal,
        [string]$BackupDir,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][ValidateSet('registry_key', 'startup_value', 'path_entry', 'path_deleted', 'service', 'task')][string]$Kind,
        [bool]$PreExisting = $true,
        [hashtable]$ExtraFields
    )

    if ($null -eq $Journal) {
        return @{ Ok = $false; ItemId = ''; Reason = 'journal_absent' }
    }

    $target = ConvertTo-RollbackJournalTarget -Kind $Kind -Item $Item
    if ([string]::IsNullOrWhiteSpace($target)) {
        return @{ Ok = $false; ItemId = ''; Reason = 'journal_target_empty' }
    }

    $entry = ConvertTo-RollbackJournalEntry -Id ([string]$Item.id) -Kind $Kind -Target $target `
        -PreExisting ([bool]$PreExisting)
    if ($ExtraFields) {
        foreach ($k in $ExtraFields.Keys) { $entry[$k] = $ExtraFields[$k] }
    }
    $null = Add-RollbackJournalEntry -Journal $Journal -Entry $entry

    $flush = Write-RollbackJournalSafely -BackupDir $BackupDir -Journal $Journal
    return @{
        Ok     = [bool]$flush.Ok
        ItemId = [string]$entry['item_id']
        Reason = [string]$flush.Reason
    }
}

function Set-RollbackEntryState {
    <#
    .SYNOPSIS
        推进某条回滚日志条目的状态并**立即落盘**（REQ-018 状态机）。
    .DESCRIPTION
        item_id 不存在时返回 journal_entry_missing：静默丢状态会让崩溃窗口
        重新出现（日志说「从未备份」而实际已删）。
        Journal 为 $null（DryRun / 无需保护）时按「无操作」成功返回，
        使调用方不需要为 DryRun 写一条分支——但也绝不落盘。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$Journal,
        [string]$BackupDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ItemId,
        [Parameter(Mandatory)][hashtable]$Fields
    )

    if ($null -eq $Journal) { return @{ Ok = $true; Reason = '' } }
    if (-not (Update-RollbackJournalEntry -Journal $Journal -ItemId $ItemId -Fields $Fields)) {
        return @{ Ok = $false; Reason = 'journal_entry_missing' }
    }
    $flush = Write-RollbackJournalSafely -BackupDir $BackupDir -Journal $Journal
    return @{ Ok = [bool]$flush.Ok; Reason = [string]$flush.Reason }
}

function Set-MachinePathValue {
    <#
    .SYNOPSIS
        写入 Machine PATH 并**回读**实际生效值（REQ-001 单次读-改-写的落点）。
    .DESCRIPTION
        `[Environment]::SetEnvironmentVariable('Path', …, 'Machine')` 在非管理员或
        组策略锁定下**静默失败**，不抛异常也不返回状态——把它当成功就是谎报。
        因此本函数的契约是「回读到的整串」，调用方必须逐段确认目标确实消失
        （与恢复端 rollback-exec 的 $SetPathScript 接缝同一语义）。
        独立成函数也是为了给单测一个可 Mock 的接缝：测试不得真的改动本机 PATH。
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    [Environment]::SetEnvironmentVariable('Path', $Value, 'Machine')
    try {
        return [Environment]::GetEnvironmentVariable('Path', 'Machine')
    } catch {
        return $null
    }
}

function Add-CleanupFailure {
    <#
    .SYNOPSIS
        向清理日志追加一条失败记录（供 Main 的 fail-closed 分支复用）。
    .DESCRIPTION
        停止后续破坏性操作时，被中断的那一条**必须**在日志里留下记录：
        否则人类报告会是「N 项成功，无失败」，而实际有一项卡在半途。
        这里写入调用方传入的 List（引用类型），避免 Main 里的同名局部变量遮蔽。
    #>
    param(
        [Parameter(Mandatory)][object]$Log,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ErrorText
    )

    $null = $Log.Add(@{ id = [string]$Item.id; action = 'cleanup_failed'; error = $ErrorText; success = $false })
    return $Log.Count
}

function Main {
    # ADR-001: Main 通过 [ref] 回传退出码，绝不调用 exit，也绝不 `return <code>`。
    #
    # 为什么不用 `return 1` / `exit (Main)`：
    #   1. `return 1` 会把整数写进**输出流**（PowerShell 函数返回语义），污染调用方
    #      stdout —— 现有测试用 `(Main 2>&1) -join` 断言输出文本，会被数字污染。
    #   2. `exit (Main)` 会让 PowerShell 先求值 `Main`，其输出被吞进 exit 的参数
    #      表达式，宿主随即退出，**此前的 Write-Output 全部丢失**（实测确认）。
    #   3. `exit` 在 dot-source + 进程内调用（测试 / 覆盖率插桩）时会杀死宿主，
    #      使 Pester 收尾崩溃、整份套件静默消失（本 sprint 的 blocker B1）。
    #
    #   `[ref]` 方案：stdout 保持纯净，退出码单独回传，进程内调用完全安全。
    #   注意 AGENTS.md 陷阱 #1（[ref]+[CmdletBinding] 失效）不适用于此：Main 无该注解。
    param([ref]$ExitCode)

    # 设置退出码的便捷脚本块（未传 [ref] 时静默忽略，便于旧调用方兼容）
    $setRc = { param([int]$v) if ($null -ne $ExitCode) { $ExitCode.Value = $v } }

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    if (-not (Test-AdminPrivilege -Mandatory)) {
        & $setRc 2
        return
    }

    # REQ-017/REQ-025：「强制精准保护」门禁挪到筛选出待清理项之后（见 Phase 0），
    # 因为门禁要回答的是「本轮是否真的有破坏性操作要保护」，以及「本轮是否有 PATH
    # 条目要删」（REQ-003(c) 只在有 PATH 条目时才要求捕获原值）。
    # 旧实现在这里检查 `backup-*` 目录是否存在（B-M7），把**可选系统还原点**当成了
    # 清理的前置条件：还原点不可用的机器永远无法清理，而自己创建的备份目录又会被
    # glob 匹配到从而让门禁形同虚设——两层保护必须分开（REQ-025 / AC-035）。

    $projectRoot = $ProjectRootOverride
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }

    # --- 加载白名单（Defense-in-Depth: 清理前二次校验） ---
    $script:whitelist = $null
    if (Test-Path $WhitelistPath) {
        try {
            $script:whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json
        } catch {
            Write-Warning "Failed to load whitelist: $_"
        }
    }

    # --- 加载报告并按模式筛选项目 ---
    try {
        $report = Get-Content $ReportPath -Raw | ConvertFrom-Json
    } catch {
        $errMsg = $_.Exception.Message
        Write-Error ("Failed to load report from {0}: {1}" -f $ReportPath, $errMsg)
        & $setRc 1
         return
    }

    # 汇总所有项目到统一列表（含 shell_residuals 分类）
    $allItems = @()
    foreach ($cat in @('filesystem_residuals','registry_residuals','ghost_services','ghost_tasks','startup_residuals','shell_residuals','path_residuals')) {
        $items = $report.$cat
        if ($items) {
            if ($items -is [array] -or $items -is [System.Collections.IList]) {
                $allItems += @($items)
            } else {
                $allItems += $items
            }
        }
    }
    # B-M4 修复：按 Mode 筛选
    # Mode A: 自动清理 Safe 项
    # Mode B: 自动清理 Safe 项，Caution 项仅标记（用户需逐项确认，由调用者控制）
    # Mode C: 全量审阅（Safe + Caution），Danger 保留
    # Mode D: 仅报告，不清理
    # 如果指定了 ConfirmFile，则跳过 Mode 筛选，直接使用用户确认的 ID 列表
    # 注意：变量名必须用 $cleanupItems 而非 $itemsToClean，因为参数 $ItemsToClean
    # 是 [string] 类型，PS 变量不区分大小写，会导致类型约束冲突
    if ($ConfirmFile -ne '') {
        # ConfirmFile 模式：ConfirmFile 是唯一删除依据（用户已通过 confirm-cleanup.ps1 确认）。
        # 安全关键（fail-closed）：文件缺失 / 无法解析 / 内容为空时必须立即中止。
        # 否则 cleanupItems 会回退到"全部非 danger"集合，导致越界删除所有残留
        # （历史 Critical 缺陷：调用方传入错误的相对路径 → Test-Path 失败 → 静默全清）。
        if (-not (Test-Path $ConfirmFile)) {
            Write-Error "ConfirmFile not found: '$ConfirmFile'. Aborting to prevent over-deletion. Pass an absolute path."
            & $setRc 1
             return
        }
        try {
            $confirmedIds = Get-Content $ConfirmFile -Raw | ConvertFrom-Json
        } catch {
            Write-Error "Failed to parse ConfirmFile '$ConfirmFile': $_. Aborting."
            & $setRc 1
             return
        }
        if (-not $confirmedIds) {
            Write-Error "ConfirmFile '$ConfirmFile' contains no confirmed IDs. Aborting (nothing to clean)."
            & $setRc 1
             return
        }
        # 以确认 ID 为权威集合，并保留 danger 双层拦截作为纵深防御
        $cleanupItems = @($allItems | Where-Object { $confirmedIds -contains $_.id -and $_.risk -ne 'danger' })
        Write-Output "Loaded $(@($confirmedIds).Count) confirmed IDs from $ConfirmFile, matched $($cleanupItems.Count) items"
    } else {
        switch ($Mode) {
            'A' { $cleanupItems = @($allItems | Where-Object { $_.risk -eq 'safe' }) }
            'B' { $cleanupItems = @($allItems | Where-Object { $_.risk -eq 'safe' }) }
            'C' { $cleanupItems = @($allItems | Where-Object { $_.risk -ne 'danger' }) }
            'D' { Write-Output "Report-only mode. No cleanup performed."; & $setRc 0; return }
        }
    }

    # 如果指定了具体 ID，则进一步过滤（B-m3 修复：try/catch）
    if ($ItemsToClean) {
        try {
            $ids = $ItemsToClean | ConvertFrom-Json
            $cleanupItems = @($cleanupItems | Where-Object { $ids -contains $_.id })
        } catch {
            Write-Warning "Invalid ItemsToClean JSON format. Ignoring filter."
        }
    }

    # --- Three-phase batch processing ---
    $log = [System.Collections.Generic.List[Hashtable]]::new()
    $prefix = if ($DryRun) { "[DRY-RUN] " } else { "" }

    # Pre-filter: whitelist + danger (applies to all phases)
    # 业务日志用 Write-Output（非 Warning）：Pester 拦截 warning 流导致 2>&1 无法捕获，
    # 且这些消息是正常流程状态而非告警
    $eligibleItems = @()
    foreach ($item in $cleanupItems) {
        if (Test-Whitelisted -Path $item.path -Key $item.key -ServiceName $item.name) {
            Write-Output "$prefix SKIP (whitelisted): $($item.id)"
            $log.Add(@{ id=$item.id; action='skipped_whitelisted'; success=$false })
            continue
        }
        if ($item.risk -eq 'danger') {
            Write-Output "$prefix SKIP (danger): $($item.id) - $($item.reason)"
            $log.Add(@{ id=$item.id; action='skipped_danger'; success=$false })
            continue
        }
        $eligibleItems += $item
    }

    # ── Phase 0: 强制精准保护门禁 + 回滚日志（REQ-003 / REQ-005 / REQ-017 / REQ-025）──
    # 意图判定保留 B-M7 想堵的 UI 缺口：UI 走 ConfirmFile 触发、Mode 仍是默认 'D'。
    # 本轮没有任何可清理项时不建保护：没有破坏性操作就没有需要记录的状态，
    # 建出来的空日志反而会被下一轮当成 T3 候选（REQ-030「无可处理条目→告警后继续」）。
    $willDelete = (-not $DryRun) -and ($ConfirmFile -ne '' -or $Mode -ne 'D')
    $needsProtection = $willDelete -and (@($eligibleItems).Count -gt 0)

    $runId = ''
    $backupDir = ''
    $journal = $null
    $machinePathOriginal = $null
    $persistenceError = $false

    if ($needsProtection) {
        if (@($script:RollbackLibsMissing).Count -gt 0) {
            Write-Error ("回滚保护组件缺失: {0}。已中止，未删除任何内容。" -f ($script:RollbackLibsMissing -join ', '))
            & $setRc 3
            return
        }

        $regExePath = Join-Path $env:SystemRoot 'System32\reg.exe'
        if (-not (Test-Path -LiteralPath $regExePath)) {
            Write-Error "reg.exe 不可用（$regExePath）。无法为注册表变更建立备份，已中止，未删除任何内容。"
            & $setRc 3
            return
        }
        $regProbe = Invoke-RegExe -Arguments @('query', 'HKCU\Software\Microsoft')
        if (-not $regProbe.ok) {
            Write-Error ("reg.exe 无法执行（退出码 {0}）: {1}。逐项备份不可用，已中止，未删除任何内容。" -f $regProbe.exit_code, $regProbe.error)
            & $setRc 1
            return
        }

        $newDir = New-RollbackBackupDirectory -ProjectRoot $projectRoot
        if (-not $newDir.Ok) {
            Write-Error ("备份目录创建失败: {0}。已中止，未删除任何内容。" -f $newDir.Reason)
            & $setRc 1
            return
        }
        $runId = [string]$newDir.RunId
        $backupDir = [string]$newDir.Path

        $fingerprint = Get-MachineFingerprint
        $journal = ConvertTo-RollbackJournal -RunId $runId -BackupDir $backupDir `
            -MachineFingerprint ([string]$fingerprint.Value) -FingerprintSource ([string]$fingerprint.Source)
        $firstFlush = Write-RollbackJournalSafely -BackupDir $backupDir -Journal $journal
        if (-not $firstFlush.Ok) {
            Write-Error ("回滚日志不可写: {0}。已中止，未删除任何内容。" -f $firstFlush.Reason)
            & $setRc 1
            return
        }
        Write-Output "Rollback journal created: $($firstFlush.Path)"

        # REQ-003(c)：Machine PATH 原值**只在本轮确实有 PATH 条目要删时**要求，
        # 且只读一次（REQ-001：消除同一轮内多次读-改-写的竞争）。
        $hasPathEntry = $false
        foreach ($item in $eligibleItems) {
            $itemKinds = Get-ItemMutationKindList -Item $item
            if (@($itemKinds) -contains 'path_entry') { $hasPathEntry = $true; break }
        }
        if ($hasPathEntry) {
            $captured = $null
            try { $captured = [Environment]::GetEnvironmentVariable('Path', 'Machine') } catch { $captured = $null }
            if ($null -eq $captured) {
                Write-Error "Machine PATH 原值无法捕获。PATH 条目将无法回滚，已中止，未删除任何内容。"
                & $setRc 1
                return
            }
            $machinePathOriginal = $captured
            $journal['machine_path_original'] = $machinePathOriginal
            $journal['machine_path_scope'] = 'Machine'
            $pathFlush = Write-RollbackJournalSafely -BackupDir $backupDir -Journal $journal
            if (-not $pathFlush.Ok) {
                Write-Error ("回滚日志（PATH 原值）落盘失败: {0}。已中止，未删除任何内容。" -f $pathFlush.Reason)
                & $setRc 1
                return
            }
        }

        # REQ-014 / REQ-025：可选层不可用**只告警**，绝不中止。
        $optProtection = Get-OptionalProtectionStatus -ProjectRoot $projectRoot
        if (-not $optProtection.Enabled) {
            Write-Warning "!! 系统还原点（可选的最后手段）不可用：$($optProtection.Detail)"
            Write-Warning "!! 本轮只有「强制逐项精准保护」（回滚日志 + 逐项备份）。文件/服务/计划任务的删除**本质上不可自动恢复**（DD-006），请先人工确认关键数据。"
        } else {
            Write-Output "Optional system restore point reported available: $($optProtection.Detail)"
        }
    }

    # Phase 1: Stop all services (stop only, no delete)
    Write-Output "$prefix Phase 1: Stopping services..."
    foreach ($item in $eligibleItems) {
        if ($item.name -and $item.binary_path) {
            Write-Output "$prefix   Stopping service: $($item.name)"
            if (-not $DryRun) {
                try {
                    # 经 Invoke-ScExe 调用（不能写裸 `sc.exe stop X 2>$null`：PS 5.1 下必然抛异常）
                    $stopResult = Invoke-ScExe -Arguments @('stop', $item.name)
                    if (-not $stopResult.ok -and $stopResult.exit_code -ne 1060) {
                        # 1060 = ERROR_SERVICE_DOES_NOT_EXIST：服务已不存在，无需停止
                        Write-Warning "  → sc.exe stop $($item.name) failed (exit $($stopResult.exit_code)): $($stopResult.error)"
                    }
                    $waited = 0
                    do {
                        Start-Sleep -Milliseconds 1000
                        $waited++
                        $svcState = (Get-CimInstance Win32_Service -Filter "Name='$($item.name)'" -ErrorAction SilentlyContinue).State
                    } while ($svcState -eq 'Running' -and $waited -lt 10)
                    if ($svcState -eq 'Running') {
                        Write-Warning "  → Service $($item.name) did not stop in time"
                    }
                } catch {
                    Write-Warning "  → Failed to stop service $($item.name): $($_.Exception.Message)"
                }
            }
        }
    }

    # Phase 2: Delete files/directories + delete services
    Write-Output "$prefix Phase 2: Deleting files and services..."
    # path_entry 的变更**不在**这里逐条写 PATH：REQ-001 要求整作用域一次读-改-写，
    # 所以循环内只做「已存在性检查 + planned 登记」，段收集后在循环外一次写回。
    $pathPending = @()
    $unjournaledMutations = @()

    foreach ($item in $eligibleItems) {
        if ($persistenceError) { break }
        $itemKinds = @(Get-ItemMutationKindList -Item $item)
        try {
            # Clean files/dirs
            # path_entry 的 .path 是"指向不存在目录的 PATH 片段"，其清理方式是移除 PATH 条目
            # （见下方 path_entry 分支），绝不能当作文件系统目录去删除，否则会误删同名真实目录并产生虚假日志。
            if ($itemKinds -contains 'path_deleted') {
                $targetPath = [string]$item.path
                Write-Output "$prefix   Deleting path: $targetPath"
                if ($DryRun) {
                    $log.Add(@{ id=$item.id; action='path_deleted'; path=$targetPath; success=$true })
                } else {
                    if (-not (Test-Path -LiteralPath $targetPath)) {
                        Write-Output "  → Path does not exist (already removed), skipping"
                        # 目标本轮本就不存在 => 没有任何变更需要保护，不登记日志条目
                        # （否则恢复端会得到一条「我们删了它」的假因果证据）。
                        $log.Add(@{ id=$item.id; action='path_deleted'; path=$targetPath; success=$true; note='absent_before_cleanup' })
                    } else {
                        $planned = New-RollbackPlannedEntry -Journal $journal -BackupDir $backupDir `
                            -Item $item -Kind 'path_deleted'
                        if (-not $planned.Ok) {
                            Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($planned.Reason)"
                            Write-Error "  → 回滚日志登记失败，已停止后续破坏性操作: $($planned.Reason)"
                            $persistenceError = $true
                            break
                        }
                        $rid = [string]$planned.ItemId
                        $outcome = ''
                        $deleted = Remove-ItemRobust -Path $targetPath -Outcome ([ref]$outcome)
                        if (-not $deleted) {
                            $null = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir `
                                -ItemId $rid -Fields @{ state = 'mutation_failed' }
                            throw "Failed to delete path after all fallback strategies"
                        }
                        # REQ-002 / AC-016：Tier-4 改名不是删除，必须如实记录新名字。
                        $renamedInfo = Get-RollbackFailureKindFromCleanupAction -Outcome $outcome
                        $stillThere = (Test-Path -LiteralPath $targetPath)
                        $fields = @{
                            state = 'mutation_succeeded'
                            absent_confirmed_after_mutation = (-not $stillThere)
                        }
                        $st = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir -ItemId $rid -Fields $fields
                        if (-not $st.Ok) {
                            # AC-052：变更已发生但记录不可靠 —— 尽力从进程内证据恢复该目标，
                            # 并**一律**标记 restore_failed(unjournaled)（不得声称回到上一个落盘点）。
                            Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed after mutation: $($st.Reason)"
                            Write-Error "  → 变更后日志落盘失败: $($st.Reason)"
                            $unjournaledMutations += , @{
                                ItemId = $rid
                                Kind   = 'path_deleted'
                                Target = $targetPath
                            }
                            $persistenceError = $true
                            break
                        }
                        if ($renamedInfo.Renamed) {
                            $log.Add(@{ id=$item.id; action='path_renamed'; path=$targetPath; renamed_to=$renamedInfo.NewName;
                                        success=$true; note='deferred delete (Tier-4 rename), content still on disk and NOT auto-restorable' })
                        } else {
                            $log.Add(@{ id=$item.id; action='path_deleted'; path=$targetPath; outcome='deleted'; success=$true })
                        }
                    }
                }
            }

            # Delete services (after files, so binaries are released)
            if ($itemKinds -contains 'service') {
                $svcName = [string]$item.name
                Write-Output "$prefix   Deleting service: $svcName"
                if ($DryRun) {
                    $log.Add(@{ id=$item.id; action='service_deleted'; name=$svcName; success=$true })
                } else {
                    # pre_existing 的证据：只有 1060（ERROR_SERVICE_DOES_NOT_EXIST）才是
                    # 「本轮本就不存在」。其它非零码（5=拒绝访问、启动失败=$null）是
                    # **无法判定**，必须继续走删除并如实记录结果 —— 把「读不到」说成
                    # 「已消失」正是 AGENTS.md 里 Confirm-RegistryTargetAbsent 的 fail-closed 反面。
                    $pre = Invoke-ScExe -Arguments @('query', $svcName)
                    if ($pre.exit_code -eq 1060) {
                        Write-Output "  → Service not found (already removed), skipping"
                        $log.Add(@{ id=$item.id; action='service_skip'; name=$svcName; success=$true; note='service not found' })
                    } else {
                        $planned = New-RollbackPlannedEntry -Journal $journal -BackupDir $backupDir `
                            -Item $item -Kind 'service'
                        if (-not $planned.Ok) {
                            Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($planned.Reason)"
                            Write-Error "  → 回滚日志登记失败，已停止后续破坏性操作: $($planned.Reason)"
                            $persistenceError = $true
                            break
                        }
                        $rid = [string]$planned.ItemId
                        $delResult = Invoke-ScExe -Arguments @('delete', $svcName)
                        # 1060 = ERROR_SERVICE_DOES_NOT_EXIST：已被删除，视为幂等成功
                        if (-not $delResult.ok -and $delResult.exit_code -ne 1060) {
                            $null = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir `
                                -ItemId $rid -Fields @{ state = 'mutation_failed' }
                            throw "sc.exe delete failed with exit code $($delResult.exit_code): $($delResult.error)"
                        }
                        $post = Invoke-ScExe -Arguments @('query', $svcName)
                        $st = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir -ItemId $rid -Fields @{
                            state = 'mutation_succeeded'
                            absent_confirmed_after_mutation = ($post.exit_code -eq 1060)
                        }
                        if (-not $st.Ok) {
                            Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed after mutation: $($st.Reason)"
                            Write-Error "  → 变更后日志落盘失败: $($st.Reason)"
                            $unjournaledMutations += , @{ ItemId = $rid; Kind = 'service'; Target = $svcName }
                            $persistenceError = $true
                            break
                        }
                        $log.Add(@{ id=$item.id; action='service_deleted'; name=$svcName; success=$true })
                    }
                }
            }

            # Delete ghost scheduled tasks（master 修复：ghost_task 分支）
            # ghost task 结构: { type='ghost_task'; name; execute; expanded_path; risk; reason; id }
            # 与 service 的区分：service 有 binary_path，task 有 expanded_path
            if ($itemKinds -contains 'task') {
                $taskName = [string]$item.name
                Write-Output "$prefix   Deleting scheduled task: $taskName"
                if ($DryRun) {
                    $log.Add(@{ id=$item.id; action='task_deleted'; name=$taskName; success=$true })
                } else {
                    # 根据 name 精确删除计划任务（Unregister-ScheduledTask 会同时删除 task + 其所有 action）
                    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    if (-not $task) {
                        Write-Output "  → Scheduled task not found (already removed), skipping"
                        $log.Add(@{ id=$item.id; action='task_skip'; name=$taskName; success=$true; note='task not found' })
                    } else {
                        $planned = New-RollbackPlannedEntry -Journal $journal -BackupDir $backupDir `
                            -Item $item -Kind 'task'
                        if (-not $planned.Ok) {
                            Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($planned.Reason)"
                            Write-Error "  → 回滚日志登记失败，已停止后续破坏性操作: $($planned.Reason)"
                            $persistenceError = $true
                            break
                        }
                        $rid = [string]$planned.ItemId
                        try {
                            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                            Write-Output "  → Scheduled task deleted: $taskName"
                        } catch {
                            $null = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir `
                                -ItemId $rid -Fields @{ state = 'mutation_failed' }
                            throw
                        }
                        $postTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                        $st = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir -ItemId $rid -Fields @{
                            state = 'mutation_succeeded'
                            absent_confirmed_after_mutation = ($null -eq $postTask)
                        }
                        if (-not $st.Ok) {
                            Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed after mutation: $($st.Reason)"
                            Write-Error "  → 变更后日志落盘失败: $($st.Reason)"
                            $unjournaledMutations += , @{ ItemId = $rid; Kind = 'task'; Target = $taskName }
                            $persistenceError = $true
                            break
                        }
                        $log.Add(@{ id=$item.id; action='task_deleted'; name=$taskName; success=$true })
                    }
                }
            }

            # Remove dead PATH entries（master 修复：path_entry 分支）
            # PATH 残留结构: { type='path_entry'; path=<dead dir>; risk; reason; id }
            # 从机器 PATH 环境变量中移除指向不存在目录的条目。
            if ($itemKinds -contains 'path_entry') {
                $seg = ([string]$item.path).Trim()
                Write-Output "$prefix   Removing dead PATH entry: $seg"
                if ($DryRun) {
                    $log.Add(@{ id=$item.id; action='path_entry_removed'; path=$seg; success=$true })
                } else {
                    # 存在性判定用**捕获的原值**（REQ-001 的本意：一轮之内只读一次），
                    # 且必须整段比较——旧写法 `-match [regex]::Escape($target)` 是子串匹配，
                    # 'C:\App' 会命中 'C:\AppData' 并把它整段删掉。
                    $absentNow = Confirm-PathEntryRemoved -PathList $machinePathOriginal -Entry $seg
                    if ([bool]$absentNow.Absent) {
                        Write-Output "  → PATH entry not found (already removed), skipping"
                        $log.Add(@{ id=$item.id; action='path_entry_skip'; path=$seg; success=$true; note='entry not present' })
                    } else {
                        $planned = New-RollbackPlannedEntry -Journal $journal -BackupDir $backupDir `
                            -Item $item -Kind 'path_entry' -ExtraFields @{ scope = 'Machine' }
                        if (-not $planned.Ok) {
                            Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($planned.Reason)"
                            Write-Error "  → 回滚日志登记失败，已停止后续破坏性操作: $($planned.Reason)"
                            $persistenceError = $true
                            break
                        }
                        $pathPending += , @{ ItemId = [string]$planned.ItemId; Seg = $seg; Id = [string]$item.id }
                    }
                }
            }
        } catch {
            $log.Add(@{ id=$item.id; action='cleanup_failed'; error=$_.Exception.Message; success=$false })
        }
    }

    # PATH 整作用域一次写回（REQ-001 / REQ-021）：所有已登记段在同一次写入里移除。
    # $persistenceError 时**绝不**写：AC-052 要求停止后续破坏性操作；这些条目停留在
    # planned（从未被变更），恢复端按 REQ-024 规则 1 会判 already_present，不会误装回去。
    if ($pathPending.Count -gt 0 -and -not $persistenceError) {
        $removedSegs = @($pathPending | ForEach-Object { [string]$_.Seg })
        $newPath = Get-ExpectedPathAfterCleanup -OriginalPath $machinePathOriginal -RemovedEntries $removedSegs
        $writeErr = ''
        $after = $null
        if ($null -eq $newPath) {
            $writeErr = 'path_original_unusable'
        } else {
            try {
                $after = Set-MachinePathValue -Value $newPath
            } catch {
                $writeErr = "path_write_failed($($_.Exception.Message))"
            }
            if ($writeErr -eq '' -and $null -eq $after) { $writeErr = 'path_write_unverified' }
        }
        foreach ($p in $pathPending) {
            $ok = ($writeErr -eq '')
            $why = $writeErr
            if ($ok) {
                # 写后回读值逐段确认（与恢复端同一个判据），绝不把「以为写进去了」当成功。
                $chk = Confirm-PathEntryRemoved -PathList $after -Entry $p.Seg
                if (-not [bool]$chk.Absent) { $ok = $false; $why = 'path_write_verify_failed' }
            }
            $fields = @{ state = 'mutation_succeeded'; absent_confirmed_after_mutation = $ok }
            if (-not $ok) { $fields['state'] = 'mutation_failed' }
            $st = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir -ItemId ([string]$p.ItemId) -Fields $fields
            if (-not $st.Ok) {
                Write-Error "  → PATH 变更后日志落盘失败: $($st.Reason)"
                $unjournaledMutations += , @{ ItemId = [string]$p.ItemId; Kind = 'path_entry'; Target = [string]$p.Seg }
                $persistenceError = $true
            }
            if ($ok) {
                Write-Output "  → Removed from machine PATH: $($p.Seg)"
                $log.Add(@{ id=$p.Id; action='path_entry_removed'; path=$p.Seg; success=$true })
            } else {
                $log.Add(@{ id=$p.Id; action='cleanup_failed'; error="PATH write not confirmed: $why"; success=$false })
            }
        }
    }

    # Phase 3: Clean registry keys
    Write-Output "$prefix Phase 3: Cleaning registry..."
    foreach ($item in $eligibleItems) {
        if ($persistenceError) { break }
        $itemKinds = @(Get-ItemMutationKindList -Item $item)
        try {
            # ── 整键删除（注册表残留）──
            if ($itemKinds -contains 'registry_key') {
                $regKey = [string]$item.key
                Write-Output "$prefix   Deleting registry key: $regKey"
                if ($DryRun) {
                    $log.Add(@{ id=$item.id; action='registry_deleted'; key=$regKey; success=$true })
                } else {
                    $abs = Confirm-RegistryTargetAbsent -Key $regKey
                    if ([bool]$abs.Absent) {
                        Write-Output "  → Registry key does not exist (already removed), skipping"
                        $log.Add(@{ id=$item.id; action='registry_skip'; key=$regKey; success=$true; note='key not found' })
                        continue
                    }
                    $planned = New-RollbackPlannedEntry -Journal $journal -BackupDir $backupDir `
                        -Item $item -Kind 'registry_key'
                    if (-not $planned.Ok) {
                        Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($planned.Reason)"
                        Write-Error "  → 回滚日志登记失败，已停止后续破坏性操作: $($planned.Reason)"
                        $persistenceError = $true
                        break
                    }
                    $rid = [string]$planned.ItemId

                    # REQ-006 逐项 fail-closed：备份不成立 = 删除不发生。
                    $export = Export-RegistryKeyBackup -Key $regKey -BackupDir $backupDir -Id ([string]$item.id)
                    $relBackup = Get-JournalBackupFileRelative -BackupDir $backupDir -Path ([string]$export.Path)
                    if (-not $export.Ok -or [string]::IsNullOrWhiteSpace($relBackup)) {
                        throw "export_failed: $(if ($export.Ok) { 'backup path outside backup dir' } else { $export.Reason })"
                    }
                    $st1 = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir -ItemId $rid -Fields @{
                        state = 'backup_created'
                        backup_file = $relBackup
                        backup_file_sha256 = [string]$export.Sha256
                    }
                    if (-not $st1.Ok) {
                        Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($st1.Reason)"
                        Write-Error "  → 备份登记落盘失败，已停止后续破坏性操作: $($st1.Reason)"
                        $persistenceError = $true
                        break
                    }

                    $del = Invoke-RegExe -Arguments @('delete', $regKey, '/f')
                    if (-not $del.ok) {
                        $null = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir `
                            -ItemId $rid -Fields @{ state = 'mutation_failed' }
                        throw "reg delete failed with exit code $($del.exit_code): $($del.error)"
                    }

                    # REQ-024 flag 3 + 迹象 (ii) 基线：删除后**立即**复查并采集父键写入时刻。
                    $post = Confirm-RegistryTargetAbsent -Key $regKey
                    $baseline = Get-ParentBaselineSnapshot -Key ([string](Get-RegistryParentPath -Key $regKey))
                    $st2 = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir -ItemId $rid -Fields @{
                        state = 'mutation_succeeded'
                        absent_confirmed_after_mutation = [bool]$post.Absent
                        parent_baseline = $baseline
                    }
                    if (-not $st2.Ok) {
                        Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($st2.Reason)"
                        Write-Error "  → 变更后日志落盘失败: $($st2.Reason)"
                        $unjournaledMutations += , @{ ItemId = $rid; Kind = 'registry_key'; Target = $regKey }
                        $persistenceError = $true
                        break
                    }
                    $log.Add(@{ id=$item.id; action='registry_deleted'; key=$regKey; success=$true })
                }
            }

            # ── 启动项 VALUE 删除 ──
            if ($itemKinds -contains 'startup_value') {
                if (-not $item.value_name) {
                    throw "startup item missing value_name; refuse to delete shared Run key"
                }
                $regKey = [string]$item.key
                $valueName = [string]$item.value_name
                Write-Output "$prefix   Deleting startup value: $regKey /v $valueName"
                if ($DryRun) {
                    $log.Add(@{ id=$item.id; action='startup_value_deleted'; key=$regKey; value=$valueName; success=$true })
                } else {
                    # 只有「找不到键/值」（1/2/3）才说明本轮无事可做；
                    # 5（拒绝访问）与启动失败（$null）属于无法判定，必须继续并如实记录结果。
                    $pre = Invoke-RegExe -Arguments @('query', $regKey, '/v', $valueName)
                    if ($null -ne $pre.exit_code -and @(1, 2, 3) -contains [int]$pre.exit_code) {
                        Write-Output "  → Startup value not found (already removed), skipping"
                        $log.Add(@{ id=$item.id; action='registry_skip'; key=$regKey; value=$valueName; success=$true; note='value not found' })
                        continue
                    }
                    $planned = New-RollbackPlannedEntry -Journal $journal -BackupDir $backupDir `
                        -Item $item -Kind 'startup_value' -ExtraFields @{ value_name = $valueName }
                    if (-not $planned.Ok) {
                        Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($planned.Reason)"
                        Write-Error "  → 回滚日志登记失败，已停止后续破坏性操作: $($planned.Reason)"
                        $persistenceError = $true
                        break
                    }
                    $rid = [string]$planned.ItemId

                    # DD-003 / REQ-007：导出父键 → 裁剪为只含该 value。裁剪失败 / 多值 / 读不回
                    # 一律 export_failed，删除不发生。共享 Run 键**永不**整键删除或整键重导。
                    $export = Export-StartupValueBackup -Key $regKey -ValueName $valueName `
                        -BackupDir $backupDir -Id ([string]$item.id)
                    $relBackup = Get-JournalBackupFileRelative -BackupDir $backupDir -Path ([string]$export.Path)
                    if (-not $export.Ok -or [string]::IsNullOrWhiteSpace($relBackup)) {
                        throw "export_failed: $(if ($export.Ok) { 'backup path outside backup dir' } else { $export.Reason })"
                    }
                    $st1 = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir -ItemId $rid -Fields @{
                        state = 'backup_created'
                        backup_file = $relBackup
                        backup_file_sha256 = [string]$export.Sha256
                    }
                    if (-not $st1.Ok) {
                        Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($st1.Reason)"
                        Write-Error "  → 备份登记落盘失败，已停止后续破坏性操作: $($st1.Reason)"
                        $persistenceError = $true
                        break
                    }

                    $del = Invoke-RegExe -Arguments @('delete', $regKey, '/v', $valueName, '/f')
                    if (-not $del.ok) {
                        $null = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir `
                            -ItemId $rid -Fields @{ state = 'mutation_failed' }
                        throw "reg delete /v failed with exit code $($del.exit_code): $($del.error)"
                    }
                    $post = Invoke-RegExe -Arguments @('query', $regKey, '/v', $valueName)
                    $baseline = Get-ParentBaselineSnapshot -Key $regKey
                    $st2 = Set-RollbackEntryState -Journal $journal -BackupDir $backupDir -ItemId $rid -Fields @{
                        state = 'mutation_succeeded'
                        absent_confirmed_after_mutation = (-not $post.ok)
                        parent_baseline = $baseline
                    }
                    if (-not $st2.Ok) {
                        Add-CleanupFailure -Log $log -Item $item -ErrorText "journal persistence failed: $($st2.Reason)"
                        Write-Error "  → 变更后日志落盘失败: $($st2.Reason)"
                        $unjournaledMutations += , @{ ItemId = $rid; Kind = 'startup_value'; Target = "$regKey|$valueName" }
                        $persistenceError = $true
                        break
                    }
                    $log.Add(@{ id=$item.id; action='startup_value_deleted'; key=$regKey; value=$valueName; success=$true })
                }
            }
        } catch {
            $log.Add(@{ id=$item.id; action='cleanup_failed'; error=$_.Exception.Message; success=$false })
        }
    }

    $summary = @{
        mode = $Mode
        dry_run = $DryRun.IsPresent
        run_id = $runId
        total_processed = $log.Count
        succeeded = @($log | Where-Object { $_.success -eq $true }).Count
        failed = @($log | Where-Object { $_.success -eq $false -and $_.action -eq 'cleanup_failed' }).Count
        skipped = @($log | Where-Object { $_.action -match 'skipped' }).Count
        timestamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    }

    Write-Output "`nCleanup summary: $($summary.succeeded) succeeded, $($summary.failed) failed, $($summary.skipped) skipped"
    if ($DryRun) { Write-Output "(DRY-RUN mode - no changes were made)" }

    # 输出日志（UTF-8 without BOM）
    # run_id 写在这里（REQ-033 / AC-088）：回滚日志与清理日志必须能证明同属一轮，
    # 否则一份被篡改的日志只要指向**另一轮**的成功清理日志，就能把强制 T3 恢复整轮跳过。
    $outputPath = Join-Path $projectRoot 'cleanup-log.json'
    $logJson = @{ run_id = $runId; summary = $summary; entries = $log } | ConvertTo-Json -Depth 3
    $cleanupLogWritten = $false
    try {
        [System.IO.File]::WriteAllText($outputPath, $logJson, [System.Text.UTF8Encoding]::new($false))
        $cleanupLogWritten = $true
        Write-Output "Cleanup log saved to: $outputPath"
    } catch {
        # 本轮的持久化记录写不下去 = 记录不再可靠（REQ-026 的 15 语义），
        # 不能按普通部分失败报告「已尽力回滚」。
        Write-Error "Failed to write cleanup log to ${outputPath}: $($_.Exception.Message)"
        $persistenceError = $true
    }

    # ── REQ-033：把清理日志绑定（路径/时间戳/哈希，同 null 或同非 null）写回日志 ──
    if ($null -ne $journal -and $cleanupLogWritten) {
        $null = Set-RollbackJournalCleanupBinding -Journal $journal -CleanupLogPath $outputPath
        $bindFlush = Write-RollbackJournalSafely -BackupDir $backupDir -Journal $journal
        if (-not $bindFlush.Ok) {
            Write-Error "清理日志绑定落盘失败: $($bindFlush.Reason)"
            $persistenceError = $true
        }
    }

    # ── T2：本轮部分失败 → 进程内精准回滚（REQ-011 / REQ-015 / REQ-020）──
    # 触发条件只看日志内容与 summary.failed，与进程退出码无关；-DryRun 时 $journal 为
    # $null，天然不会走到这里（AC-010）。
    $failedCount = [int]$summary.failed
    $hadMutations = $false
    $journalMissing = $false
    $restoreFailed = 0
    $rollbackResult = $null

    if ($needsProtection -and $failedCount -gt 0 -and -not $NoAutoRollback) {
        if ($persistenceError) {
            Write-Warning "持久化写入已失败（REQ-026 退出码 15）：不再判定回滚结果。"
        } else {
            $durable = Read-RollbackJournal -BackupDir $backupDir
            if ($null -eq $durable) {
                # REQ-026 的 12：需要回滚时发现日志已不存在/不可读。
                Write-Error "回滚日志缺失或不可读（$backupDir\rollback-journal.json），无法自动回滚。"
                $journalMissing = $true
            } else {
                $hadMutations = Test-JournalHasMutation -Journal $journal
                Write-Output "`nAuto-rollback: cleanup failed for $failedCount item(s), restoring what this run changed..."
                $rollbackResult = Invoke-RollbackRestore -Journal $journal -BackupDir $backupDir `
                    -ProjectRoot $projectRoot -AcknowledgeConflicts:$AcknowledgeConflicts
                $restoreFailed = [int]$rollbackResult.Counts.restore_failed
                # REQ-009：逐项四种判定 + 原因（人读报告）
                foreach ($line in @($rollbackResult.Report)) { Write-Output $line }
                if ($restoreFailed -gt 0) {
                    Write-Warning "$restoreFailed 项未能自动修复，清单: $($rollbackResult.UnrepairedPath)"
                }
            }
        }
    }

    # ── AC-052：变更已发生但没进日志的条目 ──
    # 只能从**进程内证据**尽力恢复，且**一律**标记 restore_failed(unjournaled)：
    # 进程内没有时间机器，不得声称「回到上一个落盘点」。
    if (@($unjournaledMutations).Count -gt 0) {
        $unrepaired = @()
        if ($null -ne $rollbackResult) { $unrepaired = $rollbackResult.Unrepaired }
        foreach ($u in @($unjournaledMutations)) {
            $unrepaired = Add-UnrepairedItem -List $unrepaired -ItemId ([string]$u.ItemId) `
                -Reason 'restore_failed(unjournaled)' -Kind ([string]$u.Kind) -Target ([string]$u.Target)
        }
        try {
            $mergedPath = Write-UnrepairedList -ProjectRoot $projectRoot -RunId $runId -Items $unrepaired `
                -BackupDir $backupDir -Reason 'journal_persistence_failed'
            Write-Output "Unrepaired list (incl. un-journaled mutations): $mergedPath"
        } catch {
            Write-Error "未修复清单落盘失败: $($_.Exception.Message)"
            $persistenceError = $true
        }
    }

    # ── 退出码（REQ-026 矩阵，唯一实现处 Get-CleanupExitCode）──
    $exitValue = Get-CleanupExitCode -FailedCount $failedCount `
        -PersistenceError ([bool]$persistenceError) `
        -NoAutoRollback ([bool]$NoAutoRollback) `
        -JournalMissing ([bool]$journalMissing) `
        -HadMutations ([bool]$hadMutations) `
        -RestoreFailedCount $restoreFailed

    # ── REQ-031：本轮正常结束必须把日志标记为完成；唯一例外是 11 ──
    # 不写完成标记，下一轮会把**已经正确清理过**的一轮当成未完成 T3，
    # 按 REQ-024 规则 3 把刚清掉的残留重新装回去。
    if ($null -ne $journal) {
        $skipCompletion = ($exitValue -eq 11)
        try {
            $cmp = Complete-RollbackJournal -BackupDir $backupDir -Journal $journal `
                -Skip:$skipCompletion -SkipReason $(if ($skipCompletion) { 'rollback_incomplete' } else { '' })
            if ($cmp.Written) {
                Write-Output "Rollback journal marked complete: $($cmp.CompletedAt)"
            } else {
                Write-Warning "回滚日志保持未完成（退出码 11，系统仍有未修复项）: $($cmp.Reason)"
            }
        } catch {
            Write-Error "完成标记写入失败: $($_.Exception.Message)"
            if (-not $skipCompletion) {
                # §3.5.1 的 15(iii)：完成/消费标记写不出去同样是「改了但记录不可靠」。
                $exitValue = Get-CleanupExitCode -PersistenceError $true
            }
        }
    }

    & $setRc $exitValue
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
# ADR-001: Main 用 [ref] 回传退出码；Main 内**不得**有 exit，也不得 `return <code>`
# （前者会杀死测试宿主致套件静默塌掉，后者会把整数写进 stdout 污染输出）。
# 注意：不能用 `exit (Main)` —— 那会吞掉 Main 的全部 Write-Output（实测）。
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    Main -ExitCode ([ref]$exitCode)
    exit $exitCode
}
