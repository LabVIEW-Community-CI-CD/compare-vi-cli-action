#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-FixtureDriftSummary.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'Write-FixtureDriftSummary.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Write-FixtureDriftSummary.ps1 not found: $script:ToolPath"
    }
  }

  BeforeEach {
    $script:SummaryPath = Join-Path $TestDrive 'step-summary.md'
    $env:GITHUB_STEP_SUMMARY = $script:SummaryPath
  }

  AfterEach {
    Remove-Item Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
  }

  It 'renders docker runtime manager details when context file is present' {
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    $driftSummary = [ordered]@{
      summaryCounts = [ordered]@{
        passed = 3
        failed = 0
      }
      notes = @('fixture drift ok')
    }
    ($driftSummary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $resultsDir 'drift-summary.json') -Encoding utf8

    $dockerContext = [ordered]@{
      manager = [ordered]@{
        status = 'success'
        startContext = 'desktop-windows'
        finalContext = 'desktop-windows'
        windowsImageDigest = 'sha256:windowsdigest'
        linuxImageDigest = 'sha256:linuxdigest'
        summaryPath = 'results/fixture-drift/docker-runtime-manager.json'
      }
    }
    ($dockerContext | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $resultsDir 'docker-runtime-manager-context.json') -Encoding utf8

    & $script:ToolPath -Dir $resultsDir

    $summary = Get-Content -LiteralPath $script:SummaryPath -Raw
    $summary | Should -Match '### Fixture Drift'
    $summary | Should -Match 'Docker Runtime Manager'
    $summary | Should -Match 'Status: success'
    $summary | Should -Match 'Start Context: desktop-windows'
    $summary | Should -Match 'Windows Digest: sha256:windowsdigest'
    $summary | Should -Match 'Linux Digest: sha256:linuxdigest'
  }

  It 'emits parse-failed note when docker context file is invalid json' {
    $resultsDir = Join-Path $TestDrive 'parse-failure'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    $driftSummary = [ordered]@{
      summaryCounts = [ordered]@{
        passed = 1
      }
    }
    ($driftSummary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $resultsDir 'drift-summary.json') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $resultsDir 'docker-runtime-manager-context.json') -Value '{invalid' -Encoding utf8

    & $script:ToolPath -Dir $resultsDir

    $summary = Get-Content -LiteralPath $script:SummaryPath -Raw
    $summary | Should -Match 'Docker Runtime Manager context parse failed'
  }
}
