#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'New-PrintToSingleFileHtmlAuthoringWorkspace.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:WrapperPath = Join-Path $script:RepoRoot 'tools' 'New-PrintToSingleFileHtmlAuthoringWorkspace.ps1'
    if (-not (Test-Path -LiteralPath $script:WrapperPath -PathType Leaf)) {
      throw "New-PrintToSingleFileHtmlAuthoringWorkspace.ps1 not found at $script:WrapperPath"
    }
  }

  It 'writes a dedicated authoring receipt on top of the generic scaffold helper' {
    $bundleRoot = Join-Path $TestDrive 'payload-bundle'
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
    @'
{
  "schema": "comparevi/operation-payload-source-bundle@v1",
  "name": "PrintToSingleFileHtml",
  "payloadMode": "additional-operation-directory",
  "sourceRepositorySlug": "LabVIEW-Community-CI-CD/compare-vi-cli-action",
  "sourceRepositoryUrl": "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action",
  "sourceLicenseSpdx": "BSD-3-Clause",
  "ownership": "repo-owned",
  "implementationBasis": "LabVIEW Print:VI To HTML",
  "intendedCertificationSurface": "print-single-file",
  "intendedChangeKinds": ["added", "deleted"],
  "expectedOperationFiles": ["GetHelp.vi", "RunOperation.vi"],
  "checkedInOperationFiles": [],
  "executableState": "source-only",
  "currentState": "licensed-source-bundle",
  "promotionTarget": "accepted",
  "promotionBlocked": true,
  "blockingReasons": [
    "Runnable LabVIEW operation files are not checked in yet.",
    "No public workflow run has proven this repo-owned payload on an added or deleted VI."
  ],
  "authoringBootstrap": {
    "issue": 1621,
    "sourceKind": "installed-cli-operation",
    "preferredInstalledOperation": "CreateComparisonReport"
  },
  "notes": [
    "Synthetic bundle for tests."
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $bundleRoot 'payload-provenance.json') -Encoding utf8

    $stubPath = Join-Path $TestDrive 'Stub-Scaffold.ps1'
    @'
param(
  [string]$SourceKind,
  [string]$SourceExamplePath,
  [string]$DestinationPath,
  [switch]$Force,
  [switch]$SkipSchemaValidation
)
$resolved = [System.IO.Path]::GetFullPath($DestinationPath)
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
  New-Item -ItemType Directory -Path $resolved -Force | Out-Null
}
$receipt = [ordered]@{
  schema = 'labview-cli-custom-operation-scaffold@v1'
  status = 'succeeded'
  sourceKind = $SourceKind
  sourceExampleName = 'CreateComparisonReport'
  sourceExamplePath = $SourceExamplePath
  destinationPath = $resolved
  receiptPath = (Join-Path $resolved 'custom-operation-scaffold.json')
  labviewPathHint = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
  copiedFileCount = 2
  copiedFiles = @('GetHelp.vi', 'RunOperation.vi')
}
$receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $receipt.receiptPath -Encoding utf8
'@ | Set-Content -LiteralPath $stubPath -Encoding utf8

    $resultsRoot = Join-Path $TestDrive 'results'
    $output = & pwsh -NoLogo -NoProfile -File $script:WrapperPath `
      -PayloadBundlePath $bundleRoot `
      -InstalledOperationPath 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\Operations\CreateComparisonReport' `
      -DestinationPath (Join-Path $resultsRoot 'authoring-workspace') `
      -ScaffoldScriptPath $stubPath `
      -ReceiptPath (Join-Path $resultsRoot 'authoring-receipt.json') `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $receipt = Get-Content -LiteralPath (Join-Path $resultsRoot 'authoring-receipt.json') -Raw | ConvertFrom-Json -Depth 20
    $receipt.schema | Should -Be 'comparevi/print-to-single-file-html-authoring-workspace@v1'
    $receipt.status | Should -Be 'succeeded'
    $receipt.payloadName | Should -Be 'PrintToSingleFileHtml'
    $receipt.declaredExecutableState | Should -Be 'source-only'
    $receipt.sourceKind | Should -Be 'installed-cli-operation'
    $receipt.preferredInstalledOperation | Should -Be 'CreateComparisonReport'
    $receipt.installedOperationPath | Should -Be 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\Operations\CreateComparisonReport'
    $receipt.scaffoldReceiptPath | Should -Match 'custom-operation-scaffold\.json$'
    (($receipt.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'Do not commit installed NI operation files verbatim'
  }
}
