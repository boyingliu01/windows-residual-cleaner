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
        # 仅尾反斜杠、无空白 → 不需要包裹，原样返回（引号规则只作用于被包裹的值）
        ConvertTo-NativeArgument 'C:\dir\' | Should -Be 'C:\dir\'
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
            (Test-Path -LiteralPath ($spaced + '"')) | Should -Be $false -Because '闭合引号被吞掉时 cmd 会把引号字面量并进目录名'
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

    It 'Remove-ItemRobust 函数体内路径类 cmdlet 一律 -LiteralPath，且禁用 Split-Path' {
        # Split-Path 的两个坑都不可在此使用：-Path 带通配符语义（同 Tier0 注入面）；
        # -LiteralPath 参数集不接受 -Parent/-Leaf（两个引擎都抛 Parameter set cannot
        # be resolved —— 2026-10-16 走查实测，tier-4 曾因此整体变成死分支且被
        # locked-fixture 的预期失败路径吞掉）。路径拆解用 [System.IO.Path] 字面量方法。
        $fn = @($script:AstCache[(Join-Path $script:Root 'references\scripts\clean-residuals.ps1')].FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-ItemRobust'
        }, $true)) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty
        $pathCmdlets = @('Remove-Item', 'Rename-Item', 'Get-Item', 'Test-Path')
        $violations = @()
        $splitSites = @($fn.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Split-Path'
        }, $true))
        foreach ($s in $splitSites) {
            $violations += "clean-residuals.ps1:$($s.Extent.StartLineNumber) Split-Path 在 Remove-ItemRobust 内禁用（-Path 有通配符语义、-LiteralPath 不接受 -Parent/-Leaf；用 [System.IO.Path]）"
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
                $violations += "clean-residuals.ps1:$($s.Extent.StartLineNumber) $($s.GetCommandName()) 未用 -LiteralPath"
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
