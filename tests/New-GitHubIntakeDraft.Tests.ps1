Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'New-GitHubIntakeDraft.ps1' {
  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'New-GitHubIntakeDraft.ps1'
  }

  It 'renders a workflow-policy issue draft from the scenario facade' {
    $body = & $scriptPath -Scenario workflow-policy

    $bodyText = [string]$body
    $bodyText | Should -Match '## Intake Context'
    $bodyText | Should -Match '## Affected contracts'
    $bodyText | Should -Match '## Validation and rollback'
  }

  It 'renders a human PR draft from the scenario facade' {
    $body = & $scriptPath -Scenario human-pr -Issue 921 -IssueTitle 'GitHub Intake: publish a machine-readable catalog and route helper for future agents'

    $bodyText = [string]$body
    $bodyText | Should -Match '## Issue Linkage'
    $bodyText | Should -Match 'Template variant: `human-change`'
    $bodyText | Should -Match '## Testing and Evidence'
    $bodyText | Should -Not -Match '## Agent Metadata'
  }

  It 'auto-populates PR draft issue metadata from the issue snapshot override directory' {
    $snapshotDir = Join-Path $TestDrive 'issue'
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    '{"number":921,"title":"Catalog issue","url":"https://example.test/issues/921","labels":["standing-priority"]}' |
      Set-Content -LiteralPath (Join-Path $snapshotDir '921.json') -Encoding utf8

    $previous = $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR
    try {
      $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $snapshotDir
      $body = & $scriptPath -Scenario automation-pr -Issue 921
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $previous
      }
    }

    $bodyText = [string]$body
    $bodyText | Should -Match 'Catalog issue'
    $bodyText | Should -Match 'https://example.test/issues/921'
    $bodyText | Should -Match 'Standing priority at PR creation: Yes'
  }
}
