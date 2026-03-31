Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterExecutionPostprocess.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:postprocessTool = Join-Path $script:repoRoot 'tools/Invoke-PesterExecutionPostprocess.ps1'
  }

  It 'preserves an existing summary and marks complete XML as complete' {
    $resultsDir = Join-Path $TestDrive 'complete'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $xmlPath = Join-Path $resultsDir 'pester-results.xml'
    $summaryPath = Join-Path $resultsDir 'pester-summary.json'
    @'
<?xml version="1.0" encoding="utf-8"?>
<test-results name="Pester" total="4" errors="0" failures="1" not-run="1" inconclusive="0" ignored="0" skipped="1" invalid="0">
  <environment nunit-version="3.0" />
  <culture-info />
</test-results>
'@ | Set-Content -LiteralPath $xmlPath -Encoding UTF8
    @{
      duration_s = 1.25
      pesterVersion = '5.7.1'
      includeIntegration = $false
    } | ConvertTo-Json | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    & $script:postprocessTool -ResultsDir $resultsDir | Out-Null

    $report = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-execution-postprocess.json') -Raw | ConvertFrom-Json
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json

    $report.status | Should -Be 'complete'
    $report.summaryWritten | Should -BeTrue
    $summary.total | Should -Be 4
    $summary.failed | Should -Be 1
    $summary.errors | Should -Be 0
    $summary.passed | Should -Be 3
    $summary.resultsXmlStatus | Should -Be 'complete'
    $summary.duration_s | Should -Be 1.25
    $summary.pesterVersion | Should -Be '5.7.1'
  }

  It 'writes a repaired machine-readable summary when XML is truncated' {
    $resultsDir = Join-Path $TestDrive 'truncated'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $xmlPath = Join-Path $resultsDir 'pester-results.xml'
    @'
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<test-results name="Pester" total="1033" errors="0" failures="156" not-run="0" inconclusive="0" ignored="0" skipped="13" invalid="0">
  <environment nunit-version="2.5.8.0" />
  <culture-info />
  <test-suite type="TestFixture" name="Broken">
    <results>
      <test-case name="Broken.case" result="Failure">
        <failure>
          <message>Expected 0, but got 1.</message>
'@ | Set-Content -LiteralPath $xmlPath -Encoding UTF8

    & $script:postprocessTool -ResultsDir $resultsDir | Out-Null

    $report = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-execution-postprocess.json') -Raw | ConvertFrom-Json
    $summary = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Raw | ConvertFrom-Json

    $report.status | Should -Be 'results-xml-truncated'
    $report.resultsXmlStatus | Should -Be 'truncated-root'
    $report.summaryWritten | Should -BeTrue
    $summary.executionPostprocessStatus | Should -Be 'results-xml-truncated'
    $summary.resultsXmlStatus | Should -Be 'truncated-root'
    $summary.total | Should -Be 1033
    $summary.failed | Should -Be 156
    $summary.errors | Should -Be 0
    $summary.passed | Should -Be 877
  }

  It 'classifies malformed closed XML with recoverable root attributes as invalid-results-xml' {
    $resultsDir = Join-Path $TestDrive 'invalid'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $xmlPath = Join-Path $resultsDir 'pester-results.xml'
    @'
<?xml version="1.0" encoding="utf-8"?>
<test-results name="Pester" total="8" errors="1" failures="2" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0">
  <environment nunit-version="3.0" />
  <culture-info />
  <test-suite>
</test-results>
'@ | Set-Content -LiteralPath $xmlPath -Encoding UTF8

    & $script:postprocessTool -ResultsDir $resultsDir | Out-Null

    $report = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-execution-postprocess.json') -Raw | ConvertFrom-Json
    $summary = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Raw | ConvertFrom-Json

    $report.status | Should -Be 'invalid-results-xml'
    $report.resultsXmlStatus | Should -Be 'invalid-root-attributes'
    $report.summaryWritten | Should -BeTrue
    $summary.executionPostprocessStatus | Should -Be 'invalid-results-xml'
    $summary.resultsXmlStatus | Should -Be 'invalid-root-attributes'
    $summary.total | Should -Be 8
    $summary.failed | Should -Be 2
    $summary.errors | Should -Be 1
    $summary.passed | Should -Be 5
  }

  It 'classifies missing XML as missing-results-xml without writing a summary' {
    $resultsDir = Join-Path $TestDrive 'missing'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    & $script:postprocessTool -ResultsDir $resultsDir | Out-Null

    $reportPath = Join-Path $resultsDir 'pester-execution-postprocess.json'
    $summaryPath = Join-Path $resultsDir 'pester-summary.json'
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json

    $report.status | Should -Be 'missing-results-xml'
    $report.resultsXmlStatus | Should -Be 'missing'
    $report.summaryWritten | Should -BeFalse
    (Test-Path -LiteralPath $summaryPath) | Should -BeFalse
  }
}
