Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'GitHubIntake.psm1' {
  BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'tools' 'GitHubIntake.psm1'
    Import-Module $modulePath -Force
  }

  It 'normalizes epic issue titles into PR titles and appends the issue number' {
    Resolve-PullRequestTitle -Issue 875 -IssueTitle 'Epic: modernize the GitHub intake layer for future agents' |
      Should -Be 'Modernize the GitHub intake layer for future agents (#875)'
  }

  It 'does not duplicate an existing issue suffix in the PR title' {
    Resolve-PullRequestTitle -Issue 875 -IssueTitle 'Modernize the GitHub intake layer for future agents (#875)' |
      Should -Be 'Modernize the GitHub intake layer for future agents (#875)'
  }

  It 'normalizes priority and epic prefixes when resolving a PR title' {
    Resolve-PullRequestTitle -Issue 875 -IssueTitle '[P1] Epic: modernize the GitHub intake layer for future agents' |
      Should -Be 'Modernize the GitHub intake layer for future agents (#875)'
  }

  It 'normalizes priority prefixes without an epic prefix when resolving a PR title' {
    Resolve-PullRequestTitle -Issue 875 -IssueTitle '[P2] modernize the GitHub intake layer for future agents' |
      Should -Be 'Modernize the GitHub intake layer for future agents (#875)'
  }

  It 'preserves the current issue branch when the issue title changes' {
    Resolve-IssueBranchName `
      -Number 875 `
      -Title 'Epic: modernize the GitHub intake layer for future agents' `
      -CurrentBranch 'issue/875-modernize-github-intake-layer' |
      Should -Be 'issue/875-modernize-github-intake-layer'
  }

  It 'normalizes epic prefixes when generating a new branch slug' {
    Resolve-IssueBranchName -Number 875 -Title 'Epic: modernize the GitHub intake layer for future agents' |
      Should -Be 'issue/875-modernize-the-github-intake-layer-for-future-agents'
  }
}
