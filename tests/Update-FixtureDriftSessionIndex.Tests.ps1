#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Update-FixtureDriftSessionIndex.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'Update-FixtureDriftSessionIndex.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Update-FixtureDriftSessionIndex.ps1 not found: $script:ToolPath"
    }
  }

  It 'persists docker manager and runner label metadata into session-index runContext' {
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    $sessionIndexPath = Join-Path $resultsDir 'session-index.json'
    $sessionIndex = [ordered]@{
      schema = 'session-index/v1'
      status = 'ok'
    }
    ($sessionIndex | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $sessionIndexPath -Encoding utf8

    $contextPath = Join-Path $resultsDir 'docker-runtime-manager-context.json'
    $context = [ordered]@{
      schema = 'fixture-drift/docker-runtime-manager-context@v1'
    }
    ($context | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $contextPath -Encoding utf8

    $resultPath = & $script:ToolPath `
      -ResultsDir $resultsDir `
      -ContextPath $contextPath `
      -RequiredLabel 'self-hosted-docker' `
      -HasRequiredLabel:$true `
      -RunnerLabelsCsv 'self-hosted,windows,self-hosted-docker' `
      -ManagerStatus 'success' `
      -ManagerSummaryPath 'results/fixture-drift/docker-runtime-manager.json' `
      -WindowsImageDigest 'sha256:windows' `
      -LinuxImageDigest 'sha256:linux' `
      -StartContext 'desktop-windows' `
      -FinalContext 'desktop-windows'

    [string]$resultPath | Should -Be $sessionIndexPath

    $updated = Get-Content -LiteralPath $sessionIndexPath -Raw | ConvertFrom-Json -Depth 30
    $updated.runContext.dockerRuntimeManager.status | Should -Be 'success'
    $updated.runContext.dockerRuntimeManager.windowsImageDigest | Should -Be 'sha256:windows'
    $updated.runContext.dockerRuntimeManager.contextArtifactPath | Should -Be $contextPath
    $updated.runContext.runnerLabelContract.requiredLabel | Should -Be 'self-hosted-docker'
    $updated.runContext.runnerLabelContract.hasRequiredLabel | Should -BeTrue
    @($updated.runContext.runnerLabelContract.labels) | Should -Contain 'self-hosted-docker'
  }

  It 'does not throw when session-index is missing and IgnoreMissingSessionIndex is enabled' {
    $resultsDir = Join-Path $TestDrive 'missing'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    {
      & $script:ToolPath -ResultsDir $resultsDir -IgnoreMissingSessionIndex
    } | Should -Not -Throw
  }
}
