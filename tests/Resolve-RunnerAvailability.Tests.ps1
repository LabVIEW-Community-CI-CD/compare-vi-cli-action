#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Resolve-RunnerAvailability.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'Resolve-RunnerAvailability.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Resolve-RunnerAvailability.ps1 not found: $script:ToolPath"
    }
  }

  It 'reports available when an online matching runner exists' {
    $work = Join-Path $TestDrive 'available'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $payloadPath = Join-Path $work 'runners.json'
    $payload = [ordered]@{
      total_count = 2
      runners = @(
        [ordered]@{
          id = 24
          name = 'GHOST-comparevi-org-main'
          os = 'Windows'
          status = 'online'
          busy = $false
          labels = @('self-hosted', 'Windows', 'X64', 'hosted-docker-windows')
        },
        [ordered]@{
          id = 25
          name = 'linux-runner'
          os = 'Linux'
          status = 'online'
          busy = $false
          labels = @('self-hosted', 'linux')
        }
      )
    }
    ($payload | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $payloadPath -Encoding utf8

    $outputJsonPath = Join-Path $work 'runner-plan.json'
    $githubOutputPath = Join-Path $work 'github-output.txt'
    $stepSummaryPath = Join-Path $work 'step-summary.md'

    {
      & $script:ToolPath `
        -Repository 'owner/repo' `
        -RequiredLabel 'hosted-docker-windows' `
        -RequiredOs 'Windows' `
        -RunnersPayloadPath $payloadPath `
        -OutputJsonPath $outputJsonPath `
        -GitHubOutputPath $githubOutputPath `
        -StepSummaryPath $stepSummaryPath
    } | Should -Not -Throw

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.schema | Should -Be 'runner-availability-plan@v1'
    $json.status | Should -Be 'available'
    $json.available | Should -BeTrue
    $json.skipReason | Should -Be ''
    $json.onlineMatchingRunnerCount | Should -Be 1
    @($json.onlineMatchingRunners | ForEach-Object { $_.name }) | Should -Contain 'GHOST-comparevi-org-main'

    $ghOutput = Get-Content -LiteralPath $githubOutputPath -Raw
    $ghOutput | Should -Match 'available=true'
    $ghOutput | Should -Match 'status=available'
    $ghOutput | Should -Match 'online_matching_runner_count=1'

    $summary = Get-Content -LiteralPath $stepSummaryPath -Raw
    $summary | Should -Match '### Self-Hosted Runner Availability'
    $summary | Should -Match 'status: `available`'
  }

  It 'reports unavailable when only offline matching runners exist' {
    $work = Join-Path $TestDrive 'offline'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $payloadPath = Join-Path $work 'runners.json'
    $payload = [ordered]@{
      total_count = 1
      runners = @(
        [ordered]@{
          id = 24
          name = 'GHOST-comparevi-org-main'
          os = 'Windows'
          status = 'offline'
          busy = $false
          labels = @('self-hosted', 'Windows', 'X64', 'hosted-docker-windows')
        }
      )
    }
    ($payload | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $payloadPath -Encoding utf8

    $outputJsonPath = Join-Path $work 'runner-plan.json'

    {
      & $script:ToolPath `
        -Repository 'owner/repo' `
        -RequiredLabel 'hosted-docker-windows' `
        -RequiredOs 'Windows' `
        -RunnersPayloadPath $payloadPath `
        -OutputJsonPath $outputJsonPath
    } | Should -Not -Throw

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.status | Should -Be 'unavailable'
    $json.available | Should -BeFalse
    $json.skipReason | Should -Be 'runner-unavailable'
    $json.failureClass | Should -Be 'runner-unavailable'
    $json.matchingRunnerCount | Should -Be 1
    $json.onlineMatchingRunnerCount | Should -Be 0
  }

  It 'classifies 403 payload failures without throwing' {
    $work = Join-Path $TestDrive 'api-permission'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $payloadPath = Join-Path $work 'runners.json'
    $payload = [ordered]@{
      status = 403
      message = 'Resource not accessible by integration'
    }
    ($payload | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $payloadPath -Encoding utf8

    $outputJsonPath = Join-Path $work 'runner-plan.json'

    {
      & $script:ToolPath `
        -Repository 'owner/repo' `
        -RequiredLabel 'hosted-docker-windows' `
        -RequiredOs 'Windows' `
        -RunnersPayloadPath $payloadPath `
        -OutputJsonPath $outputJsonPath
    } | Should -Not -Throw

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.status | Should -Be 'error'
    $json.available | Should -BeFalse
    $json.failureClass | Should -Be 'api-permission'
    $json.skipReason | Should -Be 'runner-availability-api-permission'
    $json.failureMessage | Should -Match 'Resource not accessible'
  }
}

