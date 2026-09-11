# Windows Residual Cleaner v2.0 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the half-complete Windows residual cleaner into a production-ready Qoder skill with correct scanning logic, robust cleanup, comprehensive tests, and CLI-first distribution.

**Architecture:** 4-layer concentric design — Layer 0 (Foundation: test infrastructure) → Layer 1 (Core: bug fixes + run-all.ps1 + exit codes) → Layer 2 (Polish: test fixes + regression tests) → Layer 3 (Release: UI validation + setup + docs). Each layer depends on the previous.

**Tech Stack:** PowerShell 5.1, Pester 5.x, PSScriptAnalyzer, React/Vite (optional UI)

**Design Doc:** `docs/superpowers/specs/2026-06-04-windows-residual-cleaner-release-design.md`
**Specification:** `.sprint-state/phase-outputs/specification-sprint2.yaml`

---

## 实施状态（2026-09-11 更新）

Layer 0–3 已全部移植到 `fix/test-dotsource-hang` 分支并落地。验证结果：

- Pester 全量：98 passed / 0 failed（`tests/unit` + `tests/integration`）
- PSScriptAnalyzer：0 error / 0 warning（需带 `-Settings PSScriptAnalyzerSettings.psd1`，该文件仅豁免跨作用域误报的 `PSReviewUnusedParameter`）
- `setup.ps1` 环境检查：PASSED，exit 0
- `run-all.ps1` 权限契约：非管理员下正确返回 exit 2
- `run-all.ps1` 管理员端到端（Task 15 Step 3，2026-09-11）：exit 0，总耗时 144.2s，报告 306 items（Safe 160 / Caution 146 / Danger 0）。winget JSON 解析失败自动回退文本索引（401 entries），属已知回退路径

未完成项：无。

两条注意事项：

1. 本文档中的命令写的是 `pwsh`；本机只有 Windows PowerShell 5.1，实际以 `powershell.exe` 等价执行。
2. `scan-filesystem-residuals.ps1` 单独耗时 385.7s，其余 4 步合计 11.2s。端到端验证前需预期 6~7 分钟的扫描时长。

---

## Layer 0: Foundation — Test Infrastructure

### Task 1: Function/Execution Separation — scan-residuals.ps1

**Files:**
- Modify: `references/scripts/scan-residuals.ps1`

- [x] **Step 1: Wrap top-level execution code in Main function**

**关键**: `Get-ExecutablePath` 函数（lines 17-24）保留在 Main **外部**作为顶层函数（dot-source 时可被测试调用）。仅将执行逻辑移入 Main。

```powershell
# Top of file: param block + encoding stay
# Get-ExecutablePath function (lines 17-24) stays as TOP-LEVEL function

function Main {
    # Lines 8-9 (encoding) move here
    # Lines 26-194 (scanning logic, AFTER Get-ExecutablePath) move here
    # Do NOT include Get-ExecutablePath definition inside Main
}

# Execution guard — only runs when script is directly executed, not when dot-sourced
# $MyInvocation.InvocationName is '.' when dot-sourced, empty when run via -File
if ($MyInvocation.InvocationName -ne '.') {
    Main
}
```

- [x] **Step 2: Verify script still runs standalone**

Run: `pwsh -File references/scripts/scan-residuals.ps1` (needs uninstalled-list.json to exist)
Expected: Script produces other-residuals.json as before

- [x] **Step 3: Verify dot-source only loads functions (explicit assertion)**

Run:
```powershell
pwsh -Command ". .\references\scripts\scan-residuals.ps1; Get-Command Get-ExecutablePath"
```
Expected: `Get-ExecutablePath` is listed, no scan output produced

- [x] **Step 4: Commit**

```bash
git add references/scripts/scan-residuals.ps1
git commit -m "refactor: function/execution separation in scan-residuals.ps1"
```

---

### Task 2a: Function/Execution Separation — Scripts with Top-Level Functions

**Files:**
- Modify: `references/scripts/clean-residuals.ps1`
- Modify: `references/scripts/generate-report.ps1`
- Modify: `references/scripts/scan-filesystem-residuals.ps1`

> **Delphi R2 修复 [C1/M1]**: 原 "Low-Complexity" 标题不准确（clean-residuals.ps1 含 P/Invoke），改为按"有顶层函数需保留"分类。

- [x] **Step 1: Apply pattern to clean-residuals.ps1**

Keep `Remove-ItemRobust` and `Test-Whitelisted` as **top-level** functions. Move all execution logic (lines 16-35 restore check + whitelist load, lines 154-323 report load + cleanup + summary) into `Main`. Encoding moves into Main.

```powershell
# param block (lines 1-11) stays
# Remove-ItemRobust (lines 38-135) stays as TOP-LEVEL function
# Test-Whitelisted (lines 137-152) stays as TOP-LEVEL function

function Main {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    # Lines 16-35 (restore check + whitelist load)
    # Lines 154-323 (report load + cleanup + summary)
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
```

- [x] **Step 2: Apply pattern to generate-report.ps1**

Keep `Set-Id` function as **top-level**. Move everything else into `Main`.

- [x] **Step 3: Apply pattern to scan-filesystem-residuals.ps1**

Keep `Get-EffectiveFileCount`, `Get-DirectorySizeMB`, `Test-AllSubdirsEmpty` as **top-level**. Move all execution logic (lines 68-118 foreach + JSON output) into `Main`.

- [x] **Step 4: Verify top-level functions are accessible via dot-source**

```powershell
pwsh -Command ". .\references\scripts\clean-residuals.ps1; Get-Command Remove-ItemRobust,Test-Whitelisted"
pwsh -Command ". .\references\scripts\generate-report.ps1; Get-Command Set-Id"
pwsh -Command ". .\references\scripts\scan-filesystem-residuals.ps1; Get-Command Get-EffectiveFileCount,Get-DirectorySizeMB,Test-AllSubdirsEmpty"
```
Expected: All functions listed, no scan/cleanup output

---

### Task 2b: Function/Execution Separation — Scripts without Top-Level Functions

**Files:**
- Modify: `references/scripts/scan-uninstalled.ps1`
- Modify: `references/scripts/confirm-cleanup.ps1`
- Modify: `references/scripts/build-installed-index.ps1`

> **Delphi R2 修复 [C1-Expert B]**: confirm-cleanup.ps1（6 个内部函数 + 大量顶层执行代码）和 build-installed-index.ps1（288 行纯顶层代码）在原版中完全遗漏。

- [x] **Step 1: Apply pattern to scan-uninstalled.ps1**

No top-level functions to keep. Move everything into `Main`.

- [x] **Step 2: Apply pattern to confirm-cleanup.ps1**

Keep `Get-ItemContent`, `Limit-StringLength`, `Show-Page`, `Show-Detail`, `Show-Help`, `Get-PageRange` as **top-level** functions. Move all execution logic (lines 15-456 interactive + non-interactive) into `Main`.

- [x] **Step 3: Apply pattern to build-installed-index.ps1**

No top-level functions. Move all 288 lines into `Main`.

- [x] **Step 4: Verify dot-source safety**

```powershell
pwsh -Command ". .\references\scripts\scan-uninstalled.ps1; Write-Output 'OK'"
pwsh -Command ". .\references\scripts\confirm-cleanup.ps1; Get-Command Show-Page,Show-Help"
pwsh -Command ". .\references\scripts\build-installed-index.ps1; Write-Output 'OK'"
```
Expected: No scan/cleanup/interactive output, functions accessible

- [x] **Step 5: Run existing tests to verify no regression**

Run: `pwsh -Command "Import-Module Pester -RequiredVersion 5.7.1 -Force; Invoke-Pester tests/unit/scripts.Tests.ps1 -Output Detailed"`
Expected: Tests should now complete without timeout (dot-source no longer triggers execution)

- [x] **Step 6: Commit**

```bash
git add references/scripts/scan-uninstalled.ps1 references/scripts/confirm-cleanup.ps1 references/scripts/build-installed-index.ps1
git commit -m "refactor: function/execution separation in remaining scripts"
```

---

## Layer 1: Core — Bug Fixes + Infrastructure

### Task 3a: Fix scan-uninstalled.ps1 — Two-Stage Weighted Judgment

> **Delphi R2 修复 [C2]**: 从 Task 3 拆分。Task 3a 仅处理核心判断逻辑变更，Task 3b 处理辅助 bug。

**Files:**
- Modify: `references/scripts/scan-uninstalled.ps1` (judgment logic block inside Main)

> **注意**: 行号指 Task 2b 完成后的新行号（Main 包装会增加约 2-3 行偏移）。以代码内容定位而非绝对行号。

- [x] **Step 1: Replace OR logic with two-stage weighted judgment**

Replace the judgment logic block inside Main (originally lines 38-88 before Main wrapping) with:

```powershell
            # 两阶段加权判断 (Delphi R1 C1 fix)
            # 阶段 1: 不在索引中 — 低门槛判定
            # 阶段 2: 在索引中 — 需要强证据 (AND)

            $isResidual = $false
            $confidence = 'high'

            if ($notInIndex) {
                # 不在索引中 → 直接标记为残留
                $isResidual = $true
                if ($installPathMissing -or $uninstallPathMissing) {
                    $confidence = 'high'
                } else {
                    $confidence = 'low'
                }
            } else {
                # 在索引中 → 需要路径和卸载程序都异常
                if ($installPathMissing -and $uninstallPathMissing) {
                    $isResidual = $true
                    $confidence = 'medium'
                }
            }

            if ($isResidual) {
                $evidenceParts = @()
                if ($notInIndex) { $evidenceParts += "not in installed index" }
                if ($installPathMissing) { $evidenceParts += "InstallLocation path missing" }
                if ($uninstallPathMissing) { $evidenceParts += "UninstallString exe missing" }

                $uninstalledEntries.Add([PSCustomObject]@{
                    name = $displayName
                    registry_key = "$($rp.Hive)\$subKeyPath\$name"
                    install_location = $installLocation
                    uninstall_string = $uninstallString
                    evidence = $evidenceParts -join '; '
                    confidence = $confidence
                    source = $rp.Hive
                })
            }
```

- [x] **Step 2: Verify syntax**

Run: `pwsh -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content references/scripts/scan-uninstalled.ps1 -Raw), [ref]\$null) | Out-Null; Write-Output 'OK'"`
Expected: OK (no parse errors)

- [x] **Step 3: Commit**

```bash
git add references/scripts/scan-uninstalled.ps1
git commit -m "fix: two-stage weighted judgment in scan-uninstalled.ps1"
```

---

### Task 3b: Fix scan-uninstalled.ps1 — Env Var Expansion + Array Bug

> **Delphi R2 修复 [C2]**: 从 Task 3 拆分的辅助 bug 修复，独立验证点。

**Files:**
- Modify: `references/scripts/scan-uninstalled.ps1` (InstallLocation/UninstallString path checks + candidate_directories filter inside Main)

> **注意**: 行号指 Task 2b 完成后的新行号。以代码内容定位。

- [x] **Step 1: Fix InstallLocation environment variable expansion**

Replace the InstallLocation path check block with:
```powershell
            if ($installLocation) {
                $cleanLocation = [Environment]::ExpandEnvironmentVariables($installLocation.Trim('"').Trim("'"))
                if (-not [string]::IsNullOrWhiteSpace($cleanLocation) -and -not [System.IO.Directory]::Exists($cleanLocation)) {
                    $installPathMissing = $true
                }
            }
```

Also fix UninstallString path expansion (lines 55-67) — apply same `[Environment]::ExpandEnvironmentVariables()` pattern.

- [x] **Step 2: Fix -notmatch array semantic bug (candidate_directories filter)**

> **Bug 说明**: `-notmatch` 对数组操作时返回"不匹配元素的数组"，在 if 条件中非空数组永远为 $true，导致几乎所有目录都被误判为 candidate_directory。
> **M5 修复**: `$installedNames` 是 Hashtable（由 `[hashtable]::new()` 创建），`.Keys` 返回 ICollection，确认正确。

Replace the candidate_directories filter condition:
```powershell
            if (-not $installedNames.ContainsKey($dirName) -and $installedNames.Keys -notmatch [regex]::Escape($dirName)) {
```
With:
```powershell
            $matchedNames = @($installedNames.Keys | Where-Object { $_ -match [regex]::Escape($dirName) })
            if (-not $installedNames.ContainsKey($dirName) -and $matchedNames.Count -eq 0) {
```

- [x] **Step 3: Verify syntax**

Run: `pwsh -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content references/scripts/scan-uninstalled.ps1 -Raw), [ref]\$null) | Out-Null; Write-Output 'OK'"`
Expected: OK

- [x] **Step 4: Commit**

```bash
git add references/scripts/scan-uninstalled.ps1
git commit -m "fix: env var expansion + array semantic bug in scan-uninstalled.ps1"
```

---

### Task 4: Graded Permission Checks

**Files:**
- Modify: All 9 scripts in `references/scripts/`

> **Delphi R2 修复 [M1]**: 补充实现细节和隐式依赖。
> **隐式依赖**: 依赖 Task 2a/2b 先完成 Main 函数包装。权限检查放在 Main 函数内部顶部。
> **实现方式**: 手动 `[Security.Principal.WindowsPrincipal]::IsInRole()`，不用 `#Requires`（PS 5.1 host 兼容性）。
> **M3-A 补充**: 通过 run-all.ps1 调用子脚本时，子进程继承父进程权限，权限检查永远通过。子脚本的权限检查是为**独立调用场景**提供保护（用户直接运行单个脚本时）。

- [x] **Step 1: Add forced admin check to write-operation scripts**

Add to `clean-residuals.ps1`, `create-restore-point.ps1` — inside `Main` function, at the top:

```powershell
    # Admin privilege check (mandatory for write operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Error "Administrator privileges required. Please run PowerShell as Administrator."
        exit 2
    }
```

- [x] **Step 2: Add warning-only admin check to read-only scripts**

Add to `build-installed-index.ps1`, `scan-uninstalled.ps1`, `scan-filesystem-residuals.ps1`, `scan-residuals.ps1`, `generate-report.ps1`, `confirm-cleanup.ps1` — inside `Main` function, at the top:

```powershell
    # Admin privilege check (warning only for read-only operations)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning "Running without admin. Some HKLM registry keys may not be readable."
    }
```

- [x] **Step 3: Verify dot-source does not trigger permission check**

Run: `pwsh -Command ". .\references\scripts\scan-residuals.ps1; Write-Output 'OK'"`
Expected: OK (no permission error)

- [x] **Step 4: Commit**

```bash
git add references/scripts/*.ps1
git commit -m "feat: graded permission checks (mandatory for writes, warning for reads)"
```

---

### Task 5: Add Exit Codes

**Files:**
- Modify: All scripts in `references/scripts/`

- [x] **Step 1: Audit all exit paths and add explicit exit codes**

For each script, ensure every error path has an explicit exit code:
- `exit 0` — success (at the end of Main)
- `exit 1` — general error (file not found, parse failure)
- `exit 2` — permission error
- `exit 3` — dependency missing (JSON file not found)

Specific changes:
- `scan-uninstalled.ps1`: Add `exit 3` if index JSON not found, `exit 0` at end of Main
- `scan-residuals.ps1`: Add `exit 3` if uninstalled-list.json not found, `exit 0` at end
- `scan-filesystem-residuals.ps1`: Add `exit 3` if config.json not found, `exit 0` at end
- `generate-report.ps1`: Add `exit 3` if any input JSON not found, `exit 0` at end
- `clean-residuals.ps1`: Already has `exit 1` at line 22, add `exit 0` at end
- `confirm-cleanup.ps1`: Add `exit 0` at end

- [x] **Step 2: Verify syntax + exit code consistency**

```powershell
# Syntax check all scripts
pwsh -Command "Get-ChildItem references/scripts/*.ps1 | ForEach-Object { [System.Management.Automation.PSParser]::Tokenize((Get-Content $_ -Raw), [ref]`$null) | Out-Null }; Write-Output 'All syntax OK'"
# Verify dot-source safety (no exit code triggered)
pwsh -Command ". .\references\scripts\scan-residuals.ps1; Write-Output 'OK'"
```
Expected: All syntax OK; dot-source produces 'OK' without exit

- [x] **Step 3: Commit**

```bash
git add references/scripts/*.ps1
git commit -m "feat: standardized exit codes (0=success, 1=error, 2=permission, 3=dependency)"
```

---

### Task 6: Create run-all.ps1

**Files:**
- Create: `references/scripts/run-all.ps1`

- [x] **Step 1: Create the unified entry script**

```powershell
# run-all.ps1
# Unified scan pipeline: restore point → index → scan → report
# Responsibility: SCAN ONLY. Does not perform confirmation or cleanup.
param(
    [switch]$SkipRestorePoint = $false,
    [switch]$Verbose = $false
)

function Main {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # Admin privilege check (mandatory — includes create-restore-point)
    if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Error "Administrator privileges required. Please run PowerShell as Administrator."
        exit 2
    }

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
        Write-Warning "Skipping restore point creation. Cleanup will NOT be recoverable."
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
    exit 0
}

if ($MyInvocation.InvocationName -ne '.') {
    Main
}
```

- [x] **Step 2: Verify syntax**

Run: `pwsh -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content references/scripts/run-all.ps1 -Raw), [ref]\$null) | Out-Null; Write-Output 'OK'"`
Expected: OK

- [x] **Step 3: Verify exit code propagation**

Create a test script that exits with code 3, verify run-all.ps1 captures and propagates it:
```powershell
pwsh -Command "Set-Content -Path _test_exit.ps1 -Value 'exit 3'; .\references\scripts\run-all.ps1 2>&1; Write-Output \"Exit: $LASTEXITCODE\""
```
Expected: Exit code 3 is captured (not 0 or 1)

- [x] **Step 4: Commit**

```bash
git add references/scripts/run-all.ps1
git commit -m "feat: create run-all.ps1 unified scan pipeline entry point"
```

---

### Task 7: clean-residuals.ps1 — Three-Phase Batch Processing

**Files:**
- Modify: `references/scripts/clean-residuals.ps1:226-303`
- Modify: `tests/unit/scripts.Tests.ps1` (test assertion sync)

> **Delphi R2 修复 [C3]**: 补充三阶段设计细节。

**设计说明**:
- **跨 item 拆分**: 同一个 item 可能同时包含 `path` + `key` + `name/binary_path`。三阶段按**操作类型**拆分，不按 item 拆分。例如 item `{id: svc_001, path: "C:\...", key: "HKLM:\...", name: "mysvc", binary_path: "C:\...\svc.exe"}` 会被：Phase 1 停止 mysvc → Phase 2 删除 path + 删除 mysvc → Phase 3 删除 key。
- **错误传播**: Phase 1 stop 失败不阻塞 Phase 2（服务可能已崩溃）。Phase 2 的 service delete 在 path delete 之后（确保二进制已释放）。每阶段独立 try/catch + 独立 log 条目。
- **日志原子性**: 每个 item 在每个 phase 产生独立的 log 条目（`path_deleted`, `service_deleted`, `registry_deleted`），而非一个 item 一条汇总日志。
- **服务预收集**: Phase 1 通过 foreach 遍历 `$eligibleItems` 检查 `$item.name -and $item.binary_path` 条件，无需单独的预收集步骤（条件判断已在循环内）。

- [x] **Step 1: Replace single foreach with three-phase batch processing**

Replace lines 226-303 (the `foreach ($item in $cleanupItems)` block) with:

```powershell
# --- Three-phase batch processing ---
$log = [System.Collections.Generic.List[Hashtable]]::new()
$prefix = if ($DryRun) { "[DRY-RUN] " } else { "" }

# Pre-filter: whitelist + danger (applies to all phases)
$eligibleItems = @()
foreach ($item in $cleanupItems) {
    if (Test-Whitelisted -Path $item.path -Key $item.key -ServiceName $item.name) {
        Write-Warning "$prefix SKIP (whitelisted): $($item.id)"
        $log.Add(@{ id=$item.id; action='skipped_whitelisted'; success=$false })
        continue
    }
    if ($item.risk -eq 'danger') {
        Write-Warning "$prefix SKIP (danger): $($item.id) - $($item.reason)"
        $log.Add(@{ id=$item.id; action='skipped_danger'; success=$false })
        continue
    }
    $eligibleItems += $item
}

# Phase 1: Stop all services (stop only, no delete)
Write-Output "$prefix Phase 1: Stopping services..."
foreach ($item in $eligibleItems) {
    if ($item.name -and $item.binary_path) {
        Write-Output "$prefix   Stopping service: $($item.name)"
        if (-not $DryRun) {
            try {
                sc.exe stop $item.name 2>$null
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
foreach ($item in $eligibleItems) {
    try {
        # Clean files/dirs
        if ($item.path) {
            Write-Output "$prefix   Deleting path: $($item.path)"
            if (-not $DryRun) {
                if (Test-Path $item.path) {
                    # M1-B fix: removed -WhatIf:$DryRun (already inside if(-not $DryRun) block)
                    $deleted = Remove-ItemRobust -Path $item.path
                    if (-not $deleted) {
                        throw "Failed to delete path after all fallback strategies"
                    }
                } else {
                    Write-Output "  → Path does not exist (already removed), skipping"
                }
            }
            $log.Add(@{ id=$item.id; action='path_deleted'; path=$item.path; success=$true })
        }

        # Delete services (after files, so binaries are released)
        if ($item.name -and $item.binary_path) {
            Write-Output "$prefix   Deleting service: $($item.name)"
            if (-not $DryRun) {
                sc.exe delete $item.name 2>&1
                if ($LASTEXITCODE -ne 0) { throw "sc.exe delete failed with exit code $LASTEXITCODE" }
            }
            $log.Add(@{ id=$item.id; action='service_deleted'; name=$item.name; success=$true })
        }
    } catch {
        $log.Add(@{ id=$item.id; action='cleanup_failed'; error=$_.Exception.Message; success=$false })
    }
}

# Phase 3: Clean registry keys
Write-Output "$prefix Phase 3: Cleaning registry..."
foreach ($item in $eligibleItems) {
    try {
        if ($item.key) {
            Write-Output "$prefix   Deleting registry key: $($item.key)"
            if (-not $DryRun) {
                $regKey = $item.key
                cmd /c "reg query `"$regKey`" 2>&1"
                if ($LASTEXITCODE -ne 0) {
                    Write-Output "  → Registry key does not exist (already removed), skipping"
                    $log.Add(@{ id=$item.id; action='registry_skip'; key=$item.key; success=$true; note='key not found' })
                    continue
                }
                reg delete "$regKey" /f 2>&1
                if ($LASTEXITCODE -ne 0) { throw "reg delete failed with exit code $LASTEXITCODE" }
            }
            $log.Add(@{ id=$item.id; action='registry_deleted'; key=$item.key; success=$true })
        }
    } catch {
        $log.Add(@{ id=$item.id; action='cleanup_failed'; error=$_.Exception.Message; success=$false })
    }
}
```

- [x] **Step 2: Update test assertions in scripts.Tests.ps1**

The three-phase batch processing changes output text. Update `tests/unit/scripts.Tests.ps1` line 364:

Replace:
```powershell
        $output | Should -Match 'Stopping and deleting service: testsvc'
```
With:
```powershell
        $output | Should -Match 'Stopping service: testsvc'
        $output | Should -Match 'Deleting service: testsvc'
```

- [x] **Step 3: Verify Where-Object .Count trap is fixed in summary**

> **M3-C 澄清**: 三阶段重构后的 summary 代码是新写的（Step 1 的代码块中已包含 `@()` 包装）。此步骤仅做**验证**，不做替换。

Verify the summary section of clean-residuals.ps1 uses `@()` wrapping for all Where-Object results:
```powershell
    succeeded = @($log | Where-Object { $_.success -eq $true }).Count
    failed = @($log | Where-Object { $_.success -eq $false -and $_.action -eq 'cleanup_failed' }).Count
    skipped = @($log | Where-Object { $_.action -match 'skipped' }).Count
```
If `@()` is missing on any of these, add it. This prevents the single-result `.Count` trap (AGENTS.md §3).

- [x] **Step 4: Verify syntax**

Run: `pwsh -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content references/scripts/clean-residuals.ps1 -Raw), [ref]\$null) | Out-Null; Write-Output 'OK'"`
Expected: OK

- [x] **Step 5: Commit**

```bash
git add references/scripts/clean-residuals.ps1 tests/unit/scripts.Tests.ps1
git commit -m "fix: three-phase batch processing (stop services → delete files → clean registry)"
```

---

### Task 8: Fix candidate_directories Dead Code

**Files:**
- Modify: `references/scripts/generate-report.ps1`

> **Delphi R2 修复 [M2]**: 补充数据流说明。
> **数据流**: `scan-uninstalled.ps1` 输出 `uninstalled-list.json` 包含 `candidate_directories` 数组（文件系统反查结果）。`generate-report.ps1` 读取该文件但当前只提取 `uninstalled_software`，忽略 `candidate_directories`。修复后将其纳入 `final-report.json`。
> **M4-A 澄清**: 设计文档 §1.7 说"合并到 fs-residuals.json 的数据流中"，但实际实现更简单 — 直接从 `uninstalled-list.json` 读取并写入 `final-report.json`（不经过 `fs-residuals.json` 中转）。理由：candidate_directories 来自 scan-uninstalled.ps1（非 scan-filesystem-residuals.ps1），逻辑上应保持在 uninstalled 数据流中。
> **范围限定**: 本 Task 仅修复报告管道（使其出现在 final-report.json 中）。candidate_directories 的 ID 分配和清理能力留给后续迭代（当前 agent 工作流不处理此类项）。

- [x] **Step 1: Add candidate_directories to report generation**

After line 99 (`uninstalled_software = $uninstalled.uninstalled_software`), add:

```powershell
    # Include candidate_directories from scan-uninstalled.ps1 (L1-T8 fix)
    candidate_directories = if ($uninstalled.candidate_directories) {
        $uninstalled.candidate_directories
    } else { @() }
```

- [x] **Step 2: Verify report includes candidate_directories**

Run: `pwsh -File references/scripts/generate-report.ps1` then check `final-report.json` has `candidate_directories` key.

- [x] **Step 3: Commit**

```bash
git add references/scripts/generate-report.ps1
git commit -m "fix: include candidate_directories in final report (was dead code)"
```

---

## Layer 2: Polish — Tests + Documentation

### Task 9: Fix SKILL.md Tests

**Files:**
- Modify: `tests/unit/config.Tests.ps1:119-139`

- [x] **Step 1: Fix description regex test**

Replace line 121:
```powershell
        $content | Should -Match 'description:\s+Scan and clean'
```
With:
```powershell
        $content | Should -Match 'description:\s*"?Scan and clean'
```

- [x] **Step 2: Fix cleanup modes test**

Replace lines 133-139:
```powershell
    It 'Documents all 4 cleanup modes' {
        $content = Get-Content $skillPath -Raw
        $content | Should -Match 'Option A'
        $content | Should -Match 'Option B'
        $content | Should -Match 'Option C'
        $content | Should -Match 'Option D'
    }
```
With:
```powershell
    It 'Documents cleanup workflow with safety gates' {
        $content = Get-Content $skillPath -Raw
        $content | Should -Match 'DryRun'
        $content | Should -Match 'confirm'
        $content | Should -Match 'safety'
    }
```

- [x] **Step 3: Run tests**

Run: `pwsh -Command "Import-Module Pester -RequiredVersion 5.7.1 -Force; Invoke-Pester tests/unit/config.Tests.ps1 -Output Detailed"`
Expected: All tests pass (21/21)

- [x] **Step 4: Commit**

```bash
git add tests/unit/config.Tests.ps1
git commit -m "fix: update SKILL.md tests for agent-driven workflow format"
```

---

### Task 10: Enhance rollback.ps1 Information Output

**Files:**
- Modify: `references/scripts/rollback.ps1`

- [x] **Step 1: Enhance information output**

After the existing backup directory detection logic, add the following output:

```powershell
# List registry backup files with sizes
$regFiles = Get-ChildItem -Path $backupDir -Filter "reg-*.reg" -ErrorAction SilentlyContinue
if ($regFiles) {
    Write-Output "`nRegistry backup files:"
    foreach ($f in $regFiles) {
        Write-Output "  $($f.Name) ($([math]::Round($f.Length / 1KB, 1)) KB)"
    }
} else {
    Write-Output "  No registry backup files found."
}

# Show restore status if available
$statusFile = Join-Path $backupDir "restore-status.json"
if (Test-Path $statusFile) {
    $status = Get-Content $statusFile -Raw | ConvertFrom-Json
    Write-Output "`nRestore point: $($status.restore_point_description ?? 'N/A')"
}

Write-Output "`nNOTE: Automatic rollback feature is under development."
Write-Output "To manually restore, use System Restore from Windows Recovery."
```

- [x] **Step 2: Verify syntax + commit**

```bash
git add references/scripts/rollback.ps1
git commit -m "docs: enhance rollback.ps1 information output"
```

---

### Task 11: Run Full Regression Tests

- [x] **Step 1: Run all unit tests**

Run: `pwsh -Command "Import-Module Pester -RequiredVersion 5.7.1 -Force; Invoke-Pester tests/ -Output Detailed"`
Expected: All tests pass, 0 failures

- [x] **Step 2: Fix any remaining test issues**

If tests fail, fix the specific issues. Common fixes:
- Update function name references if aliases changed
- Adjust mock data for new output format (confidence field)

- [x] **Step 3: Commit**

```bash
git add tests/
git commit -m "test: all regression tests passing after Layer 0-1 changes"
```

---

## Layer 3: Release — Distribution Ready

### Task 12: Web UI Validation (CLI-First Strategy)

- [x] **Step 1: Test npm install + build**

Run: `cd ui && npm install && npm run build`
Expected: Build succeeds

- [x] **Step 2: If build fails, assess severity**

- Minor issues (warnings, deprecations): Fix and continue
- Major issues (broken components, missing dependencies): Remove UI references, mark as "Web UI in development"

- [x] **Step 3: Commit any UI fixes**

```bash
git add ui/
git commit -m "fix: resolve Web UI build issues"
```

---

### Task 13: Create setup.ps1

**Files:**
- Create: `setup.ps1`

- [x] **Step 1: Create environment check script**

```powershell
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
```

- [x] **Step 2: Test setup.ps1**

Run: `pwsh -File setup.ps1`
Expected: Environment report with pass/fail status

- [x] **Step 3: Commit**

```bash
git add setup.ps1
git commit -m "feat: add setup.ps1 environment check script"
```

---

### Task 14: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md`

- [x] **Step 1: Add exit code table, permission grading, run-all.ps1 usage**

Add sections for:
- Exit code table (0-3 + extension space)
- Permission grading (write scripts = mandatory admin, read scripts = warning only)
- run-all.ps1 usage and responsibility boundary
- Function/execution separation pattern documentation

- [x] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: update AGENTS.md with exit codes, permissions, run-all.ps1"
```

---

### Task 15: Final Validation

- [x] **Step 1: Run full test suite**

Run: `pwsh -Command "Import-Module Pester -RequiredVersion 5.7.1 -Force; Invoke-Pester tests/ -Output Detailed"`
Expected: 0 failures

- [x] **Step 2: Run PSScriptAnalyzer on all scripts**

Run: `pwsh -Command "Invoke-ScriptAnalyzer -Path references/scripts/ -Severity Error,Warning"`
Expected: 0 errors, 0 warnings

- [x] **Step 3: Verify run-all.ps1 end-to-end (requires admin)** — 2026-09-11 管理员运行通过：exit 0，144.2s，306 items（Safe 160 / Caution 146 / Danger 0）；winget JSON 解析失败回退文本索引（401 entries）

Run: `pwsh -File references/scripts/run-all.ps1`
Expected: Generates final-report.json

- [x] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final validation — all tests passing, ready for review"
```

---

## Test Gates (Delphi R1 C3 + R2 M3 fix)

> **每个高风险 Task 完成后必须运行测试门禁，不通过则不继续后续 Task。**

### 通用通过标准（适用于所有 Gate）

1. 所有 Pester 测试通过（0 failures）
2. 被修改脚本的 dot-source 不产生副作用（`Write-Output 'OK'` 无额外输出）
3. 输出 JSON schema 无破坏性变更（或变更已同步到下游消费者）

### Gate A: After Task 3b (scan-uninstalled 所有修改完成后)

```powershell
pwsh -Command "Import-Module Pester -RequiredVersion 5.7.1 -Force; Invoke-Pester tests/ -Output Detailed"
```

### Gate B: After Task 7 (三轮批处理修改后)

```powershell
pwsh -Command "Import-Module Pester -RequiredVersion 5.7.1 -Force; Invoke-Pester tests/ -Output Detailed"
```
特别注意 `clean-residuals.ps1 ConfirmFile integration` 测试的断言文本同步。

### Gate C: After Task 4 (权限检查添加后)

```powershell
# 验证 dot-source 不触发权限检查
pwsh -Command ". .\references\scripts\clean-residuals.ps1; Write-Output 'OK'"
pwsh -Command ". .\references\scripts\scan-residuals.ps1; Write-Output 'OK'"
# 验证语法
pwsh -Command "Get-ChildItem references/scripts/*.ps1 | ForEach-Object { [System.Management.Automation.PSParser]::Tokenize((Get-Content $_ -Raw), [ref]`$null) | Out-Null }; Write-Output 'All syntax OK'"
```

### Gate D: After Task 6 (run-all.ps1 创建后)

```powershell
# 语法验证
pwsh -Command "[System.Management.Automation.PSParser]::Tokenize((Get-Content references/scripts/run-all.ps1 -Raw), [ref]`$null) | Out-Null; Write-Output 'OK'"
# dot-source 安全验证
pwsh -Command ". .\references\scripts\run-all.ps1; Write-Output 'OK'"
```

---

## Delphi Plan Review — Fix Summary

> R1: 3 位专家一致 REQUEST_CHANGES (8/10) → 修复 → R2: 再次 REQUEST_CHANGES (8/10) → 再次修复

### Round 1 Fixes

| Issue | 专家 | 修复内容 | 状态 |
|-------|------|---------|:----:|
| C1: run-all.ps1 硬编码 `pwsh` + ArgumentList 语法错误 | A, B | 动态检测 `$psExe`，正确构造 `$argList` | ✅ |
| C2: Task 3 范围过大 | C | 分步验证 | ✅ |
| C3: 测试门禁太晚 | A, C | 新增 Gate A + Gate B | ✅ |
| M1: `$stepResults +=` 作用域 Bug | A, B | 改用 `List[Hashtable]` + `.Add()` | ✅ |
| M2: Task 7 破坏现有测试断言 | A | 新增 Step 2 更新断言 | ✅ |
| M3: `$whitelist` 变量作用域 | A | 记录在案 | ✅ |
| M4: Task 2 粒度过粗 | C | 拆分为 2a + 2b | ✅ |

### Round 2 Fixes

| Issue | 专家 | 修复内容 | 状态 |
|-------|------|---------|:----:|
| C1: Task 2b 丢失 + confirm-cleanup.ps1 遗漏 | B | 恢复 Task 2b（含 confirm-cleanup + build-installed-index） | ✅ |
| C2: Task 3 仍过大 | C | 拆分为 Task 3a（加权判断）+ Task 3b（env var + notmatch） | ✅ |
| C3: Task 7 三阶段设计细节不足 | A, B, C | 补充跨 item 拆分、错误传播、日志原子性说明 | ✅ |
| M1: Task 4 缺乏实现细节 | A, B, C | 补充实现方式 + 隐式依赖说明 | ✅ |
| M2: Task 8 级联影响未分析 | A, B, C | 补充数据流 + 范围限定 | ✅ |
| M3: Test Gates 不足 | A | 新增 Gate C（T4 后）+ Gate D（T6 后）+ 通用通过标准 | ✅ |
| M4: Task 1 Get-ExecutablePath 作用域 | A, B | 明确保留在 Main 外部作为顶层函数 | ✅ |
| M5: Task 6 PS 检测策略不明确 | C | 明确 pwsh 优先 + PS 5.1 绝对路径 fallback | ✅ |

### 实施注意事项

1. **Task 3a/3b 分步执行**: 先完成 3a（加权判断）→ 3b（env var + notmatch）→ Gate A → 确认通过后再继续
2. **Task 7 测试同步**: 三轮批处理输出文本变更后，必须同步更新 `scripts.Tests.ps1` 断言
3. **PSScriptAnalyzer 目标**: 0 errors, warnings reviewed and justified
4. **回滚策略**: 每个 Task 完成后 git commit，回归时 `git revert`

---

### Round 3 Fixes (实施过程中发现)

> R3: 3 位专家一致 REQUEST_CHANGES (7/10) → 修复

| Issue | 专家 | 修复内容 | 状态 |
|-------|------|---------|:----:|
| C1: 执行守卫模式文档/实现全面不同步 | A, B, C | 计划 lines 38/90/449/838 + 设计文档 lines 49/58/63 全部更新为 `$MyInvocation.InvocationName -ne '.'` | ✅ |
| M1-A: Task 3a/3b 行号因 Task 2b 偏移 | A, C | 改为代码内容定位 + 标注"Task 2b 完成后的行号" | ✅ |
| M1-B: Task 7 Phase 2 `-WhatIf:$DryRun` 死代码 | B | 移除冗余参数（已在 `if (-not $DryRun)` 块内） | ✅ |
| M1-C: Task 5 缺少验证步骤 | C | 新增 Step 2 语法验证 + dot-source 安全验证 | ✅ |
| M2-A: Task 6 退出码传播需显式测试 | A | 新增 Step 3 退出码传播验证 | ✅ |
| M3-A: Task 4 权限检查冗余说明 | A | 补充 run-all.ps1 vs 独立调用场景说明 | ✅ |
| M3-B: Task 10 过于模糊 | B | 补充完整代码片段 + 具体输出格式 | ✅ |
| M3-C: Task 7 Step 3 自相矛盾 | C | 改为"验证"而非"替换" + 澄清说明 | ✅ |
| M4-A: candidate_directories 数据流路径不一致 | A | 补充简化偏差说明（直接从 uninstalled-list.json 到 final-report.json） | ✅ |
| M4-C: 设计文档 R1 修复注释反转 | B, C | 更新为 R3 修复记录 + 实证发现说明 | ✅ |
| M5: `$installedNames` 类型确认 | B | 确认为 Hashtable，`.Keys` 正确 | ✅ |
