#Requires -Version 5.1
<#
.SYNOPSIS
    Guard tests for tools/New-SkillPackage.ps1 and the CLI/UI packaging split.

.DESCRIPTION
    This repo ships two things with very different blast radius:

      * the PowerShell pipeline (references/) -- a cleaner
      * a local Express server (ui/server/)    -- spawns admin-privileged PowerShell

    Shipping them as one artifact means everyone who wants the cleaner silently
    acquires a privileged local listener. The packaging script enforces the split;
    these tests keep the enforcement honest, because a packaging rule that is only
    asserted by the packager itself is a rule that can be deleted together with it.

    The build is expensive-ish (copies a tree), so it runs once in BeforeAll.
#>

Describe 'Skill packaging: CLI 与 UI 的分离（2026-10-24）' {
    BeforeAll {
        $script:Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
        $script:Tool = Join-Path $script:Root 'tools/New-SkillPackage.ps1'
        $script:OutRoot = Join-Path $env:TEMP ('wrc-pkg-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        & $script:Tool -OutputRoot $script:OutRoot *> $null
        $script:SkillPkg = Join-Path $script:OutRoot 'windows-residual-cleaner-skill'
        $script:FullPkg = Join-Path $script:OutRoot 'windows-residual-cleaner-full'
    }

    AfterAll {
        if ($script:OutRoot -and (Test-Path -LiteralPath $script:OutRoot)) {
            Remove-Item -LiteralPath $script:OutRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '打包脚本存在且被 git 跟踪' {
        (Test-Path -LiteralPath $script:Tool) | Should -BeTrue -Because '没有打包脚本，分离规则只存在于人的记忆里'
        $tracked = & git -C $script:Root ls-files --error-unmatch 'tools/New-SkillPackage.ps1' 2>$null
        $LASTEXITCODE | Should -Be 0 -Because '打包脚本必须入库，否则新 clone 上无法复现发布产物'
    }

    It 'skill 包不含管理员权限的服务端（ui/、ui/server/）' {
        # 这是整个分离的存在理由：ui/server 会 spawn 管理员权限的破坏性 PowerShell。
        (Test-Path -LiteralPath (Join-Path $script:SkillPkg 'ui')) | Should -BeFalse -Because 'ui/server 以管理员权限执行删除；它绝不能随「清理器」一起分发'
        (Test-Path -LiteralPath (Join-Path $script:SkillPkg 'ui/server')) | Should -BeFalse
    }

    It 'skill 包不含测试/门禁/开发基础设施' {
        foreach ($d in @('tests', 'tools', 'githooks', 'node_modules')) {
            (Test-Path -LiteralPath (Join-Path $script:SkillPkg $d)) | Should -BeFalse -Because "skill 包是给使用者的，$d 是给维护者的；混进去既增大体积也扩大攻击面"
        }
    }

    It 'skill 包含有可运行的完整管线（不是空壳）' {
        foreach ($f in @('SKILL.md', 'LICENSE',
                         'references/scripts/run-all.ps1',
                         'references/scripts/clean-residuals.ps1',
                         'references/scripts/rollback.ps1',
                         'references/scripts/native-invoke.ps1',
                         'references/config/whitelist.json')) {
            (Test-Path -LiteralPath (Join-Path $script:SkillPkg $f)) | Should -BeTrue -Because "skill 包缺 $f —— 包不可运行，或复制清单写错了"
        }
        # 全部 17 个脚本都要在：少一个可能就是少一整个功能。
        $scripts = @(Get-ChildItem -LiteralPath (Join-Path $script:SkillPkg 'references/scripts') -Filter '*.ps1' -File)
        $scripts.Count | Should -Be 17 -Because "references/scripts 有 17 个脚本，包里只有 $($scripts.Count) 个，说明复制清单漏项"
    }

    It '打包脚本在 skill 包混入 ui/ 时**真的抛错**（防未来改坏 Include 清单）' {
        # 用 allow-list 而不是 deny-list，但 guard 仍要验证：有人把 'ui' 加进
        # skill 包的 Include 时，脚本必须在产出前中止，而不是默默打出一个危险包。
        $probeRoot = Join-Path $env:TEMP ('wrc-pkg-guard-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
        try {
            # 复制打包脚本并篡改它的 skill 包 Include 列表。
            $text = Get-Content -LiteralPath $script:Tool -Raw
            $tampered = $text.Replace(
                "Include     = @('SKILL.md', 'VERSION', 'LICENSE', 'references')",
                "Include     = @('SKILL.md', 'VERSION', 'LICENSE', 'references', 'ui')")
            $tampered | Should -Not -Be $text -Because '用例本身要能篡改到 Include 行；改不到说明脚本结构变了，需要更新此用例'
            $tamperedPath = Join-Path $script:Root 'tools/_tampered-pkg-probe.ps1'
            Set-Content -LiteralPath $tamperedPath -Value $tampered -Encoding UTF8
            try {
                { & $tamperedPath -OutputRoot $probeRoot *> $null } | Should -Throw '*必须分离*' -Because 'skill 包一旦含 ui/ 就必须中止，而不是打出来'
            }
            finally {
                Remove-Item -LiteralPath $tamperedPath -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'full 包保留 ui/（维护者需要），且产出 packages.json 清单' {
        (Test-Path -LiteralPath (Join-Path $script:FullPkg 'ui')) | Should -BeTrue -Because 'full 包是给维护者的，必须保留 UI'
        (Test-Path -LiteralPath (Join-Path $script:FullPkg 'tests')) | Should -BeTrue
        $manifestPath = Join-Path $script:OutRoot 'packages.json'
        (Test-Path -LiteralPath $manifestPath) | Should -BeTrue
        $doc = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        @($doc.packages).Count | Should -Be 2
        ($doc.packages | Where-Object { $_.name -eq 'windows-residual-cleaner-skill' }) |
            Should -Not -BeNullOrEmpty
    }

    It 'SKILL.md 的权限表与 run-all.ps1 的实际要求一致（文档不能比代码乐观）' {
        # 2026-10-24 实测：SKILL.md 曾写「扫描不需要管理员」，而 run-all.ps1:35
        # 在考虑 -SkipRestorePoint 之前就无条件 Test-AdminPrivilege -Mandatory，
        # 未提权直接退出码 2。文档比代码乐观 = 用户第一步就撞墙。
        $runAll = Get-Content -LiteralPath (Join-Path $script:Root 'references/scripts/run-all.ps1') -Raw
        $runAll | Should -Match 'Test-AdminPrivilege\s+-Mandatory' -Because 'run-all.ps1 确实要求管理员；若将来放宽，本用例与 SKILL.md 都要同步改'
        $skill = Get-Content -LiteralPath (Join-Path $script:Root 'SKILL.md') -Raw
        $skill | Should -Match '(?i)run-all\.ps1.*\*?\*?Yes' -Because 'SKILL.md 必须把 run-all.ps1 标成需要管理员'
        $skill | Should -Match '(?i)does \*?\*?not\*?\*?\*?\*? bypass|不.*绕过' -Because '必须写明 -SkipRestorePoint 不解除管理员要求（实测如此，反直觉）'
    }
}
