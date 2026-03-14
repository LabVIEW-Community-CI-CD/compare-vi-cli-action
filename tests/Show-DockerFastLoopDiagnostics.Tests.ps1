#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Show-DockerFastLoopDiagnostics.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ShowScript = Join-Path $repoRoot 'tools' 'Show-DockerFastLoopDiagnostics.ps1'
    if (-not (Test-Path -LiteralPath $script:ShowScript -PathType Leaf)) {
      throw "Show-DockerFastLoopDiagnostics.ps1 not found at $script:ShowScript"
    }
  }

  It 'prints differentiated mode diagnostics from readiness artifacts' {
    $resultsRoot = Join-Path $TestDrive 'results'
    $historyRoot = Join-Path $resultsRoot 'history-scenarios'
    New-Item -ItemType Directory -Path (Join-Path $historyRoot 'attribute\container-export') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $historyRoot 'sequential\block-diagram\container-export') -Force | Out-Null
    $hostPlaneReportPath = Join-Path $resultsRoot 'labview-2026-host-plane-report.json'
    ([ordered]@{
        schema = 'labview-2026-host-plane-report@v1'
        host = [ordered]@{
          os = 'windows'
          computerName = 'GHOST'
        }
        runner = [ordered]@{
          hostIsRunner = $true
          runnerName = 'GHOST'
          githubActions = $false
        }
        docker = [ordered]@{
          operatorLabels = @('linux-docker-fast-loop', 'windows-docker-fast-loop', 'dual-docker-fast-loop')
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

    $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $readiness = [ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      historyScenarioSet = 'smoke'
      diffEvidenceSteps = 2
      extractedReportCount = 2
      dockerDesktopPlanes = [ordered]@{
        schema = 'docker-fast-loop/docker-desktop-planes@v1'
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
          linux = [ordered]@{
            plane = 'docker-desktop/linux-container-2026'
            enabled = $false
            status = 'skipped'
            context = 'desktop-linux'
            expectedOsType = 'linux'
            observedOsType = ''
          }
        }
      }
      source = [ordered]@{
        resultsRoot = $resultsRoot
        hostPlaneReportPath = $hostPlaneReportPath
      }
      steps = @(
        [ordered]@{
          name = 'windows-history-attribute'
          isDiff = $true
          diffImageCount = 6
          durationMs = 28646
          diffEvidenceSource = 'html'
          containerExportStatus = 'success'
          extractedReportPath = (Join-Path $historyRoot 'attribute\container-export\windows-compare-report.html')
          capturePath = (Join-Path $historyRoot 'attribute\ni-windows-container-capture.json')
        },
        [ordered]@{
          name = 'windows-history-sequential-block-diagram'
          isDiff = $true
          diffImageCount = 28
          durationMs = 34471
          diffEvidenceSource = 'html'
          containerExportStatus = 'success'
          extractedReportPath = (Join-Path $historyRoot 'sequential\block-diagram\container-export\windows-compare-report.html')
          capturePath = (Join-Path $historyRoot 'sequential\block-diagram\ni-windows-container-capture.json')
        }
      )
    }
    $readiness | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ShowScript -ReadinessPath $readinessPath *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $outputText = $output -join "`n"
    $outputText | Should -Match '\[native-labview-2026-64\]\[host-plane\] status=ready'
    $outputText | Should -Match '\[host-plane-split\]\[runner\] hostIsRunner=True runnerName=GHOST githubActions=False'
    $outputText | Should -Match 'candidateParallelPairs=docker-desktop/windows-container-2026\+native-labview-2026-64,native-labview-2026-64\+native-labview-2026-32'
    $outputText | Should -Match '\[windows-docker-fast-loop\]\[docker-plane\] requested=docker-desktop/windows-container-2026 exclusiveRequired=False exclusiveSatisfied=True pairCount=1'
    $outputText | Should -Match 'lane=windows plane=docker-desktop/windows-container-2026 enabled=True status=success context=desktop-windows expectedOs=windows observedOs=windows'
    $outputText | Should -Match '\[windows-docker-fast-loop\]\[diagnostics\] scenarioSet=smoke differentiatedSteps=2 evidenceSteps=2 reports=2'
    $outputText | Should -Match 'lane=windows sequence=direct mode=attribute images=6'
    $outputText | Should -Match 'report=history-scenarios\\attribute\\container-export\\windows-compare-report.html'
    $outputText | Should -Match 'lane=windows sequence=sequential mode=block-diagram images=28'
    $outputText | Should -Match 'capture=history-scenarios\\sequential\\block-diagram\\ni-windows-container-capture.json'
  }

  It 'trims space-padded history metadata before rendering differentiated diagnostics' {
    $resultsRoot = Join-Path $TestDrive 'trimmed-metadata'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $historyRoot = Join-Path $resultsRoot 'history-scenarios'
    New-Item -ItemType Directory -Path (Join-Path $historyRoot 'attribute\container-export') -Force | Out-Null
    $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    ([ordered]@{
        schema = 'vi-history/docker-fast-loop-readiness@v1'
        historyScenarioSet = ' smoke '
        source = [ordered]@{
          resultsRoot = $resultsRoot
        }
        steps = @(
          [ordered]@{
            name = ' windows-history-attribute '
            historyLane = ' windows '
            historyMode = ' attribute '
            historySequence = ' direct '
            isDiff = $true
            diffImageCount = 3
            durationMs = 1500
            diffEvidenceSource = ' html '
            containerExportStatus = ' success '
            extractedReportPath = " $(Join-Path $historyRoot 'attribute\container-export\windows-compare-report.html') "
            capturePath = " $(Join-Path $historyRoot 'attribute\ni-windows-container-capture.json') "
          }
        )
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ShowScript -ReadinessPath $readinessPath *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $outputText = $output -join "`n"
    $outputText | Should -Match '\[windows-docker-fast-loop\]\[diagnostics\] scenarioSet=smoke differentiatedSteps=1 evidenceSteps=0 reports=0'
    $outputText | Should -Match 'lane=windows sequence=direct mode=attribute images=3'
    $outputText | Should -Match 'report=history-scenarios\\attribute\\container-export\\windows-compare-report.html'
  }

  It 'prints an explicit no-diagnostics message when no history diff steps exist' {
    $resultsRoot = Join-Path $TestDrive 'no-diff'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    ([ordered]@{
        schema = 'vi-history/docker-fast-loop-readiness@v1'
        source = [ordered]@{
          resultsRoot = $resultsRoot
        }
        steps = @(
          [ordered]@{
            name = 'windows-container-probe'
            isDiff = $false
            durationMs = 100
          }
        )
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ShowScript -ReadinessPath $readinessPath *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    ($output -join "`n") | Should -Match '\[windows-docker-fast-loop\]\[diagnostics\] no differentiated history diagnostics detected'
  }
}
