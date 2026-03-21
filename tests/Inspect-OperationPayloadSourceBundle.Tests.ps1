#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Inspect-OperationPayloadSourceBundle.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:InspectorPath = Join-Path $script:RepoRoot 'tools' 'Inspect-OperationPayloadSourceBundle.ps1'
    if (-not (Test-Path -LiteralPath $script:InspectorPath -PathType Leaf)) {
      throw "Inspect-OperationPayloadSourceBundle.ps1 not found at $script:InspectorPath"
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

  It 'reports the checked-in PrintToSingleFileHtml bundle as source-only' {
    $resultsRoot = Join-Path $TestDrive 'results'

    $output = & pwsh -NoLogo -NoProfile -File $script:InspectorPath `
      -BundlePath 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml' `
      -ReportPath (Join-Path $resultsRoot 'inspection.json') `
      -MarkdownPath (Join-Path $resultsRoot 'inspection.md') *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $reportPath = Join-Path $resultsRoot 'inspection.json'
    $reportPath | Should -Exist

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    $report.schema | Should -Be 'comparevi/operation-payload-source-bundle-inspection@v1'
    $report.status | Should -Be 'succeeded'
    $report.declaredExecutableState | Should -Be 'source-only'
    $report.observedExecutableState | Should -Be 'source-only'
    $report.executableStateAligned | Should -BeTrue
    @($report.checkedInOperationFiles) | Should -Be @()
    @($report.missingOperationFiles) | Should -Contain 'GetHelp.vi'
    @($report.missingOperationFiles) | Should -Contain 'RunOperation.vi'
  }

  It 'reports runnable when every expected operation file is present as a LabVIEW binary' {
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
  "checkedInOperationFiles": ["GetHelp.vi", "RunOperation.vi"],
  "executableState": "runnable",
  "currentState": "authoring-complete",
  "promotionTarget": "accepted",
  "promotionBlocked": true,
  "blockingReasons": ["Public proof still missing."],
  "notes": ["Synthetic bundle for tests."]
}
'@ | Set-Content -LiteralPath (Join-Path $bundleRoot 'payload-provenance.json') -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:InspectorPath `
      -BundlePath $bundleRoot `
      -ReportPath (Join-Path $TestDrive 'runnable-report.json') `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $report = Get-Content -LiteralPath (Join-Path $TestDrive 'runnable-report.json') -Raw | ConvertFrom-Json -Depth 20
    $report.status | Should -Be 'succeeded'
    $report.observedExecutableState | Should -Be 'runnable'
    @($report.checkedInOperationFiles) | Should -Be @('GetHelp.vi', 'RunOperation.vi')
    @($report.binaryOperationFiles) | Should -Be @('GetHelp.vi', 'RunOperation.vi')
    @($report.nonBinaryOperationFiles) | Should -Be @()
    @($report.missingOperationFiles) | Should -Be @()
  }

  It 'fails closed when the manifest claims runnable but required files are missing' {
    $bundleRoot = Join-Path $TestDrive 'drift-bundle'
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $bundleRoot 'GetHelp.vi') -Value 'placeholder' -Encoding utf8
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
  "checkedInOperationFiles": ["GetHelp.vi", "RunOperation.vi"],
  "executableState": "runnable",
  "currentState": "authoring-complete",
  "promotionTarget": "accepted",
  "promotionBlocked": true,
  "blockingReasons": ["Public proof still missing."],
  "notes": ["Synthetic bundle for tests."]
}
'@ | Set-Content -LiteralPath (Join-Path $bundleRoot 'payload-provenance.json') -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:InspectorPath `
      -BundlePath $bundleRoot `
      -ReportPath (Join-Path $TestDrive 'drift-report.json') `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $report = Get-Content -LiteralPath (Join-Path $TestDrive 'drift-report.json') -Raw | ConvertFrom-Json -Depth 20
    $report.status | Should -Be 'drift'
    $report.declaredExecutableState | Should -Be 'runnable'
    $report.observedExecutableState | Should -Be 'source-only'
    $report.executableStateAligned | Should -BeFalse
    @($report.missingOperationFiles) | Should -Contain 'RunOperation.vi'
  }

  It 'fails closed when required operation files exist but are not LabVIEW binaries' {
    $bundleRoot = Join-Path $TestDrive 'non-binary-bundle'
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $bundleRoot 'GetHelp.vi') -Value 'placeholder' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $bundleRoot 'RunOperation.vi') -Value 'placeholder' -Encoding utf8
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
  "checkedInOperationFiles": ["GetHelp.vi", "RunOperation.vi"],
  "executableState": "runnable",
  "currentState": "authoring-complete",
  "promotionTarget": "accepted",
  "promotionBlocked": true,
  "blockingReasons": ["Public proof still missing."],
  "notes": ["Synthetic bundle for tests."]
}
'@ | Set-Content -LiteralPath (Join-Path $bundleRoot 'payload-provenance.json') -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:InspectorPath `
      -BundlePath $bundleRoot `
      -ReportPath (Join-Path $TestDrive 'non-binary-report.json') `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $report = Get-Content -LiteralPath (Join-Path $TestDrive 'non-binary-report.json') -Raw | ConvertFrom-Json -Depth 20
    $report.status | Should -Be 'drift'
    $report.declaredExecutableState | Should -Be 'runnable'
    $report.observedExecutableState | Should -Be 'source-only'
    $report.executableStateAligned | Should -BeFalse
    @($report.checkedInOperationFiles) | Should -Be @('GetHelp.vi', 'RunOperation.vi')
    @($report.binaryOperationFiles) | Should -Be @()
    @($report.nonBinaryOperationFiles) | Should -Be @('GetHelp.vi', 'RunOperation.vi')
  }
}
