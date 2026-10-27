#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for the exit-code table GENERATOR itself (tools/Update-DocTables.ps1).

.DESCRIPTION
    doc-tables.Tests.ps1 verifies the generator's OUTPUT: it runs -Check and asserts the
    three documents agree with the code. That is the right end-to-end guard, but it is
    structurally blind to the generator's own failure handling:

      - If Get-OrderedCodeRow stopped matching the comment format, -Check would report
        "documents out of date" and the end-to-end test would go red -- with a message
        about the DOCS, when the defect is in the PARSER. The reader is then sent to the
        wrong file. Worse, a parser that silently returned a SHORT list would render a
        short but authoritative-looking table and nothing would complain.
      - The three renderers (agent / pattern / maintainer) encode different audiences.
        The maintainer variant must drop caller-side codes (0/1/2/3) because AGENTS.md
        already lists them in the section above; if that filter broke, AGENTS.md would
        carry two competing basic-code tables and no test would notice.
      - Merge-CodeRow exists because code 1 legitimately has two meanings. If the merge
        silently dropped one, the table would show a single meaning and look correct.

    These tests therefore import the generator's FUNCTIONS (not its output) and drive
    the error paths directly. The generator has no execute guard -- it is a
    script-per-invocation CLI -- so the functions are loaded by parsing the file's own
    text and invoking only the pre-execution part.

    Rationale for the extra file rather than extending doc-tables.Tests.ps1: that file
    is about "docs tell the truth"; this one is about "the generator says so when it
    cannot". Different invariants, different failure modes, different reader.
#>

Describe '退出码表生成器自身的失败处理' {
    BeforeAll {
        # Resolve here, not in BeforeDiscovery: Pester 5 runs discovery and run in
        # separate scopes, so a $script: value set during discovery is not reliably
        # visible in BeforeAll.
        $script:Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
        $script:Generator = Join-Path $script:Root 'tools/Update-DocTables.ps1'

        # --- Load the generator by dot-sourcing it. --------------------------------
        #
        # This is only possible because the generator now ends with an execution guard
        # (`if ($MyInvocation.InvocationName -ne '.')`) and wraps all side effects in
        # Main. Before that, top-level code made dot-sourcing write documents and exit,
        # so these unit tests had to rebuild the parseable part through
        # [scriptblock]::Create -- and code run from a dynamic scriptblock is NOT
        # instrumented by Pester. Measured 2026-10-27: 23 passing tests, coverage of
        # tools/Update-DocTables.ps1 still 0/138. Dot-sourcing fixes that as well.
        . $script:Generator

        # The dot-source defines $beginMarker/$endMarker/$script:MinOrderedCodes in the
        # generator's own scope. Read the marker strings from the source text (they are
        # literals there) and note that a dot-source inside BeforeAll does not publish
        # its locals into Pester's script scope, so copying them through local variables
        # would assign nothing. Asserting the literals keeps drift detectable.
        $text = [System.IO.File]::ReadAllText($script:Generator)
        $script:ProducerPath = Join-Path $script:Root 'references/scripts/rollback-producer.ps1'
        $m = [regex]::Match($text, '\$beginMarker\s*=\s*''([^'']+)''')
        $m.Success | Should -BeTrue -Because '生成器里应有 $beginMarker 字面量；形状变了就更新本测试'
        $script:BeginMarker = $m.Groups[1].Value
        $m = [regex]::Match($text, '\$endMarker\s*=\s*''([^'']+)''')
        $m.Success | Should -BeTrue -Because '生成器里应有 $endMarker 字面量'
        $script:EndMarker = $m.Groups[1].Value

        $m = [regex]::Match($text, '\$script:MinOrderedCodes\s*=\s*(\d+)')
        $m.Success | Should -BeTrue -Because '生成器里应有 $script:MinOrderedCodes 字面量'
        $script:MinOrderedCodes = [int]$m.Groups[1].Value

        function New-CodeRow {
            param([int]$Code, [string]$Meaning, [bool]$CallerSide = $false)
            [pscustomobject]@{ Code = $Code; Meaning = $Meaning; CallerSide = $CallerSide }
        }

        # A temp file with given text, UTF-8 BOM-less (matching the repo's .md/.ps1).
        function New-TempTextFile {
            param([string]$Text)
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ("wrc-doctbl-" + [guid]::NewGuid().ToString('N') + '.txt')
            [System.IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding($false)))
            return $p
        }
    }

    Context 'Get-ExitCodeDocBlock：事实来源的定位' {
        It '从真实 producer 里取到 .DESCRIPTION 注释块' {
            $desc = Get-ExitCodeDocBlock -Path $script:ProducerPath
            $desc | Should -Not -BeNullOrEmpty
            # The block is the authoritative source; if this is empty the whole chain
            # silently renders an empty table.
            $desc | Should -Match '14'
        }

        It '找不到 Get-CleanupExitCode 时抛错，而不是返回空串' {
            # A function that returns empty on failure would make the caller render a
            # short/empty table that looks authoritative. It must throw.
            $tmp = New-TempTextFile -Text 'function SomethingElse { }'
            try {
                { Get-ExitCodeDocBlock -Path $tmp } | Should -Throw -ExpectedMessage '*无法在*'
            }
            finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }

        It '注释块只取 .DESCRIPTION 到 #> 之间，不吞掉后面的代码' {
            $body = @'
function Get-CleanupExitCode {
    <#
    .DESCRIPTION
        14  previous run not consumed
        15  persistence failed
    #>
    param()
    return 0
}
'@
            $tmp = New-TempTextFile -Text $body
            try {
                $desc = Get-ExitCodeDocBlock -Path $tmp
                $desc | Should -Match '14'
                $desc | Should -Match '15'
                $desc | Should -Not -Match 'param\(\)' -Because '把代码一起取进来意味着生成器读的不是它以为的东西'
            }
            finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Get-OrderedCodeRow：格式解析与完整性下限' {
        It '按注释里的书写顺序解析出码与含义' {
            $desc = @"
  14  previous run not consumed
  15  persistence failed
  13  partial failure with -NoAutoRollback
  12  partial failure, journal missing
  11  partial failure, restore incomplete
  10  partial failure, fully restored
"@
            $rows = @(Get-OrderedCodeRow -Description $desc)
            @($rows.Code) | Should -Be @(14, 15, 13, 12, 11, 10)
            $rows[0].Meaning | Should -Be 'previous run not consumed'
            $rows | ForEach-Object { $_.CallerSide | Should -BeFalse }
        }

        It '解析结果少于下限时抛错（防止格式漂移后静默输出短表）' {
            # This is the guard that turns "the comment changed shape" into a loud
            # failure instead of a 1-row table that still passes every downstream check.
            $desc = @"
  14  only one code here
  15  and another
"@
            { Get-OrderedCodeRow -Description $desc } | Should -Throw -ExpectedMessage '*明显不完整*'
        }

        It '不把正文里恰好以数字开头的行当成退出码' {
            $desc = @"
  14  previous run not consumed
  15  persistence failed
  13  partial failure with -NoAutoRollback
  12  partial failure, journal missing
  11  partial failure, restore incomplete
  10  partial failure, fully restored

2026-10-26 note: this line starts with a 4-digit year and must not parse.
no indent at all 99 should not parse either
"@
            $rows = @(Get-OrderedCodeRow -Description $desc)
            @($rows.Code) | Should -Be @(14, 15, 13, 12, 11, 10)
        }
    }

    Context 'Get-CallerCodeRow：调用方直接返回的码' {
        It '从尾部句子解析出 权限/输入/依赖 三个码并标记为 caller-side' {
            $desc = '权限(2)/输入(1)/依赖(3) 由更早的分支直接返回。'
            $rows = @(Get-CallerCodeRow -Description $desc)
            @($rows.Code) | Should -Be @(2, 1, 3)
            $rows | ForEach-Object { $_.CallerSide | Should -BeTrue }
        }

        It '用固定的语义表填充含义（语义无法从注释推导）' {
            $desc = '权限(2)/输入(1)/依赖(3)'
            $rows = @(Get-CallerCodeRow -Description $desc)
            ($rows | Where-Object { $_.Code -eq 2 }).Meaning | Should -Match 'Permission denied'
            ($rows | Where-Object { $_.Code -eq 1 }).Meaning | Should -Match 'Required input'
        }

        It '没有那句话时返回空数组，不抛错' {
            # Caller codes are optional in the comment; absence must not break the run.
            $rows = @(Get-CallerCodeRow -Description '14  something')
            $rows.Count | Should -Be 0
        }
    }

    Context 'Merge-CodeRow：同码不同义必须合并成一行' {
        It '把码 1 的两种含义合并，且保留先出现的位置' {
            $rows = @(
                (New-CodeRow -Code 1 -Meaning 'caller: missing input' -CallerSide $true),
                (New-CodeRow -Code 14 -Meaning 'previous run not consumed'),
                (New-CodeRow -Code 1 -Meaning 'partial failure, no mutations')
            )
            $merged = @(Merge-CodeRow -Row $rows)
            $merged.Count | Should -Be 2 -Because '码 1 出现两次，合并后只应剩一行'
            $merged[0].Code | Should -Be 1 -Because '先出现的码排在前'
            $merged[0].Meaning | Should -Match 'caller: missing input'
            $merged[0].Meaning | Should -Match 'partial failure, no mutations'
            $merged[1].Code | Should -Be 14
        }

        It '没有重复时原样保留顺序与语义' {
            $rows = @(
                (New-CodeRow -Code 14 -Meaning 'a'),
                (New-CodeRow -Code 15 -Meaning 'b'),
                (New-CodeRow -Code 13 -Meaning 'c')
            )
            $merged = @(Merge-CodeRow -Row $rows)
            @($merged.Code) | Should -Be @(14, 15, 13)
            @($merged.Meaning) | Should -Be @('a', 'b', 'c')
        }
    }

    Context 'Get-ExitCodeRow：真实代码上的一次完整提取' {
        It '产出的行没有重复码，且有序行与 caller 行分开' {
            $r = Get-ExitCodeRow -Path $script:ProducerPath
            @($r.Rows).Count | Should -BeGreaterThan 5
            $codes = @($r.Rows | ForEach-Object { $_.Code })
            @($codes | Sort-Object -Unique).Count | Should -Be $codes.Count -Because '重复码会让读者无法判断哪一行适用'

            # OrderedRows is what feeds the priority chain. It must contain ONLY codes
            # that Get-CleanupExitCode itself returns -- i.e. no row flagged CallerSide.
            #
            # Note: it is NOT "no code below 10". Codes 0 and 1 legitimately appear in the
            # ordered list (0 = success, sits between 15 and 13 in the if-chain; 1 =
            # partial failure with no mutations). Asserting ">= 10" would be a false
            # invariant that fails on correct code -- which is exactly what this
            # assertion caught when first written.
            @($r.OrderedRows | Where-Object { $_.CallerSide }).Count | Should -Be 0 -Because `
                'caller-side 码(2/3，以及 caller 返回的 1)在优先级链之前就返回了，混进链里会误导读者'
            @($r.Rows | Where-Object { $_.CallerSide }).Count | Should -BeGreaterThan 0 -Because `
                '真实注释里有 权限/输入/依赖 那句话，caller 行必须被提取出来（否则表里缺基础码）'
        }
    }

    Context 'Get-PriorityOrder：优先级链只由有序行构成' {
        It '用 > 连接有序行的码，顺序即注释顺序' {
            $rows = @(
                (New-CodeRow -Code 14 -Meaning 'x'),
                (New-CodeRow -Code 15 -Meaning 'y'),
                (New-CodeRow -Code 0 -Meaning 'z')
            )
            Get-PriorityOrder -OrderedRows $rows | Should -Be '14 > 15 > 0'
        }
    }

    Context '三个渲染器：不同的读者，不同的取舍' {
        BeforeAll {
            $script:Rows = @(
                (New-CodeRow -Code 2 -Meaning 'Permission denied' -CallerSide $true),
                (New-CodeRow -Code 0 -Meaning 'Done.'),
                (New-CodeRow -Code 10 -Meaning 'fully restored'),
                (New-CodeRow -Code 14 -Meaning 'previous run not consumed'),
                (New-CodeRow -Code 99 -Meaning 'code with no advice mapping')
            )
        }

        It 'agent 变体给已知码配上「该怎么说」，未知码走兜底文案' {
            $out = @(Format-AgentRow -Row $script:Rows)
            $out.Count | Should -Be 5
            $out[0] | Should -Match 'Permission denied'
            $out[0] | Should -Match 'Administrator is required'
            # A code added to the comment before an advice entry exists must still render.
            ($out | Where-Object { $_ -match '\| `99` \|' }) | Should -Match 'Report it plainly'
        }

        It 'pattern 变体用 gloss 覆盖含义，其余保留原义' {
            $out = @(Format-PatternRow -Row $script:Rows)
            $out.Count | Should -Be 5
            ($out | Where-Object { $_ -match '^\| 14 \|' }) | Should -Match '未安全消费'
            ($out | Where-Object { $_ -match '^\| 10 \|' }) | Should -Match 'fully restored'
        }

        It 'maintainer 变体丢掉基础码 0/1/2/3，只留扩展码' {
            # AGENTS.md already lists 0/1/2/3 in its own 退出码规范 table; repeating them
            # here would put two competing basic-code tables in the maintainer doc.
            $out = @(Format-MaintainerRow -Row $script:Rows)
            $out.Count | Should -Be 3 -Because '5 行里 0 与 2 属于基础码，应被过滤'
            ($out -join "`n") | Should -Not -Match '^\| 0 \|'
            ($out -join "`n") | Should -Not -Match '^\| 2 \|'
            ($out -join "`n") | Should -Match '^\| 10 \|'
        }
    }

    Context 'Format-ExitCodeTable：表头、样式分派、换行符跟随目标文档' {
        BeforeAll {
            $script:TableRows = @(
                (New-CodeRow -Code 10 -Meaning 'fully restored'),
                (New-CodeRow -Code 14 -Meaning 'previous run not consumed')
            )
        }

        It '三种样式的表头各不相同且都带有分隔行' {
            $lfDoc = New-TempTextFile -Text "line1`nline2`n"
            try {
                $agent = Format-ExitCodeTable -Rows $script:TableRows -Style agent -DocumentPath $lfDoc
                $pattern = Format-ExitCodeTable -Rows $script:TableRows -Style pattern -DocumentPath $lfDoc
                $maint = Format-ExitCodeTable -Rows $script:TableRows -Style maintainer -DocumentPath $lfDoc
                $agent | Should -Match 'What the agent should say'
                $agent | Should -Match '\|------\|---------|'
                $pattern | Should -Match '\| 码 \| 含义 \|'
                $maint | Should -Match '\| 退出码 \| 含义 \|'
            }
            finally { Remove-Item -LiteralPath $lfDoc -Force -ErrorAction SilentlyContinue }
        }

        It '目标文档是 LF 时生成块用 LF' {
            $doc = New-TempTextFile -Text "a`nb`n"
            try {
                $block = Format-ExitCodeTable -Rows $script:TableRows -Style maintainer -DocumentPath $doc
                $block.Contains("`r`n") | Should -BeFalse
                $block.Contains("`n") | Should -BeTrue
            }
            finally { Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue }
        }

        It '目标文档是 CRLF 时生成块用 CRLF（-Check 才不会因检出方式假红）' {
            $doc = New-TempTextFile -Text "a`r`nb`r`n"
            try {
                $block = Format-ExitCodeTable -Rows $script:TableRows -Style maintainer -DocumentPath $doc
                $block.Contains("`r`n") | Should -BeTrue
                # No bare LF left over: mixing would still diff against the document.
                ([regex]::Matches($block, "(?<!`r)`n")).Count | Should -Be 0
            }
            finally { Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Merge-MarkedBlock：生成块的两端标记' {
        It '把标记之间的内容替换成新块，并报告已变更' {
            $doc = New-TempTextFile -Text ("head`n" + $script:BeginMarker + "`nold`n" + $script:EndMarker + "`ntail`n")
            try {
                $r = Merge-MarkedBlock -Path $doc -Block 'NEW'
                $r.Changed | Should -BeTrue
                $r.Original | Should -Match 'old'
                $r.Updated | Should -Match 'NEW'
                $r.Updated | Should -Not -Match 'old'
                $r.Updated | Should -Match 'head'
                $r.Updated | Should -Match 'tail'
            }
            finally { Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue }
        }

        It '内容已是最新时报告未变更（-Check 的判据）' {
            $begin = $script:BeginMarker
            $end = $script:EndMarker
            $doc = New-TempTextFile -Text ("head`n$begin`nSAME`n$end`ntail`n")
            try {
                $r = Merge-MarkedBlock -Path $doc -Block 'SAME'
                $r.Changed | Should -BeFalse
            }
            finally { Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue }
        }

        It '缺少标记时抛错，而不是静默把整篇文档留在手工维护状态' {
            $doc = New-TempTextFile -Text "no markers here`n"
            try {
                { Merge-MarkedBlock -Path $doc -Block 'X' } | Should -Throw -ExpectedMessage '*缺少生成块标记*'
            }
            finally { Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue }
        }

        It 'CRLF 文档里拼出的块也用 CRLF' {
            $begin = $script:BeginMarker
            $end = $script:EndMarker
            $doc = New-TempTextFile -Text ("head`r`n$begin`r`nold`r`n$end`r`ntail`r`n")
            try {
                $r = Merge-MarkedBlock -Path $doc -Block 'A|B'
                $r.Changed | Should -BeTrue
                ([regex]::Matches($r.Updated, "(?<!`r)`n")).Count | Should -Be 0 -Because '混入裸 LF 会让 CRLF 文档永久显示为漂移'
            }
            finally { Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue }
        }
    }
}
