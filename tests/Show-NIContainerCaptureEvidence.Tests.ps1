Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Show-NIContainerCaptureEvidence.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ShowScript = Join-Path $repoRoot 'tools' 'Show-NIContainerCaptureEvidence.ps1'
    if (-not (Test-Path -LiteralPath $script:ShowScript -PathType Leaf)) {
      throw "Show-NIContainerCaptureEvidence.ps1 not found at $script:ShowScript"
    }
  }

  It 'prints host alignment and tailed stdout/stderr content from a capture artifact' {
    $work = Join-Path $TestDrive 'capture-evidence'
    $resultsRoot = Join-Path $work 'results'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $stdoutPath = Join-Path $resultsRoot 'ni-linux-container-stdout.txt'
    $stderrPath = Join-Path $resultsRoot 'ni-linux-container-stderr.txt'
    $capturePath = Join-Path $resultsRoot 'ni-linux-container-capture.json'

    @(
      'booting compare'
      'CreateComparisonReport completed with diff.'
    ) | Set-Content -LiteralPath $stdoutPath -Encoding utf8
    @(
      'notice: prelaunch enabled'
    ) | Set-Content -LiteralPath $stderrPath -Encoding utf8

    $capture = [ordered]@{
      schema = 'ni-linux-container-compare/v1'
      status = 'diff'
      gateOutcome = 'pass'
      resultClass = 'success-diff'
      containerName = 'ni-lnx-compare-test'
      image = 'nationalinstruments/labview:2026q1-linux'
      reportPath = (Join-Path $resultsRoot 'linux-compare-report.html')
      stdoutPath = $stdoutPath
      stderrPath = $stderrPath
      observedDockerHost = 'unix:///var/run/docker.sock'
      dockerContext = 'desktop-linux'
      dockerServerOs = 'linux'
    }
    $capture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $capturePath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ShowScript `
      -CapturePath $capturePath `
      -BasePath $resultsRoot `
      -TailLineCount 5 2>&1

    $text = $output -join "`n"
    $text | Should -Match 'observedDockerHost=unix:///var/run/docker.sock'
    $text | Should -Match 'dockerContext=desktop-linux'
    $text | Should -Match 'dockerServerOs=linux'
    $text | Should -Match 'stdout=ni-linux-container-stdout.txt'
    $text | Should -Match 'stderr=ni-linux-container-stderr.txt'
    $text | Should -Match '\[ni-container-evidence\]\[stdout\] CreateComparisonReport completed with diff.'
    $text | Should -Match '\[ni-container-evidence\]\[stderr\] notice: prelaunch enabled'
  }
}
