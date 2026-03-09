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

  It 'supports fork-qualified issue branches without breaking current-branch reuse' {
    Resolve-IssueBranchName `
      -Number 875 `
      -Title 'Epic: modernize the GitHub intake layer for future agents' `
      -CurrentBranch 'issue/personal-875-modernize-github-intake-layer' `
      -ForkRemote 'personal' |
      Should -Be 'issue/personal-875-modernize-github-intake-layer'
  }

  It 'generates fork-qualified issue branches when a fork remote is supplied' {
    Resolve-IssueBranchName `
      -Number 875 `
      -Title 'Epic: modernize the GitHub intake layer for future agents' `
      -ForkRemote 'origin' |
      Should -Be 'issue/origin-875-modernize-the-github-intake-layer-for-future-agents'
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
    $route.executionKind | Should -Be 'gh-issue-create'
    $route.execution.labelSource | Should -Be 'issue-template'
  }

  It 'resolves human-pr intake to the human-change PR template' {
    $route = Resolve-GitHubIntakeRoute -Scenario 'human-pr'

    $route.routeType | Should -Be 'pull-request-template'
    $route.targetKey | Should -Be 'human-change'
    $route.targetPath | Should -Be '.github/PULL_REQUEST_TEMPLATE/human-change.md'
    $route.helperPath | Should -Be 'tools/New-GitHubIntakeDraft.ps1'
    $route.executeCommand | Should -Be 'node tools/npm/run-script.mjs priority:pr -- --issue <number> --repo <owner/repo> --branch <branch> --base <base> --title "<title>" --body-file pr-body.md'
    $route.executionKind | Should -Be 'priority-pr-create'
    $route.execution.branchSource | Should -Be 'current-or-input'
  }

  It 'normalizes legacy gh-pr-create execution kinds to the priority helper contract' {
    $catalogPath = Join-Path $TestDrive 'github-intake-catalog.json'
    @'
{
  "schema": "github-intake/catalog@v1",
  "issueTemplates": [],
  "pullRequestTemplates": [
    {
      "key": "human-change",
      "path": ".github/PULL_REQUEST_TEMPLATE/human-change.md",
      "templateLabel": "human-change",
      "metadataMode": "human",
      "summary": "Human-authored PR template."
    }
  ],
  "contactLinks": [],
  "routes": [
    {
      "scenario": "legacy-human-pr",
      "routeType": "pull-request-template",
      "targetKey": "human-change",
      "helperPath": "tools/New-GitHubIntakeDraft.ps1",
      "command": "pwsh -File tools/New-GitHubIntakeDraft.ps1 -Scenario legacy-human-pr -OutputPath pr-body.md",
      "executeCommand": "gh pr create --title \"<title>\" --body-file pr-body.md",
      "execution": {
        "kind": "gh-pr-create",
        "titleSource": "issue-derived",
        "bodySource": "draft-output",
        "baseSource": "input-or-default",
        "branchSource": "current-or-input",
        "issueSource": "input-or-snapshot"
      },
      "summary": "Legacy route."
    }
  ]
}
'@ | Set-Content -LiteralPath $catalogPath -Encoding utf8

    $previous = $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH
    try {
      $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH = $catalogPath
      $route = Resolve-GitHubIntakeRoute -Scenario 'legacy-human-pr'
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_CATALOG_PATH = $previous
      }
    }

    $route.executionKind | Should -Be 'priority-pr-create'
    $route.execution.kind | Should -Be 'priority-pr-create'
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

  It 'falls back to GitHub issue lookup when no local snapshot exists for an explicit issue' {
    Mock -ModuleName GitHubIntake Resolve-GitHubIssueSnapshotFromGitHub {
      param([int]$Issue)
      [pscustomobject]@{
        number = $Issue
        title  = 'Live catalog issue'
        url    = 'https://example.test/issues/963'
        labels = @('enhancement')
      }
    }

    $snapshotDir = Join-Path $TestDrive 'missing-issue-dir'
    $previous = $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR
    try {
      $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $snapshotDir
      $snapshot = Resolve-GitHubIssueSnapshot -Issue 963
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $previous
      }
    }

    $snapshot.number | Should -Be 963
    $snapshot.title | Should -Be 'Live catalog issue'
    Should -Invoke Resolve-GitHubIssueSnapshotFromGitHub -ModuleName GitHubIntake -Times 1 -Exactly
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
    (@($report.routes | Where-Object { $_.executionKind -eq 'branch-orchestrator' })).Count | Should -BeGreaterThan 0
  }

  It 'renders atlas markdown from the report' {
    $report = New-GitHubIntakeAtlasReport -GeneratedAtUtc '2026-03-09T00:00:00Z'
    $markdown = ConvertTo-GitHubIntakeAtlasMarkdown -Report $report

    $markdown | Should -Match '# GitHub Intake Atlas'
    $markdown | Should -Match '## Scenario Routes'
    $markdown | Should -Match '\| automation-pr \| pull-request-template \| `default` \| `branch-orchestrator` \|'
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

  It 'treats label objects from live snapshots as standing-priority markers' {
    Mock -ModuleName GitHubIntake Resolve-GitHubIssueSnapshot {
      [pscustomobject]@{
        number = 963
        title  = 'Live GH issue'
        url    = 'https://example.test/issues/963'
        labels = @([pscustomobject]@{ name = 'standing-priority' })
      }
    }

    $context = Resolve-GitHubIntakeDraftContext -Scenario 'human-pr' -Issue 963 -CurrentBranch 'issue/963-org-owned-fork-pr-helper'

    $context.issueTitle | Should -Be 'Live GH issue'
    $context.issueUrl | Should -Be 'https://example.test/issues/963'
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

  It 'builds an execution plan for workflow-policy issue intake that requires a title' {
    $plan = New-GitHubIntakeExecutionPlan -Scenario 'workflow-policy'

    $plan.schema | Should -Be 'github-intake/execution-plan@v1'
    $plan.execution.kind | Should -Be 'gh-issue-create'
    $plan.execution.labels | Should -Contain 'enhancement'
    $plan.requirements.titleRequired | Should -BeTrue
    $plan.requirements.canApply | Should -BeFalse
    $plan.requirements.missing | Should -Contain 'title'
    $plan.draft.outputPath | Should -Be 'issue-body.md'
  }

  It 'quotes whitespace and embedded quotes in the execution display command' {
    $plan = New-GitHubIntakeExecutionPlan -Scenario 'workflow-policy' -Title 'Say "hello" now'

    $plan.execution.displayCommand | Should -Match ([regex]::Escape("--title 'Say ""hello"" now'"))
  }

  It 'builds a branch-orchestrator plan for workflow-policy PR intake from snapshot context' {
    $snapshotDir = Join-Path $TestDrive 'issue'
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    '{"number":923,"title":"Execution planner issue","url":"https://example.test/issues/923","labels":["standing-priority"]}' |
      Set-Content -LiteralPath (Join-Path $snapshotDir '923.json') -Encoding utf8

    $previous = $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR
    try {
      $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $snapshotDir
      $plan = New-GitHubIntakeExecutionPlan -Scenario 'workflow-policy-pr' -Issue 923 -CurrentBranch 'issue/923-work'
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $previous
      }
    }

    $plan.execution.kind | Should -Be 'branch-orchestrator'
    $plan.execution.pullRequestTemplate | Should -Be 'workflow-policy'
    $plan.execution.title | Should -Be 'Execution planner issue (#923)'
    $plan.draft.writeOnApply | Should -BeFalse
    $plan.requirements.issueRequired | Should -BeTrue
    $plan.requirements.canApply | Should -BeTrue
  }
}
