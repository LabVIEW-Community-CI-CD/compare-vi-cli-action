Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-GitHubIntakeScenario.ps1' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $script:RepoRoot 'tools' 'Invoke-GitHubIntakeScenario.ps1'
  }

  It 'emits a schema-valid dry-run plan as JSON for issue scenarios' {
    $planPath = Join-Path $TestDrive 'issue-plan.json'
    $json = & $scriptPath `
      -Scenario workflow-policy `
      -Title 'GitHub Intake: execution planner' `
      -DraftOutputPath (Join-Path $TestDrive 'issue-body.md') `
      -PlanOutputPath $planPath `
      -AsJson

    $plan = $json | ConvertFrom-Json -Depth 10
    $plan.schema | Should -Be 'github-intake/execution-plan@v1'
    $plan.execution.kind | Should -Be 'gh-issue-create'
    $plan.requirements.canApply | Should -BeTrue

    $schemaPath = Join-Path $script:RepoRoot 'docs' 'schemas' 'github-intake-execution-plan-v1.schema.json'
    $schemaValidation = & node (Join-Path $script:RepoRoot 'tools' 'npm' 'run-script.mjs') 'schema:validate' '--' '--schema' $schemaPath '--data' $planPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($schemaValidation | Out-String)
  }

  It 'hydrates PR plan context from the issue snapshot override directory' {
    $snapshotDir = Join-Path $TestDrive 'issue'
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    '{"number":923,"title":"Execution planner issue","url":"https://example.test/issues/923","labels":["standing-priority"]}' |
      Set-Content -LiteralPath (Join-Path $snapshotDir '923.json') -Encoding utf8

    $previous = $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR
    try {
      $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $snapshotDir
      $json = & $scriptPath -Scenario human-pr -Issue 923 -Branch 'issue/923-work' -AsJson
    } finally {
      if ($null -eq $previous) {
        Remove-Item Env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_GITHUB_INTAKE_SNAPSHOT_DIR = $previous
      }
    }

    $plan = $json | ConvertFrom-Json -Depth 10
    $plan.execution.kind | Should -Be 'priority-pr-create'
    $plan.execution.branch | Should -Be 'issue/923-work'
    $plan.execution.title | Should -Be 'Execution planner issue (#923)'
    $plan.requirements.canApply | Should -BeTrue
  }
}
