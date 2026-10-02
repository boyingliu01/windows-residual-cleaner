# build-installed-index.ps1 的包管理器解析器单测。
#
# 这些解析器原先内联在 Main 里、且被 `Get-Command winget/scoop/choco` 守卫包住，
# 因此在一台没装这些工具的机器上，解析逻辑一行都不会执行 —— 也无法被覆盖。
# 抽成顶层纯函数后可直接用真实输出样本喂进去。

BeforeAll {
    $script:IndexScript = "$PSScriptRoot\..\..\references\scripts\build-installed-index.ps1"
    . $script:IndexScript
}

Describe 'ConvertFrom-WingetJson' {
    It 'maps winget JSON fields onto index entries' {
        $json = '[
            {"Name":"Git","Version":"2.43.0","Publisher":"The Git Development Community","Source":"winget"},
            {"Name":"7-Zip","Version":"23.01","Publisher":"Igor Pavlov","Source":"winget"}
        ]'
        $r = @(ConvertFrom-WingetJson -Json $json)
        $r.Count | Should -Be 2
        $r[0].name | Should -Be 'Git'
        $r[0].version | Should -Be '2.43.0'
        $r[0].publisher | Should -Be 'The Git Development Community'
        $r[0].source | Should -Be 'winget'
        $r[0].install_location | Should -Be ''
        $r[0].uninstall_string | Should -Be ''
    }

    It 'skips packages without a Name' {
        $json = '[{"Name":"Git","Version":"1"},{"Version":"9.9"},{"Name":"","Version":"x"}]'
        $r = @(ConvertFrom-WingetJson -Json $json)
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'Git'
    }

    It 'returns nothing for empty/whitespace input' {
        @(ConvertFrom-WingetJson -Json '').Count | Should -Be 0
        @(ConvertFrom-WingetJson -Json '   ').Count | Should -Be 0
    }

    It 'throws on malformed JSON so the caller can fall back to text' {
        { ConvertFrom-WingetJson -Json '{not json' } | Should -Throw
    }

    It 'handles a single-element array (no @() over ConvertFrom-Json)' {
        $r = @(ConvertFrom-WingetJson -Json '[{"Name":"Solo","Version":"1.0","Publisher":"P"}]')
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'Solo'
    }
}

Describe 'ConvertFrom-WingetText' {
    It 'splits on 2+ spaces and takes the first two columns' {
        $lines = @(
            'Git                       2.43.0   winget',
            '7-Zip                     23.01    winget'
        )
        $r = @(ConvertFrom-WingetText -Lines $lines)
        $r.Count | Should -Be 2
        $r[0].name | Should -Be 'Git'
        $r[0].version | Should -Be '2.43.0'
        $r[1].name | Should -Be '7-Zip'
    }

    It 'defaults version to empty when only one column exists' {
        $r = @(ConvertFrom-WingetText -Lines @('Lonely'))
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'Lonely'
        $r[0].version | Should -Be ''
    }

    It 'skips blank lines' {
        $r = @(ConvertFrom-WingetText -Lines @('A  1', '', '   ', 'B  2'))
        $r.Count | Should -Be 2
    }

    It 'returns nothing for an empty array' {
        @(ConvertFrom-WingetText -Lines @()).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-ScoopJson' {
    It 'maps scoop JSON fields onto index entries' {
        $json = '[{"Name":"ripgrep","Version":"14.1.0"},{"Name":"fzf","Version":"0.46.0"}]'
        $r = @(ConvertFrom-ScoopJson -Json $json)
        $r.Count | Should -Be 2
        $r[0].name | Should -Be 'ripgrep'
        $r[0].version | Should -Be '14.1.0'
        $r[0].source | Should -Be 'scoop'
        $r[0].publisher | Should -Be ''
    }

    It 'returns nothing for empty input' {
        @(ConvertFrom-ScoopJson -Json '').Count | Should -Be 0
    }

    It 'throws on malformed JSON so the caller can fall back to text' {
        { ConvertFrom-ScoopJson -Json 'nope' } | Should -Throw
    }
}

Describe 'ConvertFrom-ScoopText' {
    It 'splits on whitespace and keeps name+version' {
        $r = @(ConvertFrom-ScoopText -Lines @('ripgrep 14.1.0', 'fzf 0.46.0'))
        $r.Count | Should -Be 2
        $r[0].name | Should -Be 'ripgrep'
        $r[0].version | Should -Be '14.1.0'
        $r[1].name | Should -Be 'fzf'
    }

    It 'skips lines with a single token' {
        $r = @(ConvertFrom-ScoopText -Lines @('header', 'ripgrep 14.1.0'))
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'ripgrep'
    }

    It 'tolerates leading whitespace' {
        $r = @(ConvertFrom-ScoopText -Lines @('   ripgrep   14.1.0'))
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'ripgrep'
    }
}

Describe 'ConvertFrom-ChocoText' {
    It 'parses pipe-delimited name|version lines' {
        $r = @(ConvertFrom-ChocoText -Text "git|2.43.0`n7zip|23.01")
        $r.Count | Should -Be 2
        $r[0].name | Should -Be 'git'
        $r[0].version | Should -Be '2.43.0'
        $r[1].name | Should -Be '7zip'
        $r[0].source | Should -Be 'chocolatey'
    }

    It 'skips blank lines and lines without a pipe' {
        $r = @(ConvertFrom-ChocoText -Text "git|2.43.0`n`n   `nnot-a-package`n7zip|23.01")
        $r.Count | Should -Be 2
    }

    It 'keeps extra pipe-separated columns out of name/version' {
        $r = @(ConvertFrom-ChocoText -Text 'pkg|1.0|extra')
        $r.Count | Should -Be 1
        $r[0].name | Should -Be 'pkg'
        $r[0].version | Should -Be '1.0'
    }

    It 'returns nothing for empty input' {
        @(ConvertFrom-ChocoText -Text '').Count | Should -Be 0
    }
}

Describe 'build-installed-index.ps1 Main (in-process)' {
    It 'writes an index file containing the registry-sourced entries' {
        . $script:IndexScript
        $out = Join-Path $env:TEMP ('wrc-idx-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        try {
            $rc = 0
            $OutputPath = $out
            Main -ExitCode ([ref]$rc) *>&1 | Out-Null
            $rc | Should -Be 0
            Test-Path $out | Should -Be $true
            $doc = Get-Content $out -Raw | ConvertFrom-Json
            $idx = @($doc)
            # 真实机器上一定有已安装软件；索引不应为空
            $idx.Count | Should -BeGreaterThan 0
            $idx[0].name | Should -Not -BeNullOrEmpty
            $idx[0].source | Should -Not -BeNullOrEmpty
        } finally {
            Remove-Item $out -Force -ErrorAction SilentlyContinue
        }
    }

    It 'creates the output directory when missing' {
        . $script:IndexScript
        $dir = Join-Path $env:TEMP ('wrc-idxdir-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $out = Join-Path $dir 'nested\index.json'
        try {
            $rc = 0
            $OutputPath = $out
            Main -ExitCode ([ref]$rc) *>&1 | Out-Null
            $rc | Should -Be 0
            Test-Path $out | Should -Be $true
        } finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'dedupes on the name|version|source composite key (not name alone)' {
        # 去重语义：同一 name 的不同 version/source 是**不同**条目，必须都保留。
        . $script:IndexScript
        $out = Join-Path $env:TEMP ('wrc-idxuniq-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        try {
            $rc = 0
            $OutputPath = $out
            Main -ExitCode ([ref]$rc) *>&1 | Out-Null
            $doc = Get-Content $out -Raw | ConvertFrom-Json
            $idx = @($doc)
            $keys = @($idx | ForEach-Object { "$($_.name)|$($_.version)|$($_.source)" })
            # 复合键必须唯一（这才是脚本承诺的不变式）
            $keys.Count | Should -Be @($keys | Sort-Object -Unique).Count
        } finally {
            Remove-Item $out -Force -ErrorAction SilentlyContinue
        }
    }

    It 'ExitCode param is a [ref] and optional (ADR-001 contract)' {
        . $script:IndexScript
        $cmd = Get-Command Main
        $cmd.Parameters.ContainsKey('ExitCode') | Should -Be $true
        $cmd.Parameters['ExitCode'].ParameterType.Name | Should -Be 'PSReference'
    }
}
