Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Variable -Name skipSelfTest -Scope Script -Value $false -Force
Set-Variable -Name skipReason -Scope Script -Value 'Pattern self-test suppressed in nested dispatcher context' -Force

Describe 'Invoke-PesterTests Include/Exclude patterns' -Tag 'Unit' {
  BeforeAll {
    if ($env:SUPPRESS_PATTERN_SELFTEST -eq '1') {
      $script:skipSelfTest = $true
      $script:skipReason = 'Pattern self-test suppressed in nested dispatcher context'
      return
    }

    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    Import-Module (Join-Path $repoRoot 'tools' 'Dispatcher' 'TestSelection.psm1') -Force

    $fixtureTestsRootPs = Join-Path $TestDrive 'fixture-tests'
    New-Item -ItemType Directory -Force -Path $fixtureTestsRootPs | Out-Null
    $script:fixtureTestsRoot = (Resolve-Path -LiteralPath $fixtureTestsRootPs).Path

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

    $script:fixtureFiles = @(Get-ChildItem -LiteralPath $script:fixtureTestsRoot -Filter '*.ps1')
    $script:expectedAlpha = (Resolve-Path -LiteralPath (Join-Path $script:fixtureTestsRoot 'Alpha.Unit.Tests.ps1')).Path
    $script:expectedBeta  = (Resolve-Path -LiteralPath (Join-Path $script:fixtureTestsRoot 'Beta.Unit.Tests.ps1')).Path
  }

  It 'honors IncludePatterns for a single file' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Pattern self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    $selection = Invoke-DispatcherIncludeExcludeFilter -Files $script:fixtureFiles -IncludePatterns @('Alpha*.ps1')
    $selection.Include.Applied | Should -BeTrue
    $selection.Include.Before | Should -Be 3
    $selection.Include.After | Should -Be 1

    $resolved = @($selection.Files | ForEach-Object { $_.FullName })
    $resolved | Should -HaveCount 1
    $resolved | Should -Be @($script:expectedAlpha)
    ($selection.Files | ForEach-Object { $_.Name }) | Should -Be @('Alpha.Unit.Tests.ps1')
  }

  It 'honors ExcludePatterns to remove files' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Pattern self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    $selection = Invoke-DispatcherIncludeExcludeFilter -Files $script:fixtureFiles -ExcludePatterns @('*Helper.ps1')
    $selection.Exclude.Applied | Should -BeTrue
    $selection.Exclude.Removed | Should -Be 1

    $resolved = @($selection.Files | ForEach-Object { $_.FullName } | Sort-Object)
    $expectedPaths = @($script:expectedAlpha, $script:expectedBeta) | Sort-Object
    $resolved | Should -Be $expectedPaths

    $names = @($selection.Files | ForEach-Object { $_.Name } | Sort-Object)
    $names | Should -Be @('Alpha.Unit.Tests.ps1', 'Beta.Unit.Tests.ps1')
  }

  It 'suppresses the self-test when SUPPRESS_PATTERN_SELFTEST=1 in repo context' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Pattern self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    $patternPath = Join-Path $script:fixtureTestsRoot 'Invoke-PesterTests.Patterns.Tests.ps1'
    Set-Content -LiteralPath $patternPath -Value "Describe 'SelfTest' { }" -Encoding utf8

    $allFiles = @(Get-ChildItem -LiteralPath $script:fixtureTestsRoot -Filter '*.ps1')
    $suppression = Invoke-DispatcherPatternSelfTestSuppression -Files $allFiles -PatternSelfTestLeaf 'Invoke-PesterTests.Patterns.Tests.ps1' -SingleTestFile $patternPath -LimitToSingle

    $suppression.Removed | Should -Be 1
    $suppression.SingleCleared | Should -BeTrue
    ($suppression.Files | ForEach-Object { $_.Name }) | Should -Not -Contain 'Invoke-PesterTests.Patterns.Tests.ps1'
  }
}
