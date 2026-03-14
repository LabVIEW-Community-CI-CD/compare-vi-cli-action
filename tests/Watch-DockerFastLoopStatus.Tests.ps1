#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Watch-DockerFastLoopStatus.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:WatchScript = Join-Path $repoRoot 'tools' 'Watch-DockerFastLoopStatus.ps1'
    if (-not (Test-Path -LiteralPath $script:WatchScript -PathType Leaf)) {
      throw "Watch-DockerFastLoopStatus.ps1 not found at $script:WatchScript"
    }
  }

  It 'prints host-plane summary provenance when completed readiness declares it' {
    $resultsRoot = Join-Path $TestDrive 'watch-success'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-summary.json'
    $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $hostPlaneReportPath = Join-Path $resultsRoot 'labview-2026-host-plane-report.json'
    $hostPlaneSummaryPath = Join-Path $resultsRoot 'labview-2026-host-plane-summary.md'

    ([ordered]@{
        schema = 'labview-2026-host-plane-report@v1'
        runner = [ordered]@{
          hostIsRunner = $true
          runnerName = 'GHOST'
          githubActions = $false
        }
        native = [ordered]@{
          parallelLabVIEWSupported = $true
          planes = [ordered]@{
            x64 = [ordered]@{
              operatorLabel = 'native-labview-2026-64'
              status = 'ready'
              labviewPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
              cliPath = 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
              comparePath = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
            }
            x32 = [ordered]@{
              operatorLabel = 'native-labview-2026-32'
              status = 'ready'
              labviewPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
              cliPath = 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
              comparePath = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
            }
          }
        }
        executionPolicy = [ordered]@{
          mutuallyExclusivePairs = [ordered]@{
            pairs = @(
              [ordered]@{ left = 'docker-desktop/linux-container-2026'; right = 'docker-desktop/windows-container-2026' }
            )
          }
          candidateParallelPairs = [ordered]@{
            pairs = @(
              [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' },
              [ordered]@{ left = 'native-labview-2026-64'; right = 'native-labview-2026-32' }
            )
          }
        }
      } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $hostPlaneReportPath -Encoding utf8
    '# LabVIEW 2026 Host Plane Summary' | Set-Content -LiteralPath $hostPlaneSummaryPath -Encoding utf8
    '{}' | Set-Content -LiteralPath $summaryPath -Encoding utf8

    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = '2026-03-14T18:15:00Z'
        laneScope = 'windows'
        phase = 'completed'
        status = 'success'
        currentStep = ''
        completedSteps = 4
        totalSteps = 4
        percentComplete = 100
        summaryPath = $summaryPath
        telemetry = [ordered]@{
          etaSeconds = 0
          pushRecommendation = 'push'
        }
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statusPath -Encoding utf8

    ([ordered]@{
        schema = 'vi-history/docker-fast-loop-readiness@v1'
        loopLabel = 'windows-docker-fast-loop'
        verdict = 'ready'
        recommendation = 'push'
        source = [ordered]@{
          resultsRoot = $resultsRoot
          hostPlaneReportPath = $hostPlaneReportPath
          hostPlaneSummaryPath = $hostPlaneSummaryPath
        }
        hostPlaneSummary = [ordered]@{
          path = $hostPlaneSummaryPath
          status = 'ok'
          sha256 = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        }
        dockerDesktopPlanes = [ordered]@{
          laneScope = 'windows'
          loopLabel = 'windows-docker-fast-loop'
          requestedPlanes = @('docker-desktop/windows-container-2026')
          exclusiveRequired = $false
          exclusiveSatisfied = $true
          mutuallyExclusivePairCount = 1
          planes = [ordered]@{
            windows = [ordered]@{
              plane = 'docker-desktop/windows-container-2026'
              enabled = $true
              status = 'success'
              context = 'desktop-windows'
              expectedOsType = 'windows'
              observedOsType = 'windows'
            }
          }
        }
        steps = @()
      } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:WatchScript -StatusPath $statusPath -PollSeconds 1 -TimeoutSeconds 5 *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $outputText = $output -join "`n"
    $outputText | Should -Match '\[windows-docker-fast-loop\]\[status\] phase=completed status=success'
    $outputText | Should -Match '\[windows-docker-fast-loop\]\[readiness\] verdict=ready recommendation=push'
    $outputText | Should -Match '\[native-labview-2026-64\]\[host-plane\] status=ready'
    $outputText | Should -Match '\[host-plane-split\]\[summary\] .*labview-2026-host-plane-summary.md status=ok sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  }

  It 'fails closed after printing the missing host-plane summary reason' {
    $resultsRoot = Join-Path $TestDrive 'watch-missing-summary'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-summary.json'
    $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $missingSummaryPath = Join-Path $resultsRoot 'labview-2026-host-plane-summary.md'

    '{}' | Set-Content -LiteralPath $summaryPath -Encoding utf8

    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = '2026-03-14T18:16:00Z'
        laneScope = 'windows'
        phase = 'completed'
        status = 'success'
        currentStep = ''
        completedSteps = 4
        totalSteps = 4
        percentComplete = 100
        summaryPath = $summaryPath
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statusPath -Encoding utf8

    ([ordered]@{
        schema = 'vi-history/docker-fast-loop-readiness@v1'
        loopLabel = 'windows-docker-fast-loop'
        verdict = 'not-ready'
        recommendation = 'do-not-push'
        source = [ordered]@{
          resultsRoot = $resultsRoot
          hostPlaneSummaryPath = $missingSummaryPath
        }
        hostPlaneSummary = [ordered]@{
          path = $missingSummaryPath
          status = 'missing'
          reason = 'host-plane-summary-missing'
        }
        steps = @()
      } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:WatchScript -StatusPath $statusPath -PollSeconds 1 -TimeoutSeconds 5 *>&1
    $LASTEXITCODE | Should -Not -Be 0

    $outputText = $output -join "`n"
    $outputText | Should -Match '\[host-plane-split\]\[summary\] .*labview-2026-host-plane-summary.md status=missing reason=host-plane-summary-missing'
    $outputText | Should -Match 'Declared host-plane summary artifact not readable'
  }
}
