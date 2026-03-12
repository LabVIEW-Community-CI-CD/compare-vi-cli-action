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

    $fixtureContent = @{
      'Alpha.Unit.Tests.ps1' = @(
        '# CompareVI-TestPlane: host-neutral',
        '# CompareVI-TestModes: default, attributes',
        [string]::Format($testTemplate, 'Alpha.Unit.Tests.ps1')
      ) -join [Environment]::NewLine
      'Beta.Unit.Tests.ps1' = @(
        '# CompareVI-TestPlane: legacy-host-labview',
        [string]::Format($testTemplate, 'Beta.Unit.Tests.ps1')
      ) -join [Environment]::NewLine
      'Gamma.Helper.ps1' = [string]::Format($testTemplate, 'Gamma.Helper.ps1')
    }

    foreach ($name in $fixtureContent.Keys) {
      $content = $fixtureContent[$name]
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

  It 'matches repo-relative IncludePatterns when a path is provided' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Pattern self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    $originalLocation = Get-Location
    try {
      Push-Location $TestDrive
      $selection = Invoke-DispatcherIncludeExcludeFilter -Files $script:fixtureFiles -IncludePatterns @('fixture-tests/Alpha.Unit.Tests.ps1')
    } finally {
      Set-Location $originalLocation
    }

    $selection.Include.Applied | Should -BeTrue
    $selection.Include.After | Should -Be 1
    @($selection.Files | ForEach-Object { $_.FullName }) | Should -Be @($script:expectedAlpha)
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

  It 'parses execution plane and mode metadata' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Pattern self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    $alphaMetadata = Get-DispatcherTestMetadata -File (Get-Item -LiteralPath $script:expectedAlpha)
    $alphaMetadata.ExecutionPlane | Should -Be 'host-neutral'
    @($alphaMetadata.Modes) | Should -Be @('default', 'attributes')

    $betaMetadata = Get-DispatcherTestMetadata -File (Get-Item -LiteralPath $script:expectedBeta)
    $betaMetadata.ExecutionPlane | Should -Be 'legacy-host-labview'
  }

  It 'pre-excludes legacy host LabVIEW tests by default' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Pattern self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    $metadata = @(
      (Get-DispatcherTestMetadata -File (Get-Item -LiteralPath $script:expectedAlpha)),
      (Get-DispatcherTestMetadata -File (Get-Item -LiteralPath $script:expectedBeta))
    )
    $selection = Invoke-DispatcherExecutionPlaneFilter -Metadata $metadata
    $selection.ExcludedCount | Should -Be 1
    ($selection.Files | ForEach-Object { $_.FullName }) | Should -Be @($script:expectedAlpha)
    $selection.ExplicitBlocked | Should -BeFalse
  }

  It 'blocks an explicit legacy host LabVIEW selection when no allowed files remain' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Pattern self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    $metadata = @(Get-DispatcherTestMetadata -File (Get-Item -LiteralPath $script:expectedBeta))
    $selection = Invoke-DispatcherExecutionPlaneFilter -Metadata $metadata -ExplicitSelection
    $selection.ExcludedCount | Should -Be 1
    $selection.ExplicitBlocked | Should -BeTrue
  }
}
