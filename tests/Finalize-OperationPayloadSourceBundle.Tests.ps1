#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Finalize-OperationPayloadSourceBundle.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:FinalizePath = Join-Path $script:RepoRoot 'tools' 'Finalize-OperationPayloadSourceBundle.ps1'
    if (-not (Test-Path -LiteralPath $script:FinalizePath -PathType Leaf)) {
      throw "Finalize-OperationPayloadSourceBundle.ps1 not found at $script:FinalizePath"
    }

    function Set-LabVIEWBinaryFixture {
      param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('LVIN', 'LVCC')][string]$Signature,
        [string]$Payload = ''
      )

      $directory = Split-Path -Parent $Path
      if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
      }

      $payloadBytes = if ([string]::IsNullOrWhiteSpace($Payload)) {
        [byte[]]@()
      } else {
        [System.Text.Encoding]::UTF8.GetBytes($Payload)
      }

      $minimumLength = 12 + $payloadBytes.Length
      $bytes = New-Object byte[] ([Math]::Max(16, $minimumLength))
      [System.Text.Encoding]::ASCII.GetBytes($Signature).CopyTo($bytes, 8)
      if ($payloadBytes.Length -gt 0) {
        [Array]::Copy($payloadBytes, 0, $bytes, 12, $payloadBytes.Length)
      }

      [System.IO.File]::WriteAllBytes($Path, $bytes)
    }
  }

  It 'updates the bundle manifest when runnable LabVIEW binary files are present' {
    $bundleRoot = Join-Path $TestDrive 'synthetic-bundle'
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
    Set-LabVIEWBinaryFixture -Path (Join-Path $bundleRoot 'GetHelp.vi') -Signature 'LVIN' -Payload 'help'
    Set-LabVIEWBinaryFixture -Path (Join-Path $bundleRoot 'RunOperation.vi') -Signature 'LVIN' -Payload 'run'
    @'
{
  "schema": "comparevi/operation-payload-source-bundle@v1",
  "name": "SyntheticPrintPayload",
  "payloadMode": "additional-operation-directory",
  "sourceRepositorySlug": "LabVIEW-Community-CI-CD/compare-vi-cli-action",
  "sourceRepositoryUrl": "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action",
  "sourceLicenseSpdx": "BSD-3-Clause",
  "ownership": "repo-owned",
  "implementationBasis": "Synthetic",
  "intendedCertificationSurface": "print-single-file",
  "intendedChangeKinds": ["added"],
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
  "notes": ["Synthetic bundle for tests."]
}
'@ | Set-Content -LiteralPath (Join-Path $bundleRoot 'payload-provenance.json') -Encoding utf8

    $receiptPath = Join-Path $TestDrive 'finalization.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:FinalizePath `
      -BundlePath $bundleRoot `
      -ReceiptPath $receiptPath `
      -InspectionReportPath (Join-Path $TestDrive 'inspection.json') `
      -InspectionMarkdownPath (Join-Path $TestDrive 'inspection.md') `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 20
    $receipt.status | Should -Be 'succeeded'
    $receipt.manifestUpdated | Should -BeTrue
    $receipt.beforeDeclaredExecutableState | Should -Be 'source-only'
    $receipt.afterDeclaredExecutableState | Should -Be 'runnable'
    $receipt.afterCurrentState | Should -Be 'authoring-complete'
    @($receipt.checkedInOperationFilesAfter) | Should -Be @('GetHelp.vi', 'RunOperation.vi')

    $manifest = Get-Content -LiteralPath (Join-Path $bundleRoot 'payload-provenance.json') -Raw | ConvertFrom-Json -Depth 20
    $manifest.executableState | Should -Be 'runnable'
    $manifest.currentState | Should -Be 'authoring-complete'
    @($manifest.checkedInOperationFiles) | Should -Be @('GetHelp.vi', 'RunOperation.vi')
    @($manifest.blockingReasons) | Should -Not -Contain 'Runnable LabVIEW operation files are not checked in yet.'
    @($manifest.blockingReasons) | Should -Contain 'No public workflow run has proven this repo-owned payload on an added or deleted VI.'
  }

  It 'fails closed and leaves the manifest unchanged when runnable files are still missing' {
    $bundleRoot = Join-Path $TestDrive 'blocked-bundle'
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
    @'
{
  "schema": "comparevi/operation-payload-source-bundle@v1",
  "name": "SyntheticPrintPayload",
  "payloadMode": "additional-operation-directory",
  "sourceRepositorySlug": "LabVIEW-Community-CI-CD/compare-vi-cli-action",
  "sourceRepositoryUrl": "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action",
  "sourceLicenseSpdx": "BSD-3-Clause",
  "ownership": "repo-owned",
  "implementationBasis": "Synthetic",
  "intendedCertificationSurface": "print-single-file",
  "intendedChangeKinds": ["added"],
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
  "notes": ["Synthetic bundle for tests."]
}
'@ | Set-Content -LiteralPath (Join-Path $bundleRoot 'payload-provenance.json') -Encoding utf8

    $receiptPath = Join-Path $TestDrive 'blocked-finalization.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:FinalizePath `
      -BundlePath $bundleRoot `
      -ReceiptPath $receiptPath `
      -InspectionReportPath (Join-Path $TestDrive 'blocked-inspection.json') `
      -InspectionMarkdownPath (Join-Path $TestDrive 'blocked-inspection.md') `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 20
    $receipt.status | Should -Be 'blocked'
    $receipt.manifestUpdated | Should -BeFalse
    $receipt.beforeDeclaredExecutableState | Should -Be 'source-only'
    $receipt.afterDeclaredExecutableState | Should -Be 'source-only'

    $manifest = Get-Content -LiteralPath (Join-Path $bundleRoot 'payload-provenance.json') -Raw | ConvertFrom-Json -Depth 20
    $manifest.executableState | Should -Be 'source-only'
    $manifest.currentState | Should -Be 'licensed-source-bundle'
    @($manifest.checkedInOperationFiles) | Should -Be @()
  }
}
