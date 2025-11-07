$ErrorActionPreference = 'Stop'

Describe 'Describe-IconEditorFixture.ps1' -Tag 'IconEditor','Describe','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name describeScript -Value (Join-Path $repoRoot 'tools/icon-editor/Describe-IconEditorFixture.ps1')
        Test-Path -LiteralPath $script:describeScript | Should -BeTrue
    }

    It 'produces a fixture summary for a synthetic VIP' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        $testRoot = (Get-PSDrive -Name TestDrive).Root
        $fixtureVip = Join-Path $testRoot 'synthetic-icon-editor.vip'
        $root = Join-Path $testRoot ("vip-root-{0}" -f ([guid]::NewGuid().ToString('n')))
        $systemRoot = Join-Path $testRoot ("vip-system-{0}" -f ([guid]::NewGuid().ToString('n')))

        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Packages') -Force | Out-Null
        New-Item -ItemType Directory -Path $systemRoot -Force | Out-Null

        @"
[Package]
Name="ni_icon_editor"
Version="1.0.0.0"
[Description]
License="MIT"
"@ | Set-Content -LiteralPath (Join-Path $root 'spec') -Encoding utf8

        @"
[Package]
Name="ni_icon_editor_system"
Version="1.0.0.0"
[Description]
License="MIT"
"@ | Set-Content -LiteralPath (Join-Path $systemRoot 'spec') -Encoding utf8

        $deploymentRoot = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Tooling\deployment'
        $resourceRoot = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\resource'
        $testRoot = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Test'
        $installPlugins = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\install\plugins'
        foreach ($path in @($deploymentRoot, $resourceRoot, $testRoot, $installPlugins)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }

        Set-Content -LiteralPath (Join-Path $deploymentRoot 'runner_dependencies.vipc') -Value 'stub vipc' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $deploymentRoot 'VIP_Pre-Install Custom Action 2023.vi') -Value 'pre-install' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $resourceRoot 'StubResource.vi') -Value 'resource' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $testRoot 'StubTest.vi') -Value 'test' -Encoding utf8

        $pluginRoot = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\resource\plugins'
        New-Item -ItemType Directory -Path $pluginRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pluginRoot 'lv_icon_x64.lvlibp') -Value 'lvlibp64' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $installPlugins 'lv_icon_x86.lvlibp') -Value 'lvlibp86' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $installPlugins 'lv_icon_x64.lvlibp') -Value 'lvlibp64' -Encoding utf8

        $systemVip = Join-Path $root 'Packages\ni_icon_editor_system-1.0.0.0.vip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($systemRoot, $systemVip)
        [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $fixtureVip)
        $fixtureFullPath = (Resolve-Path -LiteralPath $fixtureVip).ProviderPath

        Remove-Item -LiteralPath $root -Recurse -Force
        Remove-Item -LiteralPath $systemRoot -Recurse -Force

        $resultsRoot = Join-Path $TestDrive 'describe-results'
        $summary = & $script:describeScript `
            -FixturePath $fixtureFullPath `
            -ResultsRoot $resultsRoot `
            -KeepWork

        $summary | Should -Not -BeNullOrEmpty
        $summary.schema | Should -Be 'icon-editor/fixture-report@v1'
        ($summary.artifacts | Measure-Object).Count | Should -BeGreaterThan 0
        ($summary.fixtureOnlyAssets | Where-Object { $_.category -eq 'resource' } | Measure-Object).Count | Should -BeGreaterThan 0
        $summary.runnerDependencies.fixture | Should -Not -BeNullOrEmpty
        $summary.stakeholder.artifacts | Should -Not -BeNullOrEmpty
    }
}
