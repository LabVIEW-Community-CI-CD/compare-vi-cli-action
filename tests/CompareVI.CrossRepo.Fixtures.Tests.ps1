Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Cross-repo history fixtures' -Tag 'CompareVI' {
  It 'tracks metadata buckets for labview-icon-editor Settings Init.vi' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $fixtureRoot = Join-Path $repoRoot 'fixtures' 'cross-repo' 'labview-icon-editor' 'settings-init'

    $manifestPath = Join-Path $fixtureRoot 'manifest.json'
    $manifestPath | Should -Exist

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.schema | Should -Be 'vi-compare/history-suite@v1'
    $manifest.targetPath | Should -Be 'resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi'
    @($manifest.requestedModes) | Should -Be @('default')
    @($manifest.executedModes) | Should -Be @('default')
    $manifest.stats.bucketCounts.metadata | Should -Be 2

    $schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'vi-compare-history-suite-v1.schema.json'
    $schemaValidation = & node (Join-Path $repoRoot 'tools' 'npm' 'run-script.mjs') 'schema:validate' '--' '--schema' $schemaPath '--data' $manifestPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($schemaValidation | ForEach-Object { "$_" }) -join [Environment]::NewLine)

    $defaultManifestPath = Join-Path $fixtureRoot 'default-manifest.json'
    $defaultManifestPath | Should -Exist
    $defaultManifest = Get-Content -LiteralPath $defaultManifestPath -Raw | ConvertFrom-Json
    $defaultManifest.stats.bucketCounts.metadata | Should -Be 2
    $defaultManifest.comparisons.Count | Should -Be 2

    $reportMdPath = Join-Path $fixtureRoot 'history-report.md'
    $reportMdPath | Should -Exist
    $reportContent = Get-Content -LiteralPath $reportMdPath -Raw
    $reportContent | Should -Match 'Bucket summary'
    $reportContent | Should -Match 'Metadata .*2'
  }
}
