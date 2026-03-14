#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'BranchExpectedContexts' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $repoRoot 'tools' 'BranchExpectedContexts.psm1') -Force -DisableNameChecking
  }

  It 'projects expected contexts from branchClassRequiredChecks when branches are absent' {
    $policy = [pscustomobject]@{
      branchClassBindings = [pscustomobject]@{
        develop = 'upstream-integration'
      }
      branchClassRequiredChecks = [pscustomobject]@{
        'upstream-integration' = @('lint', 'session-index')
      }
    }

    $expected = @(Resolve-BranchExpectedContexts -Policy $policy -BranchName 'develop')
    $expected | Should -Be @('lint', 'session-index')
  }

  It 'falls back to branches when no branch-class projection is available' {
    $policy = [pscustomobject]@{
      branches = [pscustomobject]@{
        develop = @('lint', 'fixtures')
      }
    }

    $expected = @(Resolve-BranchExpectedContexts -Policy $policy -BranchName 'develop')
    $expected | Should -Be @('fixtures', 'lint')
  }
}
