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

    $summary = [ordered]@{
      schema = 'docker-desktop-fast-loop@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      status = 'success'
      hardStopTriggered = $false
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
    $readiness.diffEvidenceSteps | Should -Be 1
    $readiness.diffLaneCount | Should -Be 1
    $readiness.extractedReportCount | Should -Be 1
    $readiness.containerExportFailureCount | Should -Be 0
    $readiness.runtimeFailureCount | Should -Be 0
    $readiness.toolFailureCount | Should -Be 0
    $readiness.lanes.windows.diffDetected | Should -BeTrue
    $readiness.lanes.windows.failureClass | Should -Be 'none'
    $readiness.lanes.linux.diffDetected | Should -BeFalse
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
