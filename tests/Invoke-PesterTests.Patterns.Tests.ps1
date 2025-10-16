Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterTests Include/Exclude patterns' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:dispatcher = Join-Path $repoRoot 'Invoke-PesterTests.ps1'
    $script:fixtureTestsRoot = Join-Path $TestDrive 'fixture-tests'
    New-Item -ItemType Directory -Force -Path $script:fixtureTestsRoot | Out-Null

    try {
      $null = Get-Command -Name 'pwsh' -ErrorAction Stop
      $script:pwshAvailable = $true
      $script:skipReason = $null
    } catch {
      $script:pwshAvailable = $false
      $script:skipReason = 'pwsh executable not available on PATH'
    }

    Import-Module (Join-Path $repoRoot 'tests' '_helpers' 'DispatcherTestHelper.psm1') -Force

    $testTemplate = @'
Describe "{0}" {{
  It "passes" {{
    1 | Should -Be 1
  }}
}}
'@

    foreach ($name in @('Alpha.Unit.Tests.ps1', 'Beta.Unit.Tests.ps1', 'Gamma.Helper.ps1')) {
      $content = [string]::Format($testTemplate, $name)
      Set-Content -LiteralPath (Join-Path $script:fixtureTestsRoot $name) -Value $content -Encoding utf8
    }
  }

  It 'honors IncludePatterns for a single file' {
    if (-not $script:pwshAvailable) {
      Set-ItResult -Skipped -Because $script:skipReason
      return
    }

    $resultsDir = Join-Path $TestDrive 'results-inc'
    $inc = 'Alpha*.ps1'
    $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcher -ResultsPath $resultsDir -IncludePatterns $inc -TestsPath $script:fixtureTestsRoot -AdditionalArgs @('-IntegrationMode', 'exclude')
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 0
    $res.StdErr.Trim() | Should -BeNullOrEmpty
    $sel = Join-Path $resultsDir 'pester-selected-files.txt'
    Test-Path $sel | Should -BeTrue
    $lines = @(Get-Content -LiteralPath $sel)
    $lines.Count | Should -Be 1
    $leafs = $lines | ForEach-Object { Split-Path -Leaf $_ }
    $leafs | Should -Be @('Alpha.Unit.Tests.ps1')
    $res.StdOut | Should -Match ([regex]::Escape($script:fixtureTestsRoot))
  }

  It 'honors ExcludePatterns to remove files' {
    if (-not $script:pwshAvailable) {
      Set-ItResult -Skipped -Because $script:skipReason
      return
    }

    $resultsDir = Join-Path $TestDrive 'results-exc'
    $exc = '*Helper.ps1'
    $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcher -ResultsPath $resultsDir -TestsPath $script:fixtureTestsRoot -AdditionalArgs @('-ExcludePatterns', $exc, '-IntegrationMode', 'exclude')
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 0
    $res.StdErr.Trim() | Should -BeNullOrEmpty
    $sel = Join-Path $resultsDir 'pester-selected-files.txt'
    Test-Path $sel | Should -BeTrue
    $lines = @(Get-Content -LiteralPath $sel)
    $lines.Count | Should -Be 2
    $leafs = $lines | ForEach-Object { Split-Path -Leaf $_ }
    $leafs | Should -Not -Contain 'Gamma.Helper.ps1'
    ($leafs | Sort-Object) | Should -Be @('Alpha.Unit.Tests.ps1', 'Beta.Unit.Tests.ps1')
    $res.StdOut | Should -Match ([regex]::Escape($script:fixtureTestsRoot))
  }
}
