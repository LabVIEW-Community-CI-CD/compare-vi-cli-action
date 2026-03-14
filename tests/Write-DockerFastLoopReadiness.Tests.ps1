#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-DockerFastLoopReadiness.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ReadinessScript = Join-Path $repoRoot 'tools' 'Write-DockerFastLoopReadiness.ps1'
    if (-not (Test-Path -LiteralPath $script:ReadinessScript -PathType Leaf)) {
      throw "Write-DockerFastLoopReadiness.ps1 not found at $script:ReadinessScript"
    }
  }

  It 'marks diff-only runs ready-to-push' {
    $resultsRoot = Join-Path $TestDrive 'ready'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-20260301010101.json'
    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'
    $hostPlaneReportPath = Join-Path $resultsRoot 'labview-2026-host-plane-report.json'
    $hostPlaneSummaryPath = Join-Path $resultsRoot 'labview-2026-host-plane-summary.md'

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      laneScope = 'both'
      status = 'success'
      hardStopTriggered = $false
      runtimeManager = [ordered]@{
        schema = 'docker-fast-loop/runtime-manager@v1'
        transitionCount = 3
        daemonUnavailableCount = 1
        parseDefectCount = 0
        probes = [ordered]@{
          windows = [ordered]@{
            enabled = $true
            status = 'success'
            context = 'desktop-windows'
            osType = 'windows'
          }
          linux = [ordered]@{
            enabled = $true
            status = 'success'
            context = 'desktop-linux'
            osType = 'linux'
          }
        }
      }
      hostPlaneReportPath = $hostPlaneReportPath
      hostPlaneSummaryPath = $hostPlaneSummaryPath
      hostPlane = [ordered]@{
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
            x64 = [ordered]@{ status = 'ready' }
            x32 = [ordered]@{ status = 'ready' }
          }
        }
        executionPolicy = [ordered]@{
          mutuallyExclusivePairs = [ordered]@{
            pairs = @(
              [ordered]@{ left = 'docker-desktop/linux-container-2026'; right = 'docker-desktop/windows-container-2026' }
            )
          }
          provenParallelPairs = [ordered]@{
            pairs = @(
              [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' }
            )
          }
          candidateParallelPairs = [ordered]@{
            pairs = @(
              [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' },
              [ordered]@{ left = 'native-labview-2026-64'; right = 'native-labview-2026-32' }
            )
          }
        }
      }
      steps = @(
        [ordered]@{
          name = 'windows-runtime-preflight'
          status = 'success'
          durationMs = 1000
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        },
        [ordered]@{
          name = 'windows-history-attribute'
          status = 'success'
          durationMs = 2000
          exitCode = 1
          resultClass = 'success-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $true
          diffEvidenceSource = 'html'
          diffImageCount = 2
          extractedReportPath = 'tests/results/local-parity/history/windows-report.html'
          containerExportStatus = 'success'
        },
        [ordered]@{
          name = 'linux-runtime-preflight'
          status = 'success'
          durationMs = 900
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        }
      )
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ($summary.hostPlane | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $hostPlaneReportPath -Encoding utf8
    '# LabVIEW 2026 Host Plane Summary' | Set-Content -LiteralPath $hostPlaneSummaryPath -Encoding utf8
    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statusPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath '' `
      -StepSummaryPath '' *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    ($output -join "`n") | Should -Match '\[dual-docker-fast-loop\]\[diagnostics\] scenarioSet=none differentiatedSteps=1 evidenceSteps=1 reports=1'
    ($output -join "`n") | Should -Match '\[dual-docker-fast-loop\]\[docker-plane\] requested=docker-desktop/windows-container-2026,docker-desktop/linux-container-2026 exclusiveRequired=True exclusiveSatisfied=True pairCount=1'
    ($output -join "`n") | Should -Match 'lane=windows plane=docker-desktop/windows-container-2026 enabled=True status=success context=desktop-windows expectedOs=windows observedOs=windows'
    ($output -join "`n") | Should -Match 'lane=windows sequence=direct mode=attribute images=2'

    $readiness = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json -Depth 16
    $readiness.loopLabel | Should -Be 'dual-docker-fast-loop'
    $readiness.verdict | Should -Be 'ready-to-push'
    $readiness.recommendation | Should -Be 'push'
    $readiness.diffStepCount | Should -Be 1
    $readiness.diffEvidenceSteps | Should -Be 1
    $readiness.diffLaneCount | Should -Be 1
    $readiness.extractedReportCount | Should -Be 1
    $readiness.containerExportFailureCount | Should -Be 0
    $readiness.runtimeFailureCount | Should -Be 0
    $readiness.toolFailureCount | Should -Be 0
    $readiness.runtimeManagerTransitionCount | Should -Be 3
    $readiness.runtimeManagerDaemonUnavailableCount | Should -Be 1
    $readiness.runtimeManagerParseDefectCount | Should -Be 0
    $readiness.runtimeManager.transitionCount | Should -Be 3
    $readiness.dockerDesktopPlanes.schema | Should -Be 'docker-fast-loop/docker-desktop-planes@v1'
    $readiness.dockerDesktopPlanes.requestedPlanes.Count | Should -Be 2
    @($readiness.dockerDesktopPlanes.requestedPlanes) | Should -Contain 'docker-desktop/windows-container-2026'
    @($readiness.dockerDesktopPlanes.requestedPlanes) | Should -Contain 'docker-desktop/linux-container-2026'
    $readiness.dockerDesktopPlanes.exclusiveRequired | Should -BeTrue
    $readiness.dockerDesktopPlanes.exclusiveSatisfied | Should -BeTrue
    $readiness.dockerDesktopPlanes.planes.windows.context | Should -Be 'desktop-windows'
    $readiness.dockerDesktopPlanes.planes.linux.context | Should -Be 'desktop-linux'
    $readiness.hostPlane.runner.hostIsRunner | Should -BeTrue
    $readiness.hostPlaneSummary.status | Should -Be 'ok'
    $readiness.hostPlaneSummary.path | Should -Be $hostPlaneSummaryPath
    $readiness.hostPlaneSummary.declared | Should -BeTrue
    $readiness.hostPlaneSummary.sha256 | Should -Not -BeNullOrEmpty
    $readiness.hostPlane.runner.runnerName | Should -Be 'GHOST'
    $readiness.hostPlane.host.os | Should -Be 'windows'
    $readiness.hostExecutionPolicy.candidateParallelPairs.pairs.Count | Should -Be 2
    $readiness.lanes.windows.diffDetected | Should -BeTrue
    $readiness.lanes.windows.failureClass | Should -Be 'none'
    $readiness.lanes.linux.diffDetected | Should -BeFalse
    $readiness.laneLifecycle.windows.status | Should -Be 'success'
    $readiness.laneLifecycle.windows.stopClass | Should -Be 'completed'
    $readiness.laneLifecycle.windows.startStep | Should -Be 'windows-runtime-preflight'
    $readiness.laneLifecycle.windows.endStep | Should -Be 'windows-history-attribute'
    $markdown = Get-Content -LiteralPath $mdOut -Raw
    $markdown | Should -Match '\| Host Is Runner \| `True` \|'
    $markdown | Should -Match '\| Host Plane Summary \| `.*labview-2026-host-plane-summary.md` \|'
    $markdown | Should -Match '\| Host Plane Summary Status \| `ok` \|'
    $markdown | Should -Match '\| Runner Name \| `GHOST` \|'
    $markdown | Should -Match '\| Mutually Exclusive Pairs \| `docker-desktop/linux-container-2026<->docker-desktop/windows-container-2026` \|'
    $markdown | Should -Match '\| Requested Docker Planes \| `docker-desktop/windows-container-2026, docker-desktop/linux-container-2026` \|'
    $markdown | Should -Match '\| Docker Exclusivity Satisfied \| `True` \|'
  }

  It 'marks tool failure runs not-ready' {
    $resultsRoot = Join-Path $TestDrive 'not-ready'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-20260301020202.json'
    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      laneScope = 'both'
      status = 'failure'
      hardStopTriggered = $false
      steps = @(
        [ordered]@{
          name = 'windows-container-probe'
          status = 'failure'
          durationMs = 1400
          exitCode = 1
          resultClass = 'failure-tool'
          gateOutcome = 'fail'
          failureClass = 'cli/tool'
          isDiff = $false
          containerExportStatus = 'failed'
        },
        [ordered]@{
          name = 'linux-runtime-preflight'
          status = 'success'
          durationMs = 900
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        }
      )
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statusPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $readiness = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json -Depth 16
    $readiness.verdict | Should -Be 'not-ready'
    $readiness.recommendation | Should -Be 'do-not-push'
    $readiness.toolFailureCount | Should -Be 1
    $readiness.containerExportFailureCount | Should -Be 1
    $readiness.runtimeFailureCount | Should -Be 0
    $readiness.lanes.windows.failureClass | Should -Be 'cli/tool'
  }

  It 'fails closed when a declared host-plane summary artifact is missing' {
    $resultsRoot = Join-Path $TestDrive 'missing-host-plane-summary'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-20260301021212.json'
    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'
    $hostPlaneReportPath = Join-Path $resultsRoot 'labview-2026-host-plane-report.json'
    $hostPlaneSummaryPath = Join-Path $resultsRoot 'labview-2026-host-plane-summary.md'

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'success'
      hostPlaneReportPath = $hostPlaneReportPath
      hostPlaneSummaryPath = $hostPlaneSummaryPath
      hostPlane = [ordered]@{
        schema = 'labview-2026-host-plane-report@v1'
        host = [ordered]@{ os = 'windows' }
        runner = [ordered]@{ hostIsRunner = $true; runnerName = 'GHOST'; githubActions = $false }
        native = [ordered]@{
          parallelLabVIEWSupported = $false
          planes = [ordered]@{
            x64 = [ordered]@{ status = 'ready' }
            x32 = [ordered]@{ status = 'missing' }
          }
        }
        executionPolicy = [ordered]@{
          candidateParallelPairs = [ordered]@{ pairs = @() }
          mutuallyExclusivePairs = [ordered]@{ pairs = @() }
        }
      }
      steps = @(
        [ordered]@{
          name = 'windows-container-probe'
          status = 'success'
          durationMs = 100
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        }
      )
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ($summary.hostPlane | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $hostPlaneReportPath -Encoding utf8
    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statusPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $readiness = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json -Depth 16
    $readiness.verdict | Should -Be 'not-ready'
    $readiness.recommendation | Should -Be 'do-not-push'
    $readiness.hostPlaneSummary.status | Should -Be 'missing'
    $readiness.hostPlaneSummary.reason | Should -Be 'declared-summary-unreadable'
    $readiness.hostPlaneSummary.declared | Should -BeTrue
    $readiness.source.hostPlaneSummaryPath | Should -Be $hostPlaneSummaryPath
  }

  It 'records a single-lane linux Docker plane projection when only the linux lane is requested' {
    $resultsRoot = Join-Path $TestDrive 'linux-plane'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-20260301030303.json'
    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      laneScope = 'linux'
      status = 'success'
      hardStopTriggered = $false
      runtimeManager = [ordered]@{
        schema = 'docker-fast-loop/runtime-manager@v1'
        transitionCount = 1
        daemonUnavailableCount = 0
        parseDefectCount = 0
        probes = [ordered]@{
          windows = [ordered]@{
            enabled = $false
            status = 'skipped'
            context = 'desktop-windows'
            osType = ''
          }
          linux = [ordered]@{
            enabled = $true
            status = 'success'
            context = 'desktop-linux'
            osType = 'linux'
          }
        }
      }
      steps = @(
        [ordered]@{
          name = 'linux-runtime-preflight'
          status = 'success'
          durationMs = 900
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        }
      )
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statusPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath '' `
      -StepSummaryPath '' *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    ($output -join "`n") | Should -Match '\[linux-docker-fast-loop\]\[docker-plane\] requested=docker-desktop/linux-container-2026 exclusiveRequired=False exclusiveSatisfied=True pairCount=0'

    $readiness = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json -Depth 16
    $readiness.loopLabel | Should -Be 'linux-docker-fast-loop'
    @($readiness.dockerDesktopPlanes.requestedPlanes) | Should -Be @('docker-desktop/linux-container-2026')
    $readiness.dockerDesktopPlanes.exclusiveRequired | Should -BeFalse
    $readiness.dockerDesktopPlanes.exclusiveSatisfied | Should -BeTrue
    $readiness.dockerDesktopPlanes.planes.linux.context | Should -Be 'desktop-linux'
    $readiness.dockerDesktopPlanes.planes.windows.enabled | Should -BeFalse
  }

  It 'marks runtime hard-stop runs not-ready with runtime failure counts' {
    $resultsRoot = Join-Path $TestDrive 'runtime-hard-stop'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-20260301030303.json'
    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'failure'
      hardStopTriggered = $true
      hardStopReason = 'Runtime determinism check failed at step windows-runtime-preflight'
      steps = @(
        [ordered]@{
          name = 'windows-runtime-preflight'
          status = 'failure'
          durationMs = 850
          exitCode = 2
          resultClass = 'failure-runtime'
          gateOutcome = 'fail'
          failureClass = 'runtime-determinism'
          isDiff = $false
        },
        [ordered]@{
          name = 'linux-runtime-preflight'
          status = 'success'
          durationMs = 700
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        }
      )
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statusPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $readiness = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json -Depth 16
    $readiness.verdict | Should -Be 'not-ready'
    $readiness.recommendation | Should -Be 'do-not-push'
    $readiness.hardStopTriggered | Should -BeTrue
    $readiness.runtimeFailureCount | Should -Be 1
    $readiness.toolFailureCount | Should -Be 0
    $readiness.lanes.windows.failureClass | Should -Be 'runtime-determinism'
    $readiness.lanes.linux.failureClass | Should -Be 'none'
    $readiness.laneLifecycle.windows.stopClass | Should -Be 'hard-stop'
    $readiness.laneLifecycle.windows.stopReason | Should -Match 'Runtime determinism'
  }

  It 'ignores unknown step lanes while preserving step rows' {
    $resultsRoot = Join-Path $TestDrive 'unknown-step-lane'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-20260301040404.json'
    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'success'
      hardStopTriggered = $false
      steps = @(
        [ordered]@{
          name = 'prepare-manifest'
          status = 'success'
          durationMs = 111
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        },
        [ordered]@{
          name = 'windows-container-probe'
          status = 'success'
          durationMs = 222
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        },
        [ordered]@{
          name = 'linux-container-probe'
          status = 'success'
          durationMs = 333
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        }
      )
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statusPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $readiness = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json -Depth 16
    $readiness.lanes.windows.total | Should -Be 1
    $readiness.lanes.linux.total | Should -Be 1
    $markdown = Get-Content -LiteralPath $mdOut -Raw
    $markdown | Should -Match '\| `prepare-manifest` \| - \|'
  }

  It 'computes readiness from classification even when summary status is failure' {
    $resultsRoot = Join-Path $TestDrive 'classification-over-status'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-20260301050505.json'
    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'failure'
      hardStopTriggered = $false
      steps = @(
        [ordered]@{
          name = 'windows-history-attribute'
          status = 'success'
          durationMs = 500
          exitCode = 1
          resultClass = 'success-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $true
        },
        [ordered]@{
          name = 'linux-container-probe'
          status = 'success'
          durationMs = 400
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        }
      )
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statusPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $readiness = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json -Depth 16
    $readiness.verdict | Should -Be 'ready-to-push'
    $readiness.recommendation | Should -Be 'push'
    $readiness.diffStepCount | Should -Be 1
    $readiness.runtimeFailureCount | Should -Be 0
    $readiness.toolFailureCount | Should -Be 0
  }

  It 'falls back to not-ready when summary json is missing' {
    $resultsRoot = Join-Path $TestDrive 'missing-summary'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    Test-Path -LiteralPath $jsonOut | Should -BeTrue
    $readiness = Get-Content -LiteralPath $jsonOut -Raw | ConvertFrom-Json -Depth 16
    $readiness.verdict | Should -Be 'not-ready'
    $readiness.recommendation | Should -Be 'do-not-push'
    $readiness.hardStopTriggered | Should -BeTrue
    $readiness.run.status | Should -Be 'missing-summary'
    $readiness.source.summaryPath | Should -Be ''
    $readiness.hardStopReason | Should -Match 'Unable to locate docker fast-loop summary json'
  }

  It 'writes GitHub outputs for readiness paths and verdict' {
    $resultsRoot = Join-Path $TestDrive 'github-output-contract'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    $summaryPath = Join-Path $resultsRoot 'docker-runtime-fastloop-20260301060606.json'
    $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
    $jsonOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    $mdOut = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.md'
    $ghOut = Join-Path $resultsRoot 'github-output.txt'

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'success'
      hardStopTriggered = $false
      steps = @(
        [ordered]@{
          name = 'windows-container-probe'
          status = 'success'
          durationMs = 100
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        },
        [ordered]@{
          name = 'linux-container-probe'
          status = 'success'
          durationMs = 100
          exitCode = 0
          resultClass = 'success-no-diff'
          gateOutcome = 'pass'
          failureClass = 'none'
          isDiff = $false
        }
      )
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
        schema = 'docker-desktop-fast-loop-status@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $statusPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -ResultsRoot $resultsRoot `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputJsonPath $jsonOut `
      -OutputMarkdownPath $mdOut `
      -GitHubOutputPath $ghOut `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    Test-Path -LiteralPath $ghOut | Should -BeTrue
    $outText = Get-Content -LiteralPath $ghOut -Raw
    $outText | Should -Match 'readiness-json-path='
    $outText | Should -Match 'readiness-markdown-path='
    $outText | Should -Match 'readiness-verdict='
    $outText | Should -Match 'readiness-recommendation='
  }
}
