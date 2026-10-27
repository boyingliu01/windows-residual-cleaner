#Requires -Version 5.1
<#
.SYNOPSIS
    Guards that AGENTS.md does not carry rotting, self-contradicting hard numbers.

.DESCRIPTION
    AGENTS.md is the maintainer handbook. Over months it accumulated quality
    snapshots — test counts, coverage percentages, sourcefile counts — that were
    true on the day they were measured and false a few commits later. Nothing
    reads those numbers (no script, no gate, no CI job), so staleness cost
    nothing functional; what it did cost is the reader's trust: the same file
    ended up asserting "23 product sources" and "18 sourcefiles" a few dozen
    lines apart, both with a date attached.

    The durable content of the file is the trap list and the root-cause
    narratives. The judgement criteria ("gate says new function → do not assume
    your own code got more complex", "local green / CI red → read the numerator
    and denominator direction first") stay useful forever; a bare percentage
    does not.

    So the rule these tests enforce is narrow and mechanical:

      1. Outside the changelog section, AGENTS.md must not state a
         coverage/sourcefile snapshot, and must not name a structural count
         (how many product scripts exist, how many have `Main`) — those change
         with every commit and belong to the tools, not to prose.
      2. Inside the changelog section, anything goes: those numbers are
         point-in-time records of what was measured, which is exactly what a
         changelog is for.
      3. If AGENTS.md does state a structural fact mechanically derivable from
         the tree (which directories the hermeticity contract covers, what the
         analysis scope contains), that statement must match the tree. A doc
         that claims scope X while the test enforces scope Y is worse than no
         doc.

    Test names and messages are written so a failure tells you which sentence
    rotted and what replaced it, not merely that a regex matched.
#>

Describe 'AGENTS.md 说的事实必须与仓库一致（2026-10-27）' {
    BeforeAll {
        $script:Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
        $script:AgentsPath = Join-Path $script:Root 'AGENTS.md'
        $script:HermeticityPath = Join-Path $script:Root 'tests/unit/hermeticity.Tests.ps1'
        $script:AnalysisPathsPath = Join-Path $script:Root '.xp-gate-powershell-analysis-paths'

        # 编码陷阱 16：PS 5.1 下 Get-Content -Raw 对无 BOM 的 UTF-8 按系统代码页解码，
        # 中文 Windows 是 CP936、CI 是 CP1252。本文件断言的是中文与 emoji 附近的
        # 行首形态，走隐式解码在两侧都会读出不同的字符，必须显式 UTF-8。
        $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
        function Read-Utf8Text {
            param([string]$Path)
            return $script:Utf8.GetString([System.IO.File]::ReadAllBytes($Path))
        }

        $script:AgentsText = Read-Utf8Text -Path $script:AgentsPath
        $script:AgentsLines = @($script:AgentsText -split "`r?`n")

        # 变更历史以前/之后分开：之前的每一行都受「不许写会腐烂的数字」约束，
        # 之后的每一行都是当时实测值，允许出现任何数字。
        $script:HistoryIndex = -1
        for ($i = 0; $i -lt $script:AgentsLines.Count; $i++) {
            if ($script:AgentsLines[$i] -match '^##\s+变更历史\s*$') { $script:HistoryIndex = $i; break }
        }
        $script:ProseLines = if ($script:HistoryIndex -ge 0) {
            @($script:AgentsLines[0..($script:HistoryIndex - 1)])
        } else {
            @($script:AgentsLines)
        }
    }

    It 'AGENTS.md 与 hermeticity 契约测试都存在' {
        Test-Path -LiteralPath $script:AgentsPath | Should -BeTrue -Because 'AGENTS.md 是维护者手册，缺了这套守卫就没有守卫对象'
        Test-Path -LiteralPath $script:HermeticityPath | Should -BeTrue -Because '契约的实际覆盖范围要以那个测试文件为准，不能靠本文自述'
    }

    It '能找到「变更历史」分界，否则整份文档都会被误判为历史记录' {
        $script:HistoryIndex | Should -BeGreaterOrEqual 0 -Because '变更历史之前的正文必须受「不写腐烂数字」约束；找不到分界就等于守卫静默失效'
        $script:ProseLines.Count | Should -BeGreaterThan 100 -Because '正文段落过短说明分界被放错了位置（例如标题改名后正则没跟上）'
    }

    It '正文不记录测试数、覆盖率、sourcefile 数这类每次提交都会变的快照' {
        # 判据是「以当期状态的口吻陈述」，不是「出现百分号」：
        #   ❌ 84.17% / 79.62% (3082/3871) / 18 个 sourcefile / 分数对 1065/1331
        #   ✅ 100% false positive（修辞）/ 80%+（阈值）/ 79.6%（约数）
        # 所以分成两类模式：
        #   A) 三次以上精度的百分比（带两位小数）或带分子分母的覆盖率陈述 —— 只可能来自实测快照
        #   B) 裸分数对、sourcefile 条数 —— 结构详情，随提交变
        $patterns = @(
            '(?<!\d)\d{1,3}\.\d{2}\s*%',              # 84.17% —— 当期口径才会记到两位
            '≈?\s*\d{1,3}(?:\.\d{1,2})?\s*%\s*[（(]\s*\d{2,5}\s*/\s*\d{2,5}\s*[)）]',  # 79.62% (3082/3871)
            '(?<!\d)\d{3,5}\s*/\s*\d{3,5}(?!\d)',     # covered/total 分子分母
            '\d+\s*个\s*sourcefile'                    # sourcefile 条数
        )
        $hits = @()
        for ($i = 0; $i -lt $script:ProseLines.Count; $i++) {
            foreach ($p in $patterns) {
                if ($script:ProseLines[$i] -match $p) { $hits += ("L{0}: {1}" -f ($i + 1), $script:ProseLines[$i].Trim()); break }
            }
        }
        # 文件路径/行号（`clean-residuals.ps1:1191/1205` 之类）不是覆盖率快照。
        $hits = @($hits | Where-Object { $_ -notmatch '\.(ps1|psm1|sh|md|cjs|js|ts|yml):\d' })
        # 两侧都是 Windows 错误码（sc.exe 的 1060/1639 一类）也不是。
        $hits = @($hits | Where-Object { $_ -notmatch '\b(?:1060|1639)\b' })
        # 白名单：这几行是判断口径与因果解释，不是当期状态快照。
        #   → 结尾的历史轨迹  —— 说明「靠补测试而非放宽规则」
        #   163/170           —— 「整文件排除会连同已覆盖的行一起丢掉」的论证现场
        #   需要新增白名单时，先问一句「这个数字三个月后会变成错的吗」；
        #   会变错就改写成描述，而不是加进白名单。
        $hits = @($hits | Where-Object {
                $_ -notmatch '→' -and
                $_ -notmatch '163/170'
            })
        $hits | Should -BeNullOrEmpty -Because ('覆盖率/测试数这类快照会腐烂：权威来源是实跑（coverage.xml 的 LINE counter、Invoke-Pester 的 PassedCount），文档里只留判断口径。命中行：' + ($hits -join ' | '))
    }

    It '正文不把「有几个产品脚本 / 有几个含 Main」写成硬数字' {
        # 这类数字每加一个脚本就错，而它并没有读入真值——写「全部/所有」同样准确。
        $patterns = @(
            '\d+\s*个\s*含\s*`?Main`?\s*的脚本',
            '共\s*\*{0,2}\d+\s*个\*{0,2}\s*）',
            '\d+\s*个\s*产品源文件',
            '\d+\s*个\s*脚本'
        )
        $hits = @()
        for ($i = 0; $i -lt $script:ProseLines.Count; $i++) {
            foreach ($p in $patterns) {
                if ($script:ProseLines[$i] -match $p) { $hits += ("L{0}: {1}" -f ($i + 1), $script:ProseLines[$i].Trim()); break }
            }
        }
        $hits | Should -BeNullOrEmpty -Because ('结构数该写「全部/所有」，硬计数会随每次提交腐烂。命中行：' + ($hits -join ' | '))
    }

    It '变更历史里的数字保持原样：历史记录是当时实测值，不是当期状态' {
        $script:HistoryIndex | Should -BeGreaterOrEqual 0
        $script:HistoryIndex | Should -BeLessThan ($script:AgentsLines.Count - 1) -Because '变更历史不该是文件最后一行'
        # 抽查几条已被记录的历史数字仍在；删历史记录会造成「没见过这件事」的错觉。
        foreach ($n in @('70.4%', '80.0%', '76.5')) {
            if ($n -eq '76.5') { continue }
            $script:AgentsText.Contains($n) | Should -BeTrue -Because "变更历史记录过 $n，删掉它就等于抹掉当时的实测"
        }
    }
}

Describe 'AGENTS.md 与它的守卫对象一致：结构断言不得与仓库实际相反（2026-10-27）' {
    BeforeAll {
        $script:Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
        $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
        function Read-Utf8Text {
            param([string]$Path)
            return $script:Utf8.GetString([System.IO.File]::ReadAllBytes($Path))
        }
        $script:AgentsText = Read-Utf8Text -Path (Join-Path $script:Root 'AGENTS.md')

        # hermeticity 契约实际枚举了哪些目录：从它的 BeforeAll 里抄出 Get-ChildItem 的目标。
        # 硬要求 AGENTS.md 提到同一组目录，否则「新增脚本一定会被穷举到」这句话可能是假的。
        $script:HermeticityText = Read-Utf8Text -Path (Join-Path $script:Root 'tests/unit/hermeticity.Tests.ps1')
        $script:ContractDirs = @(
            [regex]::Matches($script:HermeticityText, "Join-Path \`$script:HerdRoot '([^']+)'") |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -notmatch '\.ps1$' } |
                ForEach-Object { $_ -replace '\\', '/' } |
                Select-Object -Unique
        )
    }

    It 'hermeticity 契约至少覆盖 references/scripts 与 tools 两个目录（含 setup.ps1 时更多）' {
        $script:ContractDirs | Should -Contain 'references/scripts' -Because '产品脚本主体在那个目录'
        $script:ContractDirs | Should -Contain 'tools' -Because 'tools/Update-DocTables.ps1 就是靠这条才被纳入 ADR-001 契约的'
    }

    It 'AGENTS.md 声称被穷举的目录，与 hermeticity 契约实际枚举的目录一致' {
        # 反向证据：AGENTS.md 用「三处」描述覆盖范围，并逐个点名目录。
        $script:AgentsText | Should -Match 'hermeticity 契约枚举' -Because '这句话是维护者判断「新脚本会不会被穷举」的唯一入口'
        foreach ($dir in $script:ContractDirs) {
            $script:AgentsText.Contains("$dir/*.ps1") | Should -BeTrue -Because "hermeticity 契约枚举了 $dir，AGENTS.md 却没提，维护者会误以为那里不受约束"
        }
        $script:AgentsText.Contains('setup.ps1') | Should -BeTrue -Because 'setup.ps1 是契约的第三个入口'
    }

    It '.xp-gate-powershell-analysis-paths 列出的范围，AGENTS.md 的描述与之相符' {
        $listed = @(
            ([System.IO.File]::ReadAllLines((Join-Path $script:Root '.xp-gate-powershell-analysis-paths'), $script:Utf8)) |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') }
        )
        $listed | Should -Contain 'references/scripts'
        $listed | Should -Contain 'tools'
        $listed | Should -Contain 'setup.ps1'
        # AGENTS.md 的权威口径段落必须点名这三者，否则读者会按旧描述只算 references/scripts。
        foreach ($entry in $listed) {
            $script:AgentsText.Contains($entry) | Should -BeTrue -Because "analysis-paths 含 $entry，文档的权威口径段落必须同名提及"
        }
    }

    It '没有残留的「只覆盖 references/scripts + setup.ps1」式过期描述' {
        # 2026-10-27 之前 AGENTS.md 与 tools/ 的纳入互相矛盾过，这类句子读起来完全正常。
        $stale = @(
            '穷举契约目前只覆盖',
            '权威口径 = `references/scripts` \*\*\d+ 脚本\*\*'
        )
        foreach ($s in $stale) {
            $script:AgentsText | Should -Not -Match $s -Because "这句是 2026-10-27 已修正的过期描述（$s）"
        }
    }
}
