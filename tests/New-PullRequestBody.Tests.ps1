Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'New-PullRequestBody.ps1' {
  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'New-PullRequestBody.ps1'
  }

  It 'renders the default template with issue linkage and agent metadata' {
    $body = & $scriptPath `
      -Template default `
      -Issue 875 `
      -IssueTitle 'Epic: modernize the GitHub intake layer for future agents' `
      -IssueUrl 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/875' `
      -Base develop `
      -Branch 'issue/875-modernize-github-intake-layer' `
      -StandingPriority

    $bodyText = [string]$body
    $bodyText | Should -Match '## Issue Linkage'
    $bodyText | Should -Match '- Primary issue: #875'
    $bodyText | Should -Match 'Standing priority at PR creation: Yes'
    $bodyText | Should -Match '## Agent Metadata'
    $bodyText | Should -Match '## Validation Evidence'
  }

  It 'renders the workflow policy template variant label and headings' {
    $body = & $scriptPath -Template workflow-policy -Issue 875 -Base develop -Branch 'issue/875-modernize-github-intake-layer'

    $bodyText = [string]$body
    $bodyText | Should -Match 'Template variant: `workflow-policy`'
    $bodyText | Should -Match '## Workflow and Policy Impact'
    $bodyText | Should -Match '## Rollout and Rollback'
  }

  It 'renders the human template without the agent metadata block' {
    $body = & $scriptPath -Template human-change -Issue 875

    $bodyText = [string]$body
    $bodyText | Should -Not -Match '## Agent Metadata'
    $bodyText | Should -Match '## Testing and Evidence'
  }

  It 'writes the rendered body to an output path when requested' {
    $outputPath = Join-Path $TestDrive 'pr-body.md'

    & $scriptPath -Template agent-maintenance -Issue 875 -OutputPath $outputPath

    Test-Path -LiteralPath $outputPath | Should -BeTrue
    (Get-Content -LiteralPath $outputPath -Raw) | Should -Match '## Queue and Follow-up'
  }
}
