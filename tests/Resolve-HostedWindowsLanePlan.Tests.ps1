#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Resolve-HostedWindowsLanePlan.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'Resolve-HostedWindowsLanePlan.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Resolve-HostedWindowsLanePlan.ps1 not found: $script:ToolPath"
    }
  }

  It 'writes a portable hosted Windows plan artifact and GitHub outputs' {
    $work = Join-Path $TestDrive 'hosted-plan'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $outputJsonPath = Join-Path $work 'hosted-plan.json'
    $githubOutputPath = Join-Path $work 'github-output.txt'
    $stepSummaryPath = Join-Path $work 'step-summary.md'

    {
      & $script:ToolPath `
        -RunnerImage 'windows-2022' `
        -ContainerImage 'nationalinstruments/labview:2026q1-windows' `
        -ExpectedContext 'default' `
        -ExpectedOs 'windows' `
        -OutputJsonPath $outputJsonPath `
        -GitHubOutputPath $githubOutputPath `
        -StepSummaryPath $stepSummaryPath
    } | Should -Not -Throw

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.schema | Should -Be 'hosted-windows-lane-plan@v1'
    $json.status | Should -Be 'portable-hosted'
    $json.available | Should -BeTrue
    $json.executionModel | Should -Be 'github-hosted-windows'
    $json.runnerImage | Should -Be 'windows-2022'
    $json.expectedContext | Should -Be 'default'
    $json.expectedOs | Should -Be 'windows'
    $json.hostEngineMutationAllowed | Should -BeFalse

    $ghOutput = Get-Content -LiteralPath $githubOutputPath -Raw
    $ghOutput | Should -Match 'available=true'
    $ghOutput | Should -Match 'execution_model=github-hosted-windows'
    $ghOutput | Should -Match 'runner_image=windows-2022'

    $summary = Get-Content -LiteralPath $stepSummaryPath -Raw
    $summary | Should -Match '### Hosted Windows Lane Plan'
    $summary | Should -Match 'runner_image: `windows-2022`'
  }
}
