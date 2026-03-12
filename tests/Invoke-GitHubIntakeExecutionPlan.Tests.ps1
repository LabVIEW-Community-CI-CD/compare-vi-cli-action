Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-GitHubIntakeExecutionPlan' {
  BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'tools' 'GitHubIntake.psm1') -Force
  }

  It 'dispatches issue-create plans through the draft renderer and native invoker' {
    $plan = New-GitHubIntakeExecutionPlan `
      -Scenario workflow-policy `
      -Title 'GitHub Intake: execution planner' `
      -DraftOutputPath (Join-Path $TestDrive 'issue-body.md')

    $calls = [System.Collections.Generic.List[object]]::new()
    $result = Invoke-GitHubIntakeExecutionPlan `
      -Plan $plan `
      -DraftRenderer {
        param([hashtable]$DraftParameters)
        $calls.Add([pscustomobject]@{ kind = 'draft'; outputPath = $DraftParameters.OutputPath; scenario = $DraftParameters.Scenario }) | Out-Null
        Set-Content -LiteralPath $DraftParameters.OutputPath -Value '# issue draft' -NoNewline
        return $DraftParameters.OutputPath
      } `
      -NativeInvoker {
        param([string]$FilePath, [string[]]$Arguments)
        $calls.Add([pscustomobject]@{ kind = 'native'; filePath = $FilePath; arguments = @($Arguments) }) | Out-Null
        return 'https://example.test/issues/923'
      }

    $result.executionKind | Should -Be 'gh-issue-create'
    $result.draftWritten | Should -BeTrue
    $calls.Count | Should -Be 2
    $calls[0].kind | Should -Be 'draft'
    $calls[1].kind | Should -Be 'native'
    $calls[1].filePath | Should -Be 'gh'
    $calls[1].arguments | Should -Contain '--title'
    $calls[1].arguments | Should -Contain 'GitHub Intake: execution planner'
    $calls[1].arguments | Should -Contain '--label'
  }

  It 'dispatches branch-orchestrator plans without writing a draft first' {
    $plan = New-GitHubIntakeExecutionPlan `
      -Scenario workflow-policy-pr `
      -Issue 923 `
      -IssueTitle 'Execution planner issue' `
      -CurrentBranch 'issue/923-work' `
      -ForkRemote 'origin' `
      -HeadRemote 'personal'

    $state = [pscustomobject]@{
      DraftCalled = $false
      Invocation  = $null
    }
    $result = Invoke-GitHubIntakeExecutionPlan `
      -Plan $plan `
      -DraftRenderer {
        param([hashtable]$DraftParameters)
        $state.DraftCalled = $true
        return $DraftParameters.OutputPath
      } `
      -BranchOrchestratorInvoker {
        param([hashtable]$Parameters)
        $state.Invocation = [pscustomobject]$Parameters
        return 'branch orchestrator invoked'
      }

    $result.executionKind | Should -Be 'branch-orchestrator'
    $result.draftWritten | Should -BeFalse
    $result.commandFilePath | Should -Match 'Branch-Orchestrator\.ps1$'
    $result.arguments | Should -Contain '-Issue'
    $result.arguments | Should -Contain '-PRTemplate'
    $result.arguments | Should -Contain '-ForkRemote'
    $result.arguments | Should -Contain 'origin'
    $result.arguments | Should -Contain '-HeadRemote'
    $result.arguments | Should -Contain 'personal'
    $state.DraftCalled | Should -BeFalse
    $state.Invocation.Issue | Should -Be 923
    $state.Invocation.Execute | Should -BeTrue
    $state.Invocation.PRTemplate | Should -Be 'workflow-policy'
    $state.Invocation.ForkRemote | Should -Be 'origin'
    $state.Invocation.HeadRemote | Should -Be 'personal'
  }

  It 'dispatches priority-pr-create plans through node after rendering the draft' {
    $plan = New-GitHubIntakeExecutionPlan `
      -Scenario human-pr `
      -Issue 963 `
      -IssueTitle 'Support org-owned fork PR creation without upstream mirroring' `
      -Branch 'issue/963-org-owned-fork-pr-helper' `
      -HeadRemote 'origin' `
      -DraftOutputPath (Join-Path $TestDrive 'pr-body.md')

    $calls = [System.Collections.Generic.List[object]]::new()
    $result = Invoke-GitHubIntakeExecutionPlan `
      -Plan $plan `
      -DraftRenderer {
        param([hashtable]$DraftParameters)
        $calls.Add([pscustomobject]@{ kind = 'draft'; outputPath = $DraftParameters.OutputPath; scenario = $DraftParameters.Scenario }) | Out-Null
        Set-Content -LiteralPath $DraftParameters.OutputPath -Value '# pr draft' -NoNewline
        return $DraftParameters.OutputPath
      } `
      -NativeInvoker {
        param([string]$FilePath, [string[]]$Arguments)
        $calls.Add([pscustomobject]@{ kind = 'native'; filePath = $FilePath; arguments = @($Arguments) }) | Out-Null
        return 'https://example.test/pull/963'
      }

    $result.executionKind | Should -Be 'priority-pr-create'
    $result.draftWritten | Should -BeTrue
    $result.commandFilePath | Should -Be 'node'
    $calls.Count | Should -Be 2
    $calls[0].kind | Should -Be 'draft'
    $calls[1].kind | Should -Be 'native'
    $calls[1].filePath | Should -Be 'node'
    $calls[1].arguments | Should -Contain 'tools/npm/run-script.mjs'
    $calls[1].arguments | Should -Contain 'priority:pr'
    $calls[1].arguments | Should -Contain '--issue'
    $calls[1].arguments | Should -Contain '963'
    $calls[1].arguments | Should -Contain '--branch'
    $calls[1].arguments | Should -Contain 'issue/963-org-owned-fork-pr-helper'
    $calls[1].arguments | Should -Contain '--head-remote'
    $calls[1].arguments | Should -Contain 'origin'
    $calls[1].arguments | Should -Contain '--body-file'
  }

  It 'refuses to apply a plan with missing required inputs' {
    $plan = New-GitHubIntakeExecutionPlan -Scenario bug

    { Invoke-GitHubIntakeExecutionPlan -Plan $plan } |
      Should -Throw '*missing required inputs*title*'
  }
}
