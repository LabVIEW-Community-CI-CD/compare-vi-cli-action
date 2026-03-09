Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-GitHubIntakeAtlas.ps1' {
  BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $script:RepoRoot 'tools' 'Write-GitHubIntakeAtlas.ps1'
  }

  It 'writes markdown and schema-valid JSON from the intake catalog' {
    $resultsRoot = Join-Path $TestDrive 'intake'
    $report = & $scriptPath -ResultsRoot $resultsRoot -PassThru

    $jsonPath = Join-Path $resultsRoot 'github-intake-atlas.json'
    $markdownPath = Join-Path $resultsRoot 'github-intake-atlas.md'

    Test-Path -LiteralPath $jsonPath | Should -BeTrue
    Test-Path -LiteralPath $markdownPath | Should -BeTrue
    $report.schema | Should -Be 'github-intake/atlas@v1'
    $report.counts.scenarios | Should -BeGreaterThan 0

    $schemaPath = Join-Path $script:RepoRoot 'docs' 'schemas' 'github-intake-atlas-v1.schema.json'
    $schemaValidation = & node (Join-Path $script:RepoRoot 'tools' 'npm' 'run-script.mjs') 'schema:validate' '--' '--schema' $schemaPath '--data' $jsonPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($schemaValidation | Out-String)

    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    $markdown | Should -Match '# GitHub Intake Atlas'
    $markdown | Should -Match '\| Scenario \| Route Type \| Target \| Execution \| Helper \| Draft Command \| Execute Command \|'
    $markdown | Should -Match '\| bug \| issue-template \| `bug-report` \| `gh-issue-create` \|'
  }
}
