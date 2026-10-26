#Requires -Version 5.1
<#
.SYNOPSIS
    Guards that the exit-code table in the docs still matches the code.

.DESCRIPTION
    Before this existed, the exit-code semantics were retyped by hand into four
    places: rollback-producer.ps1 (the implementation), SKILL.md,
    docs/agent-workflow-pattern.md, and AGENTS.md. One truth, four copies, and no
    mechanism that fails when they disagree.

    That is precisely the failure shape this repo keeps hitting: a fact is correct
    when written and rots silently afterwards. `tools/Update-DocTables.ps1` now
    derives both doc tables from the code comment; these tests make sure nobody
    quietly reintroduces a hand-maintained copy.

    The tests run the generator in -Check mode (the same thing CI runs), so a
    documented table that drifts from Get-CleanupExitCode turns the suite red
    instead of being discovered by a reader months later.
#>

Describe 'Doc tables: 退出码表单一事实来源（2026-10-25）' {
    BeforeAll {
        $script:Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
        $script:Generator = Join-Path $script:Root 'tools/Update-DocTables.ps1'
        $script:Producer = Join-Path $script:Root 'references/scripts/rollback-producer.ps1'
        $script:SkillPath = Join-Path $script:Root 'SKILL.md'
        $script:PatternPath = Join-Path $script:Root 'docs/agent-workflow-pattern.md'
        $script:AgentsPath = Join-Path $script:Root 'AGENTS.md'

        function Get-MarkedBlock {
            param([string]$Path, [string]$Begin, [string]$End)
            $text = Get-Content -LiteralPath $Path -Raw
            $m = [regex]::Match($text, '(?s)' + [regex]::Escape($Begin) + '(.*?)' + [regex]::Escape($End))
            return $m.Groups[1].Value
        }
    }

    It '生成器与两份文档都被 git 跟踪' {
        foreach ($rel in @('tools/Update-DocTables.ps1', 'SKILL.md', 'docs/agent-workflow-pattern.md', 'AGENTS.md')) {
            & git -C $script:Root ls-files --error-unmatch $rel 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0 -Because "$rel 必须入库，否则新 clone 上漂移检查跑不起来"
        }
    }

    It '文档中的退出码表与代码一致（运行生成器的 -Check 模式）' {
        # 这是 CI 跑的同一条命令；不一致即红。
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Generator -Check 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "退出码表漂移：$($out -join ' | ')"
    }

    It '生成块的换行符与所在文档一致（否则干净 checkout 上的 -Check 会假红）' {
        # 2026-10-25 CI 实测：仓库里这三份 .md 存的是 LF，但生成器当时用 CRLF 拼块。
        # 本机工作树恰好是 CRLF 所以本地绿，CI 干净检出是 LF → 三份文档全报 OUT OF DATE。
        # 断言「块内不含 CRLF 与文档自身不一致的情况」，让这类检出差异当场变红。
        foreach ($path in @($script:SkillPath, $script:PatternPath, $script:AgentsPath)) {
            $text = Get-Content -LiteralPath $path -Raw
            $block = Get-MarkedBlock -Path $path -Begin '<!-- BEGIN GENERATED: exit-codes -->' -End '<!-- END GENERATED: exit-codes -->'
            $block | Should -Not -BeNullOrEmpty -Because "$([System.IO.Path]::GetFileName($path)) 的生成块应当非空"
            $docHasCrlf = $text.Contains("`r`n")
            $blockHasCrlf = $block.Contains("`r`n")
            $blockHasCrlf | Should -Be $docHasCrlf -Because "$([System.IO.Path]::GetFileName($path))：文档换行=$(if ($docHasCrlf) {'CRLF'} else {'LF'})，生成块换行=$(if ($blockHasCrlf) {'CRLF'} else {'LF'})——生成器必须沿用目标文档的换行符，否则本机与 CI 的 -Check 结论会相反"
        }
    }

    It 'SKILL.md 与 pattern 文档都带生成块标记' {
        # 标记是把两份文档绑到同一个事实来源的**唯一机制**。
        # 删掉标记 = 悄悄退回手工维护，而那正是这次要消除的东西。
        foreach ($p in @($script:SkillPath, $script:PatternPath, $script:AgentsPath)) {
            $text = Get-Content -LiteralPath $p -Raw
            $text | Should -Match '<!-- BEGIN GENERATED: exit-codes -->' -Because "$([System.IO.Path]::GetFileName($p)) 缺起始标记，表格会退回手工维护"
            $text | Should -Match '<!-- END GENERATED: exit-codes -->' -Because "$([System.IO.Path]::GetFileName($p)) 缺结束标记"
        }
    }

    It '两份文档的码集合完全相同（同一个来源，不允许各自漂移）' {
        $skillBlock = Get-MarkedBlock -Path $script:SkillPath -Begin '<!-- BEGIN GENERATED: exit-codes -->' -End '<!-- END GENERATED: exit-codes -->'
        $patternBlock = Get-MarkedBlock -Path $script:PatternPath -Begin '<!-- BEGIN GENERATED: exit-codes -->' -End '<!-- END GENERATED: exit-codes -->'

        $skillCodes = @([regex]::Matches($skillBlock, '\|\s*`(\d+)`\s*\|') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $patternCodes = @([regex]::Matches($patternBlock, '\|\s*(\d+)\s*\|') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)

        $skillCodes.Count | Should -BeGreaterThan 0
        ($skillCodes -join ',') | Should -Be ($patternCodes -join ',') -Because '两份文档的退出码集合必须一致——它们来自同一个生成器'
    }

    It '每个码在表里只出现一次（同码不同义要合并，不是插两行）' {
        # 实测坑：码 1 既是「缺输入」（调用方早返回）又是「部分失败无已变更记录」
        # （Get-CleanupExitCode）。第一版生成器把两者各插一行，表格出现两个 `1`，
        # 读者无法判断哪个适用。现在合并为一行。
        $block = Get-MarkedBlock -Path $script:SkillPath -Begin '<!-- BEGIN GENERATED: exit-codes -->' -End '<!-- END GENERATED: exit-codes -->'
        $codes = @([regex]::Matches($block, '\|\s*`(\d+)`\s*\|') | ForEach-Object { $_.Groups[1].Value })
        $codes.Count | Should -Be (@($codes | Sort-Object -Unique).Count) -Because "表里出现重复码：$($codes -join ',')"
    }

    It '表里包含代码中确有语义的每一个码（不能因为「不在优先级链里」就不写）' {
        # 2/3 是调用方早返回的，不参与优先级链，但 agent 看到 2 必须知道是「没提权」。
        $block = Get-MarkedBlock -Path $script:SkillPath -Begin '<!-- BEGIN GENERATED: exit-codes -->' -End '<!-- END GENERATED: exit-codes -->'
        foreach ($code in @('0', '1', '2', '3', '10', '11', '12', '13', '14', '15')) {
            $block | Should -Match "\|\s*``$code``\s*\|" -Because "退出码 $code 在代码里有明确语义，表格必须收录"
        }
    }

    It '优先级链与代码的分支顺序一致' {
        # Get-CleanupExitCode 的 guard 顺序即优先级，**包括 0 的位置**。
        # 实测：代码是 14,15,0,13,12,1,11,10 —— 0 夹在 15 与 13 之间
        # （`$FailedCount -le 0` 的判定早于 `$NoAutoRollback`）。0 的位置本身有意义：
        # 它说明「没有失败」优先于「显式放弃回滚」的判断，所以必须原样比，
        # 不能像第一版那样把 0 过滤掉（那样会得出错误结论并误判不一致）。
        $producer = Get-Content -LiteralPath $script:Producer -Raw
        # 用索引切出函数体，不用正则：`(.*?)\n\}` 会被函数体内任何一层缩进的
        # 右花括号提前截断（实测切到第 4 个分支就停了），得到一份「看起来对」的
        # 短清单。按大括号配平扫描才可靠。
        $startIdx = $producer.IndexOf('function Get-CleanupExitCode')
        $startIdx | Should -BeGreaterThan -1 -Because '定位不到 Get-CleanupExitCode，本用例失去基准'
        $openIdx = $producer.IndexOf('{', $startIdx)
        $openIdx | Should -BeGreaterThan -1
        $depth = 0
        $endIdx = -1
        for ($i = $openIdx; $i -lt $producer.Length; $i++) {
            if ($producer[$i] -eq '{') { $depth++ }
            elseif ($producer[$i] -eq '}') {
                $depth--
                if ($depth -eq 0) { $endIdx = $i; break }
            }
        }
        $endIdx | Should -BeGreaterThan $openIdx -Because '函数体没有配平的右花括号'

        $body = $producer.Substring($openIdx, $endIdx - $openIdx)
        $actual = @()
        foreach ($m in [regex]::Matches($body, 'if\s*\(.*?\)\s*\{\s*return\s+(\d+)\s*\}')) {
            $actual += $m.Groups[1].Value
        }
        # 末尾不带 if 的兜底 `return 10` / `return 0` 单独补
        foreach ($m in [regex]::Matches($body, '\n\s*return\s+(\d+)\s*\n')) {
            $actual += $m.Groups[1].Value
        }

        $expected = @('14', '15', '0', '13', '12', '1', '11', '10')
        ($actual -join ',') | Should -Be ($expected -join ',') -Because '代码里的 return 顺序变了，文档的优先级链会随之失真'
    }
    It '文档里的相对链接都能解析（拆文档最容易留下的债）' {
        # 实测：2026-10-25 把 SKILL.md 拆出 pattern 文档时，末尾留下了
        # `[`SKILL.md`](../../SKILL.md)` —— 从 docs/ 出发会跳到**仓库之外**，
        # 那个链接从来没解析成功过。拆文档必然引入这种债，所以用测试钉住。
        $docs = @(
            (Join-Path $script:Root 'SKILL.md'),
            (Join-Path $script:Root 'docs/agent-workflow-pattern.md')
        )
        $broken = @()
        foreach ($docPath in $docs) {
            $dir = Split-Path -Parent $docPath
            $text = Get-Content -LiteralPath $docPath -Raw
            foreach ($m in [regex]::Matches($text, '\]\((?!#)([^)#]+)')) {
                $target = $m.Groups[1].Value
                if ($target -match '^https?:|^mailto:') { continue }
                # 只校验明显是路径的目标；行内代码里的 `[array]( if ... )` 之类
                # 会被正则误当作链接，用「含空格」排除掉。
                if ($target -match '\s') { continue }
                $resolved = [System.IO.Path]::GetFullPath((Join-Path $dir $target))
                if (-not (Test-Path -LiteralPath $resolved)) {
                    $broken += "$([System.IO.Path]::GetFileName($docPath)) -> $target"
                }
            }
        }
        $broken | Should -BeNullOrEmpty -Because "相对链接解析失败：$($broken -join ' | ')"
    }
}