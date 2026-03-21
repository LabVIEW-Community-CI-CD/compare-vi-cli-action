#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-HeadlessSampleVICorpusPrintProof.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ProofScript = Join-Path $script:RepoRoot 'tools' 'Invoke-HeadlessSampleVICorpusPrintProof.ps1'
    if (-not (Test-Path -LiteralPath $script:ProofScript -PathType Leaf)) {
      throw "Invoke-HeadlessSampleVICorpusPrintProof.ps1 not found at $script:ProofScript"
    }
  }

  It 'emits a blocked receipt when the payload bundle is still source-only' {
    $catalogPath = Join-Path $TestDrive 'catalog.json'
    @'
{
  "$schema": "../../docs/schemas/headless-sample-vi-corpus-targets-v1.schema.json",
  "schema": "vi-headless/sample-targets@v1",
  "generatedAt": "2026-03-21T00:00:00Z",
  "description": "Synthetic catalog.",
  "storagePolicy": {
    "checkedInCatalogPath": "fixtures/headless-corpus/sample-vi-corpus.targets.json",
    "generatedRoot": "tests/results/_agent/headless-sample-corpus",
    "rawArtifactsInGit": false
  },
  "admissionPolicy": {
    "acceptedTargetsRequirePublicGithubEvidence": true,
    "acceptedTargetsRequireLicense": true,
    "acceptedTargetsRequirePinnedCommit": true,
    "acceptedTargetsRequirePromotableOperationPayload": true,
    "provisionalTargetsAllowed": true
  },
  "targets": [
    {
      "id": "print-target",
      "label": "Synthetic print target",
      "admission": { "state": "provisional", "reasons": ["Synthetic"] },
      "source": {
        "repoSlug": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
        "repoUrl": "https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo",
        "licenseSpdx": "MIT",
        "targetPath": "Tooling/comparevi-history-canary/CanaryProbe.vi",
        "changeKind": "added",
        "pinnedCommit": "91516373bf6c95e1d3cee2ee97452bc9d08f4ed7"
      },
      "renderStrategy": {
        "certificationSurface": "print-single-file",
        "operation": "PrintToSingleFileHtml",
        "planeApplicability": ["linux-proof"],
        "evidenceClass": "change-kind-print"
      },
      "operationPayload": {
        "mode": "additional-operation-directory",
        "provenanceState": "research-only",
        "sourceRepositorySlug": "LabVIEW-Community-CI-CD/compare-vi-cli-action",
        "sourceRepositoryUrl": "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action",
        "sourceLicenseSpdx": "BSD-3-Clause",
        "notes": ["Synthetic payload."]
      },
      "publicEvidence": []
    }
  ]
}
'@ | Set-Content -LiteralPath $catalogPath -Encoding utf8

    $inspectionStub = Join-Path $TestDrive 'Stub-Inspect.ps1'
    @'
param(
  [string]$BundlePath,
  [string]$ReportPath,
  [string]$MarkdownPath,
  [switch]$SkipSchemaValidation
)
$report = [ordered]@{
  schema = 'comparevi/operation-payload-source-bundle-inspection@v1'
  status = 'succeeded'
  bundlePath = $BundlePath
  declaredExecutableState = 'source-only'
  observedExecutableState = 'source-only'
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding utf8
'# Inspection summary' | Set-Content -LiteralPath $MarkdownPath -Encoding utf8
'@ | Set-Content -LiteralPath $inspectionStub -Encoding utf8

    $resultsRoot = Join-Path $TestDrive 'results'
    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -CatalogPath $catalogPath `
      -TargetId 'print-target' `
      -PayloadBundlePath 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml' `
      -ResultsRoot $resultsRoot `
      -InspectionScriptPath $inspectionStub `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $reportPath = Join-Path $resultsRoot 'print-proof-print-target.json'
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    $report.schema | Should -Be 'vi-headless/sample-print-proof@v1'
    $report.finalStatus | Should -Be 'blocked'
    $report.blockingReason | Should -Be 'payload-source-only'
    $report.executionAttempted | Should -BeFalse
    $report.payloadObservedExecutableState | Should -Be 'source-only'
  }

  It 'emits a ready receipt when the payload bundle is no longer source-only' {
    $catalogPath = Join-Path $TestDrive 'catalog-ready.json'
    @'
{
  "$schema": "../../docs/schemas/headless-sample-vi-corpus-targets-v1.schema.json",
  "schema": "vi-headless/sample-targets@v1",
  "generatedAt": "2026-03-21T00:00:00Z",
  "description": "Synthetic catalog.",
  "storagePolicy": {
    "checkedInCatalogPath": "fixtures/headless-corpus/sample-vi-corpus.targets.json",
    "generatedRoot": "tests/results/_agent/headless-sample-corpus",
    "rawArtifactsInGit": false
  },
  "admissionPolicy": {
    "acceptedTargetsRequirePublicGithubEvidence": true,
    "acceptedTargetsRequireLicense": true,
    "acceptedTargetsRequirePinnedCommit": true,
    "acceptedTargetsRequirePromotableOperationPayload": true,
    "provisionalTargetsAllowed": true
  },
  "targets": [
    {
      "id": "print-target",
      "label": "Synthetic print target",
      "admission": { "state": "provisional", "reasons": ["Synthetic"] },
      "source": {
        "repoSlug": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
        "repoUrl": "https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo",
        "licenseSpdx": "MIT",
        "targetPath": "Tooling/comparevi-history-canary/CanaryProbe.vi",
        "changeKind": "deleted",
        "pinnedCommit": "91516373bf6c95e1d3cee2ee97452bc9d08f4ed7"
      },
      "renderStrategy": {
        "certificationSurface": "print-single-file",
        "operation": "PrintToSingleFileHtml",
        "planeApplicability": ["linux-proof"],
        "evidenceClass": "change-kind-print"
      },
      "operationPayload": {
        "mode": "additional-operation-directory",
        "provenanceState": "research-only",
        "sourceRepositorySlug": "LabVIEW-Community-CI-CD/compare-vi-cli-action",
        "sourceRepositoryUrl": "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action",
        "sourceLicenseSpdx": "BSD-3-Clause",
        "notes": ["Synthetic payload."]
      },
      "publicEvidence": []
    }
  ]
}
'@ | Set-Content -LiteralPath $catalogPath -Encoding utf8

    $inspectionStub = Join-Path $TestDrive 'Stub-InspectReady.ps1'
    @'
param(
  [string]$BundlePath,
  [string]$ReportPath,
  [string]$MarkdownPath,
  [switch]$SkipSchemaValidation
)
$report = [ordered]@{
  schema = 'comparevi/operation-payload-source-bundle-inspection@v1'
  status = 'succeeded'
  bundlePath = $BundlePath
  declaredExecutableState = 'runnable'
  observedExecutableState = 'runnable'
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding utf8
'# Inspection summary' | Set-Content -LiteralPath $MarkdownPath -Encoding utf8
'@ | Set-Content -LiteralPath $inspectionStub -Encoding utf8

    $resultsRoot = Join-Path $TestDrive 'results-ready'
    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -CatalogPath $catalogPath `
      -TargetId 'print-target' `
      -PayloadBundlePath 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml' `
      -ResultsRoot $resultsRoot `
      -InspectionScriptPath $inspectionStub `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $reportPath = Join-Path $resultsRoot 'print-proof-print-target.json'
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    $report.finalStatus | Should -Be 'ready'
    $report.blockingReason | Should -BeNullOrEmpty
    $report.executionAttempted | Should -BeFalse
    $report.payloadObservedExecutableState | Should -Be 'runnable'
  }
}
