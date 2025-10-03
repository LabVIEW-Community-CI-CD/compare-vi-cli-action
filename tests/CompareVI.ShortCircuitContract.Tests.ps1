# Tests for CompareVI result contract, focusing on ShortCircuitedIdenticalPath presence
# Tags: Unit

Set-StrictMode -Version Latest

Describe 'Invoke-CompareVI result contract' -Tag 'Unit' {
  BeforeAll {
    $script:_origAllow32 = $env:LVCOMPARE_ALLOW_32BIT
    $env:LVCOMPARE_ALLOW_32BIT = '1'
    $script:_origBypass = $env:LVCOMPARE_TEST_BYPASS
    $env:LVCOMPARE_TEST_BYPASS = '1'
  }
  BeforeEach {
    # Mock Resolve-Cli so bitness validation & filesystem presence are bypassed
    Mock -CommandName Resolve-Cli -MockWith { 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe' } -Verifiable
  }
  AfterAll {
    if ($null -ne $script:_origAllow32) { $env:LVCOMPARE_ALLOW_32BIT = $script:_origAllow32 } else { Remove-Item Env:LVCOMPARE_ALLOW_32BIT -ErrorAction SilentlyContinue }
    if ($null -ne $script:_origBypass) { $env:LVCOMPARE_TEST_BYPASS = $script:_origBypass } else { Remove-Item Env:LVCOMPARE_TEST_BYPASS -ErrorAction SilentlyContinue }
  }
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $compareScript = Join-Path $script:RepoRoot 'scripts' 'CompareVI.ps1'
    if (-not (Test-Path -LiteralPath $compareScript)) { throw "CompareVI.ps1 not found under RepoRoot=$script:RepoRoot" }
    . $compareScript
  }
  Context 'Non short-circuit path (different files)' {
    # Use the real VI artifacts in repo root (VI1.vi vs VI2.vi)
    It 'emits ShortCircuitedIdenticalPath = $false' {
      $res = Invoke-CompareVI -Base (Join-Path $script:RepoRoot 'VI1.vi') -Head (Join-Path $script:RepoRoot 'VI2.vi') -FailOnDiff:$false -LvCompareArgs '' -GitHubOutputPath $null -GitHubStepSummaryPath $null -Executor { param($cli,$b,$h,$cliArgs) return 0 }
      $res | Should -Not -BeNullOrEmpty
      $res.PSObject.Properties.Name | Should -Contain 'ShortCircuitedIdenticalPath'
      $res.ShortCircuitedIdenticalPath | Should -BeFalse
    }
  }

  Context 'Short-circuit path (same file)' {
    It 'emits ShortCircuitedIdenticalPath = $true' {
      $viPath = Join-Path $script:RepoRoot 'VI1.vi'
      $res = Invoke-CompareVI -Base $viPath -Head $viPath -FailOnDiff:$false -LvCompareArgs '' -GitHubOutputPath $null -GitHubStepSummaryPath $null -Executor { param($cli,$b,$h,$cliArgs) throw 'Should not be called in short-circuit test' }
      $res.ShortCircuitedIdenticalPath | Should -BeTrue
      $res.ExitCode | Should -Be 0
      $res.Diff | Should -BeFalse
    }
  }

  Context 'Contract properties completeness' {
    It 'includes all properties consumed by action.yml' {
  $res = Invoke-CompareVI -Base (Join-Path $script:RepoRoot 'VI1.vi') -Head (Join-Path $script:RepoRoot 'VI2.vi') -FailOnDiff:$false -LvCompareArgs '' -GitHubOutputPath $null -GitHubStepSummaryPath $null -Executor { param($cli,$b,$h,$cliArgs) return 0 }
      $expected = 'Base','Head','Cwd','CliPath','Command','ExitCode','Diff','CompareDurationSeconds','CompareDurationNanoseconds','ShortCircuitedIdenticalPath'
      foreach ($p in $expected) {
        $res.PSObject.Properties.Name | Should -Contain $p
      }
    }
  }
}
