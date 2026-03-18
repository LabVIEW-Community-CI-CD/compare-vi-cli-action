# CompareVI-TestPlane: host-neutral
# CompareVI-TestModes: attributes, front-panel, block-diagram
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'CompareVI history bundle certification' -Tag 'CompareVI' {
    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:CertificationScript = Join-Path $script:RepoRoot 'tools' 'Test-CompareVIHistoryBundleCertification.ps1'
        $script:BundlePublishScript = Join-Path $script:RepoRoot 'tools' 'Publish-CompareVIToolsArtifact.ps1'
    }

    It 'certifies the published multi-mode bundle without unspecified categories' {
        if (-not (Test-Path -LiteralPath $script:CertificationScript -PathType Leaf)) {
            Set-ItResult -Skipped -Because "Certification script not found: $script:CertificationScript"
            return
        }

        $targetPath = Join-Path $script:RepoRoot 'VI1.vi'
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            Set-ItResult -Skipped -Because "Target file not found: $targetPath"
            return
        }

        $resultsDir = Join-Path $TestDrive 'bundle-certification'
        $summaryPath = Join-Path $resultsDir 'bundle-certification.json'
        $bundleOutputRoot = Join-Path $TestDrive 'bundle-output'
        $bundleMetadataPath = Join-Path $bundleOutputRoot 'comparevi-tools-artifact.json'

        & pwsh -NoLogo -NoProfile -File $script:BundlePublishScript `
            -OutputRoot $bundleOutputRoot `
            -MetadataReportPath $bundleMetadataPath | Out-Null

        $LASTEXITCODE | Should -Be 0

        $bundleMetadata = Get-Content -LiteralPath $bundleMetadataPath -Raw | ConvertFrom-Json -Depth 12
        $bundleArchivePath = Join-Path $bundleOutputRoot $bundleMetadata.bundle.archiveName
        Test-Path -LiteralPath $bundleArchivePath -PathType Leaf | Should -BeTrue

        & pwsh -NoLogo -NoProfile -File $script:CertificationScript `
            -ResultsDir $resultsDir `
            -SummaryJsonPath $summaryPath `
            -BundleArchivePath $bundleArchivePath | Out-Null

        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath $summaryPath -PathType Leaf | Should -BeTrue

        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
        $summary.schema | Should -Be 'comparevi-history-bundle-certification@v1'
        $summary.execution.mode | Should -Be 'bundle'
        $summary.execution.bundleArchivePath | Should -Be $bundleArchivePath
        $summary.sourceBranchRef | Should -Be 'develop'
        $summary.execution.historyScriptSupportsSourceBranchRef | Should -BeTrue
        $summary.certification.passed | Should -BeTrue
        $summary.certification.noUnspecified | Should -BeTrue
        $summary.certification.warningHasUnspecified | Should -BeFalse
        $summary.certification.warningHasExplicitCategories | Should -BeTrue
        $summary.certification.historyFacadeSchemaMatches | Should -BeTrue
        $summary.certification.historyFacadeRequestedModesMatch | Should -BeTrue
        $summary.certification.historyFacadeExecutedModesMatch | Should -BeTrue
        $summary.certification.historyFacadeModeListMatch | Should -BeTrue
        $summary.certification.historyFacadeCoverageAligned | Should -BeTrue
        $summary.certification.historyScriptSupportsSourceBranchRef | Should -BeTrue
        $summary.certification.historyFacadeSourceBranchRefMatches | Should -BeTrue
        $summary.warningText | Should -Match 'LVCompare detected differences'
        $summary.warningText | Should -Not -Match 'unspecified'
        @($summary.certification.actualModes) | Should -Be @('attributes', 'front-panel', 'block-diagram')
        $summary.historyFacade.schema | Should -Be 'comparevi-tools/history-facade@v1'
        @($summary.historyFacade.requestedModes) | Should -Be @('attributes', 'front-panel', 'block-diagram')
        @($summary.historyFacade.executedModes) | Should -Be @('attributes', 'front-panel', 'block-diagram')
        $summary.historyFacade.sourceBranchRef | Should -Be 'develop'
        $summary.historyFacade.coverageClass | Should -Be 'catalog-aligned'
        Test-Path -LiteralPath $summary.outputs.historySummaryJson -PathType Leaf | Should -BeTrue

        $modeIndex = @{}
        foreach ($mode in @($summary.modes)) {
            $modeIndex[[string]$mode.slug] = $mode
        }

        $modeIndex.ContainsKey('attributes') | Should -BeTrue
        $modeIndex.ContainsKey('front-panel') | Should -BeTrue
        $modeIndex.ContainsKey('block-diagram') | Should -BeTrue

        @($modeIndex['attributes'].collapsedNoise.categoryCounts.PSObject.Properties.Name) | Should -Contain 'vi-attribute'
        @($modeIndex['front-panel'].categoryCounts.PSObject.Properties.Name) | Should -Contain 'Control Changes'
        @($modeIndex['block-diagram'].categoryCounts.PSObject.Properties.Name) | Should -Contain 'Block Diagram'
    }
}
