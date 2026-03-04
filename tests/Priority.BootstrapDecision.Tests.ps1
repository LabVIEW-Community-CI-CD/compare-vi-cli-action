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
    $decision.Action | Should Be 'noop-already-develop'
  }

  It 'skips work branches' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'issue/588-seam' -IsDirty:$false -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should Be 'skip-work-branch'
  }

  It 'retains non-bootstrap branches' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'chore/local' -IsDirty:$false -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should Be 'skip-retain-branch'
  }

  It 'skips checkout when working tree is dirty' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'main' -IsDirty:$true -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should Be 'skip-dirty'
  }

  It 'chooses remote branch creation when develop is missing locally' {
    $decision = & $script:DecisionModule {
      Get-DevelopCheckoutDecision -CurrentBranch 'main' -IsDirty:$false -HasDevelop:$false -RemoteDevelopRef @{ Remote = 'upstream'; Ref = 'upstream/develop' }
    }

    $decision.Action | Should Be 'create-develop-from-remote'
    $decision.Remote | Should Be 'upstream'
    $decision.Ref | Should Be 'upstream/develop'
  }

  It 'checks out develop when local branch exists' {
    $decision = & $script:DecisionModule { Get-DevelopCheckoutDecision -CurrentBranch 'main' -IsDirty:$false -HasDevelop:$true -RemoteDevelopRef $null }
    $decision.Action | Should Be 'checkout-develop'
  }
}
