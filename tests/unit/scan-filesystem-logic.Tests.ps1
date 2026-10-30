# scan-filesystem-residuals.ps1 的活性/白名单判定纯函数（issue #10）。
#
# 背景：文件系统扫描原本只按「文件数 + 体积」判定残留，既不识别系统目录，
# 也不识别正在被进程/服务使用的目录，于是 22.5GB 的运行中 WSL 虚拟磁盘、
# 正在运行的 gh.exe / Everything / Office 都被列为残留。
# 这些闸门抽成纯函数后可以直接喂真值表，不再依赖本机装了什么。

BeforeAll {
    . "$PSScriptRoot\..\..\references\scripts\scan-filesystem-residuals.ps1"
}

Describe 'Get-ProtectedDirName / Test-ProtectedDirName' {
    It '默认白名单包含 WSL 虚拟磁盘目录' {
        @(Get-ProtectedDirName -config $null) | Should -Contain 'wsl'
    }

    It '默认白名单按前缀覆盖 Microsoft 系组件目录' {
        Test-ProtectedDirName -name 'Microsoft Office 15' -protectedNames @(Get-ProtectedDirName -config $null) | Should -Be $true
    }

    It 'config 中的自定义条目与默认值合并' {
        $config = [PSCustomObject]@{ protected_dir_names = @('MyVendorData') }
        $names = @(Get-ProtectedDirName -config $config)
        $names | Should -Contain 'MyVendorData'
        $names | Should -Contain 'wsl'
    }

    It '普通应用目录不被保护' {
        Test-ProtectedDirName -name 'Docker' -protectedNames @(Get-ProtectedDirName -config $null) | Should -Be $false
    }

    It '支持通配模式' {
        Test-ProtectedDirName -name 'regid.1991-06.com.microsoft' -protectedNames @('regid.*') | Should -Be $true
    }
}

Describe 'Test-DirectoryInUse' {
    It '目录是运行中进程可执行文件的前缀目录 → 在用' {
        $live = @('C:\Program Files\GitHub CLI\gh.exe', 'C:\Windows\System32\svchost.exe')
        Test-DirectoryInUse -path 'C:\Program Files\GitHub CLI' -livePaths $live | Should -Be $true
    }

    It '目录只是名字前缀相同的兄弟目录 → 不在用' {
        $live = @('C:\Program Files\Git\cmd\git.exe')
        Test-DirectoryInUse -path 'C:\Program Files\GitHub CLI' -livePaths $live | Should -Be $false
    }

    It '末尾反斜杠不影响判定' {
        $live = @('C:\ProgramData\LKY Office Tools\LKY_OfficeTools.exe')
        Test-DirectoryInUse -path 'C:\ProgramData\LKY Office Tools\' -livePaths $live | Should -Be $true
    }

    It '大小写不敏感' {
        $live = @('c:\program files\github cli\gh.exe')
        Test-DirectoryInUse -path 'C:\Program Files\GitHub CLI' -livePaths $live | Should -Be $true
    }
}

Describe 'Split-NameToken' {
    It '按非字母数字拆分并丢弃通用词' {
        Split-NameToken 'wetype_renderer' | Should -Be @('wetype')
    }

    It '复合词整体保留' {
        Split-NameToken '@genieworkbuddy-desktop-updater' | Should -Be @('genieworkbuddy')
    }

    It '短词元被丢弃' {
        Split-NameToken 'gh-cli' | Should -Be @()
    }
}

Describe 'Test-NameRelatedToLive' {
    It 'Qoder 进程 → qoder-updater 目录' {
        Test-NameRelatedToLive -dirName 'qoder-updater' -liveTokens @('qoder') | Should -Be $true
    }

    It '只做词元精确匹配：复合词不命中（宁可漏报不可误杀）' {
        Test-NameRelatedToLive -dirName '@genieworkbuddy-desktop-updater' -liveTokens @('workbuddy') | Should -Be $false
        Test-NameRelatedToLive -dirName 'fontconfig' -liveTokens @('config') | Should -Be $false
        Test-NameRelatedToLive -dirName 'dtprinter' -liveTokens @('printer') | Should -Be $false
        Test-NameRelatedToLive -dirName 'LarkShellSingleton' -liveTokens @('singleton') | Should -Be $false
    }

    It 'WeType 服务 → wetype_update 目录' {
        Test-NameRelatedToLive -dirName 'wetype_update' -liveTokens @('wetype','management') | Should -Be $true
    }

    It '无关软件不误伤' {
        Test-NameRelatedToLive -dirName 'mongodb' -liveTokens @('qoder','workbuddy') | Should -Be $false
    }

    It '空目录名返回 false' {
        Test-NameRelatedToLive -dirName '' -liveTokens @('qoder') | Should -Be $false
    }
}

Describe 'Get-LiveNameToken（含已安装索引）' {
    BeforeAll {
        $script:IndexPath = Join-Path $TestDrive 'installed-software-index.json'
        $index = @(
            [PSCustomObject]@{ name = 'Zyxwvu Studio 2.0'; publisher = 'Zyxwvu Labs'; install_location = $null; source = 'test' }
        )
        [System.IO.File]::WriteAllText($script:IndexPath, ($index | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    }

    It '索引中的软件名进入活体词元，可命中同名目录' {
        $tokens = @(Get-LiveNameToken -IndexPath $script:IndexPath)
        $tokens | Should -Contain 'zyxwvu'
        Test-NameRelatedToLive -dirName 'zyxwvu-updater' -liveTokens $tokens | Should -Be $true
    }

    It '索引缺失时回退到进程/服务，不抛错' {
        { Get-LiveNameToken -IndexPath (Join-Path $TestDrive 'missing.json') } | Should -Not -Throw
    }
}
