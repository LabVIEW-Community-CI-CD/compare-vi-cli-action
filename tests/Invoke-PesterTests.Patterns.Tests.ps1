Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterTests Include/Exclude patterns' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:dispatcher = Join-Path $repoRoot 'Invoke-PesterTests.ps1'
    $fixtureTestsRootPs = Join-Path $TestDrive 'fixture-tests'
    New-Item -ItemType Directory -Force -Path $fixtureTestsRootPs | Out-Null
    $script:fixtureTestsRoot = (Resolve-Path -LiteralPath $fixtureTestsRootPs).Path
    $script:testDriveRoot = Split-Path -Parent $script:fixtureTestsRoot

    Import-Module (Join-Path $repoRoot 'tests' '_helpers' 'DispatcherTestHelper.psm1') -Force

    $script:pwshPath = Get-PwshExePath
    if ($script:pwshPath) {
      $script:pwshAvailable = $true
      $script:skipReason = $null
    } else {
      $script:pwshAvailable = $false
      $script:skipReason = 'pwsh executable not available on PATH'
    }

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

    $script:expectedAlpha = (Resolve-Path -LiteralPath (Join-Path $script:fixtureTestsRoot 'Alpha.Unit.Tests.ps1')).Path
    $script:expectedBeta  = (Resolve-Path -LiteralPath (Join-Path $script:fixtureTestsRoot 'Beta.Unit.Tests.ps1')).Path
  }

  It 'honors IncludePatterns for a single file' {
    if (-not $script:pwshAvailable) {
      Set-ItResult -Skipped -Because $script:skipReason
      return
    }

    $resultsDir = Join-Path $script:testDriveRoot 'results-inc'
    if (Test-Path -LiteralPath $resultsDir) {
      Remove-Item -LiteralPath $resultsDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
    $inc = 'Alpha*.ps1'
    $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcher -ResultsPath $resultsDir -IncludePatterns $inc -TestsPath $script:fixtureTestsRoot -AdditionalArgs @('-IntegrationMode', 'exclude')
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 0
    $res.StdErr.Trim() | Should -BeNullOrEmpty
    $sel = Join-Path $resultsDir 'pester-selected-files.txt'
    Test-Path $sel | Should -BeTrue
    $lines = @(Get-Content -LiteralPath $sel | Where-Object {
      $_ -and $_.Trim().Length -gt 0
    })
    $lines.Count | Should -Be 1
    $resolved = $lines | ForEach-Object { (Resolve-Path -LiteralPath $_).Path }
    $resolved | Should -Be @($script:expectedAlpha)
    $leafs = $resolved | ForEach-Object { Split-Path -Leaf $_ }
    $leafs | Should -Be @('Alpha.Unit.Tests.ps1')
    $res.StdOut | Should -Not -Match 'Single-invoker mode'
    $res.StdOut | Should -Match ([regex]::Escape($script:fixtureTestsRoot))
    $xmlPath = Join-Path $resultsDir 'pester-results.xml'
    Test-Path $xmlPath | Should -BeTrue
    $xmlText = Get-Content -LiteralPath $xmlPath -Raw
    $xmlText | Should -Match 'Alpha\.Unit\.Tests\.ps1'
    $xmlText | Should -Not -Match 'Beta\.Unit\.Tests\.ps1'
    $xmlText | Should -Not -Match 'Gamma\.Helper\.ps1'
  }

  It 'honors ExcludePatterns to remove files' {
    if (-not $script:pwshAvailable) {
      Set-ItResult -Skipped -Because $script:skipReason
      return
    }

    $resultsDir = Join-Path $script:testDriveRoot 'results-exc'
    if (Test-Path -LiteralPath $resultsDir) {
      Remove-Item -LiteralPath $resultsDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
    $exc = '*Helper.ps1'
    $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcher -ResultsPath $resultsDir -TestsPath $script:fixtureTestsRoot -AdditionalArgs @('-ExcludePatterns', $exc, '-IntegrationMode', 'exclude')
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 0
    $res.StdErr.Trim() | Should -BeNullOrEmpty
    $sel = Join-Path $resultsDir 'pester-selected-files.txt'
    Test-Path $sel | Should -BeTrue
    $lines = @(Get-Content -LiteralPath $sel | Where-Object {
      $_ -and $_.Trim().Length -gt 0
    })
    $lines.Count | Should -Be 2
    $resolved = $lines | ForEach-Object { (Resolve-Path -LiteralPath $_).Path }
    $expected = @($script:expectedAlpha, $script:expectedBeta) | Sort-Object
    ($resolved | Sort-Object) | Should -Be $expected
    $leafs = $resolved | ForEach-Object { Split-Path -Leaf $_ }
    $leafs | Should -Not -Contain 'Gamma.Helper.ps1'
    ($leafs | Sort-Object) | Should -Be @('Alpha.Unit.Tests.ps1', 'Beta.Unit.Tests.ps1')
    $res.StdOut | Should -Not -Match 'Single-invoker mode'
    $res.StdOut | Should -Match ([regex]::Escape($script:fixtureTestsRoot))
    $xmlPath = Join-Path $resultsDir 'pester-results.xml'
    Test-Path $xmlPath | Should -BeTrue
    $xmlText = Get-Content -LiteralPath $xmlPath -Raw
    $xmlText | Should -Match 'Alpha\.Unit\.Tests\.ps1'
    $xmlText | Should -Match 'Beta\.Unit\.Tests\.ps1'
    $xmlText | Should -Not -Match 'Gamma\.Helper\.ps1'
  }
}
