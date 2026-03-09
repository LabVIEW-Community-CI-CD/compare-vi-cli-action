Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Resolve-GitHubIntakeRoute.ps1' {
  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'Resolve-GitHubIntakeRoute.ps1'
  }

  It 'lists the supported intake scenarios' {
    $routes = @(& $scriptPath -ListScenarios)

    $routes.scenario | Should -Contain 'bug'
    $routes.scenario | Should -Contain 'automation-pr'
    $routes.scenario | Should -Contain 'human-pr'
  }

  It 'emits a JSON route for automation PRs when requested' {
    $json = & $scriptPath -Scenario 'automation-pr' -AsJson
    $route = $json | ConvertFrom-Json -ErrorAction Stop

    $route.routeType | Should -Be 'pull-request-template'
    $route.targetKey | Should -Be 'default'
    $route.helperPath | Should -Be 'tools/New-GitHubIntakeDraft.ps1'
    $route.executeCommand | Should -Be 'pwsh -NoLogo -NoProfile -File tools/Branch-Orchestrator.ps1 -Issue <number> -Execute'
  }
}
