#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-VIHistoryLaneEvidence.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'Write-VIHistoryLaneEvidence.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Write-VIHistoryLaneEvidence.ps1 not found: $script:ToolPath"
    }
  }

  It 'projects runtime alignment and Docker-side evidence into console and step summary' {
    $work = Join-Path $TestDrive 'lane-evidence'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $runtimePath = Join-Path $work 'runtime-determinism.json'
    $capturePath = Join-Path $work 'ni-linux-container-capture.json'
    $stdoutPath = Join-Path $work 'ni-linux-container-stdout.txt'
    $stderrPath = Join-Path $work 'ni-linux-container-stderr.txt'
    $summaryPath = Join-Path $work 'step-summary.md'

    @{
      schema = 'docker-runtime-determinism@v1'
      observed = @{
        osType = 'linux'
        context = 'desktop-linux'
        dockerHost = 'unix:///var/run/docker.sock'
      }
      result = @{
        status = 'ok'
        reason = ''
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimePath -Encoding utf8

    @{
      schema = 'ni-linux-container-compare/v1'
      status = 'diff'
      gateOutcome = 'pass'
      resultClass = 'success-diff'
      reportPath = (Join-Path $work 'linux-compare-report.html')
      stdoutPath = $stdoutPath
      stderrPath = $stderrPath
      dockerContext = 'desktop-linux'
      dockerServerOs = 'linux'
      observedDockerHost = 'unix:///var/run/docker.sock'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $capturePath -Encoding utf8

    @(
      'stdout line 1'
      'stdout line 2'
    ) | Set-Content -LiteralPath $stdoutPath -Encoding utf8
    @(
      'stderr line 1'
    ) | Set-Content -LiteralPath $stderrPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ToolPath `
      -LaneName 'vi-history-scenarios-linux' `
      -RuntimeSnapshotPath $runtimePath `
      -CapturePath $capturePath `
      -StepSummaryPath $summaryPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $outputText = $output -join "`n"
    $outputText | Should -Match 'observedDockerHost=unix:///var/run/docker\.sock'
    $outputText | Should -Match 'dockerContext=desktop-linux'
    $outputText | Should -Match '\[vi-history-scenarios-linux-stdout\] stdout line 2'
    $outputText | Should -Match '\[vi-history-scenarios-linux-stderr\] stderr line 1'

    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match 'observedDockerHost: `unix:///var/run/docker\.sock`'
    $summary | Should -Match 'docker_context: `desktop-linux`'
    $summary | Should -Match 'result_class: `success-diff`'
  }

  It 'reads hosted Windows preflight receipts when compare capture is not present' {
    $work = Join-Path $TestDrive 'windows-preflight-only'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $preflightPath = Join-Path $work 'windows-ni-2026q1-host-preflight.json'
    $summaryPath = Join-Path $work 'step-summary.md'

    @{
      schema = 'comparevi/windows-host-preflight@v1'
      executionSurface = 'github-hosted-windows'
      dockerHost = 'npipe:////./pipe/docker_engine'
      contexts = @{
        final = 'default'
        finalOsType = 'windows'
      }
      runtimeDeterminism = @{
        status = 'ok'
        reason = ''
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $preflightPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ToolPath `
      -LaneName 'vi-history-scenarios-windows-preflight' `
      -PreflightPath $preflightPath `
      -StepSummaryPath $summaryPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $outputText = $output -join "`n"
    $outputText | Should -Match 'observedDockerHost=npipe:////\./pipe/docker_engine'
    $outputText | Should -Match 'dockerServerOs=windows'

    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match 'observedDockerHost: `npipe:////\./pipe/docker_engine`'
    $summary | Should -Match 'runtime_source: `preflight`'
  }
}
