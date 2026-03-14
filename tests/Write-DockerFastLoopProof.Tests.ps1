#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-DockerFastLoopProof.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ProofScript = Join-Path $repoRoot 'tools' 'Write-DockerFastLoopProof.ps1'
    if (-not (Test-Path -LiteralPath $script:ProofScript -PathType Leaf)) {
      throw "Write-DockerFastLoopProof.ps1 not found at $script:ProofScript"
    }
  }

  It 'writes proof with readiness-derived classification aggregates and hashes' {
    $work = Join-Path $TestDrive 'proof-readiness'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $summaryPath = Join-Path $work 'docker-runtime-fastloop-20260301010101.json'
    $statusPath = Join-Path $work 'docker-runtime-fastloop-status.json'
    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'
    $hostPlaneReportPath = Join-Path $work 'labview-2026-host-plane-report.json'
    $hostPlaneSummaryPath = Join-Path $work 'labview-2026-host-plane-summary.md'

    ([ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'success'
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
      schema = 'docker-desktop-fast-loop-status@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $statusPath -Encoding utf8

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
        planes = [ordered]@{
          x64 = [ordered]@{ status = 'ready' }
          x32 = [ordered]@{ status = 'ready' }
        }
      }
      executionPolicy = [ordered]@{
        candidateParallelPairs = [ordered]@{
          pairs = @(
            [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' },
            [ordered]@{ left = 'native-labview-2026-64'; right = 'native-labview-2026-32' }
          )
        }
      }
    } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $hostPlaneReportPath -Encoding utf8
    '# LabVIEW 2026 Host Plane Summary' | Set-Content -LiteralPath $hostPlaneSummaryPath -Encoding utf8

    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'ready-to-push'
      recommendation = 'push'
      diffStepCount = 3
      diffEvidenceSteps = 2
      diffLaneCount = 2
      extractedReportCount = 2
      containerExportFailureCount = 0
      runtimeFailureCount = 0
      toolFailureCount = 0
      hardStopTriggered = $false
      hardStopReason = ''
      runtimeManagerTransitionCount = 2
      runtimeManagerDaemonUnavailableCount = 1
      runtimeManagerParseDefectCount = 0
      runtimeManager = [ordered]@{
        schema = 'docker-fast-loop/runtime-manager@v1'
        transitionCount = 2
        daemonUnavailableCount = 1
        parseDefectCount = 0
      }
      source = [ordered]@{
        summaryPath = $summaryPath
        statusPath = $statusPath
        hostPlaneReportPath = $hostPlaneReportPath
        hostPlaneSummaryPath = $hostPlaneSummaryPath
      }
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
      }
      laneLifecycle = [ordered]@{
        windows = [ordered]@{
          status = 'success'
          stopClass = 'completed'
          stopReason = 'lane-complete'
          startStep = 'windows-runtime-preflight'
          endStep = 'windows-container-probe'
        }
        linux = [ordered]@{
          status = 'success'
          stopClass = 'completed'
          stopReason = 'lane-complete'
          startStep = 'linux-runtime-preflight'
          endStep = 'linux-container-probe'
        }
      }
      lanes = [ordered]@{
        windows = [ordered]@{ status = 'success'; diffDetected = $true; failureClass = 'none' }
        linux = [ordered]@{ status = 'success'; diffDetected = $true; failureClass = 'none' }
      }
      hostPlanes = [ordered]@{
        x64 = [ordered]@{ status = 'ready' }
        x32 = [ordered]@{ status = 'ready' }
      }
      hostExecutionPolicy = [ordered]@{
        candidateParallelPairs = [ordered]@{
          pairs = @(
            [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' },
            [ordered]@{ left = 'native-labview-2026-64'; right = 'native-labview-2026-32' }
          )
        }
      }
    } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -SummaryPath $summaryPath `
      -StatusPath $statusPath `
      -OutputPath $proofPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    Test-Path -LiteralPath $proofPath | Should -BeTrue

    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -Depth 16
    $proof.schema | Should -Be 'vi-history/docker-fast-loop-proof@v1'
    $proof.verdict | Should -Be 'ready-to-push'
    $proof.recommendation | Should -Be 'push'
    $proof.diffStepCount | Should -Be 3
    $proof.diffEvidenceSteps | Should -Be 2
    $proof.diffLaneCount | Should -Be 2
    $proof.extractedReportCount | Should -Be 2
    $proof.containerExportFailureCount | Should -Be 0
    $proof.runtimeFailureCount | Should -Be 0
    $proof.toolFailureCount | Should -Be 0
    $proof.hardStopTriggered | Should -BeFalse
    $proof.runtimeManagerTransitionCount | Should -Be 2
    $proof.runtimeManagerDaemonUnavailableCount | Should -Be 1
    $proof.runtimeManagerParseDefectCount | Should -Be 0
    $proof.runtimeManager.transitionCount | Should -Be 2
    $proof.hostPlaneReportPath | Should -Match 'labview-2026-host-plane-report\.json'
    $proof.hostPlaneSummaryPath | Should -Match 'labview-2026-host-plane-summary\.md'
    $proof.hostPlaneProvenance.status | Should -Be 'ok'
    $proof.hostPlaneSummaryProvenance.status | Should -Be 'ok'
    $proof.hostPlane.runner.hostIsRunner | Should -BeTrue
    $proof.hostPlane.runner.runnerName | Should -Be 'GHOST'
    $proof.hostPlanes.x64.status | Should -Be 'ready'
    $proof.hostExecutionPolicy.candidateParallelPairs.pairs.Count | Should -Be 2
    $proof.hashes.readinessSha256 | Should -Not -BeNullOrEmpty
    $proof.hashes.summarySha256 | Should -Not -BeNullOrEmpty
    $proof.hashes.statusSha256 | Should -Not -BeNullOrEmpty
    $proof.hashes.hostPlaneReportSha256 | Should -Not -BeNullOrEmpty
    $proof.hashes.hostPlaneSummarySha256 | Should -Not -BeNullOrEmpty
    $proof.lanes.windows.diffDetected | Should -BeTrue
    $proof.laneLifecycle.windows.stopClass | Should -Be 'completed'
    $proof.laneLifecycle.windows.startStep | Should -Be 'windows-runtime-preflight'
  }

  It 'falls back to summary aggregates when readiness omits additive fields' {
    $work = Join-Path $TestDrive 'proof-summary-fallback'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $summaryPath = Join-Path $work 'docker-runtime-fastloop-20260301020202.json'
    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'

    ([ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'failure'
      diffStepCount = 1
      diffEvidenceSteps = 1
      diffLaneCount = 1
      extractedReportCount = 1
      containerExportFailureCount = 1
      runtimeFailureCount = 1
      toolFailureCount = 2
      hardStopTriggered = $true
      hardStopReason = 'Runtime determinism check failed at step windows-runtime-preflight'
      runtimeManager = [ordered]@{
        schema = 'docker-fast-loop/runtime-manager@v1'
        transitionCount = 4
        daemonUnavailableCount = 1
        parseDefectCount = 1
      }
      laneLifecycle = [ordered]@{
        windows = [ordered]@{
          status = 'failure'
          stopClass = 'hard-stop'
          stopReason = 'Runtime determinism check failed at step windows-runtime-preflight'
        }
        linux = [ordered]@{
          status = 'blocked'
          stopClass = 'blocked'
          stopReason = 'Runtime determinism check failed at step windows-runtime-preflight'
        }
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $summaryPath -Encoding utf8

    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'not-ready'
      recommendation = 'do-not-push'
      source = [ordered]@{
        summaryPath = $summaryPath
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -OutputPath $proofPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    Test-Path -LiteralPath $proofPath | Should -BeTrue

    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -Depth 16
    $proof.verdict | Should -Be 'not-ready'
    $proof.recommendation | Should -Be 'do-not-push'
    $proof.diffStepCount | Should -Be 1
    $proof.diffEvidenceSteps | Should -Be 1
    $proof.diffLaneCount | Should -Be 1
    $proof.extractedReportCount | Should -Be 1
    $proof.containerExportFailureCount | Should -Be 1
    $proof.runtimeFailureCount | Should -Be 1
    $proof.toolFailureCount | Should -Be 2
    $proof.hardStopTriggered | Should -BeTrue
    $proof.hardStopReason | Should -Match 'Runtime determinism'
    $proof.runtimeManagerTransitionCount | Should -Be 4
    $proof.runtimeManagerDaemonUnavailableCount | Should -Be 1
    $proof.runtimeManagerParseDefectCount | Should -Be 1
    $proof.runtimeManager.transitionCount | Should -Be 4
    $proof.laneLifecycle.windows.stopClass | Should -Be 'hard-stop'
    $proof.laneLifecycle.linux.stopClass | Should -Be 'blocked'
  }

  It 'keeps optional hashes null when summary/status files are unavailable' {
    $work = Join-Path $TestDrive 'proof-missing-source-files'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'

    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'ready-to-push'
      recommendation = 'push'
      source = [ordered]@{
        summaryPath = (Join-Path $work 'missing-summary.json')
        statusPath = (Join-Path $work 'missing-status.json')
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -OutputPath $proofPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -Depth 16
    $proof.verdict | Should -Be 'not-ready'
    $proof.recommendation | Should -Be 'do-not-push'
    $proof.hashes.readinessSha256 | Should -Not -BeNullOrEmpty
    $proof.hashes.summarySha256 | Should -Be $null
    $proof.hashes.statusSha256 | Should -Be $null
    $proof.hashes.hostPlaneReportSha256 | Should -Be $null
    $proof.hashes.hostPlaneSummarySha256 | Should -Be $null
    $proof.hostPlaneProvenance.status | Should -Be 'missing'
    $proof.hostPlaneProvenance.reason | Should -Be 'host-plane-provenance-missing'
    $proof.hostPlaneSummaryProvenance.status | Should -Be 'not-present'
  }

  It 'fails closed when host-plane report provenance is declared but unreadable' {
    $work = Join-Path $TestDrive 'proof-missing-host-plane-report'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'
    $missingHostPlaneReport = Join-Path $work 'missing-host-plane-report.json'

    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'ready-to-push'
      recommendation = 'push'
      source = [ordered]@{
        hostPlaneReportPath = $missingHostPlaneReport
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -OutputPath $proofPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -Depth 16
    $proof.verdict | Should -Be 'not-ready'
    $proof.recommendation | Should -Be 'do-not-push'
    $proof.hostPlaneProvenance.status | Should -Be 'corrupt'
    $proof.hostPlaneProvenance.reason | Should -Be 'host-plane-report-missing'
    $proof.hostPlaneReportPath | Should -Match 'missing-host-plane-report\.json'
    $proof.hashes.hostPlaneReportSha256 | Should -Be $null
  }

  It 'fails closed when a declared host-plane summary artifact is unreadable' {
    $work = Join-Path $TestDrive 'proof-missing-host-plane-summary'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'
    $declaredSummaryPath = Join-Path $work 'labview-2026-host-plane-summary.md'

    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'ready-to-push'
      recommendation = 'push'
      source = [ordered]@{
        hostPlaneSummaryPath = $declaredSummaryPath
      }
      hostPlaneSummary = [ordered]@{
        path = $declaredSummaryPath
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -OutputPath $proofPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -Depth 16
    $proof.verdict | Should -Be 'not-ready'
    $proof.recommendation | Should -Be 'do-not-push'
    $proof.hostPlaneSummaryPath | Should -Match 'labview-2026-host-plane-summary\.md'
    $proof.hostPlaneSummaryProvenance.status | Should -Be 'corrupt'
    $proof.hostPlaneSummaryProvenance.reason | Should -Be 'host-plane-summary-missing'
    $proof.hashes.hostPlaneSummarySha256 | Should -Be $null
  }

  It 'writes GitHub output path for proof artifact' {
    $work = Join-Path $TestDrive 'proof-github-output'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $summaryPath = Join-Path $work 'docker-runtime-fastloop-20260301070707.json'
    $statusPath = Join-Path $work 'docker-runtime-fastloop-status.json'
    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'
    $ghOut = Join-Path $work 'github-output.txt'
    $hostPlaneReportPath = Join-Path $work 'labview-2026-host-plane-report.json'
    $hostPlaneSummaryPath = Join-Path $work 'labview-2026-host-plane-summary.md'

    ([ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'success'
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
      schema = 'docker-desktop-fast-loop-status@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $statusPath -Encoding utf8
    ([ordered]@{
      schema = 'labview-2026-host-plane-report@v1'
      runner = [ordered]@{
        hostIsRunner = $true
        runnerName = 'GHOST'
      }
      native = [ordered]@{
        planes = [ordered]@{
          x64 = [ordered]@{ status = 'ready' }
          x32 = [ordered]@{ status = 'ready' }
        }
      }
      executionPolicy = [ordered]@{
        candidateParallelPairs = [ordered]@{
          pairs = @(
            [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' }
          )
        }
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $hostPlaneReportPath -Encoding utf8
    '# LabVIEW 2026 Host Plane Summary' | Set-Content -LiteralPath $hostPlaneSummaryPath -Encoding utf8
    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'ready-to-push'
      recommendation = 'push'
      source = [ordered]@{
        summaryPath = $summaryPath
        statusPath = $statusPath
        hostPlaneReportPath = $hostPlaneReportPath
        hostPlaneSummaryPath = $hostPlaneSummaryPath
      }
      hostPlane = [ordered]@{
        runner = [ordered]@{
          hostIsRunner = $true
          runnerName = 'GHOST'
        }
      }
      hostPlanes = [ordered]@{
        x64 = [ordered]@{ status = 'ready' }
        x32 = [ordered]@{ status = 'ready' }
      }
      hostExecutionPolicy = [ordered]@{
        candidateParallelPairs = [ordered]@{
          pairs = @(
            [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' }
          )
        }
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -OutputPath $proofPath `
      -GitHubOutputPath $ghOut 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    Test-Path -LiteralPath $ghOut | Should -BeTrue
    $outText = Get-Content -LiteralPath $ghOut -Raw
    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -Depth 16
    $outText | Should -Match 'docker-fast-loop-proof-path='
    $outText | Should -Match ('docker-fast-loop-proof-host-plane-summary-path={0}' -f [regex]::Escape($hostPlaneSummaryPath))
    $outText | Should -Match ('docker-fast-loop-proof-host-plane-summary-sha256={0}' -f [regex]::Escape([string]$proof.hashes.hostPlaneSummarySha256))
  }

  It 'writes host-plane summary provenance into the step summary surface' {
    $work = Join-Path $TestDrive 'proof-step-summary'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $summaryPath = Join-Path $work 'docker-runtime-fastloop-20260301080808.json'
    $statusPath = Join-Path $work 'docker-runtime-fastloop-status.json'
    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'
    $stepSummaryPath = Join-Path $work 'step-summary.md'
    $hostPlaneReportPath = Join-Path $work 'labview-2026-host-plane-report.json'
    $hostPlaneSummaryPath = Join-Path $work 'labview-2026-host-plane-summary.md'

    ([ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'success'
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $summaryPath -Encoding utf8
    ([ordered]@{
      schema = 'docker-desktop-fast-loop-status@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $statusPath -Encoding utf8
    ([ordered]@{
      schema = 'labview-2026-host-plane-report@v1'
      runner = [ordered]@{
        hostIsRunner = $true
        runnerName = 'GHOST'
      }
      native = [ordered]@{
        planes = [ordered]@{
          x64 = [ordered]@{ status = 'ready' }
          x32 = [ordered]@{ status = 'ready' }
        }
      }
      executionPolicy = [ordered]@{
        candidateParallelPairs = [ordered]@{
          pairs = @(
            [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' }
          )
        }
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $hostPlaneReportPath -Encoding utf8
    '# LabVIEW 2026 Host Plane Summary' | Set-Content -LiteralPath $hostPlaneSummaryPath -Encoding utf8
    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'ready-to-push'
      recommendation = 'push'
      source = [ordered]@{
        summaryPath = $summaryPath
        statusPath = $statusPath
        hostPlaneReportPath = $hostPlaneReportPath
        hostPlaneSummaryPath = $hostPlaneSummaryPath
      }
      hostPlane = [ordered]@{
        runner = [ordered]@{
          hostIsRunner = $true
          runnerName = 'GHOST'
        }
      }
      hostPlanes = [ordered]@{
        x64 = [ordered]@{ status = 'ready' }
        x32 = [ordered]@{ status = 'ready' }
      }
      hostExecutionPolicy = [ordered]@{
        candidateParallelPairs = [ordered]@{
          pairs = @(
            [ordered]@{ left = 'docker-desktop/windows-container-2026'; right = 'native-labview-2026-64' }
          )
        }
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -OutputPath $proofPath `
      -GitHubOutputPath '' `
      -StepSummaryPath $stepSummaryPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -Depth 16
    $stepSummary = Get-Content -LiteralPath $stepSummaryPath -Raw
    $stepSummary | Should -Match '### Docker Fast Loop Proof'
    $stepSummary | Should -Match ('- Proof: `'+ [regex]::Escape($proofPath) + '`')
    $stepSummary | Should -Match ('- Host Plane Summary: `'+ [regex]::Escape($hostPlaneSummaryPath) + '`')
    $stepSummary | Should -Match '- Host Plane Summary Status: `ok`'
    $stepSummary | Should -Match ('- Host Plane Summary SHA-256: `'+ [regex]::Escape([string]$proof.hashes.hostPlaneSummarySha256) + '`')
  }

  It 'writes fail-closed host-plane summary reason into the step summary surface' {
    $work = Join-Path $TestDrive 'proof-step-summary-missing-host-summary'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'
    $stepSummaryPath = Join-Path $work 'step-summary.md'
    $declaredSummaryPath = Join-Path $work 'labview-2026-host-plane-summary.md'

    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'ready-to-push'
      recommendation = 'push'
      source = [ordered]@{
        hostPlaneSummaryPath = $declaredSummaryPath
      }
      hostPlaneSummary = [ordered]@{
        path = $declaredSummaryPath
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -OutputPath $proofPath `
      -GitHubOutputPath '' `
      -StepSummaryPath $stepSummaryPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $stepSummary = Get-Content -LiteralPath $stepSummaryPath -Raw
    $stepSummary | Should -Match '- Verdict: `not-ready`'
    $stepSummary | Should -Match '- Recommendation: `do-not-push`'
    $stepSummary | Should -Match ('- Host Plane Summary: `'+ [regex]::Escape($declaredSummaryPath) + '`')
    $stepSummary | Should -Match '- Host Plane Summary Status: `corrupt`'
    $stepSummary | Should -Match '- Host Plane Summary Reason: `host-plane-summary-missing`'
  }
}
