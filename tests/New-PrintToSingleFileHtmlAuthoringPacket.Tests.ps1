#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'New-PrintToSingleFileHtmlAuthoringPacket.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PacketPath = Join-Path $script:RepoRoot 'tools' 'New-PrintToSingleFileHtmlAuthoringPacket.ps1'
    if (-not (Test-Path -LiteralPath $script:PacketPath -PathType Leaf)) {
      throw "New-PrintToSingleFileHtmlAuthoringPacket.ps1 not found at $script:PacketPath"
    }
  }

  It 'writes a native authoring packet on top of the dedicated workspace wrapper' {
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

    $wrapperStubPath = Join-Path $TestDrive 'Stub-AuthoringWorkspace.ps1'
    @'
param(
  [string]$PayloadBundlePath,
  [string]$DestinationPath,
  [string]$ReceiptPath,
  [switch]$Force,
  [switch]$SkipSchemaValidation
)
$resolved = [System.IO.Path]::GetFullPath($DestinationPath)
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
  New-Item -ItemType Directory -Path $resolved -Force | Out-Null
}
$receipt = [ordered]@{
  schema = 'comparevi/print-to-single-file-html-authoring-workspace@v1'
  status = 'succeeded'
  payloadBundlePath = $PayloadBundlePath
  payloadManifestPath = (Join-Path $PayloadBundlePath 'payload-provenance.json')
  payloadName = 'PrintToSingleFileHtml'
  declaredExecutableState = 'source-only'
  sourceKind = 'installed-cli-operation'
  preferredInstalledOperation = 'CreateComparisonReport'
  installedOperationPath = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\Operations\CreateComparisonReport'
  destinationPath = $resolved
  scaffoldReceiptPath = (Join-Path $resolved 'custom-operation-scaffold.json')
  labviewPathHint = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
}
$receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8
'@ | Set-Content -LiteralPath $wrapperStubPath -Encoding utf8

    $labviewPath = Join-Path $TestDrive 'LabVIEW.exe'
    $operationsProjectPath = Join-Path $TestDrive 'Operations.lvproj'
    $toolkitOperationsProjectPath = Join-Path $TestDrive 'Toolkit-Operations.lvproj'
    Set-Content -LiteralPath $labviewPath -Value 'stub' -Encoding utf8
    Set-Content -LiteralPath $operationsProjectPath -Value 'stub' -Encoding utf8
    Set-Content -LiteralPath $toolkitOperationsProjectPath -Value 'stub' -Encoding utf8

    $packetRoot = Join-Path $TestDrive 'packet'
    $receiptPath = Join-Path $packetRoot 'packet.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:PacketPath `
      -PayloadBundlePath $bundleRoot `
      -DestinationPath $packetRoot `
      -ReceiptPath $receiptPath `
      -AuthoringWorkspaceScriptPath $wrapperStubPath `
      -LabVIEWPath $labviewPath `
      -OperationsProjectPath $operationsProjectPath `
      -ToolkitOperationsProjectPath $toolkitOperationsProjectPath `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 20
    $receipt.schema | Should -Be 'comparevi/print-to-single-file-html-authoring-packet@v1'
    $receipt.status | Should -Be 'succeeded'
    $receipt.payloadName | Should -Be 'PrintToSingleFileHtml'
    $receipt.declaredExecutableState | Should -Be 'source-only'
    $receipt.launchScriptPath | Should -Match 'Open-PrintToSingleFileHtmlAuthoringWorkspace\.ps1$'
    $receipt.checklistPath | Should -Match 'AUTHORING_CHECKLIST\.md$'
    (($receipt.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'native LabVIEW authoring handoff'
    (($receipt.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match '#1617'
    (($receipt.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match '#1726'
    (($receipt.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match '#1467'

    $checklistPath = Join-Path $packetRoot 'AUTHORING_CHECKLIST.md'
    $launchScriptPath = Join-Path $packetRoot 'Open-PrintToSingleFileHtmlAuthoringWorkspace.ps1'
    $checklistPath | Should -Exist
    $launchScriptPath | Should -Exist
    (Get-Content -LiteralPath $checklistPath -Raw) | Should -Match 'Open Operations\.lvproj in LabVIEW 2026 x86'
    (Get-Content -LiteralPath $checklistPath -Raw) | Should -Match '#1617'
    (Get-Content -LiteralPath $checklistPath -Raw) | Should -Match '#1726'
    (Get-Content -LiteralPath $checklistPath -Raw) | Should -Match '#1467'
    (Get-Content -LiteralPath $checklistPath -Raw) | Should -Match 'Finalize-OperationPayloadSourceBundle\.ps1'
    (Get-Content -LiteralPath $launchScriptPath -Raw) | Should -Match 'Start-Process -FilePath \$labviewPath'
  }
}
