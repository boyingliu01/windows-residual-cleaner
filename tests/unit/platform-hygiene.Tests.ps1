# =============================================================================
# platform-hygiene.Tests.ps1 — 平台层细节的静态与行为契约
# =============================================================================
# 背景（2026-10-16 接管审计）：P1-1（Start-Process -ArgumentList 不加引号）、
# P2（Remove-ItemRobust 通配符语义）都通过了行覆盖率门禁却从未被任何用例喂过
# 真实形态的输入。本文件把「教训只在 drill 现场修、没回流产品链」的形态
# 钉成三条 AST 守卫 + 一组真实进程行为测试，新增违规会在门禁变红。
# =============================================================================

Describe 'Platform hygiene: ConvertTo-NativeArgument（引号封装契约）' {
    BeforeAll {
        $script:Root = (Resolve-Path "$PSScriptRoot\..\..").Path
        . (Join-Path $script:Root 'references\scripts\native-invoke.ps1')
    }

    It '不含空白与引号的值原样返回' {
        ConvertTo-NativeArgument 'C:\Windows\System32\reg.exe' | Should -Be 'C:\Windows\System32\reg.exe'
        ConvertTo-NativeArgument '/y' | Should -Be '/y'
    }

    It '含空格的路径被双引号包裹' {
        ConvertTo-NativeArgument 'C:\Program Files\App' | Should -Be '"C:\Program Files\App"'
    }

    It '空值变成空串引号（保证元素不消失）' {
        ConvertTo-NativeArgument '' | Should -Be '""'
        ConvertTo-NativeArgument $null | Should -Be '""'
    }

    It '值内嵌引号被转义且前置反斜杠翻倍' {
        # C:\say \"hi\" 形态：内部引号前的反斜杠必须翻倍，否则引号提前闭合
        ConvertTo-NativeArgument 'C:\say "hi"' | Should -Be '"C:\say \"hi\""'
        ConvertTo-NativeArgument 'a\"b' | Should -Be '"a\\\"b"'
    }

    It '结尾反斜杠在包裹前翻倍（防止吞掉闭合引号）' {
        # Round-2/3/5 走查（2026-10-16，三形态真值）：失败面取决于透传形态——
        # `&` 原生绑定裸透传是引擎分歧（PS 5.1 失败 / pwsh 7 的原生实参绑定正确转义，
        # 实测三种 PSNativeCommandArgumentPassing 模式均成功）；
        # Start-Process 纯拼接裸透传才是两引擎共有失败（空格碎裂）；本函数的
        # 包裹+翻倍两引擎都正确，故尾反斜杠值一律进入包裹分支（见 native-invoke.ps1
        # 三形态注释与下方可执行钉子用例）。
        ConvertTo-NativeArgument 'C:\dir\' | Should -Be '"C:\dir\\"'
        # 被包裹的值（含空格）结尾反斜杠必须翻倍，否则吞掉闭合引号
        ConvertTo-NativeArgument 'C:\Program Files\dir \' | Should -Be '"C:\Program Files\dir \\"'
    }
}

Describe 'Platform hygiene: Invoke-NativeExe（真实进程行为）' {
    BeforeAll {
        $script:Root = (Resolve-Path "$PSScriptRoot\..\..").Path
        . (Join-Path $script:Root 'references\scripts\native-invoke.ps1')
        $script:Cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $script:Ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
    }

    It '拿到真实退出码：cmd /c exit 5 → exit_code 5 且 ok 为假' {
        $r = Invoke-NativeExe -FilePath $script:Cmd -Arguments @('/c', 'exit', '5') -TimeoutSeconds 15
        $r.exit_code | Should -Be 5
        $r.ok | Should -Be $false
    }

    It '成功路径：ok 为真、error 为空串' {
        $r = Invoke-NativeExe -FilePath $script:Cmd -Arguments @('/c', 'exit', '0') -TimeoutSeconds 15
        $r.ok | Should -Be $true
        $r.exit_code | Should -Be 0
        $r.error | Should -Be ''
    }

    It 'P1-1 回归：含空格参数必须整体到达目标进程（md 带空格目录）' {
        # 旧实现的命令行是 md C:\...\a b c（碎成三个目录）；引号正确时只建一个。
        $base = Join-Path ([System.IO.Path]::GetTempPath()) "wrc-native-$(New-Guid)"
        $spaced = Join-Path $base 'a b c'
        try {
            $r = Invoke-NativeExe -FilePath $script:Cmd -Arguments @('/c', 'md', $spaced) -TimeoutSeconds 15
            $r.ok | Should -Be $true -Because "md 失败说明参数在拼接处碎裂: $($r.error)"
            (Test-Path -LiteralPath $spaced) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $base 'a')) | Should -Be $false -Because '路径被按空格拆散就会产生这个碎片目录'
        } finally {
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        }
    }

    It 'P1-1 回归：含空格且带尾反斜杠的路径整体到达（md trailing backslash）' {
        # delphi 走查 2026-10-16 争议形态：尾反斜杠在包裹前翻倍后，目标进程必须
        # 收到与输入完全一致的路径（不得多出/吞掉反斜杠，也不得吞掉闭合引号）。
        $base = Join-Path ([System.IO.Path]::GetTempPath()) "wrc-native-$(New-Guid)"
        $spaced = Join-Path $base 'a b'
        try {
            $r = Invoke-NativeExe -FilePath $script:Cmd -Arguments @('/c', 'md', ($spaced + '\')) -TimeoutSeconds 15
            $r.ok | Should -Be $true -Because "md 失败说明尾反斜杠形态被引号规则破坏: $($r.error)"
            (Test-Path -LiteralPath $spaced) | Should -Be $true
            (Test-Path -LiteralPath ($spaced + '"') -ErrorAction SilentlyContinue) | Should -Be $false -Because '闭合引号被吞掉时 cmd 会把引号字面量并进目录名'
        } finally {
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        }
    }

    It 'Round-5 三形态真值钉子：& 裸透传引擎分歧 / Start-Process 拼接两引擎共有失败 / 包裹后成功' {
        # 陷阱 7 纪律的落点：写下「必然」必须附可复现命令——本用例就是命令的自动化
        # 形态，双引擎各跑一次即持续复核因果口径（R6 走查 构远图 残余项 → 实测
        # 反而更正了 R3 的「两引擎共有」口径：它只对 Start-Process 纯拼接成立）。
        # 形态一 `&` 原生绑定：PS 5.1 尾反斜杠吞闭合引号 → 失败；pwsh 7 的原生
        # 实参绑定正确转义 → 成功（引擎分歧；实测三种 PSNativeCommandArgumentPassing
        # 模式均如此）。
        # 形态二 Start-Process 纯拼接：含空格元素按空格碎裂 → 两引擎共有失败
        # （与尾反斜杠无关；仅「引号不翻倍」形态才报另一种 not-found 错误）。
        # 形态三 ConvertTo-NativeArgument 包裹：两引擎都成功（产品唯一通道）。
        $takeown = Join-Path $env:SystemRoot 'System32\takeown.exe'
        $base = Join-Path ([System.IO.Path]::GetTempPath()) "wrc-takeown-$(New-Guid)"
        $spaced = Join-Path $base 'a b'
        New-Item -ItemType Directory -Path $spaced -Force | Out-Null
        $isCore = $PSVersionTable.PSVersion.Major -ge 7
        $engine = if ($isCore) { 'pwsh 7' } else { 'PS 5.1' }
        try {
            # 形态一：& 裸透传 —— 引擎分歧，按引擎分别钉住
            $null = & $takeown /f "$spaced\" 2>&1
            $bareExit = $LASTEXITCODE
            if ($isCore) {
                $bareExit | Should -Be 0 -Because "pwsh 7 原生实参绑定下裸透传必须成功；变红说明引擎行为变化，须重审三形态口径: exit=$bareExit"
            } else {
                $bareExit | Should -Be 1 -Because "PS 5.1 裸透传必须失败（尾反斜杠吞闭合引号）: exit=$bareExit"
            }
            # 形态二：Start-Process 纯拼接 —— 两引擎共有失败（空格碎裂）
            $outFile = [System.IO.Path]::GetTempFileName()
            $errFile = [System.IO.Path]::GetTempFileName()
            try {
                $proc = Start-Process -FilePath $takeown -ArgumentList @('/f', "$spaced\") -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                $proc.ExitCode | Should -Be 1 -Because "Start-Process 纯拼接在 $engine 下也必须失败（两引擎共有形态）"
                (Get-Content $errFile -Raw) | Should -Match 'Invalid argument/option'
            } finally {
                Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
            }
            # 形态三：包裹 + 翻倍 —— 两引擎都成功（产品唯一通道）
            $r = Invoke-NativeExe -FilePath $takeown -Arguments @('/f', ($spaced + '\')) -TimeoutSeconds 60
            $r.ok | Should -Be $true -Because "包裹后必须成功: exit=$($r.exit_code) err=$($r.error)"
        } finally {
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        }
    }

    It '真实超时：挂起进程在 TimeoutSeconds 后被击杀，exit_code 为 null' {
        # Start-Process -Wait 无法超时（旧实现的 TimeoutSeconds 只是报错文案装饰）；
        # ping -n 5 约 4 秒，1 秒超时必然命中。
        $r = Invoke-NativeExe -FilePath $script:Ping -Arguments @('-n', '5', '127.0.0.1') -TimeoutSeconds 1
        $r.exit_code | Should -Be $null
        $r.error | Should -Match 'timed out'
        $r.ok | Should -Be $false
    }

    It 'exe 不存在：不抛异常，返回 ok=false 且 exit_code 为 null' {
        $r = Invoke-NativeExe -FilePath 'Z:\definitely\not\here.exe' -Arguments @() -TimeoutSeconds 5
        $r.ok | Should -Be $false
        $r.exit_code | Should -Be $null
        $r.error | Should -Not -BeNullOrEmpty
    }

    It 'run-all Invoke-Step 的逃生舱形态（元素显式包引号）对含空格脚本路径真实可用' {
        # 陷阱 14a 的白名单豁免点：run-all.ps1 的 Invoke-Step 用
        # -ArgumentList @('-ExecutionPolicy','Bypass','-File', "`"$ScriptPath`"")
        # 单变量逃生舱（AGENTS.md 注明「不宜扩展新调用点」）。Round-2 走查
        # （构远图 Major）要求该形态至少有一条可执行回归——脚本路径永不含尾
        # 反斜杠（是文件不是目录），显式引号在拼接后保持完整，-File 拿到整路径。
        $base = Join-Path ([System.IO.Path]::GetTempPath()) "wrc-runall-$(New-Guid)"
        New-Item -ItemType Directory -Path $base -Force | Out-Null
        $spacedScript = Join-Path $base 'a b.ps1'
        [System.IO.File]::WriteAllText($spacedScript, "`$host.SetShouldExit(7)`nexit 7`n")
        try {
            $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if (-not $psExe) { $psExe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }
            $argList = @('-ExecutionPolicy', 'Bypass', '-File', "`"$spacedScript`"")
            $proc = Start-Process -FilePath $psExe -ArgumentList $argList -Wait -PassThru -NoNewWindow
            $proc.ExitCode | Should -Be 7 -Because '引号碎裂时 -File 收不到完整路径，退出码不会是脚本写的 7'
        } finally {
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        }
    }
}

Describe 'Platform hygiene: Invoke-ScExe / Invoke-RegExe 对含空格参数的行为（P1-1 回归）' {
    BeforeAll {
        $script:Root = (Resolve-Path "$PSScriptRoot\..\..").Path
        . (Join-Path $script:Root 'references\scripts\rollback-backup.ps1')
        . (Join-Path $script:Root 'references\scripts\clean-residuals.ps1')
    }

    It 'Invoke-ScExe：查询含空格的不存在服务名返回 1060（引号损坏时 sc 返回 1639 Invalid Option）' {
        $r = Invoke-ScExe -Arguments @('query', 'wrc probe spaced svc name')
        $r.exit_code | Should -Be 1060 -Because "实测引号碎裂时 sc 解析成额外 token 返回 1639；只有整体引号包裹才得到 1060 (error=$($r.error))"
    }

    It 'Invoke-ScExe：服务名含单引号与空格仍整体到达（返回 1060 而非参数碎裂）' {
        # 走查 2026-10-16 Major：单引号是 Windows 服务名的合法字符。sc.exe 按
        # MSVCRT 惯例解析 argv，单引号不是引号界定符——若封装层把 `'` 当危险
        # 字符或漏掉包裹，服务名都会碎裂。1060 = 名字整体到达且服务不存在。
        $r = Invoke-ScExe -Arguments @('query', "wrc' probe spaced")
        $r.exit_code | Should -Be 1060 -Because "单引号击穿封装时 sc 会把名字拆成错误 token（非 1060）: exit=$($r.exit_code) error=$($r.error)"
    }

    It 'Invoke-RegExe：导出键名含空格的真实 HKCU 键成功且文件含键名' {
        # 注意：该用例写真实注册表 HKCU\Software（finally 清理）；测试进程被
        # 强杀时可能遗留 WRC Quote Probe Space Key，属系统交互测试的已知取舍。
        $keyName = 'WRC Quote Probe Space Key'
        $keyPath = "HKCU:\Software\$keyName"
        New-Item -Path $keyPath -Force | Out-Null
        New-ItemProperty -Path $keyPath -Name 'Probe' -Value '1' -PropertyType DWord -Force | Out-Null
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "wrc-reg-$(New-Guid).reg"
        try {
            $r = Invoke-RegExe -Arguments @('export', "HKCU\Software\$keyName", $out, '/y')
            $r.ok | Should -Be $true -Because "reg export 失败说明含空格键名被拆散: $($r.error)"
            (Test-Path -LiteralPath $out) | Should -Be $true
            (Get-Content -LiteralPath $out -Raw) | Should -Match ([regex]::Escape($keyName))
        } finally {
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
            Remove-Item -Path $keyPath -Recurse -Force
        }
    }

    It 'Invoke-RegExe：导出键名含内嵌引号的 HKCU 键成功（create-restore-point 调用形态）' {
        # delphi 走查 2026-10-16 Critical 争议的最终裁决用例：值内嵌 `"` 经
        # ConvertTo-NativeArgument 转义、Start-Process 原样拼接后，reg.exe 按
        # MSVCRT 规则必须把键名原样收到（含引号字符）。双引擎实测通过。
        $keyName = 'WRC"QuoteProbe'
        $keyPath = "HKCU:\Software\$keyName"
        $null = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\$keyName")
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "wrc-reg-$(New-Guid).reg"
        try {
            $r = Invoke-RegExe -Arguments @('export', "HKCU\Software\$keyName", $out, '/y')
            $r.ok | Should -Be $true -Because "内嵌引号键名导出失败说明引号转义或拼接破坏了参数: $($r.error)"
            (Test-Path -LiteralPath $out) | Should -Be $true
            (Get-Content -LiteralPath $out -Raw) | Should -Match ([regex]::Escape($keyName))
        } finally {
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey("Software\$keyName", $false)
        }
    }
}

Describe 'Platform hygiene: AST 静态守卫（新增违规即在门禁变红）' {
    BeforeAll {
        $script:Root = (Resolve-Path "$PSScriptRoot\..\..").Path
        $script:ScriptFiles = @(
            (Get-ChildItem -LiteralPath (Join-Path $script:Root 'references\scripts') -Filter '*.ps1' -File).FullName
            (Join-Path $script:Root 'setup.ps1')
        )
        $script:AstCache = @{}
        foreach ($f in $script:ScriptFiles) {
            $tokens = $null; $errors = $null
            $script:AstCache[$f] = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
        }
    }

    It 'Start-Process 只允许出现在白名单文件（native-invoke.ps1 / run-all.ps1）' {
        # 白名单 = 唯一封装通道 Invoke-NativeExe 所在文件 + 管道编排器
        # Invoke-Step（其 -File 参数已显式反引号引号包裹并有注释说明）。
        $allow = @('native-invoke.ps1', 'run-all.ps1')
        $violations = @()
        foreach ($file in $script:ScriptFiles) {
            if ($allow -contains (Split-Path $file -Leaf)) { continue }
            $sites = @($script:AstCache[$file].FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Start-Process'
            }, $true))
            foreach ($s in $sites) {
                $violations += "$(Split-Path $file -Leaf):$($s.Extent.StartLineNumber) Start-Process 必须经 Invoke-NativeExe"
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It '白名单内的 Start-Process -ArgumentList 禁止含裸变量的数组字面量（P1-1 形态）' {
        # 数组字面量里混入 $var 元素 = Start-Process 拼接后碎裂的历史形态；
        # 必须经 ConvertTo-NativeArgument 转换后以单变量传入。
        $violations = @()
        foreach ($file in $script:ScriptFiles) {
            $sites = @($script:AstCache[$file].FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Start-Process'
            }, $true))
            foreach ($s in $sites) {
                $argParam = @($s.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'ArgumentList'
                }, $true)) | Select-Object -First 1
                if ($null -eq $argParam) { continue }
                $val = $argParam.Argument
                if ($val -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                    $bareVars = @($val.Elements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] })
                    if ($bareVars.Count -gt 0) {
                        $violations += "$(Split-Path $file -Leaf):$($s.Extent.StartLineNumber) -ArgumentList 数组字面量含裸变量（必须经 ConvertTo-NativeArgument）"
                    }
                }
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It 'Remove-* 破坏性函数体内路径类 cmdlet 一律 -LiteralPath，且禁用 Split-Path' {
        # Round-2 走查（构远图 Minor）：守卫从「单文件单函数」升级为**名字模式穷举**——
        # 上一轮真实死分支（tier-4 Split-Path）结构上属于任何破坏性函数；凡名为
        # Remove-* 的函数体一律适用本契约，新增破坏性函数自动进守卫。
        # Split-Path 的两个坑都不可在此使用：-Path 带通配符语义（同 Tier0 注入面）；
        # -LiteralPath 参数集不接受 -Parent/-Leaf（两个引擎都抛 Parameter set cannot
        # be resolved —— 2026-10-16 走查实测，tier-4 曾因此整体变成死分支且被
        # locked-fixture 的预期失败路径吞掉）。路径拆解用 [System.IO.Path] 字面量方法。
        $destructiveFns = @()
        foreach ($file in $script:ScriptFiles) {
            $fns = @($script:AstCache[$file].FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -match '^Remove-'
            }, $true))
            foreach ($fnAst in $fns) { $destructiveFns += @{ File = $file; Ast = $fnAst } }
        }
        $destructiveFns.Count | Should -BeGreaterThan 0 -Because '守卫必须实际覆盖到至少一个破坏性函数，否则是空跑'
        $pathCmdlets = @('Remove-Item', 'Rename-Item', 'Get-Item', 'Test-Path')
        $violations = @()
        foreach ($entry in $destructiveFns) {
            $fn = $entry.Ast
            $fileLeaf = Split-Path $entry.File -Leaf
            $splitSites = @($fn.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Split-Path'
            }, $true))
            foreach ($s in $splitSites) {
                $violations += "${fileLeaf}:$($s.Extent.StartLineNumber) Split-Path 在破坏性函数 $($fn.Name) 内禁用（-Path 有通配符语义、-LiteralPath 不接受 -Parent/-Leaf；用 [System.IO.Path]）"
            }
            $sites = @($fn.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $pathCmdlets -contains $n.GetCommandName()
            }, $true))
            foreach ($s in $sites) {
                $hasLiteral = @($s.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'LiteralPath'
                }, $true)).Count -gt 0
                if (-not $hasLiteral) {
                    $violations += "${fileLeaf}:$($s.Extent.StartLineNumber) $($s.GetCommandName()) 未用 -LiteralPath"
                }
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It '产品脚本内禁止裸 reg/sc 命令（必须走 Invoke-RegExe / Invoke-ScExe 封装）' {
        $violations = @()
        foreach ($file in $script:ScriptFiles) {
            $sites = @($script:AstCache[$file].FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -match '^(reg|sc)(\.exe)?$'
            }, $true))
            foreach ($s in $sites) {
                $violations += "$(Split-Path $file -Leaf):$($s.Extent.StartLineNumber) 裸 $($s.GetCommandName()) 调用（走封装）"
            }
        }
        $violations | Should -BeNullOrEmpty
    }

    It 'rollback 库清单：每个列出的库都存在且 rollback.ps1 清单是 clean-residuals 清单的同序子集' {
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'references\scripts\clean-residuals.ps1') -Raw
        $rollback = Get-Content -LiteralPath (Join-Path $script:Root 'references\scripts\rollback.ps1') -Raw
        $cleanOrder = [regex]::Match($clean, "(?s)\`$rollbackLibOrder = @\(([^)]*)\)").Groups[1].Value
        $rollbackOrder = [regex]::Match($rollback, "(?s)\`$rollbackLibOrder = @\(([^)]*)\)").Groups[1].Value
        $cleanOrder | Should -Not -BeNullOrEmpty -Because 'clean-residuals.ps1 必须声明库清单'
        $rollbackOrder | Should -Not -BeNullOrEmpty -Because 'rollback.ps1 必须声明库清单'

        $cleanLibs = [regex]::Matches($cleanOrder, "'([^']+\.ps1)'") | ForEach-Object { $_.Groups[1].Value }
        $rollbackLibs = [regex]::Matches($rollbackOrder, "'([^']+\.ps1)'") | ForEach-Object { $_.Groups[1].Value }

        foreach ($lib in $cleanLibs) {
            (Test-Path -LiteralPath (Join-Path $script:Root "references\scripts\$lib")) | Should -Be $true -Because "清单里的 $lib 必须存在，缺失即假 fail-closed"
        }
        # native-invoke.ps1 在 clean-residuals 侧是直接调用（Invoke-ScExe / Tier2 takeown），
        # 在 rollback 侧仅经 rollback-backup.ps1 的包装间接使用，故不在 rollback 清单里；
        # 其存在性由下面单独的存在断言钉住（走查 2026-10-16：字符串断言不等于存在性）。
        (Test-Path -LiteralPath (Join-Path $script:Root 'references\scripts\native-invoke.ps1')) | Should -Be $true -Because 'native-invoke.ps1 是平台原语，被误删时必须在这里变红'
        # rollback 不需要 producer（只读 + 消费端）与 native-invoke（间接加载），
        # 但其余库必须与 clean 同序。
        $expected = @($cleanLibs | Where-Object { $_ -ne 'rollback-producer.ps1' -and $_ -ne 'native-invoke.ps1' })
        @($rollbackLibs -join '|') | Should -Be (@($expected -join '|'))
    }

    It 'native-invoke.ps1 被 rollback-backup.ps1 / create-restore-point.ps1 / clean-residuals.ps1 显式加载' {
        $backup = Get-Content -LiteralPath (Join-Path $script:Root 'references\scripts\rollback-backup.ps1') -Raw
        $create = Get-Content -LiteralPath (Join-Path $script:Root 'references\scripts\create-restore-point.ps1') -Raw
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'references\scripts\clean-residuals.ps1') -Raw
        $backup | Should -Match 'native-invoke\.ps1'
        $create | Should -Match 'native-invoke\.ps1'
        # clean-residuals 直接调用 Invoke-NativeExe（Tier2），必须自己显式加载，
        # 不得依赖 rollback-backup 的传递加载（走查 2026-10-16 minor）。
        $clean | Should -Match "'native-invoke\.ps1'"
    }
}

Describe 'Platform hygiene: 门禁边界一致性（R6 走查证实项 2026-10-17）' {
    # 背景：R6 三专家走查实测证明——analysis-paths 的「硬边界」此前只由散文承诺，
    # 钩子对「列表条目缺失」是静默跳过（fail-open），产品源若放错了位置 Gate 1
    # 对它失明且无人报警。本组用例把散文边界变成可执行守卫（fail-closed）。
    # 自带 BeforeAll（R6 Round-2 稳落地 minor）：过滤单跑本组时不再依赖首个
    # Describe 设置的 $script:Root。
    BeforeAll {
        if (-not $script:Root) {
            $script:Root = (Resolve-Path "$PSScriptRoot\..\..").Path
        }
    }

    It 'analysis-paths 覆盖全部 tracked 产品源；列表条目必须真实存在' {
        $scope = @(Get-Content -LiteralPath (Join-Path $script:Root '.xp-gate-powershell-analysis-paths') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
        $scope.Count | Should -BeGreaterThan 0 -Because '空 scope 会让 Gate 1 降级（analysis-paths-empty WARN）'
        foreach ($t in $scope) {
            (Test-Path -LiteralPath (Join-Path $script:Root $t)) | Should -Be $true -Because "analysis-paths 条目 $t 不存在——钩子会以 analysis-path-missing 发 WARN，产品代码失明"
        }
        # 产品源 = git tracked *.ps1，排除测试与已 prune 的脚手架/演练目录。
        # prune 前缀从 .xp-gate-powershell-prune-dirs 推导（R6 Round-2 稳落地：
        # 不再硬编码第四份副本）；dot 目录是适配器内置清单，按文档保留。
        $pruneDirs = @(Get-Content -LiteralPath (Join-Path $script:Root '.xp-gate-powershell-prune-dirs') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
        $prunedPrefixes = @('tests/') + @($pruneDirs | ForEach-Object { ($_ -replace '\\', '/').TrimEnd('/') + '/' }) +
            @('.sprint-state/', '.delphi-work/', '.worktrees/', '.workbuddy/', '.qoder/', '.vscode/', '.idea/', '.xp-gate/')
        $tracked = @(& git -C $script:Root ls-files '*.ps1' | ForEach-Object { $_ -replace '\\', '/' })
        $product = @($tracked | Where-Object {
            $p = $_
            -not ($prunedPrefixes | Where-Object { $p.StartsWith($_) })
        })
        $product.Count | Should -BeGreaterThan 0
        foreach ($p in $product) {
            $covered = $false
            foreach ($t in $scope) {
                $tn = ($t -replace '\\', '/').TrimEnd('/')
                if ($p -eq $tn -or $p.StartsWith("$tn/")) { $covered = $true; break }
            }
            $covered | Should -BeTrue -Because "产品源 $p 不被 .xp-gate-powershell-analysis-paths 覆盖——Gate 1 对它失明；新产品脚本必须同提交加路径（硬边界）"
        }
    }

    It 'coverage-ignore 保持空列表（分母即真实产品清单，禁止按产物减扣）' {
        $active = @(Get-Content -LiteralPath (Join-Path $script:Root '.xp-gate-powershell-coverage-ignore') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
        $active | Should -BeNullOrEmpty -Because 'prune 机制已让发现=分母；往 coverage-ignore 加条目会把真实产品代码从覆盖率分母里静默减掉'
    }

    It 'prune-dirs 声明 wrc-drill（本机演练脚手架必须隔离于发现/覆盖率/分析三处分母）' {
        $prune = @(Get-Content -LiteralPath (Join-Path $script:Root '.xp-gate-powershell-prune-dirs') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
        $prune | Should -Contain 'wrc-drill' -Because 'wrc-drill 是本机管理员演练脚手架（会创建真实系统对象，2026-10-20 起已移出 git 跟踪、仅存本地），必须留在三处分母之外'
    }

    It '非 ASCII 的 .ps1 一律带 UTF-8 BOM（CI 编码守卫的本地等价物）' {
        # CI run 40100344167 / 40102096196 连续两次因此报红，而**本地从未拦过**：
        # 这条守卫只存在于 .github/workflows/ci.yml。PSScriptAnalyzer 虽有
        # PSUseBOMForUnicodeEncodedFile，但 Gate 1 的分析范围收敛在
        # `.xp-gate-powershell-analysis-paths`（产品源），**tests/ 不在其中**，
        # 所以这条规则从未在本地对测试文件生效。
        #
        # 后果：开发者跑完双引擎 Pester、vitest、PSSA、覆盖率全绿，推送后 CI 红。
        # 「门禁只在 CI 生效的那一半，等于本地没有。」本用例把那半边补到本地。
        #
        # 实测触发方式极隐蔽：编辑工具整文件重写 `.ps1` 会**丢掉原有 BOM**，
        # 即使 diff 只显示改了几行断言。本用例因此必须覆盖 tests/ 与 tools/。
        $scope = @(Get-ChildItem -LiteralPath $script:Root -Recurse -Filter '*.ps1' -File |
            Where-Object { $_.FullName -notmatch '\\node_modules\\|\\\.git\\' } |
            Where-Object {
                $rel = $_.FullName.Substring($script:Root.Length).TrimStart('\', '/')
                # 与 CI 守卫同样的排除面：gitignored 的本机脚手架没有跨机器契约。
                $rel -notmatch '^(\.workbuddy|\.delphi-work|\.qoder|\.sprint-state|\.worktrees|\.xp-gate|wrc-drill)[\\/]'
            })
        $offenders = @()
        foreach ($f in $scope) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            if ($hasBom) { continue }
            $hasNonAscii = $false
            foreach ($b in $bytes) { if ($b -gt 0x7F) { $hasNonAscii = $true; break } }
            if ($hasNonAscii) { $offenders += $f.FullName.Substring($script:Root.Length).TrimStart('\', '/') }
        }
        $offenders | Should -BeNullOrEmpty -Because "以下 .ps1 含非 ASCII 却缺 UTF-8 BOM：$($offenders -join ', ')。PS 5.1 会按系统 ANSI 码页读取无 BOM 文件，中文变乱码甚至解析失败；CI 编码守卫会直接拒绝"
    }

    It '钩子安装与 vendored 副本一致（被回退/删除时变红，杜绝静默降级）' {
        # R6 Round-2 稳落地 BLOCKING CANDIDATE 的落实：2026-10-17 实测一个外部
        # xp-gate 维护进程把 batch-3 硬化文件整体回退为 legacy（保留旧 mtime，
        # ls -l 无异常），两次实弹提交的 Gate 1/Gate 10 实为 skip-as-pass。
        # 本用例把「live 钩子 == 仓库 vendored 权威副本」变成套件判据：回退即红。
        # R6 Round-3 修正：live 文件被**删除**（而非回退内容）时哈希断言曾静默
        # 跳过（目录存在 ⇒ 文件必须存在，缺席即红）；vendored 存在性断言移到
        # Inconclusive 早退之前，使 CI/新克隆也守得住仓库侧副本。
        $hookDir = Join-Path $HOME '.config\xp-gate'
        $pairs = @(
            @{ live = 'adapters\powershell.sh'; vendored = 'githooks\adapters\powershell.sh' },
            @{ live = 'adapters\gate-10.sh'; vendored = 'githooks\adapters\gate-10.sh' },
            # 2026-10-24 加入：require_tool 的 PATH 探测补丁（npm 全局 bin /
            # 子项目 node_modules/.bin）落在 adapter-common.sh。它不在原白名单里，
            # 于是补丁被回退时一致性测试不会红——正是本用例要消除的那类盲区。
            @{ live = 'adapters\adapter-common.sh'; vendored = 'githooks\adapters\adapter-common.sh' },
            # 2026-10-24 加入：Gate 3 的 PowerShell 分支（AST 复杂度 + 棘轮）。
            # 这一层补丁若被回退，Gate 3 会静默退回「no PowerShell tool」的硬 SKIP，
            # 报告里只是少一道 PASS —— 没人会注意到复杂度维度又空了。
            @{ live = 'adapters\gate-3.sh'; vendored = 'githooks\adapters\gate-3.sh' },
            @{ live = 'hooks\pre-commit'; vendored = 'githooks\hooks\pre-commit' }
        )
        foreach ($pair in $pairs) {
            $vendoredPath = Join-Path $script:Root $pair.vendored
            (Test-Path -LiteralPath $vendoredPath) | Should -Be $true -Because "vendored 副本 $($pair.vendored) 缺失——防回退机制被拆掉"
        }
        if (-not (Test-Path -LiteralPath $hookDir)) {
            Set-ItResult -Inconclusive -Because '用户级 xp-gate 未安装（新克隆/CI）：live 一致性只在本机安装存在时校验'
            return
        }
        foreach ($pair in $pairs) {
            $livePath = Join-Path $hookDir $pair.live
            $vendoredPath = Join-Path $script:Root $pair.vendored
            (Test-Path -LiteralPath $livePath) | Should -Be $true -Because "live $($pair.live) 缺失——文件被删除与被回退同级（R6 R3 修正：原实现静默跳过假绿）；恢复：cp $($pair.vendored) ~/.config/xp-gate/$($pair.live -replace '\\','/')"
            $liveHash = (Get-FileHash -LiteralPath $livePath -Algorithm SHA256).Hash
            $vendoredHash = (Get-FileHash -LiteralPath $vendoredPath -Algorithm SHA256).Hash
            $liveHash | Should -Be $vendoredHash -Because "live $($pair.live) 与 vendored 副本不一致——硬化补丁被外部进程回退（实测发生过）；恢复：cp $($pair.vendored) ~/.config/xp-gate/$($pair.live -replace '\\','/')"
        }
        # 标记断言用 Gate-1 powershell 分支**专属**符号（R6 R3：'powershell)' 在
        # 上游文件出现 2 处、'\.ps1$' 2 处，弱子串在「只回退其中一处」时失效）。
        $livePreCommit = Join-Path $hookDir 'hooks\pre-commit'
        $pc = Get-Content -LiteralPath $livePreCommit -Raw
        $pc.Contains('PS_G1_REASON') | Should -BeTrue -Because 'pre-commit 缺 PS_G1_REASON 协议——Gate 1 powershell fail-closed 分支被回退'
        $pc.Contains('GATE_1_DETAIL="powershell:') | Should -BeTrue -Because 'pre-commit 缺 GATE_1_DETAIL powershell 前缀——WARN 详情映射被回退'
        # 谓词断言（2026-10-21 升级 0.30.5 后校正）：上游 0.30.5 把 psm1 并进
        # 同一条扩展名正则（`...(dart|sh|ps1|psm1)$`），本仓历史补丁用的是独立
        # 参数 `"\.ps1$" "\.psm1$"`。两种形态都满足「psm1 被 Gate 1/Gate 10
        # 谓词覆盖」这一实质要求，故按语义断言而不是钉死某一种字面写法——
        # 否则每次上游合并写法变化都会假红。
        $pc.Contains('ps1)') | Should -BeTrue -Because 'pre-commit Gate 1/Gate 10 谓词不含 ps1（独立参数或并入扩展名正则均可）——ps1 变更会绕过静态分析与 SAST'
        $pc.Contains('psm1') | Should -BeTrue -Because 'pre-commit Gate 1/Gate 10 谓词不含 psm1——psm1 变更会绕过静态分析与 SAST'

        # 第 5 判据（2026-10-17 事故第三次实证）：内容完好还不够——git 必须真的
        # 走 xp-gate 链。实测 .git/config 被外部进程写入空 core.hooksPath（空值
        # 覆盖全局配置 → 钩子目录回落到无钩子的 .git/hooks），提交完全不跑门禁
        # 且报告零输出。本用例断言解析后的 core.hooksPath 指向用户级 xp-gate。
        # （-C 钉定仓库，R6 R3：过滤单跑/换 cwd 时不得读到别的仓库的配置。）
        $expectedHooks = (Join-Path $hookDir 'hooks').Replace('\', '/')
        $resolved = (git -C $script:Root config core.hooksPath)
        $resolvedNorm = if ([string]::IsNullOrWhiteSpace($resolved)) { '' } else { $resolved.Replace('\', '/').TrimEnd('/') }
        $resolvedNorm | Should -Be ($expectedHooks.TrimEnd('/')) -Because "core.hooksPath 解析为 '$resolved'——xp-gate 链被断开或指向别处（实测 .git/config 被写入空值覆盖全局配置，提交零门禁）；恢复：git config core.hooksPath $expectedHooks"

        # 第 6 判据（2026-10-24 实测追加）：PowerShell 门禁的「真生效」本身也要钉住。
        # 实测基线：只改 .ps1 的提交跑出来的报告是 6/12 PASS、verdict PASS，而
        # Gate 10 显示 「no supported language files changed」、Gate 5 的覆盖率
        # 只吃了 vitest 的 subset —— 门禁没有失败，是它看不见。下列标记就是
        # 本仓对「看得见」的修法所在；任何一次回退都会让其中一条变红。
        $pc.Contains('Coverage report integrity') | Should -BeTrue -Because 'pre-commit 缺 PowerShell 覆盖率报告完整性校验——coverage.xml 会以任意 sourcefile 集合通过 80% 线（实测出现过 23 个 sourcefile 与 0 个两种污染形态）'
        $pc.Contains('Gate 5c-ps') | Should -BeTrue -Because 'pre-commit 缺 Pester 侧 @test 注解校验——PowerShell 测试的语义对齐在 jq/req-ids.json 缺席时是 no-op'
        $pc.Contains('-ge 0 ] 2>/dev/null; then') | Should -BeTrue -Because 'pre-commit 缺「0% 覆盖率是数据而非缺失」的修复（#570）——什么都没测的套件会被当作"无法判定"放行'
        $pc.Contains('PS_COV_EXPECTED') | Should -BeTrue -Because 'pre-commit 缺覆盖率分母（发现列表）与报告 sourcefile 的交叉校验'
    }
}

Describe 'Platform hygiene: 需求 ID 单一真相源（2026-10-24）' {
    # 背景：Gate 5c 的语义对齐在本仓长期是空转（req-ids.json 从未生成 + jq 不在
    # 钩子 PATH + 发现只认 JS/TS 测试名）。修法是把 id 清单放进仓库
    # （.xp-gate-req-ids，由 .xp-gate-req-ids.cjs 从 specification.yaml 生成），
    # 钩子读它做校验。本组用例保证「清单不会腐烂」：任一侧改了 id 而另一侧
    # 没跟上，套件立刻变红，而不是等到某个提交莫名其妙被放行。
    BeforeAll {
        if (-not $script:Root) {
            $script:Root = (Resolve-Path "$PSScriptRoot\..\..").Path
        }
        $script:ReqIdsPath = Join-Path $script:Root '.xp-gate-req-ids'
        $script:SpecPath = Join-Path $script:Root 'specification.yaml'
        $script:GeneratorPath = Join-Path $script:Root '.xp-gate-req-ids.cjs'
    }

    It '.xp-gate-req-ids 与 specification.yaml 的 id 集合完全一致（双向）' {
        (Test-Path -LiteralPath $script:ReqIdsPath) | Should -BeTrue -Because '缺少 .xp-gate-req-ids 会让钩子直接跳过 PowerShell 注解校验'
        $specIds = @(
            Select-String -LiteralPath $script:SpecPath -Pattern '^\s*-\s+id:\s*(REQ-\d+|AC-\d+)\s*$' |
                ForEach-Object { $_.Matches[0].Groups[1].Value } |
                Sort-Object -Unique
        )
        $specIds.Count | Should -BeGreaterThan 0 -Because '正则若失配，本用例会退化成空断言'
        $listIds = @(Get-Content -LiteralPath $script:ReqIdsPath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Sort-Object -Unique)
        $listIds.Count | Should -BeGreaterThan 0
        $missing = @($specIds | Where-Object { $listIds -notcontains $_ })
        $extra = @($listIds | Where-Object { $specIds -notcontains $_ })
        $missing -join ', ' | Should -Be '' -Because "specification.yaml 有而 .xp-gate-req-ids 没有的 id：$($missing -join ', ')——用 node .xp-gate-req-ids.cjs > .xp-gate-req-ids 重新生成"
        $extra -join ', ' | Should -Be '' -Because "清单里有而 specification.yaml 已经没有的 id：$($extra -join ', ')——注解指向了已被删除的需求，测试无法为它失败"
    }

    It '清单可用钩子里的同一套 grep 判据逐条匹配（含 CRLF/BOM 容错）' {
        # 钩子用 `grep -qxF -- "$id"` 对清洗后的清单做整行匹配。本用例用 PowerShell
        # 复刻这条判据，确保清单的每一行都能被它命中（首尾空白、CRLF、注释行都是
        # 实测过的翻车点）。
        $raw = [System.IO.File]::ReadAllText($script:ReqIdsPath)
        $clean = @($raw -split "`r?`n" |
            ForEach-Object { ($_ -replace '^\uFEFF', '').TrimEnd() } |
            Where-Object { $_ -and -not $_.TrimStart().StartsWith('#') })
        $clean.Count | Should -BeGreaterThan 100
        foreach ($id in @('REQ-001', 'REQ-035', 'AC-001', 'AC-100')) {
            $clean | Should -Contain $id -Because "清单必须能让钩子按整行匹配到 $id"
        }
        # BOM 直接看字节，不看字符串：.NET 的 ReadAllText 会自动剥离 BOM，
        # 用 [string]::StartsWith 判断会把带 BOM 的文件判成「干净」（本用例
        # 第一版就是这么假绿的——实测 0xEF,0xBB,0xBF 仍在文件头）。
        $bytes = [System.IO.File]::ReadAllBytes($script:ReqIdsPath)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $hasBom | Should -BeFalse -Because '带 BOM 的清单会让第一行 id 永远匹配不上（各工具对 BOM 的处理不一致）；用 node .xp-gate-req-ids.cjs 重新生成'
    }

    It '生成器存在且能独立跑通（specification.yaml 是唯一真相源）' {
        (Test-Path -LiteralPath $script:GeneratorPath) | Should -BeTrue -Because '生成器入库才能让「重新生成」这条建议可执行'
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) {
            Set-ItResult -Inconclusive -Because 'node 不可用：生成器行为由 CI/Gate 5 的 root vitest 侧覆盖'
            return
        }
        $generated = & node $script:GeneratorPath 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because "生成器跑失败：$generated"
        $generated | Should -Match 'REQ-001'
        $generated | Should -Match 'AC-100'
    }
}

Describe 'Platform hygiene: 适配器 stdout 契约（2026-10-24 实测）' {
    # 背景：`_find_powershell_files` 的 **stdout 就是文件清单**，每个调用方都把它
    # 收进 Pester 的 `Run.Path` / `CodeCoverage.Path` 数组。
    #
    # 2026-10-24 实测：上游把 `pruning directory name 'wrc-drill'` 这行提示 echo 到
    # stdout，于是提示语变成了「路径」，Pester 报
    #   Could not resolve coverage path '  ℹ️  pruning directory name ...'
    # 并写出 **2 字节空 coverage.xml**。门禁随后报「could not parse coverage」——
    # 在 #570 修复前，这会被当成「无法判定」而**放行一条零覆盖率证据的提交**。
    #
    # 本组用例不 mock 任何东西：直接跑适配器的发现函数，断言「stdout 里每行都是
    # .ps1 路径」。这类缺陷只能靠「输出面」断言抓到，逻辑断言永远是绿的。
    BeforeAll {
        if (-not $script:Root) {
            $script:Root = (Resolve-Path "$PSScriptRoot\..\..").Path
        }
        $script:Bash = @(
            'C:\Program Files\Git\bin\bash.exe',
            'C:\Program Files\Git\usr\bin\bash.exe',
            '/usr/bin/bash'
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }

    It '文件发现函数的 stdout 只含 .ps1 路径，提示语全部走 stderr' {
        if (-not $script:Bash) {
            Set-ItResult -Inconclusive -Because 'bash 不可用：钩子适配器只在 git-bash 下运行'
            return
        }
        $liveAdapter = Join-Path $env:USERPROFILE '.config\xp-gate\adapters\powershell.sh'
        if (-not (Test-Path -LiteralPath $liveAdapter)) {
            Set-ItResult -Inconclusive -Because '用户级 xp-gate 未安装（新克隆/CI）'
            return
        }
        $script = & $script:Bash -lc "cd '$($script:Root -replace '\\','/')' && source '$($liveAdapter -replace '\\','/')' && _find_powershell_files '*.ps1' 2>/dev/null"
        $lines = @($script | Where-Object { $_ -ne '' })
        $lines.Count | Should -BeGreaterThan 0 -Because '发现结果为空说明适配器根本没跑起来，断言会退化为假绿'
        $leaks = @($lines | Where-Object { $_ -notmatch '\.ps1$' })
        $leaks -join ' | ' | Should -Be '' -Because "stdout 混入非 .ps1 的提示行：这些行会被当作路径塞进 Pester 的 CodeCoverage.Path，导致覆盖率产物变成空文档。漏出的行：$($leaks -join ' | ')"
    }

    It '发现的产品源恰好 18 个（17 脚本 + setup.ps1，权威口径）' {        if (-not $script:Bash) {
            Set-ItResult -Inconclusive -Because 'bash 不可用'
            return
        }
        $liveAdapter = Join-Path $env:USERPROFILE '.config\xp-gate\adapters\powershell.sh'
        if (-not (Test-Path -LiteralPath $liveAdapter)) {
            Set-ItResult -Inconclusive -Because '用户级 xp-gate 未安装'
            return
        }
        $script = & $script:Bash -lc "cd '$($script:Root -replace '\\','/')' && source '$($liveAdapter -replace '\\','/')' && _find_powershell_files '*.ps1' 2>/dev/null"
        $product = @($script | Where-Object { $_ -match '\.ps1$' -and $_ -notmatch '\.Tests\.ps1$' })
        # AGENTS.md「coverage.xml 的口径与污染」：权威口径 = references/scripts 17
        # 脚本 + setup.ps1 + tools/ 下 3 个门禁工具脚本 = 21 sourcefile。
        # 数量变了要么是新脚本没入列的缺陷，要么是文档没跟上——两种都需要人看一眼，
        # 所以这里钉死。（2026-10-24：tools/Measure-PowerShellComplexity.ps1、
        # tools/Update-ComplexityBaseline.ps1、tools/Test-PowerShellArchitecture.ps1
        # 入库后由 18 变为 21。）
        $product.Count | Should -Be 21 -Because "发现到的产品源是 $($product.Count) 个（清单：$($product -join ', ')）——权威口径是 21 个（17 脚本 + setup.ps1 + 3 个 tools 门禁工具），数量不符时先查是不是演练目录/本地脚本混进了分母，或者新脚本没被算进来"
        @($product | Where-Object { $_ -match 'wrc-drill|\.workbuddy|backup-' }).Count |
            Should -Be 0 -Because '演练目录/本地产物不得进入覆盖率分母（prune-dirs 的职责）'
    }

    It '覆盖率运行有独立的、不小于普通测试运行的单次超时预算（2026-10-24 实测）' {
        $liveAdapter = Join-Path $env:USERPROFILE '.config\xp-gate\adapters\powershell.sh'
        if (-not (Test-Path -LiteralPath $liveAdapter)) {
            Set-ItResult -Inconclusive -Because '用户级 xp-gate 未安装'
            return
        }
        # 真实缺陷（2026-10-24 实测）：覆盖率运行与普通测试运行共用 300s 预算。
        # 本仓库 762 个用例的普通运行就要约 285s，**插桩运行更慢**，于是覆盖率
        # 每次都在 300s 被杀 → 门禁报 "Pester coverage TIMED OUT (may be hanging)"
        # → 「预算不够」被说成「测试挂住」，且**每一个**代码提交都被拦。
        # 实测错误信息的误导性正是重点：它让人去找挂住的测试，而真正的问题在预算。
        $text = Get-Content -LiteralPath $liveAdapter -Raw
        $coverageMatch = [regex]::Match($text, 'XP_GATE_POWERSHELL_COVERAGE_TIMEOUT_S:-(\d+)')
        $testMatch = [regex]::Match($text, 'XP_GATE_POWERSHELL_TEST_TIMEOUT_S:-(\d+)')
        $coverageMatch.Success | Should -BeTrue -Because '覆盖率超时预算必须显式存在（XP_GATE_POWERSHELL_COVERAGE_TIMEOUT_S），否则退回普通测试预算——正是本次缺陷'
        $testMatch.Success | Should -BeTrue -Because '普通测试超时预算必须显式存在'
        $coverageDefault = [int]$coverageMatch.Groups[1].Value
        $testDefault = [int]$testMatch.Groups[1].Value
        $coverageDefault | Should -BeGreaterOrEqual $testDefault -Because "插桩运行比普通运行慢，覆盖率预算（${coverageDefault}s）不得小于普通测试预算（${testDefault}s）——否则健康的套件会被预算杀掉"
        # 300s 是被实测证明不够的下限；钉死「明显更大」防止有人改回去。
        $coverageDefault | Should -BeGreaterThan 300 -Because '实测 762 用例的插桩运行超过 300s；覆盖率预算必须显著高于曾经出问题的 300s'
    }

    It '覆盖率运行用的是覆盖率预算，而不是普通测试预算' {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Root 'githooks/adapters/powershell.sh'))) {
            Set-ItResult -Inconclusive -Because 'vendored 适配器缺失'
            return
        }
        $adapter = Get-Content -LiteralPath (Join-Path $script:Root 'githooks/adapters/powershell.sh') -Raw
        # run_coverage 里必须调用 _pester_coverage_timeout；用错成 _pester_timeout
        # 会让「加了独立预算」变成没人用到的死代码（本次缺陷的下一层形态）。
        $adapter | Should -Match '_pester_coverage_timeout\s+"\$PWSH"' -Because 'run_coverage 必须用覆盖率的专用超时包装；用普通 _pester_timeout 时独立预算形同不存在'
        $adapter | Should -Match 'CodeCoverage\.Enabled' -Because '覆盖率运行必须真的开启 CodeCoverage'
    }

    It 'Gate 10 的 semgrep 探测覆盖了「包装器 + pysemgrep 同目录」两种形态' {
        $vendored = Join-Path $script:Root 'githooks/adapters/gate-10.sh'
        if (-not (Test-Path -LiteralPath $vendored)) {
            Set-ItResult -Inconclusive -Because 'vendored gate-10.sh 缺失'
            return
        }
        # 真实缺陷（2026-10-24 实测）：`semgrep.exe` 只是 zipapp 包装器，内部
        # exec `pysemgrep`（另一个可执行文件，在同一 pip Scripts 目录）。
        # 只解析到包装器而该目录不在 PATH 上时，semgrep 报
        #   executing pysemgrep failed: run ["pysemgrep" ...]: No such file or directory
        # 于是 Gate 10 在「工具其实装好了」的情况下 WARN 跳过——而它是唯一会扫
        # .ps1 的安全门禁。
        $text = Get-Content -LiteralPath $vendored -Raw
        $text | Should -Match 'pysemgrep' -Because 'gate-10.sh 的注释必须记下「包装器需要 pysemgrep 在同目录」这条实测根因，否则下一个维护者会把它「简化」掉'
        $text | Should -Match 'AppData/Roaming/Python' -Because 'pip --user 的 Scripts 目录必须进探测/注入范围：pysemgrep 就在那里'
        $text | Should -Match '\$HOME/bin/semgrep' -Because '实测 semgrep 可能装在手放的 ~/bin 下，必须探测'
    }
}
