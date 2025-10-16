Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterTests Include/Exclude patterns' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:dispatcher = Join-Path $repoRoot 'Invoke-PesterTests.ps1'
    $script:fixtureTestsRoot = Join-Path $TestDrive 'fixture-tests'
    New-Item -ItemType Directory -Force -Path $script:fixtureTestsRoot | Out-Null

    Import-Module (Join-Path $repoRoot 'tests' '_helpers' 'DispatcherTestHelper.psm1') -Force

    $testTemplate = @'
Describe "{0}" {
  It "passes" {
    1 | Should -Be 1
  }
}
'@

    foreach ($name in @('Alpha.Unit.Tests.ps1', 'Beta.Unit.Tests.ps1', 'Gamma.Helper.ps1')) {
      $content = [string]::Format($testTemplate, $name)
      Set-Content -LiteralPath (Join-Path $script:fixtureTestsRoot $name) -Value $content -Encoding utf8
    }
  }

  It 'honors IncludePatterns for a single file' {
    $resultsDir = Join-Path $TestDrive 'results-inc'
    $inc = 'Alpha*.ps1'
    $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcher -ResultsPath $resultsDir -IncludePatterns $inc -TestsPath $script:fixtureTestsRoot -AdditionalArgs @('-IntegrationMode', 'exclude')
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 0
    $sel = Join-Path $resultsDir 'pester-selected-files.txt'
    Test-Path $sel | Should -BeTrue
    $lines = @(Get-Content -LiteralPath $sel)
    $lines.Count | Should -Be 1
    ($lines | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @('Alpha.Unit.Tests.ps1')
  }

  It 'honors ExcludePatterns to remove files' {
    $resultsDir = Join-Path $TestDrive 'results-exc'
    $exc = '*Helper.ps1'
    $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcher -ResultsPath $resultsDir -TestsPath $script:fixtureTestsRoot -AdditionalArgs @('-ExcludePatterns', $exc, '-IntegrationMode', 'exclude')
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 0
    $sel = Join-Path $resultsDir 'pester-selected-files.txt'
    Test-Path $sel | Should -BeTrue
    $lines = @(Get-Content -LiteralPath $sel)
    $lines.Count | Should -Be 2
    $leafs = $lines | ForEach-Object { Split-Path -Leaf $_ }
    $leafs | Should -NotContain 'Gamma.Helper.ps1'
    $leafs | Should -Contain 'Alpha.Unit.Tests.ps1'
    $leafs | Should -Contain 'Beta.Unit.Tests.ps1'
  }
}
