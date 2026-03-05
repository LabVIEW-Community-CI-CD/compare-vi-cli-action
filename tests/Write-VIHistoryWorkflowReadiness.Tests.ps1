#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-VIHistoryWorkflowReadiness.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ReadinessScript = Join-Path $repoRoot 'tools' 'Write-VIHistoryWorkflowReadiness.ps1'
    if (-not (Test-Path -LiteralPath $script:ReadinessScript -PathType Leaf)) {
      throw "Write-VIHistoryWorkflowReadiness.ps1 not found at $script:ReadinessScript"
    }
  }

  It 'writes envelope with explicit lane lifecycle metadata and markdown columns' {
    $work = Join-Path $TestDrive 'workflow-readiness-explicit'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jsonPath = Join-Path $work 'vi-history-workflow-readiness.json'
    $mdPath = Join-Path $work 'vi-history-workflow-readiness.md'

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -WindowsLaneStatus success `
      -LinuxLaneStatus failure `
      -WindowsDiffDetected true `
      -LinuxDiffDetected false `
      -WindowsFailureClass none `
      -LinuxFailureClass preflight `
      -WindowsLaneStopClass completed `
      -LinuxLaneStopClass hard-stop `
      -WindowsLaneStopReason lane-complete `
      -LinuxLaneStopReason runtime-determinism-hard-stop `
      -WindowsLaneStartStep windows-runtime-preflight `
      -WindowsLaneEndStep windows-container-probe `
      -LinuxLaneStartStep linux-runtime-preflight `
      -LinuxLaneEndStep linux-runtime-preflight `
      -LinuxLaneHardStopTriggered true `
      -ResultsRoot $work `
      -SummaryPath 'D:\tmp\summary.json' `
      -LinuxSmokeSummaryPath 'D:\tmp\linux-smoke-summary.json' `
      -WindowsRuntimeSnapshotPath 'D:\tmp\windows-runtime.json' `
      -LinuxRuntimeSnapshotPath 'D:\tmp\linux-runtime.json' `
      -RunUrl 'https://example.invalid/run/123' `
      -PrNumber '42' `
      -OutputJsonPath $jsonPath `
      -OutputMarkdownPath $mdPath `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    Test-Path -LiteralPath $jsonPath | Should -BeTrue
    Test-Path -LiteralPath $mdPath | Should -BeTrue

    $envelope = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 10
    $envelope.schema | Should -Be 'vi-history/workflow-readiness@v1'
    $envelope.verdict | Should -Be 'not-ready'
    $envelope.recommendation | Should -Be 'hold'
    $envelope.pullRequestNumber | Should -Be '42'
    $envelope.lanes.windows.status | Should -Be 'success'
    $envelope.lanes.windows.diffDetected | Should -BeTrue
    $envelope.lanes.windows.failureClass | Should -Be 'none'
    $envelope.lanes.windows.stopClass | Should -Be 'completed'
    $envelope.lanes.windows.stopReason | Should -Be 'lane-complete'
    $envelope.lanes.linux.status | Should -Be 'failure'
    $envelope.lanes.linux.diffDetected | Should -BeFalse
    $envelope.lanes.linux.failureClass | Should -Be 'preflight'
    $envelope.lanes.linux.stopClass | Should -Be 'hard-stop'
    $envelope.lanes.linux.stopReason | Should -Be 'runtime-determinism-hard-stop'
    $envelope.laneLifecycle.windows.startStep | Should -Be 'windows-runtime-preflight'
    $envelope.laneLifecycle.windows.endStep | Should -Be 'windows-container-probe'
    $envelope.laneLifecycle.linux.startStep | Should -Be 'linux-runtime-preflight'
    $envelope.laneLifecycle.linux.endStep | Should -Be 'linux-runtime-preflight'
    $envelope.laneLifecycle.linux.hardStopTriggered | Should -BeTrue

    $markdown = Get-Content -LiteralPath $mdPath -Raw
    $markdown | Should -Match '\| Lane \| Status \| Diff Detected \| Failure Class \| Stop Class \| Start Step \| End Step \| Runtime Snapshot \| Summary \|'
    $markdown | Should -Match '\| windows \| `success` \| `True` \| `none` \|'
    $markdown | Should -Match '\| linux \| `failure` \| `False` \| `preflight` \| `hard-stop` \|'
    $markdown | Should -Match '\| \| \| \| \| stop reason \| runtime-determinism-hard-stop \|'
  }

  It 'applies fallback failure classes when not provided' {
    $work = Join-Path $TestDrive 'workflow-readiness-fallback'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jsonPath = Join-Path $work 'vi-history-workflow-readiness.json'
    $mdPath = Join-Path $work 'vi-history-workflow-readiness.md'

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -WindowsLaneStatus failure `
      -LinuxLaneStatus success `
      -ResultsRoot $work `
      -OutputJsonPath $jsonPath `
      -OutputMarkdownPath $mdPath `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $envelope = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 10
    $envelope.verdict | Should -Be 'not-ready'
    $envelope.lanes.windows.failureClass | Should -Be 'cli/tool'
    $envelope.lanes.windows.diffDetected | Should -BeFalse
    $envelope.lanes.windows.stopClass | Should -Be 'failure'
    $envelope.laneLifecycle.windows.stopReason | Should -Match 'lane-failed'
    $envelope.lanes.linux.failureClass | Should -Be 'none'
    $envelope.lanes.linux.diffDetected | Should -BeFalse
    $envelope.lanes.linux.stopClass | Should -Be 'completed'
  }

  It 'normalizes lane statuses and bool-like diff flags' {
    $work = Join-Path $TestDrive 'workflow-readiness-normalize'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jsonPath = Join-Path $work 'vi-history-workflow-readiness.json'
    $mdPath = Join-Path $work 'vi-history-workflow-readiness.md'

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -WindowsLaneStatus OK `
      -LinuxLaneStatus FAILED `
      -WindowsDiffDetected yes `
      -LinuxDiffDetected off `
      -WindowsFailureClass NONE `
      -LinuxFailureClass CLI/Tool `
      -ResultsRoot $work `
      -OutputJsonPath $jsonPath `
      -OutputMarkdownPath $mdPath `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $envelope = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 10
    $envelope.lanes.windows.status | Should -Be 'success'
    $envelope.lanes.linux.status | Should -Be 'failure'
    $envelope.lanes.windows.diffDetected | Should -BeTrue
    $envelope.lanes.linux.diffDetected | Should -BeFalse
    $envelope.lanes.windows.failureClass | Should -Be 'none'
    $envelope.lanes.linux.failureClass | Should -Be 'cli/tool'
    $envelope.lanes.windows.stopClass | Should -Be 'completed'
    $envelope.lanes.linux.stopClass | Should -Be 'failure'
  }

  It 'marks ready only when both lanes are success' {
    $work = Join-Path $TestDrive 'workflow-readiness-ready'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jsonPath = Join-Path $work 'vi-history-workflow-readiness.json'
    $mdPath = Join-Path $work 'vi-history-workflow-readiness.md'

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -WindowsLaneStatus success `
      -LinuxLaneStatus success `
      -ResultsRoot $work `
      -OutputJsonPath $jsonPath `
      -OutputMarkdownPath $mdPath `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $envelope = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 10
    $envelope.verdict | Should -Be 'ready'
    $envelope.recommendation | Should -Be 'proceed'
    $envelope.laneLifecycle.windows.stopClass | Should -Be 'completed'
    $envelope.laneLifecycle.linux.stopClass | Should -Be 'completed'
  }

  It 'imports lane lifecycle from fast-loop readiness artifact when explicit values are not provided' {
    $work = Join-Path $TestDrive 'workflow-readiness-fastloop-import'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jsonPath = Join-Path $work 'vi-history-workflow-readiness.json'
    $mdPath = Join-Path $work 'vi-history-workflow-readiness.md'
    $fastLoopPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'

    ([ordered]@{
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      laneLifecycle = [ordered]@{
        windows = [ordered]@{
          stopClass = 'completed'
          stopReason = 'lane-complete'
          startStep = 'windows-runtime-preflight'
          endStep = 'windows-container-probe'
          started = $true
          completed = $true
          totalPlannedSteps = 2
          executedSteps = 2
        }
        linux = [ordered]@{
          stopClass = 'blocked'
          stopReason = 'Runtime determinism check failed at step windows-runtime-preflight'
          startStep = ''
          endStep = ''
          started = $false
          completed = $false
          totalPlannedSteps = 3
          executedSteps = 0
        }
      }
    } | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $fastLoopPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -WindowsLaneStatus success `
      -LinuxLaneStatus failure `
      -LinuxFailureClass runtime-determinism `
      -FastLoopReadinessPath $fastLoopPath `
      -ResultsRoot $work `
      -OutputJsonPath $jsonPath `
      -OutputMarkdownPath $mdPath `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $envelope = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 12
    $envelope.source.fastLoopReadinessPath | Should -Be $fastLoopPath
    $envelope.laneLifecycle.windows.startStep | Should -Be 'windows-runtime-preflight'
    $envelope.laneLifecycle.windows.endStep | Should -Be 'windows-container-probe'
    $envelope.laneLifecycle.linux.stopClass | Should -Be 'blocked'
    $envelope.laneLifecycle.linux.stopReason | Should -Match 'Runtime determinism'
    $envelope.lanes.linux.stopClass | Should -Be 'blocked'
  }

  It 'writes GitHub output keys and appends step summary markdown' {
    $work = Join-Path $TestDrive 'workflow-readiness-output-contract'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $jsonPath = Join-Path $work 'vi-history-workflow-readiness.json'
    $mdPath = Join-Path $work 'vi-history-workflow-readiness.md'
    $ghOut = Join-Path $work 'github-output.txt'
    $stepSummary = Join-Path $work 'step-summary.md'

    $output = & pwsh -NoLogo -NoProfile -File $script:ReadinessScript `
      -WindowsLaneStatus success `
      -LinuxLaneStatus success `
      -WindowsDiffDetected true `
      -LinuxDiffDetected true `
      -WindowsFailureClass none `
      -LinuxFailureClass none `
      -ResultsRoot $work `
      -OutputJsonPath $jsonPath `
      -OutputMarkdownPath $mdPath `
      -GitHubOutputPath $ghOut `
      -StepSummaryPath $stepSummary 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    Test-Path -LiteralPath $ghOut | Should -BeTrue
    Test-Path -LiteralPath $stepSummary | Should -BeTrue

    $outText = Get-Content -LiteralPath $ghOut -Raw
    $outText | Should -Match 'workflow-readiness-json-path='
    $outText | Should -Match 'workflow-readiness-markdown-path='
    $outText | Should -Match 'workflow-readiness-verdict='
    $outText | Should -Match 'workflow-readiness-recommendation='

    $stepText = Get-Content -LiteralPath $stepSummary -Raw
    $stepText | Should -Match '### VI History Workflow Readiness'
    $stepText | Should -Match '\| Lane \| Status \| Diff Detected \| Failure Class \| Stop Class \|'
  }
}
