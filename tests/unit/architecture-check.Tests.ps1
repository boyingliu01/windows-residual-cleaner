#Requires -Version 5.1
<#
.SYNOPSIS
    Guard tests for tools/Test-PowerShellArchitecture.ps1 (Gate 6 PowerShell arm).

.DESCRIPTION
    Gate 6 printed `SKIPPED - Architecture validation (no tool for PowerShell)`
    until 2026-10-24. `archlint` really cannot parse PowerShell, but the
    constraint is not about a parser: "which script may depend on which" is
    language-agnostic. The layering now lives in architecture.yaml and is checked
    by this tool.

    These tests exist because a layering checker has two distinct ways to be
    useless, and neither is visible from a green run:
      1. it parses no layers          -> "0 violations" because it inspected nothing
      2. it finds no edges            -> same, at a different layer
    Both were MEASURED while building it (block-list `paths:` unsupported ->
    edges=1 instead of 14), so both are pinned here.
#>

Describe 'Test-PowerShellArchitecture (Gate 6 PowerShell arm)' {
    BeforeAll {
        $script:Root = Join-Path $PSScriptRoot '..\..'
        $script:Tool = Join-Path $script:Root 'tools/Test-PowerShellArchitecture.ps1'
        $script:Yaml = Join-Path $script:Root 'architecture.yaml'

        function New-ScratchRepo {
            <#
                Copy architecture.yaml + the checker into a scratch tree so tests can
                inject violations without touching the real repo.
            #>
            $dir = Join-Path $env:TEMP ('arch-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path (Join-Path $dir 'references/scripts') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $dir 'tools') -Force | Out-Null
            Copy-Item -LiteralPath $script:Yaml -Destination (Join-Path $dir 'architecture.yaml') -Force
            Copy-Item -LiteralPath $script:Tool -Destination (Join-Path $dir 'tools/Test-PowerShellArchitecture.ps1') -Force
            return $dir
        }

        function Invoke-Checker {
            param([string]$RepoDir)
            $out = & (Join-Path $RepoDir 'tools/Test-PowerShellArchitecture.ps1') 2>&1
            $text = ($out | Out-String)
            $summary = @{}
            foreach ($k in @('layers', 'edges', 'violations', 'failing')) {
                $m = [regex]::Match($text, "$k=(\d+)")
                $summary[$k] = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
            }
            return [pscustomobject]@{
                Text   = $text
                Exit   = $LASTEXITCODE
                Layers = $summary['layers']
                Edges  = $summary['edges']
                Viol   = $summary['violations']
                Fail   = $summary['failing']
            }
        }
    }

    AfterAll {
        Get-ChildItem -Path $env:TEMP -Directory -Filter 'arch-test-*' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'architecture.yaml 里有 powershell 分层块（否则 Gate 6 只能 WARN 或 SKIP）' {
        (Test-Path -LiteralPath $script:Yaml) | Should -BeTrue
        $text = Get-Content -LiteralPath $script:Yaml -Raw
        $text | Should -Match '(?m)^powershell:' -Because 'Gate 6 的 PowerShell 分支要求 architecture.yaml 含顶层 powershell: 块；缺席时门禁会如实 WARN 而不是假装通过'
    }

    It '真实仓库：分层能解析、边能找出、无违规' {
        $r = Invoke-Checker -RepoDir $script:Root
        $r.Layers | Should -BeGreaterThan 0 -Because '解析出 0 层等于没检查任何东西（这正是开发中实测到的第一个坑）'
        $r.Edges | Should -BeGreaterThan 5 -Because "本仓的 rollback 库、scan 叶子、clean 都真实存在依赖边；只找到 $($r.Edges) 条说明 YAML 块列表（paths:\n  - x）没被解析（开发中实测 edges=1 而非 14）"
        $r.Viol | Should -Be 0 -Because "真实仓库当前不应有分层违规；实际：`n$($r.Text)"
        $r.Exit | Should -Be 0
    }

    It '注入「扫描器依赖回滚库」违规会被判失败（证明检查器非空转）' {
        $dir = New-ScratchRepo
        Set-Content -LiteralPath (Join-Path $dir 'references/scripts/rollback-backup.ps1') -Value 'function X { }'
        # ps-scan 层绝不能依赖 ps-rollback-lib 层：扫描器若能回滚就不再是扫描器。
        Set-Content -LiteralPath (Join-Path $dir 'references/scripts/scan-residuals.ps1') -Value @'
$libs = @('rollback-backup.ps1')
. $libPath
'@
        $r = Invoke-Checker -RepoDir $dir
        $r.Viol | Should -BeGreaterThan 0
        $r.Fail | Should -BeGreaterThan 0
        $r.Exit | Should -Not -Be 0 -Because '检测到违规必须让 Gate 6 BLOCK'
        $r.Text | Should -Match 'VIOLATION .*scan-residuals\.ps1 \(ps-scan\) -> rollback-backup\.ps1 \(ps-rollback-lib\)' -Because '违规信息必须点名两端，否则无法修'
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '允许方向的依赖不误报（clean 依赖回滚库是合法的）' {
        $dir = New-ScratchRepo
        Set-Content -LiteralPath (Join-Path $dir 'references/scripts/rollback-backup.ps1') -Value 'function X { }'
        Set-Content -LiteralPath (Join-Path $dir 'references/scripts/clean-residuals.ps1') -Value @'
$libs = @('rollback-backup.ps1')
. $libPath
'@
        $r = Invoke-Checker -RepoDir $dir
        $r.Edges | Should -BeGreaterThan 0 -Because '这条依赖必须被识别成边（否则「无违规」只是因为没找边）'
        $r.Fail | Should -Be 0 -Because "ps-clean -> ps-rollback-lib 在 allowed_imports 里，不该拦；实际：`n$($r.Text)"
        $r.Exit | Should -Be 0
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'scan 叶子依赖 clean 也被拦（反向依赖同样违规）' {
        $dir = New-ScratchRepo
        Set-Content -LiteralPath (Join-Path $dir 'references/scripts/clean-residuals.ps1') -Value 'function Y { }'
        Set-Content -LiteralPath (Join-Path $dir 'references/scripts/scan-uninstalled.ps1') -Value @'
$deps = @('clean-residuals.ps1')
'@
        $r = Invoke-Checker -RepoDir $dir
        $r.Fail | Should -BeGreaterThan 0 -Because 'scan 依赖 clean 会让「扫描→清理」不再是单向管道'
        $r.Text | Should -Match 'ps-scan\) -> clean-residuals\.ps1 \(ps-clean\)'
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '缺 powershell 块时输出 NO_POWERSHELL_LAYERS（不能静默算作通过）' {
        $dir = Join-Path $env:TEMP ('arch-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $dir 'tools') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir 'references/scripts') -Force | Out-Null
        Copy-Item -LiteralPath $script:Tool -Destination (Join-Path $dir 'tools/Test-PowerShellArchitecture.ps1') -Force
        # A yaml with only the TypeScript layers.
        Set-Content -LiteralPath (Join-Path $dir 'architecture.yaml') -Encoding UTF8 -Value @'
layers:
  - name: app
    paths: ["ui/src/**"]
    allowed_imports: []
'@
        $r = Invoke-Checker -RepoDir $dir
        $r.Text | Should -Match 'NO_POWERSHELL_LAYERS' -Because '「没配分层」与「没违规」必须可区分；否则删掉 powershell 块就能让门禁变绿'
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '块列表形式的 paths 被正确解析（架构约束不能静默丢层）' {
        $dir = New-ScratchRepo
        foreach ($f in @('scan-residuals.ps1', 'clean-residuals.ps1', 'rollback-backup.ps1')) {
            Set-Content -LiteralPath (Join-Path $dir "references/scripts/$f") -Value 'function Z { }'
        }
        # scan-uninstalled.ps1 is listed in a BLOCK list in architecture.yaml.
        Set-Content -LiteralPath (Join-Path $dir 'references/scripts/scan-uninstalled.ps1') -Value @'
$deps = @('clean-residuals.ps1')
'@
        $r = Invoke-Checker -RepoDir $dir
        $r.Fail | Should -BeGreaterThan 0 -Because 'scan-uninstalled 只在 YAML 的块列表里出现；解析失败会让它「不属于任何层」从而永远无违规（开发中实测就是这个 bug）'
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
