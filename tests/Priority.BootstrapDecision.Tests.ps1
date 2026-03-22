Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Bootstrap develop checkout decision' -Tag 'Unit' {
  BeforeAll {
    $root = Resolve-Path (Join-Path $PSScriptRoot '..')
    $modulePath = Join-Path $root 'tools' 'priority' 'bootstrap-decision.psm1'
    $script:DecisionModule = Import-Module $modulePath -Force -PassThru
  }

  It 'returns noop when already on develop' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'develop' -IsDirty:$false -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should -Be 'noop-already-develop'
  }

  It 'skips work branches' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'issue/588-seam' -IsDirty:$false -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should -Be 'skip-work-branch'
  }

  It 'retains non-bootstrap branches' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'chore/local' -IsDirty:$false -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should -Be 'skip-retain-branch'
  }

  It 'skips checkout when working tree is dirty' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'main' -IsDirty:$true -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should -Be 'skip-dirty'
  }

  It 'chooses remote branch creation when develop is missing locally' {
    $decision = & $script:DecisionModule {
      Get-DevelopCheckoutDecision -CurrentBranch 'main' -IsDirty:$false -HasDevelop:$false -RemoteDevelopRef @{ Remote = 'upstream'; Ref = 'upstream/develop' }
    }

    $decision.Action | Should -Be 'create-develop-from-remote'
    $decision.Remote | Should -Be 'upstream'
    $decision.Ref | Should -Be 'upstream/develop'
  }

  It 'checks out develop when local branch exists' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'main' -IsDirty:$false -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should -Be 'checkout-develop'
  }

  It 'delegates standing-priority helpers to a develop worktree when bootstrapping from a work branch' {
    $decision = & $script:DecisionModule {
      Get-BootstrapHelperRootDecision `
        -CurrentBranch 'issue/1276-bootstrap-helper-root' `
        -CurrentRepoRoot 'C:\repo\issue-1276' `
        -DevelopWorktreeRoots @([pscustomobject]@{ Root = 'C:\repo\develop-root'; IsClean = $true })
    }

    $decision.Action | Should -Be 'delegate-develop-worktree'
    $decision.HelperRoot | Should -Be 'C:\repo\develop-root'
  }

  It 'keeps the caller checkout when already on develop' {
    $decision = & $script:DecisionModule {
      Get-BootstrapHelperRootDecision `
        -CurrentBranch 'develop' `
        -CurrentRepoRoot 'C:\repo\develop-root' `
        -DevelopWorktreeRoots @([pscustomobject]@{ Root = 'C:\repo\develop-root'; IsClean = $true })
    }

    $decision.Action | Should -Be 'use-current-root'
    $decision.HelperRoot | Should -Be 'C:\repo\develop-root'
  }

  It 'falls back to the caller checkout when no develop worktree is available' {
    $decision = & $script:DecisionModule {
      Get-BootstrapHelperRootDecision `
        -CurrentBranch 'issue/1276-bootstrap-helper-root' `
        -CurrentRepoRoot 'C:\repo\issue-1276' `
        -DevelopWorktreeRoots @()
    }

    $decision.Action | Should -Be 'use-current-root'
    $decision.HelperRoot | Should -Be 'C:\repo\issue-1276'
  }

  It 'skips dirty develop helpers when a clean helper is available' {
    $decision = & $script:DecisionModule {
      Get-BootstrapHelperRootDecision `
        -CurrentBranch 'issue/1744-router-refresh' `
        -CurrentRepoRoot 'C:\repo\issue-1744' `
        -DevelopWorktreeRoots @(
          [pscustomobject]@{ Root = 'C:\repo\develop-dirty'; IsClean = $false },
          [pscustomobject]@{ Root = 'C:\repo\develop-clean'; IsClean = $true }
        )
    }

    $decision.Action | Should -Be 'delegate-develop-worktree'
    $decision.HelperRoot | Should -Be 'C:\repo\develop-clean'
    $decision.Message | Should -Match 'clean develop helper checkout'
  }

  It 'falls back to the caller checkout when only dirty develop helpers exist' {
    $decision = & $script:DecisionModule {
      Get-BootstrapHelperRootDecision `
        -CurrentBranch 'issue/1744-router-refresh' `
        -CurrentRepoRoot 'C:\repo\issue-1744' `
        -DevelopWorktreeRoots @(
          [pscustomobject]@{ Root = 'C:\repo\develop-dirty'; IsClean = $false }
        )
    }

    $decision.Action | Should -Be 'use-current-root'
    $decision.HelperRoot | Should -Be 'C:\repo\issue-1744'
    $decision.Message | Should -Match 'only dirty develop helper'
  }

  It 'delegates away from a dirty develop root when a clean helper exists' {
    $decision = & $script:DecisionModule {
      Get-BootstrapHelperRootDecision `
        -CurrentBranch 'develop' `
        -CurrentRepoRoot 'C:\repo\develop-dirty' `
        -DevelopWorktreeRoots @(
          [pscustomobject]@{ Root = 'C:\repo\develop-dirty'; IsClean = $false },
          [pscustomobject]@{ Root = 'C:\repo\develop-clean'; IsClean = $true }
        )
    }

    $decision.Action | Should -Be 'delegate-clean-develop-worktree'
    $decision.HelperRoot | Should -Be 'C:\repo\develop-clean'
    $decision.Message | Should -Match 'dirty; using clean develop helper'
  }
}
