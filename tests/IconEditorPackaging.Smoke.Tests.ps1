$ErrorActionPreference = 'Stop'

Describe 'Icon Editor packaging smoke guards' -Tag 'IconEditor','Packaging','Smoke' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        function New-TestIconEditorVip {
            param(
                [string]$Path,
                [string]$Version = '1.0.0.0'
            )

            $root = Join-Path $TestDrive ("vip-root-{0}" -f ([guid]::NewGuid().ToString('n')))
            $systemRoot = Join-Path $TestDrive ("vip-system-{0}" -f ([guid]::NewGuid().ToString('n')))

            New-Item -ItemType Directory -Path $root -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'Packages') -Force | Out-Null
            New-Item -ItemType Directory -Path $systemRoot -Force | Out-Null

            @"
[Package]
Name="ni_icon_editor"
Version="$Version"
[Description]
License="MIT"
"@ | Set-Content -LiteralPath (Join-Path $root 'spec') -Encoding utf8

            New-Item -ItemType Directory -Path (Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Tooling\deployment') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\scripts') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Test') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\resource') -Force | Out-Null

            @"
[Package]
Name="ni_icon_editor_system"
Version="$Version"
[Description]
License="MIT"
"@ | Set-Content -LiteralPath (Join-Path $systemRoot 'spec') -Encoding utf8

            $deploymentRoot = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Tooling\deployment'
            foreach ($name in @(
                'VIP_Pre-Install Custom Action 2021.vi',
                'VIP_Post-Install Custom Action 2021.vi',
                'VIP_Pre-Uninstall Custom Action 2021.vi',
                'VIP_Post-Uninstall Custom Action 2021.vi'
            )) {
                Set-Content -LiteralPath (Join-Path $deploymentRoot $name) -Value ("stub {0}" -f $name) -Encoding utf8
            }
            Set-Content -LiteralPath (Join-Path $deploymentRoot 'runner_dependencies.vipc') -Value 'stub vipc' -Encoding utf8

            Set-Content -LiteralPath (Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\scripts\StubScript.vi') -Value 'script' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Test\StubTest.vi') -Value 'test' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\resource\StubResource.vi') -Value 'resource' -Encoding utf8

            $systemVip = Join-Path $root ('Packages\ni_icon_editor_system-{0}.vip' -f $Version)
            if (Test-Path -LiteralPath $systemVip) { Remove-Item -LiteralPath $systemVip -Force }
            [System.IO.Compression.ZipFile]::CreateFromDirectory($systemRoot, $systemVip)

            $manifestDir = Join-Path $root 'File Group 0\National Instruments\LabVIEW Icon Editor\Tooling\deployment'
            if (-not (Test-Path -LiteralPath $manifestDir)) {
                New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
            }

            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
            [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $Path)

            Remove-Item -LiteralPath $root -Recurse -Force
            Remove-Item -LiteralPath $systemRoot -Recurse -Force
        }

        function New-TestBaselineManifest {
            param(
                [string]$Path
            )
            $manifest = [ordered]@{
                schema  = 'icon-editor/fixture-manifest@v1'
                entries = @(
                    [ordered]@{
                        key       = 'resource:resource\StubResource.vi'
                        category  = 'resource'
                        path      = 'resource\StubResource.vi'
                        sizeBytes = 8
                        hash      = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                    },
                    [ordered]@{
                        key       = 'test:tests\StubTest.vi'
                        category  = 'test'
                        path      = 'tests\StubTest.vi'
                        sizeBytes = 4
                        hash      = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                    }
                )
            }
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
        }

        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name describeScript -Value (Join-Path $repoRoot 'tools/icon-editor/Describe-IconEditorFixture.ps1')
        Set-Variable -Scope Script -Name updateReportScript -Value (Join-Path $repoRoot 'tools/icon-editor/Update-IconEditorFixtureReport.ps1')
        Set-Variable -Scope Script -Name stageScript -Value (Join-Path $repoRoot 'tools/icon-editor/Stage-IconEditorSnapshot.ps1')
        Set-Variable -Scope Script -Name validateScript -Value (Join-Path $repoRoot 'tools/icon-editor/Invoke-ValidateLocal.ps1')
        Set-Variable -Scope Script -Name renderScript -Value (Join-Path $repoRoot 'tools/icon-editor/Render-IconEditorFixtureReport.ps1')
        Set-Variable -Scope Script -Name prepareScript -Value (Join-Path $repoRoot 'tools/icon-editor/Prepare-FixtureViDiffs.ps1')
        Set-Variable -Scope Script -Name simulateScript -Value (Join-Path $repoRoot 'tools/icon-editor/Simulate-IconEditorBuild.ps1')
        Set-Variable -Scope Script -Name enableDevModeScript -Value (Join-Path $repoRoot 'tools/icon-editor/Enable-DevMode.ps1')
        Set-Variable -Scope Script -Name disableDevModeScript -Value (Join-Path $repoRoot 'tools/icon-editor/Disable-DevMode.ps1')

        Test-Path -LiteralPath $script:describeScript | Should -BeTrue
        Test-Path -LiteralPath $script:updateReportScript | Should -BeTrue
        Test-Path -LiteralPath $script:stageScript | Should -BeTrue
        Test-Path -LiteralPath $script:validateScript | Should -BeTrue
        Test-Path -LiteralPath $script:renderScript | Should -BeTrue
        Test-Path -LiteralPath $script:prepareScript | Should -BeTrue
        Test-Path -LiteralPath $script:simulateScript | Should -BeTrue

        $fixtureVipPath = Join-Path $TestDrive 'synthetic-icon-editor.vip'
        $baselineVipPath = Join-Path $TestDrive 'synthetic-icon-editor-baseline.vip'
        $baselineManifestPath = Join-Path $TestDrive 'synthetic-baseline-manifest.json'

        New-TestIconEditorVip -Path $fixtureVipPath -Version '1.5.0.0'
        New-TestIconEditorVip -Path $baselineVipPath -Version '1.4.0.0'
        New-TestBaselineManifest -Path $baselineManifestPath

        $script:fixtureVipPath = (Resolve-Path -LiteralPath $fixtureVipPath).ProviderPath
        $script:baselineVipPath = (Resolve-Path -LiteralPath $baselineVipPath).ProviderPath
        $script:baselineManifestPath = (Resolve-Path -LiteralPath $baselineManifestPath).ProviderPath

        $env:ICON_EDITOR_FIXTURE_PATH = $script:fixtureVipPath
        $env:ICON_EDITOR_BASELINE_FIXTURE_PATH = $script:baselineVipPath
        $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $script:baselineManifestPath
    }

    It 'Enable-DevMode.ps1 forwards parameters to IconEditorDevMode' {
        $modulePath = Join-Path $script:repoRoot 'tools/icon-editor/IconEditorDevMode.psm1'
        $backupPath = Join-Path $TestDrive 'IconEditorDevMode.enable.bak'
        Copy-Item -LiteralPath $modulePath -Destination $backupPath -Force
        $Global:DevModeCallLog = @()

        try {
@"
function Enable-IconEditorDevelopmentMode {
    param(
        [string]`$RepoRoot,
        [string]`$IconEditorRoot,
        [int[]]`$Versions,
        [int[]]`$Bitness,
        [string]`$Operation
    )
    `$Global:DevModeCallLog += [pscustomobject]@{
        Command       = 'Enable'
        RepoRoot      = `$RepoRoot
        IconEditorRoot= `$IconEditorRoot
        Versions      = `$Versions
        Bitness       = `$Bitness
        Operation     = `$Operation
    }
    return [pscustomobject]@{
        Path      = 'state.json'
        UpdatedAt = '2025-01-01T00:00:00Z'
    }
}
function Disable-IconEditorDevelopmentMode {
    param(
        [string]`$RepoRoot,
        [string]`$IconEditorRoot,
        [int[]]`$Versions,
        [int[]]`$Bitness,
        [string]`$Operation
    )
    `$Global:DevModeCallLog += [pscustomobject]@{
        Command       = 'Disable'
        RepoRoot      = `$RepoRoot
        IconEditorRoot= `$IconEditorRoot
        Versions      = `$Versions
        Bitness       = `$Bitness
        Operation     = `$Operation
    }
    return [pscustomobject]@{
        Path      = 'state.json'
        UpdatedAt = '2025-01-01T01:00:00Z'
    }
}
"@ | Set-Content -LiteralPath $modulePath -Encoding utf8

            $result = & $script:enableDevModeScript `
                -RepoRoot 'C:\repo' `
                -IconEditorRoot 'C:\icon' `
                -Versions 2023,2026 `
                -Bitness 32,64 `
                -Operation 'BuildPackage'
        }
        finally {
            Copy-Item -LiteralPath $backupPath -Destination $modulePath -Force
            Remove-Item -LiteralPath $backupPath -Force
        }

        $result.Path | Should -Be 'state.json'
        $result.UpdatedAt | Should -Be '2025-01-01T00:00:00Z'
        $Global:DevModeCallLog.Count | Should -Be 1
        $captured = $Global:DevModeCallLog[0]
        $captured.Command | Should -Be 'Enable'
        $captured.RepoRoot | Should -Be 'C:\repo'
        $captured.IconEditorRoot | Should -Be 'C:\icon'
        ($captured.Versions | Sort-Object) | Should -Be @(2023,2026)
        ($captured.Bitness | Sort-Object) | Should -Be @(32,64)
        $captured.Operation | Should -Be 'BuildPackage'
        Remove-Variable -Name DevModeCallLog -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Disable-DevMode.ps1 forwards parameters to IconEditorDevMode' {
        $modulePath = Join-Path $script:repoRoot 'tools/icon-editor/IconEditorDevMode.psm1'
        $backupPath = Join-Path $TestDrive 'IconEditorDevMode.disable.bak'
        Copy-Item -LiteralPath $modulePath -Destination $backupPath -Force
        $Global:DevModeCallLog = @()

        try {
@"
function Enable-IconEditorDevelopmentMode {
    param(
        [string]`$RepoRoot,
        [string]`$IconEditorRoot,
        [int[]]`$Versions,
        [int[]]`$Bitness,
        [string]`$Operation
    )
    `$Global:DevModeCallLog += [pscustomobject]@{
        Command       = 'Enable'
        RepoRoot      = `$RepoRoot
        IconEditorRoot= `$IconEditorRoot
        Versions      = `$Versions
        Bitness       = `$Bitness
        Operation     = `$Operation
    }
    return [pscustomobject]@{
        Path      = 'state.json'
        UpdatedAt = '2025-01-01T00:00:00Z'
    }
}
function Disable-IconEditorDevelopmentMode {
    param(
        [string]`$RepoRoot,
        [string]`$IconEditorRoot,
        [int[]]`$Versions,
        [int[]]`$Bitness,
        [string]`$Operation
    )
    `$Global:DevModeCallLog += [pscustomobject]@{
        Command       = 'Disable'
        RepoRoot      = `$RepoRoot
        IconEditorRoot= `$IconEditorRoot
        Versions      = `$Versions
        Bitness       = `$Bitness
        Operation     = `$Operation
    }
    return [pscustomobject]@{
        Path      = 'state.json'
        UpdatedAt = '2025-01-01T01:00:00Z'
    }
}
"@ | Set-Content -LiteralPath $modulePath -Encoding utf8

            $result = & $script:disableDevModeScript `
                -RepoRoot 'C:\repo' `
                -IconEditorRoot 'C:\icon' `
                -Versions 2023 `
                -Bitness 64 `
                -Operation 'BuildPackage'
        }
        finally {
            Copy-Item -LiteralPath $backupPath -Destination $modulePath -Force
            Remove-Item -LiteralPath $backupPath -Force
        }

        $result.Path | Should -Be 'state.json'
        $result.UpdatedAt | Should -Be '2025-01-01T01:00:00Z'
        $Global:DevModeCallLog.Count | Should -Be 1
        $captured = $Global:DevModeCallLog[0]
        $captured.Command | Should -Be 'Disable'
        $captured.RepoRoot | Should -Be 'C:\repo'
        $captured.IconEditorRoot | Should -Be 'C:\icon'
        $captured.Versions | Should -Be @(2023)
        $captured.Bitness | Should -Be @(64)
        $captured.Operation | Should -Be 'BuildPackage'
        Remove-Variable -Name DevModeCallLog -Scope Global -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item Env:ICON_EDITOR_FIXTURE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:ICON_EDITOR_BASELINE_FIXTURE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
    }

    It 'Describe-IconEditorFixture.ps1 requires -FixturePath' {
        { & $script:describeScript } | Should -Throw '*FixturePath*'
    }

    It 'Update-IconEditorFixtureReport.ps1 requires -FixturePath' {
        { & $script:updateReportScript } | Should -Throw '*FixturePath*'
    }

    It 'Describe-IconEditorFixture.ps1 produces a summary for a synthetic VIP' {
        $summary = & $script:describeScript -FixturePath $script:fixtureVipPath
        $summary.schema | Should -Be 'icon-editor/fixture-report@v1'
        ($summary.artifacts | Measure-Object).Count | Should -BeGreaterThan 0
        ($summary.fixtureOnlyAssets | Measure-Object).Count | Should -BeGreaterThan 0
    }

    It 'Stage-IconEditorSnapshot.ps1 fails fast when FixturePath missing' {
        { & $script:stageScript `
            -SourcePath (Join-Path $script:repoRoot 'vendor/icon-editor') `
            -StageName 'smoke' `
            -SkipValidate `
            -SkipLVCompare `
            -DryRun } | Should -Throw '*FixturePath*'
    }

    It 'Stage-IconEditorSnapshot.ps1 honors baseline paths' {
        $workspace = Join-Path $TestDrive 'snapshot-workspace'
        $result = & $script:stageScript `
            -SourcePath (Join-Path $script:repoRoot 'vendor/icon-editor') `
            -StageName 'baseline-check' `
            -WorkspaceRoot $workspace `
            -FixturePath $script:fixtureVipPath `
            -BaselineFixture $script:baselineVipPath `
            -BaselineManifest $script:baselineManifestPath `
            -SkipValidate `
            -SkipLVCompare `
            -DryRun

        $result.stageExecuted | Should -BeTrue
        $result.fixturePath | Should -Be (Resolve-Path $script:fixtureVipPath).Path
        $result.baselineFixture | Should -Be (Resolve-Path $script:baselineVipPath).Path
        $result.baselineManifest | Should -Be (Resolve-Path $script:baselineManifestPath).Path
    }

    It 'Invoke-ValidateLocal.ps1 requires FixturePath' {
        { & $script:validateScript `
            -SkipBootstrap `
            -DryRun `
            -SkipLVCompare } | Should -Throw '*FixturePath*'
    }

    It 'Prepare-FixtureViDiffs.ps1 emits requests with a baseline manifest' {
        $resultsRoot = Join-Path $TestDrive 'report-root'
        $reportPath = Join-Path $resultsRoot 'fixture-report.json'
        & $script:updateReportScript `
            -FixturePath $script:fixtureVipPath `
            -ManifestPath (Join-Path $resultsRoot 'fixture-generated-manifest.json') `
            -ResultsRoot $resultsRoot `
            -NoSummary | Out-Null

        $outputDir = Join-Path $TestDrive 'vi-diff-output'
        & $script:prepareScript `
            -ReportPath $reportPath `
            -BaselineManifestPath $script:baselineManifestPath `
            -BaselineFixturePath $script:baselineVipPath `
            -OutputDir $outputDir | Out-Null

        $requestsPath = Join-Path $outputDir 'vi-diff-requests.json'
        Test-Path -LiteralPath $requestsPath | Should -BeTrue
        $requests = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json -Depth 6
        $requests.count | Should -BeGreaterThan 0
    }

    It 'Render-IconEditorFixtureReport.ps1 includes delta information when baseline manifest env var is set' {
        $resultsRoot = Join-Path $TestDrive 'render-root'
        $reportPath = Join-Path $resultsRoot 'fixture-report.json'
        & $script:updateReportScript `
            -FixturePath $script:fixtureVipPath `
            -ResultsRoot $resultsRoot `
            -NoSummary | Out-Null

        $markdownPath = Join-Path $resultsRoot 'fixture-report.md'
        $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $script:baselineManifestPath
        & $script:renderScript `
            -ReportPath $reportPath `
            -FixturePath $script:fixtureVipPath `
            -OutputPath $markdownPath | Out-Null

        $content = Get-Content -LiteralPath $markdownPath -Raw
        $content | Should -Match 'Fixture-only manifest delta'
        $content | Should -Match 'Added:'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
    }

    It 'Invoke-VipmCliBuild.ps1 calls rogue detection and close between VIPC targets' -Tag 'VipmSequence' {
        $repoRoot = Join-Path $TestDrive 'vipm-repo'
        $iconRoot = Join-Path $repoRoot 'vendor/icon-editor'
        $applyRoot = Join-Path $iconRoot '.github/actions/apply-vipc'
        $closeRoot = Join-Path $iconRoot '.github/actions/close-labview'

        New-Item -ItemType Directory -Path (Join-Path $repoRoot 'tools') -Force | Out-Null
        New-Item -ItemType Directory -Path $applyRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $closeRoot -Force | Out-Null

        $logPath = Join-Path $TestDrive 'vipm-sequence.log'
        $env:VIPM_TEST_LOG = $logPath

        @'
param([switch]$FailOnRogue)
Add-Content -LiteralPath $env:VIPM_TEST_LOG -Value 'detect'
'@ | Set-Content -LiteralPath (Join-Path $repoRoot 'tools/Detect-RogueLV.ps1') -Encoding utf8

        @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness
)
Add-Content -LiteralPath $env:VIPM_TEST_LOG -Value ('close-{0}-{1}' -f $MinimumSupportedLVVersion, $SupportedBitness)
'@ | Set-Content -LiteralPath (Join-Path $closeRoot 'Close_LabVIEW.ps1') -Encoding utf8

        @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$IconEditorRoot,
  [string]$VIP_LVVersion
)
Add-Content -LiteralPath $env:VIPM_TEST_LOG -Value ('apply-{0}-{1}-{2}' -f $SupportedBitness, $MinimumSupportedLVVersion, $VIP_LVVersion)
'@ | Set-Content -LiteralPath (Join-Path $applyRoot 'ApplyVIPC.ps1') -Encoding utf8

        try {
            & (Join-Path $script:repoRoot 'tools/icon-editor/Invoke-VipmCliBuild.ps1') `
                -RepoRoot $repoRoot `
                -IconEditorRoot $iconRoot `
                -SkipSync `
                -SkipBuild | Out-Null
        }
        finally {
            Remove-Item Env:VIPM_TEST_LOG -ErrorAction SilentlyContinue
        }

        Test-Path -LiteralPath $logPath -PathType Leaf | Should -BeTrue
        $log = Get-Content -LiteralPath $logPath

        $log[0] | Should -Be 'detect'
        $applyEntries = $log | Where-Object { $_ -like 'apply-*' }
        $applyEntries.Count | Should -Be 3
        $applyEntries | Should -Contain 'apply-32-2023-2023'
        $applyEntries | Should -Contain 'apply-64-2023-2023'
        $applyEntries | Should -Contain 'apply-64-2026-2026'

        foreach ($entry in $applyEntries) {
            $index = [Array]::IndexOf($log, $entry)
            $log[$index + 1] | Should -Match '^close-'
            $log[$index + 2] | Should -Be 'detect'
        }
    }

    It 'Simulate-IconEditorBuild.ps1 produces dry-run artifacts' {
        $resultsRoot = Join-Path $TestDrive 'simulate'
        $vipDiffDir = Join-Path $resultsRoot 'vip-diff'
        $requestsPath = Join-Path $vipDiffDir 'vi-diff-requests.json'
        $expectedVersion = [pscustomobject]@{
            major = 1
            minor = 5
            patch = 0
            build = 0
            commit = 'unit-test'
        }

        & $script:simulateScript `
            -FixturePath $script:fixtureVipPath `
            -ResultsRoot $resultsRoot `
            -VipDiffOutputDir $vipDiffDir `
            -VipDiffRequestsPath $requestsPath `
            -ExpectedVersion $expectedVersion `
            -SkipResourceOverlay | Out-Null

        Test-Path -LiteralPath (Join-Path $resultsRoot 'package-smoke-summary.json') | Should -BeTrue
        Test-Path -LiteralPath $requestsPath | Should -BeTrue
        $requestJson = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json -Depth 6
        $requestJson.count | Should -BeGreaterThan 0
    }
}
