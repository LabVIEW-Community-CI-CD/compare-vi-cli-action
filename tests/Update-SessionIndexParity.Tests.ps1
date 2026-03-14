#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Update-SessionIndexParity.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'Update-SessionIndexParity.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Update-SessionIndexParity.ps1 not found: $script:ToolPath"
    }
  }

  It 'injects parity telemetry into session-index and appends step summary' {
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    $sessionIndexPath = Join-Path $resultsDir 'session-index.json'
    $sessionIndex = [ordered]@{
      schema = 'session-index/v1'
      status = 'ok'
      runContext = [ordered]@{}
    }
    ($sessionIndex | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $sessionIndexPath -Encoding utf8

    $parityPath = Join-Path $resultsDir 'origin-upstream-parity.json'
    $parity = [ordered]@{
      schema = 'origin-upstream-parity@v1'
      status = 'ok'
      generatedAt = '2026-03-03T00:00:00Z'
      baseRef = 'upstream/develop'
      headRef = 'origin/develop'
      planeTransition = [ordered]@{
        from = 'upstream'
        to = 'origin'
        action = 'sync'
        via = 'priority:develop:sync'
        baseRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        headRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      }
      tipDiff = [ordered]@{
        fileCount = 0
      }
      treeParity = [ordered]@{
        equal = $true
        status = 'equal'
      }
      historyParity = [ordered]@{
        equal = $false
        status = 'diverged'
      }
      recommendation = [ordered]@{
        code = 'history-diverged-tree-equal'
        summary = 'Tree aligned, history diverged.'
      }
      commitDivergence = [ordered]@{
        baseOnly = 33
        headOnly = 126
      }
    }
    ($parity | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $parityPath -Encoding utf8

    $summaryPath = Join-Path $resultsDir 'summary.md'
    New-Item -ItemType File -Path $summaryPath -Force | Out-Null

    $resultPath = & $script:ToolPath `
      -ResultsDir $resultsDir `
      -ParityReportPath $parityPath `
      -StepSummaryPath $summaryPath

    [string]$resultPath | Should -Be $sessionIndexPath

    $updated = Get-Content -LiteralPath $sessionIndexPath -Raw | ConvertFrom-Json -Depth 30
    $updated.runContext.parity.status | Should -Be 'ok'
    $updated.runContext.parity.tipDiff.fileCount | Should -Be 0
    $updated.runContext.parity.treeParity.status | Should -Be 'equal'
    $updated.runContext.parity.historyParity.status | Should -Be 'diverged'
    $updated.runContext.parity.recommendation.code | Should -Be 'history-diverged-tree-equal'
    $updated.runContext.parity.commitDivergence.baseOnly | Should -Be 33
    $updated.runContext.parity.commitDivergence.headOnly | Should -Be 126
    $updated.runContext.parity.reportPath | Should -Be $parityPath
    $updated.runContext.parity.planeTransition.from | Should -Be 'upstream'
    $updated.runContext.parity.planeTransition.to | Should -Be 'origin'
    $updated.runContext.parity.planeTransition.via | Should -Be 'priority:develop:sync'

    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match 'Origin/Upstream Parity Telemetry'
    $summary | Should -Match 'Tree Parity \| equal'
    $summary | Should -Match 'History Parity \| diverged'
    $summary | Should -Match 'Plane Transition \| upstream->origin \(priority:develop:sync\)'
    $summary | Should -Match 'Tip Diff File Count \| 0'
    $summary | Should -Match 'Commit Divergence \(base-only/head-only\) \| 33/126'
    $summary | Should -Match 'Recommendation \| history-diverged-tree-equal'
  }

  It 'writes unavailable parity telemetry when report is missing' {
    $resultsDir = Join-Path $TestDrive 'missing'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    $sessionIndexPath = Join-Path $resultsDir 'session-index.json'
    $sessionIndex = [ordered]@{
      schema = 'session-index/v1'
      status = 'ok'
    }
    ($sessionIndex | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $sessionIndexPath -Encoding utf8

    & $script:ToolPath -ResultsDir $resultsDir -ParityReportPath (Join-Path $resultsDir 'does-not-exist.json') | Out-Null

    $updated = Get-Content -LiteralPath $sessionIndexPath -Raw | ConvertFrom-Json -Depth 30
    $updated.runContext.parity.status | Should -Be 'unavailable'
    $updated.runContext.parity.reason | Should -Be 'report-missing'
  }

  It 'fails closed when an ok parity report omits plane transition evidence' {
    $resultsDir = Join-Path $TestDrive 'missing-plane-transition'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    $sessionIndexPath = Join-Path $resultsDir 'session-index.json'
    [ordered]@{
      schema = 'session-index/v1'
      status = 'ok'
      runContext = [ordered]@{}
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sessionIndexPath -Encoding utf8

    $parityPath = Join-Path $resultsDir 'origin-upstream-parity.json'
    [ordered]@{
      schema = 'origin-upstream-parity@v1'
      status = 'ok'
      generatedAt = '2026-03-03T00:00:00Z'
      baseRef = 'upstream/develop'
      headRef = 'origin/develop'
      tipDiff = [ordered]@{ fileCount = 0 }
      treeParity = [ordered]@{ equal = $true; status = 'equal' }
      historyParity = [ordered]@{ equal = $true; status = 'equal' }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parityPath -Encoding utf8

    & $script:ToolPath -ResultsDir $resultsDir -ParityReportPath $parityPath | Out-Null

    $updated = Get-Content -LiteralPath $sessionIndexPath -Raw | ConvertFrom-Json -Depth 30
    $updated.runContext.parity.status | Should -Be 'fail'
    $updated.runContext.parity.reason | Should -Match 'missing-plane-transition'
    $updated.runContext.parity.planeTransition | Should -Be $null
  }

  It 'does not throw when session-index is missing and IgnoreMissingSessionIndex is enabled' {
    $resultsDir = Join-Path $TestDrive 'ignore'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    {
      & $script:ToolPath -ResultsDir $resultsDir -IgnoreMissingSessionIndex
    } | Should -Not -Throw
  }
}
