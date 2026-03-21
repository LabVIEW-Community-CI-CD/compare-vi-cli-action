#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'PrintToSingleFileHtml payload source bundle' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PayloadRoot = Join-Path $script:RepoRoot 'fixtures' 'headless-corpus' 'operation-payloads' 'PrintToSingleFileHtml'
    $script:ManifestPath = Join-Path $script:PayloadRoot 'payload-provenance.json'
    $script:LicensePath = Join-Path $script:PayloadRoot 'LICENSE'
    $script:ReadmePath = Join-Path $script:PayloadRoot 'README.md'
    $script:ProvenanceDocPath = Join-Path $script:RepoRoot 'docs' 'knowledgebase' 'PrintToSingleFileHtml-Provenance.md'
  }

  It 'declares a repo-owned BSD-3 source bundle for the PrintToSingleFileHtml payload' {
    $script:PayloadRoot | Should -Exist
    $script:ManifestPath | Should -Exist
    $script:LicensePath | Should -Exist
    $script:ReadmePath | Should -Exist

    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json -Depth 20
    $manifest.schema | Should -Be 'comparevi/operation-payload-source-bundle@v1'
    $manifest.name | Should -Be 'PrintToSingleFileHtml'
    $manifest.payloadMode | Should -Be 'additional-operation-directory'
    $manifest.sourceRepositorySlug | Should -Be 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    $manifest.sourceLicenseSpdx | Should -Be 'BSD-3-Clause'
    $manifest.ownership | Should -Be 'repo-owned'
    $manifest.implementationBasis | Should -Be 'LabVIEW Print:VI To HTML'
    @($manifest.intendedChangeKinds) | Should -Be @('added', 'deleted')
    @($manifest.expectedOperationFiles) | Should -Contain 'GetHelp.vi'
    @($manifest.expectedOperationFiles) | Should -Contain 'RunOperation.vi'
    @($manifest.checkedInOperationFiles) | Should -Be @()
    $manifest.executableState | Should -Be 'source-only'
    $manifest.authoringBootstrap.issue | Should -Be 1621
    $manifest.authoringBootstrap.sourceKind | Should -Be 'installed-cli-operation'
    $manifest.authoringBootstrap.preferredInstalledOperation | Should -Be 'CreateComparisonReport'
  }

  It 'records that promotion remains blocked until runnable payload files and public proof exist' {
    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json -Depth 20
    $manifest.currentState | Should -Be 'licensed-source-bundle'
    $manifest.promotionTarget | Should -Be 'accepted'
    $manifest.promotionBlocked | Should -BeTrue
    (($manifest.blockingReasons | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'Runnable LabVIEW operation files are not checked in yet'
    (($manifest.blockingReasons | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'No public workflow run has proven this repo-owned payload'

    $readme = Get-Content -LiteralPath $script:ReadmePath -Raw
    $readme | Should -Match 'not yet executable'
    $readme | Should -Match 'source-only'
    $readme | Should -Match 'not yet promotable'
    $readme | Should -Match 'official LabVIEW `Print:VI To HTML` capability'
    $readme | Should -Match 'installed-operation scaffold'

    $provenanceDoc = Get-Content -LiteralPath $script:ProvenanceDocPath -Raw
    $provenanceDoc | Should -Match 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml/'
    $provenanceDoc | Should -Match 'Public proof is still required'
    $provenanceDoc | Should -Match '#1619'
    $provenanceDoc | Should -Match '#1621'
  }
}
