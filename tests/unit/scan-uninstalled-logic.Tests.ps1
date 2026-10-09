# scan-uninstalled.ps1 的残留判定纯函数。
#
# 这些判定逻辑原本内联在 Main 的注册表循环里，需要真实注册表项才能走到，
# 因此大量分支（confidence 分级、系统卸载器跳过）长期未覆盖。
# 抽成纯函数后可直接枚举真值表。

BeforeAll {
    $script:ScanScript = "$PSScriptRoot\..\..\references\scripts\scan-uninstalled.ps1"
    . $script:ScanScript
}

Describe 'Get-ResidualVerdict (two-phase weighted decision)' {
    It 'not in index + no evidence => residual with low confidence' {
        $v = Get-ResidualVerdict -NotInIndex $true -InstallPathMissing $false -UninstallPathMissing $false
        $v.is_residual | Should -Be $true
        $v.confidence | Should -Be 'low'
    }

    It 'not in index + install path missing => high confidence' {
        $v = Get-ResidualVerdict -NotInIndex $true -InstallPathMissing $true -UninstallPathMissing $false
        $v.is_residual | Should -Be $true
        $v.confidence | Should -Be 'high'
    }

    It 'not in index + uninstall exe missing => high confidence' {
        $v = Get-ResidualVerdict -NotInIndex $true -InstallPathMissing $false -UninstallPathMissing $true
        $v.is_residual | Should -Be $true
        $v.confidence | Should -Be 'high'
    }

    It 'in index + both missing => residual with medium confidence' {
        $v = Get-ResidualVerdict -NotInIndex $false -InstallPathMissing $true -UninstallPathMissing $true
        $v.is_residual | Should -Be $true
        $v.confidence | Should -Be 'medium'
    }

    # 这是 AGENTS.md「权威信号必须 gate 辅助信号」的核心不变式：
    # 在索引中（已安装）时，单个异常信号不得独立触发残留判定。
    It 'in index + only install path missing => NOT residual (authority gates evidence)' {
        $v = Get-ResidualVerdict -NotInIndex $false -InstallPathMissing $true -UninstallPathMissing $false
        $v.is_residual | Should -Be $false
    }

    It 'in index + only uninstall exe missing => NOT residual' {
        $v = Get-ResidualVerdict -NotInIndex $false -InstallPathMissing $false -UninstallPathMissing $true
        $v.is_residual | Should -Be $false
    }

    It 'in index + nothing missing => NOT residual' {
        $v = Get-ResidualVerdict -NotInIndex $false -InstallPathMissing $false -UninstallPathMissing $false
        $v.is_residual | Should -Be $false
    }
}

Describe 'Get-ResidualEvidence' {
    It 'lists all three signals when all present' {
        Get-ResidualEvidence -NotInIndex $true -InstallPathMissing $true -UninstallPathMissing $true |
            Should -Be 'not in installed index; InstallLocation path missing; UninstallString exe missing'
    }

    It 'lists only the index signal for a low-confidence hit' {
        Get-ResidualEvidence -NotInIndex $true -InstallPathMissing $false -UninstallPathMissing $false |
            Should -Be 'not in installed index'
    }

    It 'returns an empty string when nothing is wrong' {
        Get-ResidualEvidence -NotInIndex $false -InstallPathMissing $false -UninstallPathMissing $false |
            Should -Be ''
    }

    It 'preserves signal order regardless of which are set' {
        Get-ResidualEvidence -NotInIndex $false -InstallPathMissing $true -UninstallPathMissing $true |
            Should -Be 'InstallLocation path missing; UninstallString exe missing'
    }
}

Describe 'Get-UninstallExePath' {
    It 'skips MsiExec (system uninstaller)' {
        Get-UninstallExePath -UninstallString 'MsiExec.exe /X{GUID}' | Should -BeNullOrEmpty
    }

    It 'skips rundll32' {
        Get-UninstallExePath -UninstallString 'rundll32.exe foo.dll,Bar' | Should -BeNullOrEmpty
    }

    It 'skips regsvr32' {
        Get-UninstallExePath -UninstallString 'regsvr32.exe /u x.dll' | Should -BeNullOrEmpty
    }

    It 'skips system uninstallers case-insensitively with leading spaces' {
        Get-UninstallExePath -UninstallString '  msiexec.exe /X{G}' | Should -BeNullOrEmpty
    }

    It 'extracts a quoted exe path' {
        Get-UninstallExePath -UninstallString '"C:\Program Files\App\uninst.exe" /S' |
            Should -Be 'C:\Program Files\App\uninst.exe'
    }

    It 'extracts an unquoted exe path' {
        Get-UninstallExePath -UninstallString 'C:\App\uninst.exe /S' |
            Should -Be 'C:\App\uninst.exe'
    }

    It 'expands environment variables in the exe path' {
        $r = Get-UninstallExePath -UninstallString '%windir%\System32\notepad.exe'
        $r | Should -Not -Match '%windir%'
        $r | Should -Match 'notepad\.exe$'
    }

    It 'returns null for an empty or null string' {
        Get-UninstallExePath -UninstallString '' | Should -BeNullOrEmpty
        Get-UninstallExePath -UninstallString $null | Should -BeNullOrEmpty
    }

    It 'returns null when no .exe is present' {
        Get-UninstallExePath -UninstallString 'C:\App\uninst.bat' | Should -BeNullOrEmpty
    }
}

Describe 'Test-PathMissing' {
    It 'returns false for a null or empty InstallLocation' {
        Test-PathMissing -InstallLocation '' | Should -Be $false
        Test-PathMissing -InstallLocation $null | Should -Be $false
    }

    It 'returns true for a directory that does not exist' {
        $missing = 'C:\DefinitelyNotHere_' + [guid]::NewGuid().ToString('N')
        Test-PathMissing -InstallLocation $missing | Should -Be $true
    }

    It 'returns false for a directory that exists' {
        Test-PathMissing -InstallLocation $env:SystemRoot | Should -Be $false
    }

    # AGENTS.md 陷阱 #4：.NET IO 不 Trim 引号
    It 'strips surrounding double quotes before checking' {
        Test-PathMissing -InstallLocation "`"$env:SystemRoot`"" | Should -Be $false
    }

    It 'strips surrounding single quotes before checking' {
        Test-PathMissing -InstallLocation "'$env:SystemRoot'" | Should -Be $false
    }

    # AGENTS.md 陷阱 #5：必须展开环境变量
    It 'expands environment variables before checking' {
        Test-PathMissing -InstallLocation '%windir%' | Should -Be $false
    }

    It 'returns false for a whitespace-only location' {
        Test-PathMissing -InstallLocation '   ' | Should -Be $false
    }
}

Describe 'scan-uninstalled.ps1 Main contract' {
    It 'ExitCode param is a [ref] and optional' {
        . $script:ScanScript
        $cmd = Get-Command Main
        $cmd.Parameters.ContainsKey('ExitCode') | Should -Be $true
        $cmd.Parameters['ExitCode'].ParameterType.Name | Should -Be 'PSReference'
    }

    It 'returns 3 without exiting the host when the index is missing' {
        . $script:ScanScript
        $rc = 0
        Main -ExitCode ([ref]$rc) `
            -IndexPathOverride (Join-Path $env:TEMP ('nope-' + [guid]::NewGuid().ToString('N') + '.json')) `
            -OutputPathOverride (Join-Path $env:TEMP 'unused.json') *>&1 | Out-Null
        $rc | Should -Be 3
    }

    It 'scans real registry data and writes a well-formed output file' {
        # 先用真实索引（build-installed-index 产出的那份）
        $idxScript = "$PSScriptRoot\..\..\references\scripts\build-installed-index.ps1"
        $idxPath = Join-Path $env:TEMP ('wrc-idx-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $outPath = Join-Path $env:TEMP ('wrc-uninst-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        try {
            # 注意：两个脚本的顶层 param() 同名（IndexPath/OutputPath）。
            # dot-source 会把 param 默认值绑进调用方作用域，从而**覆盖**调用方同名变量
            # （PS 5.1 实测：dot-source 后 $IndexPath 被重置为脚本默认值）。
            # 因此这里显式用 -IndexPath/-OutputPath 实参传值，不依赖调用方变量。
            & {
                . $idxScript
                $idxRc = 0
                Main -ExitCode ([ref]$idxRc) -OutputPathOverride $idxPath *>&1 | Out-Null
            }
            Test-Path $idxPath | Should -Be $true

            $script:scanRc = 0
            & {
                . $script:ScanScript
                Main -ExitCode ([ref]$script:scanRc) -IndexPathOverride $idxPath -OutputPathOverride $outPath *>&1 | Out-Null
            }
            $script:scanRc | Should -Be 0
            Test-Path $outPath | Should -Be $true

            $doc = Get-Content $outPath -Raw | ConvertFrom-Json
            # 输出是对象（两个集合），不是扁平数组
            $doc.PSObject.Properties.Name | Should -Contain 'uninstalled_software'
            $doc.PSObject.Properties.Name | Should -Contain 'candidate_directories'

            # 每个残留条目都必须有六元组字段，且 confidence/source 取值合法
            $entries = @($doc.uninstalled_software)
            foreach ($e in $entries) {
                $e.name | Should -Not -BeNullOrEmpty
                $e.registry_key | Should -Not -BeNullOrEmpty
                $e.confidence | Should -BeIn @('high', 'medium', 'low')
                $e.source | Should -BeIn @('HKLM', 'HKCU')
            }

            # 每个候选目录条目都必须有 name/path/evidence
            foreach ($d in @($doc.candidate_directories)) {
                $d.name | Should -Not -BeNullOrEmpty
                $d.path | Should -Not -BeNullOrEmpty
                $d.evidence | Should -Not -BeNullOrEmpty
            }
        } finally {
            Remove-Item $idxPath, $outPath -Force -ErrorAction SilentlyContinue
        }
    }
}
