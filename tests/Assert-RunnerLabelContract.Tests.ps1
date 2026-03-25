#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Assert-RunnerLabelContract.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'Assert-RunnerLabelContract.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Assert-RunnerLabelContract.ps1 not found: $script:ToolPath"
    }
  }

  It 'passes when required label is present in run-jobs payload' {
    $work = Join-Path $TestDrive 'success'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jobsPayloadPath = Join-Path $work 'jobs.json'
    $payload = [ordered]@{
      jobs = @(
        [ordered]@{
          runner_name = 'host-a'
          runner_id = 42
          status = 'in_progress'
          started_at = '2026-03-02T00:00:00Z'
          labels = @('self-hosted', 'windows', 'comparevi', 'capability-ingress')
        }
      )
    }
    ($payload | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jobsPayloadPath -Encoding utf8

    $outputJsonPath = Join-Path $work 'runner-label-contract.json'
    $githubOutputPath = Join-Path $work 'github-output.txt'
    $stepSummaryPath = Join-Path $work 'step-summary.md'

    {
      & $script:ToolPath `
        -Repository 'owner/repo' `
        -RunId '100' `
        -RunnerName 'host-a' `
        -RequiredLabel 'capability-ingress' `
        -JobsPayloadPath $jobsPayloadPath `
        -OutputJsonPath $outputJsonPath `
        -GitHubOutputPath $githubOutputPath `
        -StepSummaryPath $stepSummaryPath
    } | Should -Not -Throw

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.schema | Should -Be 'runner-label-contract@v1'
    $json.validationMode | Should -Be 'run-job'
    $json.status | Should -Be 'success'
    $json.failureClass | Should -Be 'none'
    $json.hasRequiredLabel | Should -BeTrue
    $json.runnerId | Should -Be '42'
    @($json.labels) | Should -Contain 'capability-ingress'

    $ghOutput = Get-Content -LiteralPath $githubOutputPath -Raw
    $ghOutput | Should -Match 'has_required_label=true'
    $ghOutput | Should -Match 'runner_label_contract_status=success'
    $ghOutput | Should -Match 'runner_id=42'

    $summary = Get-Content -LiteralPath $stepSummaryPath -Raw
    $summary | Should -Match '### Runner Label Contract'
    $summary | Should -Match 'status: `success`'
  }

  It 'fails with missing-label class when required label is absent' {
    $work = Join-Path $TestDrive 'missing-label'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jobsPayloadPath = Join-Path $work 'jobs.json'
    $payload = [ordered]@{
      jobs = @(
        [ordered]@{
          runner_name = 'host-b'
          runner_id = 77
          status = 'completed'
          started_at = '2026-03-02T00:01:00Z'
          labels = @('self-hosted', 'windows')
        }
      )
    }
    ($payload | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jobsPayloadPath -Encoding utf8

    $outputJsonPath = Join-Path $work 'runner-label-contract.json'

    {
      & $script:ToolPath `
        -Repository 'owner/repo' `
        -RunId '101' `
        -RunnerName 'host-b' `
        -RequiredLabel 'capability-ingress' `
        -JobsPayloadPath $jobsPayloadPath `
        -OutputJsonPath $outputJsonPath
    } | Should -Throw

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.status | Should -Be 'failure'
    $json.failureClass | Should -Be 'missing-label'
    $json.failureMessage | Should -Match 'missing required label'
    $json.hasRequiredLabel | Should -BeFalse
  }

  It 'classifies 403 payload failures as api-permission' {
    $work = Join-Path $TestDrive 'api-permission'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jobsPayloadPath = Join-Path $work 'jobs.json'
    $payload = [ordered]@{
      status = 403
      message = 'Resource not accessible by integration'
    }
    ($payload | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jobsPayloadPath -Encoding utf8

    $outputJsonPath = Join-Path $work 'runner-label-contract.json'

    {
      & $script:ToolPath `
        -Repository 'owner/repo' `
        -RunId '102' `
        -RunnerName 'host-c' `
        -RequiredLabel 'capability-ingress' `
        -JobsPayloadPath $jobsPayloadPath `
        -OutputJsonPath $outputJsonPath
    } | Should -Throw

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.status | Should -Be 'failure'
    $json.failureClass | Should -Be 'api-permission'
    $json.failureMessage | Should -Match 'Resource not accessible'
  }

  It 'passes when required label is present in repository runner inventory payload' {
    $work = Join-Path $TestDrive 'inventory-success'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $runnerInventoryPath = Join-Path $work 'runners.json'
    $payload = [ordered]@{
      runners = @(
        [ordered]@{
          id = 25
          name = 'GHOST-comparevi-capability-ingress'
          status = 'online'
          labels = @(
            [ordered]@{ name = 'self-hosted' },
            [ordered]@{ name = 'windows' },
            [ordered]@{ name = 'comparevi' },
            [ordered]@{ name = 'capability-ingress' }
          )
        }
      )
    }
    ($payload | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $runnerInventoryPath -Encoding utf8

    $outputJsonPath = Join-Path $work 'runner-label-contract.json'

    {
      & $script:ToolPath `
        -Repository 'owner/repo' `
        -RunnerName 'GHOST-comparevi-capability-ingress' `
        -RequiredLabel 'capability-ingress' `
        -RunnerInventoryPath $runnerInventoryPath `
        -OutputJsonPath $outputJsonPath
    } | Should -Not -Throw

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.validationMode | Should -Be 'repository-runner'
    $json.status | Should -Be 'success'
    $json.runnerId | Should -Be '25'
    @($json.labels) | Should -Contain 'capability-ingress'
  }
}
