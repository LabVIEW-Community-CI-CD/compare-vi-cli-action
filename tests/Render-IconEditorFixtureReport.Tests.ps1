$ErrorActionPreference = 'Stop'

Describe 'Render-IconEditorFixtureReport.ps1' -Tag 'IconEditor','FixtureReport','Render','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name renderScript -Value (Join-Path $repoRoot 'tools/icon-editor/Render-IconEditorFixtureReport.ps1')

        Set-Variable -Scope Script -Name newSummary -Value {
            [ordered]@{
                schema        = 'icon-editor/fixture-report@v1'
                generatedAt   = (Get-Date).ToString('o')
                source        = [ordered]@{ fixturePath = 'C:\fixtures\icon-editor.vip' }
                fixture       = [ordered]@{
                    package     = @{ Version = '1.0.0.0' }
                    description = @{ License = 'MIT' }
                }
                systemPackage = [ordered]@{
                    package     = @{ Version = '1.0.0.0' }
                    description = @{ License = 'MIT' }
                }
                manifest = [ordered]@{
                    packageSmoke = [ordered]@{ status = 'ok'; vipCount = 1 }
                    simulation   = [ordered]@{ enabled = $true }
                    unitTestsRun = 12
                }
                artifacts = @(
                    [ordered]@{
                        name      = 'build-log.txt'
                        hash      = 'hash-build-log'
                        sizeBytes = 1024
                    }
                )
                customActions = @(
                    [ordered]@{
                        name      = 'VIP_Pre-Install Custom Action 2023.vi'
                        fixture   = [ordered]@{ hash = 'hash-action-fixture' }
                        repo      = [ordered]@{ hash = 'hash-action-fixture' }
                        hashMatch = $true
                    }
                )
                runnerDependencies = [ordered]@{
                    fixture   = [ordered]@{ hash = 'hash-runner'; name = 'runner_dependencies.vipc'; sizeBytes = 2048 }
                    repo      = [ordered]@{ hash = 'hash-runner'; name = 'runner_dependencies.vipc'; sizeBytes = 2048 }
                    hashMatch = $true
                }
                fixtureOnlyAssets = @(
                    [ordered]@{ category = 'test';     name = 'Tests\Alpha.vi';  sizeBytes = 12; hash = 'hash-alpha-new' },
                    [ordered]@{ category = 'test';     name = 'Tests\Beta.vi';   sizeBytes = 14; hash = 'hash-beta' },
                    [ordered]@{ category = 'resource'; name = 'Icons\Gamma.vi';  sizeBytes = 20; hash = 'hash-gamma' }
                )
                stakeholder = [ordered]@{
                    smokeStatus        = 'ok'
                    runnerDependencies = @{ matchesRepo = $true }
                    customActions      = @()
                    fixtureOnlyAssets  = @()
                    generatedAt        = (Get-Date).ToString('o')
                }
            }
        }

        Set-Variable -Scope Script -Name newBaseline -Value {
            param([array]$Entries)
            [ordered]@{
                schema      = 'icon-editor/fixture-manifest@v1'
                generatedAt = (Get-Date).ToString('o')
                entries     = $Entries
            }
        }

        Set-Variable -Scope Script -Name writeSummary -Value {
            param([string]$Path, [hashtable]$Summary)
            $Summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
        }

        Set-Variable -Scope Script -Name writeBaseline -Value {
            param([string]$Path, [array]$Entries)
            (& $script:newBaseline $Entries) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
        }

        Test-Path -LiteralPath $script:renderScript | Should -BeTrue
    }

    It 'emits baseline skip messaging when manifest env is missing' {
        $summary = & $script:newSummary
        $reportPath = Join-Path $TestDrive 'fixture-report-skip.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-output.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH

        try {
            Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            Test-Path -LiteralPath $outputPath -PathType Leaf | Should -BeTrue
            $content = Get-Content -LiteralPath $outputPath -Raw
            $content | Should -Match '- Baseline manifest not provided; skipping delta\.'
            $content | Should -Match 'build-log\.txt - \d+(\.\d+)? MB'
            $content | Should -Match '\| VIP_Pre-Install Custom Action 2023\.vi \|'
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'truncates fixture-only asset listings beyond five entries per category' {
        $summary = & $script:newSummary
        $summary.fixtureOnlyAssets = 0..6 | ForEach-Object {
            [ordered]@{
                category  = 'test'
                name      = ('Tests\Asset{0}.vi' -f $_)
                sizeBytes = 10 + $_
                hash      = ('hash-asset-{0}' -f $_)
            }
        }
        $reportPath = Join-Path $TestDrive 'fixture-report-truncate.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-truncate.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null

        $contentLines = Get-Content -LiteralPath $outputPath
        $contentLines | Should -Contain '- test (7 entries)'
        ($contentLines | Where-Object { $_ -like '*Asset0*' }) | Should -Not -BeNullOrEmpty
        ($contentLines | Where-Object { $_ -like '*Asset4*' }) | Should -Not -BeNullOrEmpty
        $contentLines | Should -Contain '  - ... 2 more'
    }

    It 'renders placeholders for missing custom-action hashes and mismatch status' {
        $summary = & $script:newSummary
        $summary.customActions = @(
            [ordered]@{
                name      = 'ActionMissingFixture'
                fixture   = $null
                repo      = [ordered]@{ hash = 'hash-repo' }
                hashMatch = $false
            },
            [ordered]@{
                name      = 'ActionMissingRepo'
                fixture   = [ordered]@{ hash = 'hash-fixture' }
                repo      = $null
                hashMatch = $true
            }
        )
        $reportPath = Join-Path $TestDrive 'fixture-report-customactions.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-customactions.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null

        $contentLines = Get-Content -LiteralPath $outputPath
        $contentLines | Should -Contain '| ActionMissingFixture | `_missing_` | `hash-repo` | mismatch |'
        $contentLines | Should -Contain '| ActionMissingRepo | `hash-fixture` | `_missing_` | match |'
    }

    It 'renders empty fixture-only asset section when no assets are present' {
        $summary = & $script:newSummary
        $summary.fixtureOnlyAssets = @()
        $reportPath = Join-Path $TestDrive 'fixture-report-noassets.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-noassets.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null

        $content = Get-Content -LiteralPath $outputPath -Raw
        $content | Should -Match '## Fixture-only assets'
        $content | Should -Match '- None detected\.'
    }

    It 'summarises baseline delta when manifest env is supplied' {
        $summary = & $script:newSummary
        $reportPath = Join-Path $TestDrive 'fixture-report-delta.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $baselinePath = Join-Path $TestDrive 'baseline-manifest.json'
        & $script:writeBaseline -Path $baselinePath -Entries @(
            [ordered]@{
                key       = 'test:tests\tests\alpha.vi'
                category  = 'test'
                path      = 'tests\tests\alpha.vi'
                sizeBytes = 10
                hash      = 'hash-alpha-old'
            },
            [ordered]@{
                key       = 'resource:resource\legacy.vi'
                category  = 'resource'
                path      = 'resource\legacy.vi'
                sizeBytes = 8
                hash      = 'hash-legacy'
            }
        )

        $outputPath = Join-Path $TestDrive 'render-delta.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH

        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselinePath

            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            Test-Path -LiteralPath $outputPath -PathType Leaf | Should -BeTrue
            $content = Get-Content -LiteralPath $outputPath -Raw
            $content | Should -Match '- Added: \d+, Removed: \d+, Changed: \d+'
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'lists manifest delta entries with bullet details' {
        $summary = & $script:newSummary
        $reportPath = Join-Path $TestDrive 'synthetic-report.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $baselinePath = Join-Path $TestDrive 'synthetic-baseline.json'
        & $script:writeBaseline -Path $baselinePath -Entries @(
            [ordered]@{
                key       = 'test:tests\tests\alpha.vi'
                category  = 'test'
                path      = 'tests\tests\alpha.vi'
                sizeBytes = 10
                hash      = 'hash-alpha-old'
            },
            [ordered]@{
                key       = 'resource:resource\legacy.vi'
                category  = 'resource'
                path      = 'resource\legacy.vi'
                sizeBytes = 8
                hash      = 'hash-legacy'
            }
        )

        $outputPath = Join-Path $TestDrive 'render-detailed.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH

        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselinePath

            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            $content = Get-Content -LiteralPath $outputPath -Raw
            $content | Should -Match '- Added: 2, Removed: 1, Changed: 1'
            $content | Should -Match '  - `test:tests\\tests\\beta.vi`'
            $content | Should -Match '  - `resource:tests\\icons\\gamma.vi`'
            $content | Should -Match '  - `test:tests\\tests\\alpha.vi`'
            $content | Should -Match '  - `resource:resource\\legacy.vi`'
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'writes markdown to stdout when OutputPath is omitted' {
        $summary = & $script:newSummary
        $reportPath = Join-Path $TestDrive 'fixture-report-stdout.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        $output = & pwsh -NoLogo -NoProfile -File $script:renderScript `
            -ReportPath $reportPath

        $lines = $output -split "`r?`n"
        $lines[0] | Should -Be '## Package layout highlights'
        $lines[-1] | Should -Be '- Unit tests executed: 12'
    }

    It 'renders headings when artifacts and custom actions are empty' {
        $summary = & $script:newSummary
        $summary.artifacts = @()
        $summary.customActions = @()
        $reportPath = Join-Path $TestDrive 'fixture-report-no-collections.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-no-collections.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null

        $contentLines = Get-Content -LiteralPath $outputPath
        $contentLines | Should -Contain '- Artifacts:'
        $contentLines | Should -Contain '- Custom actions: 0 entries (all match: True)'
    }

    It 'reflects runner dependency mismatches in stakeholder summary' {
        $summary = & $script:newSummary
        $summary.runnerDependencies.hashMatch = $false
        $summary.stakeholder.runnerDependencies.matchesRepo = $false
        $reportPath = Join-Path $TestDrive 'fixture-report-runner-mismatch.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-runner-mismatch.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null

        $contentLines = Get-Content -LiteralPath $outputPath
        $contentLines | Should -Contain '- Runner dependencies: mismatch'
        $contentLines | Should -Contain '- Runner dependencies hash match: mismatch'
    }

    It 'handles missing packageSmoke metadata without throwing' {
        $summary = & $script:newSummary
        $summary.manifest.Remove('packageSmoke')
        $reportPath = Join-Path $TestDrive 'fixture-report-missing-smoke.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-missing-smoke.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        { & $script:renderScript -ReportPath $reportPath -OutputPath $outputPath } | Should -Throw
    }

    It 'computes delta when baseline entries is null' {
        $summary = & $script:newSummary
        $summary.fixtureOnlyAssets = @(
            [ordered]@{ category = 'test'; name = 'Tests\Alpha.vi'; sizeBytes = 12; hash = 'hash-alpha-new' }
        )
        $reportPath = Join-Path $TestDrive 'fixture-report-null-entries.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $baselinePath = Join-Path $TestDrive 'baseline-null-entries.json'
        @{
            schema  = 'icon-editor/fixture-manifest@v1'
            entries = $null
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $baselinePath -Encoding utf8

        $outputPath = Join-Path $TestDrive 'render-null-entries.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH
        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselinePath
            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            $contentLines = Get-Content -LiteralPath $outputPath
            $contentLines | Should -Contain '- Added: 1, Removed: 0, Changed: 0'
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'computes delta when baseline entries omit optional fields' {
        $summary = & $script:newSummary
        $summary.fixtureOnlyAssets = @(
            [ordered]@{ category = 'test'; name = 'Tests\Alpha.vi'; sizeBytes = 12; hash = 'hash-alpha-new' }
        )
        $reportPath = Join-Path $TestDrive 'fixture-report-missing-fields.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $baselinePath = Join-Path $TestDrive 'baseline-missing-fields.json'
        & $script:writeBaseline -Path $baselinePath -Entries @(
            [ordered]@{
                key      = 'test:tests\alpha.vi'
                category = 'test'
                path     = 'tests\alpha.vi'
            }
        )

        $outputPath = Join-Path $TestDrive 'render-missing-fields.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH
        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselinePath
            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            $contentLines = Get-Content -LiteralPath $outputPath
            $contentLines | Should -Contain '- Added: 1, Removed: 1, Changed: 0'
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'truncates fixture-only assets independently per category' {
        $summary = & $script:newSummary
        $summary.fixtureOnlyAssets = @()
        foreach ($i in 0..5) {
            $summary.fixtureOnlyAssets += [ordered]@{
                category  = 'test'
                name      = ('Tests\TestAsset{0}.vi' -f $i)
                sizeBytes = 10
                hash      = ('hash-test-{0}' -f $i)
            }
        }
        foreach ($i in 0..5) {
            $summary.fixtureOnlyAssets += [ordered]@{
                category  = 'resource'
                name      = ('Resource\ResourceAsset{0}.vi' -f $i)
                sizeBytes = 10
                hash      = ('hash-resource-{0}' -f $i)
            }
        }

        $reportPath = Join-Path $TestDrive 'fixture-report-multi-category.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-multi-category.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null

        $contentLines = Get-Content -LiteralPath $outputPath
        $contentLines | Where-Object { $_ -eq '- test (6 entries)' } | Should -Not -BeNullOrEmpty
        $contentLines | Where-Object { $_ -eq '- resource (6 entries)' } | Should -Not -BeNullOrEmpty
        ($contentLines | Where-Object { $_ -eq '  - ... 1 more' }).Count | Should -Be 2
    }

    It 'includes script assets with scripts prefix in manifest delta' {
        $summary = & $script:newSummary
        $summary.fixtureOnlyAssets = @(
            [ordered]@{
                category  = 'script'
                name      = 'Deploy.vi'
                sizeBytes = 20
                hash      = 'hash-script-new'
            }
        )
        $reportPath = Join-Path $TestDrive 'fixture-report-script.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $baselinePath = Join-Path $TestDrive 'baseline-script.json'
        & $script:writeBaseline -Path $baselinePath -Entries @()

        $outputPath = Join-Path $TestDrive 'render-script.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH
        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselinePath
            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            $contentLines = Get-Content -LiteralPath $outputPath
            ($contentLines | Where-Object { $_ -match 'script:scripts\\deploy.vi' }) | Should -Not -BeNullOrEmpty
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'formats artifacts with zero size and missing hash' {
        $summary = & $script:newSummary
        $summary.artifacts = @(
            [ordered]@{
                name      = 'empty-log.txt'
                sizeBytes = 0
                hash      = $null
            }
        )
        $reportPath = Join-Path $TestDrive 'fixture-report-artifact-zero.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-artifact-zero.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null

        $contentLines = Get-Content -LiteralPath $outputPath
        ($contentLines | Where-Object { $_ -match 'empty-log.txt - 0 MB' }) | Should -Not -BeNullOrEmpty
    }

    It 'lists changed entries in delta when hashes differ' {
        $summary = & $script:newSummary
        $summary.fixtureOnlyAssets = @(
            [ordered]@{ category = 'test'; name = 'Alpha.vi'; sizeBytes = 12; hash = 'hash-alpha-new' }
        )
        $reportPath = Join-Path $TestDrive 'fixture-report-changed.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $baselinePath = Join-Path $TestDrive 'baseline-changed.json'
        & $script:writeBaseline -Path $baselinePath -Entries @(
            [ordered]@{
                key       = 'test:tests\alpha.vi'
                category  = 'test'
                path      = 'tests\alpha.vi'
                sizeBytes = 12
                hash      = 'hash-alpha-old'
            }
        )

        $outputPath = Join-Path $TestDrive 'render-changed.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH
        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselinePath
            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            $contentLines = Get-Content -LiteralPath $outputPath
            $contentLines | Should -Contain '- Added: 0, Removed: 0, Changed: 1'
            ($contentLines | Where-Object { $_ -match 'Changed:' }) | Should -Not -BeNullOrEmpty
            ($contentLines | Where-Object { $_ -match 'test:tests\\alpha.vi' }) | Should -Not -BeNullOrEmpty
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'preserves custom action ordering' {
        $summary = & $script:newSummary
        $summary.customActions = @(
            [ordered]@{ name = 'Alpha'; fixture = [ordered]@{ hash = 'a' }; repo = [ordered]@{ hash = 'a' }; hashMatch = $true },
            [ordered]@{ name = 'Beta'; fixture = [ordered]@{ hash = 'b' }; repo = [ordered]@{ hash = 'b' }; hashMatch = $true },
            [ordered]@{ name = 'Gamma'; fixture = [ordered]@{ hash = 'c' }; repo = [ordered]@{ hash = 'c' }; hashMatch = $true }
        )
        $reportPath = Join-Path $TestDrive 'fixture-report-order.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'render-order.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null

        $contentLines = Get-Content -LiteralPath $outputPath
        $tableLines = $contentLines | Where-Object { $_ -match '^\| ' } | Select-Object -Skip 2 # skip header
        $tableLines[0] | Should -Match '\| Alpha \|'
        $tableLines[1] | Should -Match '\| Beta \|'
        $tableLines[2] | Should -Match '\| Gamma \|'
    }

    It 'rejects baseline manifest paths outside the repository' {
        $summary = & $script:newSummary
        $reportPath = Join-Path $TestDrive 'fixture-report-outside.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outsideBaseline = Join-Path ([System.IO.Path]::GetTempPath()) 'external-baseline.json'
        Set-Content -LiteralPath $outsideBaseline -Encoding utf8 -Value (@{
            schema  = 'icon-editor/fixture-manifest@v1'
            entries = @()
        } | ConvertTo-Json -Depth 4)

        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH
        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = '..\..\..\..\..\..\..\..\..\..\' + (Split-Path $outsideBaseline -Leaf)
            { & $script:renderScript -ReportPath $reportPath -FixturePath $reportPath } | Should -Throw
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $outsideBaseline -Force -ErrorAction SilentlyContinue
        }
    }

    It 'invokes Describe helper when ReportPath is omitted' {
        $summary = & $script:newSummary
        $summaryJson = $summary | ConvertTo-Json -Depth 8

        $tempRepo = Join-Path $TestDrive 'repo-fallback'
        $renderDest = Join-Path $tempRepo 'tools/icon-editor/Render-IconEditorFixtureReport.ps1'
        New-Item -ItemType Directory -Path (Split-Path $renderDest -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $script:renderScript -Destination $renderDest

        $describeScript = Join-Path $tempRepo 'tools/icon-editor/Describe-IconEditorFixture.ps1'
        $stub = @"
param(
  [string]`$FixturePath,
  [string]`$ResultsRoot,
  [string]`$OutputPath,
  [switch]`$KeepWork
)
`$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Split-Path `$OutputPath -Parent))) {
  New-Item -ItemType Directory -Path (Split-Path `$OutputPath -Parent) -Force | Out-Null
}
@'
$summaryJson
'@ | Set-Content -LiteralPath `$OutputPath -Encoding utf8
"@
        $stub | Set-Content -LiteralPath $describeScript -Encoding utf8

        $outputPath = Join-Path $tempRepo 'render-output.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        Push-Location $tempRepo
        try {
            & pwsh -NoLogo -NoProfile -File $renderDest `
                -FixturePath 'C:\temp\synthetic.vip' `
                -OutputPath $outputPath | Out-Null
        }
        finally {
            Pop-Location
        }

        $defaultReport = Join-Path $tempRepo 'tests/results/_agent/icon-editor/fixture-report.json'
        Test-Path -LiteralPath $defaultReport -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath $defaultReport -Raw | ConvertFrom-Json).schema | Should -Be 'icon-editor/fixture-report@v1'
    }

    It 'supports relative baseline manifest within repo fallback' {
        $summary = & $script:newSummary
        $summaryJson = $summary | ConvertTo-Json -Depth 8

        $tempRepo = Join-Path $TestDrive 'repo-fallback-baseline'
        $renderDest = Join-Path $tempRepo 'tools/icon-editor/Render-IconEditorFixtureReport.ps1'
        New-Item -ItemType Directory -Path (Split-Path $renderDest -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $script:renderScript -Destination $renderDest

        $describeScript = Join-Path $tempRepo 'tools/icon-editor/Describe-IconEditorFixture.ps1'
        $stub = @"
param([string]`$FixturePath,[string]`$ResultsRoot,[string]`$OutputPath,[switch]`$KeepWork)
`$ErrorActionPreference='Stop'
if (-not (Test-Path -LiteralPath (Split-Path `$OutputPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path `$OutputPath -Parent) -Force | Out-Null
}
@'
$summaryJson
'@ | Set-Content -LiteralPath `$OutputPath -Encoding utf8
"@
        $stub | Set-Content -LiteralPath $describeScript -Encoding utf8

        $baselineRelative = 'tests/baseline-manifest.json'
        $baselineAbsolute = Join-Path $tempRepo $baselineRelative
        New-Item -ItemType Directory -Path (Split-Path $baselineAbsolute -Parent) -Force | Out-Null
        @{
            schema  = 'icon-editor/fixture-manifest@v1'
            entries = @()
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $baselineAbsolute -Encoding utf8

        Push-Location $tempRepo
        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselineRelative

            & pwsh -NoLogo -NoProfile -File $renderDest `
                -FixturePath 'C:\temp\synthetic.vip' `
                -OutputPath (Join-Path $tempRepo 'render.md') | Out-Null
            Test-Path -LiteralPath $baselineAbsolute -PathType Leaf | Should -BeTrue
        }
        finally {
            Pop-Location
        }
    }

    It 'skips delta when relative baseline manifest is missing in repo fallback' {
        $summary = & $script:newSummary
        $summaryJson = $summary | ConvertTo-Json -Depth 8

        $tempRepo = Join-Path $TestDrive 'repo-fallback-baseline-new'
        $renderDest = Join-Path $tempRepo 'tools/icon-editor/Render-IconEditorFixtureReport.ps1'
        New-Item -ItemType Directory -Path (Split-Path $renderDest -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $script:renderScript -Destination $renderDest

        $describeScript = Join-Path $tempRepo 'tools/icon-editor/Describe-IconEditorFixture.ps1'
        $stub = @"
param([string]`$FixturePath,[string]`$ResultsRoot,[string]`$OutputPath,[switch]`$KeepWork)
`$ErrorActionPreference='Stop'
if (-not (Test-Path -LiteralPath (Split-Path `$OutputPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path `$OutputPath -Parent) -Force | Out-Null
}
@'
$summaryJson
'@ | Set-Content -LiteralPath `$OutputPath -Encoding utf8
"@
        $stub | Set-Content -LiteralPath $describeScript -Encoding utf8

        Push-Location $tempRepo
        try {
            $relativeBaseline = 'baselines/new/baseline.json'
            $baselineDir = Join-Path $tempRepo (Split-Path $relativeBaseline -Parent)
            Remove-Item -LiteralPath $baselineDir -Force -Recurse -ErrorAction SilentlyContinue
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $relativeBaseline

            & pwsh -NoLogo -NoProfile -File $renderDest `
                -FixturePath 'C:\temp\synthetic.vip' `
                -OutputPath (Join-Path $tempRepo 'render.md') | Out-Null

            $rendered = Get-Content -LiteralPath (Join-Path $tempRepo 'render.md')
            ($rendered | Where-Object { $_ -match 'Baseline manifest not provided; skipping delta.' }) | Should -Not -BeNullOrEmpty
        }
        finally {
            Pop-Location
        }
    }

    It 'updates ICON_EDITOR_PACKAGE.md when -UpdateDoc is specified' {
        $summary = & $script:newSummary
        $tempRepo = Join-Path $TestDrive 'repo-doc'
        $renderDest = Join-Path $tempRepo 'tools/icon-editor/Render-IconEditorFixtureReport.ps1'
        New-Item -ItemType Directory -Path (Split-Path $renderDest -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $script:renderScript -Destination $renderDest

        $reportPath = Join-Path $tempRepo 'tests/results/_agent/icon-editor/fixture-report.json'
        New-Item -ItemType Directory -Path (Split-Path $reportPath -Parent) -Force | Out-Null
        & $script:writeSummary -Path $reportPath -Summary $summary

        $docPath = Join-Path $tempRepo 'docs/ICON_EDITOR_PACKAGE.md'
        New-Item -ItemType Directory -Path (Split-Path $docPath -Parent) -Force | Out-Null
        @"
Intro text
<!-- icon-editor-report:start -->
placeholder
<!-- icon-editor-report:end -->
Closing text
"@ | Set-Content -LiteralPath $docPath -Encoding utf8

        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
        $outputPath = Join-Path $tempRepo 'render-output.md'

        Push-Location $tempRepo
        try {
            & pwsh -NoLogo -NoProfile -File $renderDest `
                -ReportPath $reportPath `
                -OutputPath $outputPath `
                -UpdateDoc | Out-Null
        }
        finally {
            Pop-Location
        }

        $updated = Get-Content -LiteralPath $docPath -Raw
        $updated | Should -Match '## Package layout highlights'
        ($updated -split '<!-- icon-editor-report:start -->').Count | Should -Be 2
        ($updated -split '<!-- icon-editor-report:end -->').Count | Should -Be 2

        $preSecondRun = $updated

        Push-Location $tempRepo
        try {
            & pwsh -NoLogo -NoProfile -File $renderDest `
                -ReportPath $reportPath `
                -OutputPath $outputPath `
                -UpdateDoc | Out-Null
        }
        finally {
            Pop-Location
        }

        $postSecondRun = Get-Content -LiteralPath $docPath -Raw
        $postSecondRun | Should -BeExactly $preSecondRun
    }

    It 'updates documentation when -UpdateDoc is used without OutputPath' {
        $summary = & $script:newSummary
        $tempRepo = Join-Path $TestDrive 'repo-doc-nooutput'
        $renderDest = Join-Path $tempRepo 'tools/icon-editor/Render-IconEditorFixtureReport.ps1'
        New-Item -ItemType Directory -Path (Split-Path $renderDest -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $script:renderScript -Destination $renderDest

        $reportPath = Join-Path $tempRepo 'tests/results/_agent/icon-editor/fixture-report.json'
        New-Item -ItemType Directory -Path (Split-Path $reportPath -Parent) -Force | Out-Null
        & $script:writeSummary -Path $reportPath -Summary $summary

        $docPath = Join-Path $tempRepo 'docs/ICON_EDITOR_PACKAGE.md'
        New-Item -ItemType Directory -Path (Split-Path $docPath -Parent) -Force | Out-Null
        @"
Intro
<!-- icon-editor-report:start -->
old
<!-- icon-editor-report:end -->
Outro
"@ | Set-Content -LiteralPath $docPath -Encoding utf8

        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        Push-Location $tempRepo
        try {
            $output = & pwsh -NoLogo -NoProfile -File $renderDest `
                -ReportPath $reportPath `
                -UpdateDoc
            $output | Should -Not -BeNullOrEmpty
        }
        finally {
            Pop-Location
        }

        $updated = Get-Content -LiteralPath $docPath -Raw
        $updated | Should -Match '## Package layout highlights'
    }

    It 'throws when OutputPath directory does not exist' {
        $summary = & $script:newSummary
        $reportPath = Join-Path $TestDrive 'fixture-report-output.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $outputPath = Join-Path $TestDrive 'nested/output/render.md'
        Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue

        { & $script:renderScript `
            -ReportPath $reportPath `
            -OutputPath $outputPath | Out-Null } | Should -Throw
    }

    It 'reports delta errors when baseline manifest cannot be parsed' {
        $summary = & $script:newSummary
        $reportPath = Join-Path $TestDrive 'invalid-baseline-report.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $baselinePath = Join-Path $TestDrive 'invalid-baseline.json'
        Set-Content -LiteralPath $baselinePath -Encoding utf8 -Value 'not-json'

        $outputPath = Join-Path $TestDrive 'render-invalid.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH

        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselinePath
            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            $content = Get-Content -LiteralPath $outputPath -Raw
            $content | Should -Match '- Failed to compute delta:'
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    It 'handles empty baseline manifest files without crashing' {
        $summary = & $script:newSummary
        $reportPath = Join-Path $TestDrive 'empty-baseline-report.json'
        & $script:writeSummary -Path $reportPath -Summary $summary

        $baselinePath = Join-Path $TestDrive 'empty-baseline.json'
        New-Item -ItemType File -Path $baselinePath -Force | Out-Null

        $outputPath = Join-Path $TestDrive 'render-empty.md'
        $originalBaseline = $env:ICON_EDITOR_BASELINE_MANIFEST_PATH

        try {
            $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $baselinePath
            & $script:renderScript `
                -ReportPath $reportPath `
                -OutputPath $outputPath | Out-Null

            $content = Get-Content -LiteralPath $outputPath -Raw
            $content | Should -Match '- Failed to compute delta:'
        }
        finally {
            if ($null -ne $originalBaseline) {
                $env:ICON_EDITOR_BASELINE_MANIFEST_PATH = $originalBaseline
            } else {
                Remove-Item Env:ICON_EDITOR_BASELINE_MANIFEST_PATH -ErrorAction SilentlyContinue
            }
        }
    }
}
