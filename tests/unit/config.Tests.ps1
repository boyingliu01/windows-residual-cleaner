# Pester Configuration Validation Tests (Pester 3.x Compatible)

Describe 'whitelist.json' {
    BeforeAll {
        $whitelistPath = "$PSScriptRoot\..\..\references\config\whitelist.json"
    }
    
    It 'File exists' {
        Test-Path $whitelistPath | Should -Be $true
    }
    
    It 'Is valid JSON' {
        $w = $null
        { $w = Get-Content $whitelistPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
    
    It 'Has registry_patterns array' {
        $w = Get-Content $whitelistPath -Raw | ConvertFrom-Json
        $w.registry_patterns | Should -Not -BeNullOrEmpty
        @($w.registry_patterns).Count | Should -BeGreaterThan 0
    }
    
    It 'Has path_patterns array' {
        $w = Get-Content $whitelistPath -Raw | ConvertFrom-Json
        $w.path_patterns | Should -Not -BeNullOrEmpty
        @($w.path_patterns).Count | Should -BeGreaterThan 0
    }
    
    It 'Has service_names array' {
        $w = Get-Content $whitelistPath -Raw | ConvertFrom-Json
        $w.service_names | Should -Not -BeNullOrEmpty
        @($w.service_names).Count | Should -BeGreaterThan 0
    }
    
    It 'Each registry pattern has reason and added_date fields' {
        $w = Get-Content $whitelistPath -Raw | ConvertFrom-Json
        foreach ($rp in $w.registry_patterns) {
            $rp.reason | Should -Not -BeNullOrEmpty
            $rp.added_date | Should -Not -BeNullOrEmpty
        }
    }
    
    It 'Covers expected vendor patterns' {
        $w = Get-Content $whitelistPath -Raw | ConvertFrom-Json
        $patterns = $w.registry_patterns | ForEach-Object { $_.pattern }
        $hasMs = ($patterns | Where-Object { $_ -match 'Microsoft' })
        $hasVC = ($patterns | Where-Object { $_ -match 'VCRedist' })
        $hasIntel = ($patterns | Where-Object { $_ -match 'Intel' })
        $hasNvidia = ($patterns | Where-Object { $_ -match 'NVIDIA' })
        $hasMs | Should -Not -BeNullOrEmpty
        $hasVC | Should -Not -BeNullOrEmpty
        $hasIntel | Should -Not -BeNullOrEmpty
        $hasNvidia | Should -Not -BeNullOrEmpty
    }
    
    It 'Covers critical service names' {
        $w = Get-Content $whitelistPath -Raw | ConvertFrom-Json
        ($w.service_names -contains 'Winmgmt') | Should -Be $true
        ($w.service_names -contains 'RpcSs') | Should -Be $true
        ($w.service_names -contains 'EventLog') | Should -Be $true
    }
}

Describe 'config.json' {
    BeforeAll {
        $configPath = "$PSScriptRoot\..\..\references\config\config.json"
    }
    
    It 'File exists' {
        Test-Path $configPath | Should -Be $true
    }
    
    It 'Is valid JSON' {
        { Get-Content $configPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
    
    It 'Has file_thresholds section' {
        $c = Get-Content $configPath -Raw | ConvertFrom-Json
        $c.file_thresholds | Should -Not -BeNullOrEmpty
    }
    
    It 'max_file_count is a positive integer' {
        $c = Get-Content $configPath -Raw | ConvertFrom-Json
        $c.file_thresholds.max_file_count | Should -BeGreaterThan 0
    }
    
    It 'max_size_mb is a positive number' {
        $c = Get-Content $configPath -Raw | ConvertFrom-Json
        $c.file_thresholds.max_size_mb | Should -BeGreaterThan 0
    }
    
    It 'excluded_files contains common placeholders' {
        $c = Get-Content $configPath -Raw | ConvertFrom-Json
        ($c.file_thresholds.excluded_files -contains '.gitkeep') | Should -Be $true
        ($c.file_thresholds.excluded_files -contains 'desktop.ini') | Should -Be $true
    }
    
    It 'Has target_directories array with enough entries' {
        $c = Get-Content $configPath -Raw | ConvertFrom-Json
        $c.target_directories | Should -Not -BeNullOrEmpty
        @($c.target_directories).Count | Should -BeGreaterThan 2
    }
}

Describe 'SKILL.md' {
    BeforeAll {
        $skillPath = "$PSScriptRoot\..\..\SKILL.md"
    }
    
    It 'File exists' {
        Test-Path $skillPath | Should -Be $true
    }
    
    It 'Has YAML frontmatter with name' {
        $content = Get-Content $skillPath -Raw
        $content | Should -Match 'name:\s+windows-residual-cleaner'
    }
    
    It 'Has YAML frontmatter with description' {
        $content = Get-Content $skillPath -Raw
        # description 值可能是引号包裹或裸文本，匹配 'description:' 后跟 Scan and clean
        $content | Should -Match 'description:\s*"?Scan and clean'
    }
    
    It 'Lists key workflow steps' {
        $content = Get-Content $skillPath -Raw
        $content | Should -Match 'System restore'
        $content | Should -Match 'Build installed'
        $content | Should -Match 'Scan uninstalled'
        $content | Should -Match 'Scan filesystem'
        $content | Should -Match 'Generate.*report'
    }
    
    It 'Documents the Phase-based agent workflow' {
        $content = Get-Content $skillPath -Raw
        # SKILL.md 使用 Phase 1-6 工作流（而非旧版 Option A/B/C/D）
        $content | Should -Match 'Phase 1: Auto-Scan'
        $content | Should -Match 'Phase 2: Present Itemized List'
        $content | Should -Match 'Phase 3: Parse User Selection'
        $content | Should -Match 'Phase 4: Export Confirmed IDs'
        $content | Should -Match 'Phase 5: DryRun Preview'
        $content | Should -Match 'Phase 6: Execute Cleanup'
    }
    
    It 'Documents the confirmation safety gates' {
        $content = Get-Content $skillPath -Raw
        $content | Should -Match 'Gate 1'
        $content | Should -Match 'Gate 2'
        $content | Should -Match 'Gate 3'
    }
    
    It 'Mentions DryRun mode' {
        $content = Get-Content $skillPath -Raw
        $content | Should -Match 'DryRun'
    }
}
