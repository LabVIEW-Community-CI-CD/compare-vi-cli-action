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

  It 'loads the checked-in intake catalog with issue and PR templates' {
    $catalog = Get-GitHubIntakeCatalog

    $catalog.schema | Should -Be 'github-intake/catalog@v1'
    $catalog.issueTemplates.key | Should -Contain 'workflow-policy-agent-ux'
    $catalog.pullRequestTemplates.key | Should -Contain 'human-change'
    $catalog.routes.scenario | Should -Contain 'workflow-policy'
    $catalog.routes.scenario | Should -Contain 'human-pr'
  }

  It 'resolves workflow-policy intake to the workflow-policy issue template' {
    $route = Resolve-GitHubIntakeRoute -Scenario 'workflow-policy'

    $route.routeType | Should -Be 'issue-template'
    $route.targetKey | Should -Be 'workflow-policy-agent-ux'
    $route.targetPath | Should -Be '.github/ISSUE_TEMPLATE/03-workflow-policy-agent-ux.yml'
    $route.helperPath | Should -Be 'tools/New-GitHubIntakeDraft.ps1'
  }

  It 'resolves human-pr intake to the human-change PR template' {
    $route = Resolve-GitHubIntakeRoute -Scenario 'human-pr'

    $route.routeType | Should -Be 'pull-request-template'
    $route.targetKey | Should -Be 'human-change'
    $route.targetPath | Should -Be '.github/PULL_REQUEST_TEMPLATE/human-change.md'
    $route.helperPath | Should -Be 'tools/New-GitHubIntakeDraft.ps1'
    $route.executeCommand | Should -Be 'gh pr create --title "<title>" --body-file pr-body.md'
  }

  It 'resolves an issue snapshot from the override directory when present' {
    $snapshotDir = Join-Path $TestDrive 'issue'
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    '{"number":921,"title":"Catalog issue","url":"https://example.test/issues/921","labels":["standing-priority"]}' |
      Set-Content -LiteralPath (Join-Path $snapshotDir '921.json') -Encoding utf8

    $previous = $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR
    try {
      $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $snapshotDir
      $snapshot = Resolve-GitHubIssueSnapshot -Issue 921
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $previous
      }
    }

    $snapshot.number | Should -Be 921
    $snapshot.title | Should -Be 'Catalog issue'
  }

  It 'loads the intake catalog from the override path when present' {
    $catalogPath = Join-Path $TestDrive 'github-intake-catalog.json'
    @'
{
  "schema": "github-intake/catalog@v1",
  "issueTemplates": [],
  "pullRequestTemplates": [
    {
      "key": "default",
      "path": ".github/pull_request_template.md",
      "templateLabel": "default-agent-template",
      "metadataMode": "agent",
      "summary": "Default automation-authored PR template."
    }
  ],
  "contactLinks": [],
  "routes": [
    {
      "scenario": "custom-pr",
      "routeType": "pull-request-template",
      "targetKey": "default",
      "helperPath": "tools/New-GitHubIntakeDraft.ps1",
      "command": "pwsh -File tools/New-GitHubIntakeDraft.ps1 -Scenario custom-pr -OutputPath pr-body.md",
      "summary": "Custom route without an execute command."
    }
  ]
}
'@ | Set-Content -LiteralPath $catalogPath -Encoding utf8

    $previous = $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH
    try {
      $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH = $catalogPath
      $catalog = Get-GitHubIntakeCatalog
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH = $previous
      }
    }

    $catalog.routes.scenario | Should -Contain 'custom-pr'
    $catalog.pullRequestTemplates.key | Should -Contain 'default'
  }

  It 'builds an atlas report from the intake catalog' {
    $report = New-GitHubIntakeAtlasReport -GeneratedAtUtc '2026-03-09T00:00:00Z'

    $report.schema | Should -Be 'github-intake/atlas@v1'
    $report.counts.issueTemplates | Should -BeGreaterThan 0
    $report.routes.scenario | Should -Contain 'automation-pr'
  }

  It 'renders atlas markdown from the report' {
    $report = New-GitHubIntakeAtlasReport -GeneratedAtUtc '2026-03-09T00:00:00Z'
    $markdown = ConvertTo-GitHubIntakeAtlasMarkdown -Report $report

    $markdown | Should -Match '# GitHub Intake Atlas'
    $markdown | Should -Match '## Scenario Routes'
    $markdown | Should -Match '\| automation-pr \| pull-request-template \|'
  }

  It 'resolves draft context for PR scenarios from snapshot and current branch' {
    $snapshotDir = Join-Path $TestDrive 'issue'
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    '{"number":921,"title":"Catalog issue","url":"https://example.test/issues/921","labels":["standing-priority"]}' |
      Set-Content -LiteralPath (Join-Path $snapshotDir '921.json') -Encoding utf8

    $previous = $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR
    try {
      $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $snapshotDir
      $context = Resolve-GitHubIntakeDraftContext -Scenario 'automation-pr' -Issue 921 -CurrentBranch 'issue/921-work'
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $previous
      }
    }

    $context.templateKey | Should -Be 'default'
    $context.issueTitle | Should -Be 'Catalog issue'
    $context.issueUrl | Should -Be 'https://example.test/issues/921'
    $context.branch | Should -Be 'issue/921-work'
    $context.standingPriority | Should -BeTrue
    $context.snapshotResolved | Should -BeTrue
  }

  It 'preserves a null execute command when the catalog route omits it' {
    $catalogPath = Join-Path $TestDrive 'github-intake-catalog.json'
    @'
{
  "schema": "github-intake/catalog@v1",
  "issueTemplates": [],
  "pullRequestTemplates": [
    {
      "key": "default",
      "path": ".github/pull_request_template.md",
      "templateLabel": "default-agent-template",
      "metadataMode": "agent",
      "summary": "Default automation-authored PR template."
    }
  ],
  "contactLinks": [],
  "routes": [
    {
      "scenario": "custom-pr",
      "routeType": "pull-request-template",
      "targetKey": "default",
      "helperPath": "tools/New-GitHubIntakeDraft.ps1",
      "command": "pwsh -File tools/New-GitHubIntakeDraft.ps1 -Scenario custom-pr -OutputPath pr-body.md",
      "summary": "Custom route without an execute command."
    }
  ]
}
'@ | Set-Content -LiteralPath $catalogPath -Encoding utf8

    $previous = $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH
    try {
      $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH = $catalogPath
      $context = Resolve-GitHubIntakeDraftContext -Scenario 'custom-pr' -CurrentBranch 'issue/921-work'
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH = $previous
      }
    }

    $context.templateKey | Should -Be 'default'
    $context.executeCommand | Should -Be $null
    $context.branch | Should -Be 'issue/921-work'
  }
}
