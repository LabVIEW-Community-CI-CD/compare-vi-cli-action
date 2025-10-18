# Tests for CompareVI result contract, focusing on ShortCircuitedIdenticalPath presence
# Tags: Unit

Set-StrictMode -Version Latest

Describe 'Invoke-CompareVI result contract' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $compareScript = Join-Path $script:RepoRoot 'scripts' 'CompareVI.ps1'
    if (-not (Test-Path -LiteralPath $compareScript)) { throw "CompareVI.ps1 not found under RepoRoot=$script:RepoRoot" }
    . $compareScript
    
    # Mock Resolve-Cli to avoid dependency on actual LVCompare installation
    $script:canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    Mock -CommandName Resolve-Cli -MockWith { param($Explicit,$PreferredBitness) $script:canonical }
  }
  Context 'Non short-circuit path (different files)' {
    # Use the provided VI1.vi and VI2.vi in repo root (they should differ)
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
