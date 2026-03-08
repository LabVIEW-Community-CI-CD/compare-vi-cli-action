Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'New-IssueBody.ps1' {
  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'New-IssueBody.ps1'
  }

  It 'renders the feature-program intake body with context preamble' {
    $body = & $scriptPath -Template feature-program -StandingPriority -RelatedIssues '#875, #876'

    $bodyText = [string]$body
    $bodyText | Should -Match '## Intake Context'
    $bodyText | Should -Match 'Standing priority at draft time: Yes'
    $bodyText | Should -Match 'Related issues or repos: #875, #876'
    $bodyText | Should -Match '## Acceptance criteria'
    $bodyText | Should -Match '## Evidence expectations'
  }

  It 'renders the workflow-policy-agent-ux template headings' {
    $body = & $scriptPath -Template workflow-policy-agent-ux

    $bodyText = [string]$body
    $bodyText | Should -Match '## Affected contracts'
    $bodyText | Should -Match '## Validation and rollback'
    $bodyText | Should -Match '## Reviewer focus'
  }

  It 'writes the investigation template to disk when requested' {
    $outputPath = Join-Path $TestDrive 'issue-body.md'

    & $scriptPath -Template investigation-anomaly -OutputPath $outputPath

    Test-Path -LiteralPath $outputPath | Should -BeTrue
    (Get-Content -LiteralPath $outputPath -Raw) | Should -Match '## Working hypotheses and next steps'
  }
}
