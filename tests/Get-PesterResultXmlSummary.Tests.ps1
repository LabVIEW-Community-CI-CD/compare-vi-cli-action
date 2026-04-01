Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Get-PesterResultXmlSummary.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:summaryTool = Join-Path $script:repoRoot 'tools/Get-PesterResultXmlSummary.ps1'
  }

  It 'parses complete NUnit XML through the DOM path' {
    $xmlPath = Join-Path $TestDrive 'complete.xml'
    $xml = @'
<?xml version="1.0" encoding="utf-8"?>
<test-results name="Pester" total="4" errors="0" failures="1" not-run="1" inconclusive="0" ignored="0" skipped="1" invalid="0">
  <environment nunit-version="3.0" />
  <culture-info />
</test-results>
'@
    Set-Content -LiteralPath $xmlPath -Value $xml -Encoding UTF8

    $result = & $script:summaryTool -XmlPath $xmlPath -StabilizationTimeoutSeconds 0

    $result.schema | Should -Be 'pester-result-xml-summary@v1'
    $result.status | Should -Be 'complete'
    $result.summarySource | Should -Be 'xml-dom'
    $result.closeTagPresent | Should -BeTrue
    $result.total | Should -Be 4
    $result.failed | Should -Be 1
    $result.errors | Should -Be 0
    $result.skipped | Should -Be 1
    $result.parseError | Should -BeNullOrEmpty
  }

  It 'falls back to root attributes when the XML is truncated but totals are still recoverable' {
    $xmlPath = Join-Path $TestDrive 'truncated.xml'
    $xml = @'
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<test-results name="Pester" total="1033" errors="0" failures="156" not-run="0" inconclusive="0" ignored="0" skipped="13" invalid="0">
  <environment nunit-version="2.5.8.0" />
  <culture-info />
  <test-suite type="TestFixture" name="Broken">
    <results>
      <test-case name="Broken.case" result="Failure">
        <failure>
          <message>Expected 0, but got 1.</message>
'@
    Set-Content -LiteralPath $xmlPath -Value $xml -Encoding UTF8

    $result = & $script:summaryTool -XmlPath $xmlPath -StabilizationTimeoutSeconds 0

    $result.status | Should -Be 'truncated-root'
    $result.summarySource | Should -Be 'root-attributes'
    $result.closeTagPresent | Should -BeFalse
    $result.total | Should -Be 1033
    $result.failed | Should -Be 156
    $result.errors | Should -Be 0
    $result.skipped | Should -Be 0
    $result.parseError | Should -Match 'Unexpected end of file'
  }
}
