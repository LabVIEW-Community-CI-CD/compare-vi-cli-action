#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-HealthSnapshot.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'priority' 'Write-HealthSnapshot.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Write-HealthSnapshot.ps1 not found: $script:ToolPath"
    }
  }

  It 'records explicit plane-transition evidence in the health snapshot' {
    $resultsDir = Join-Path $TestDrive 'results'
    $outputDir = Join-Path $TestDrive 'out'
    $parityPath = Join-Path $outputDir 'origin-upstream-parity.json'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

    $sessionIndex = [ordered]@{
      schema = 'session-index/v1'
      branchProtection = [ordered]@{
        result = [ordered]@{
          status = 'ok'
        }
      }
    }
    ($sessionIndex | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Encoding utf8

    $parity = [ordered]@{
      schema = 'origin-upstream-parity@v1'
      status = 'ok'
      baseRef = 'upstream/develop'
      headRef = 'origin/develop'
      tipDiff = [ordered]@{
        fileCount = 0
      }
      treeParity = [ordered]@{
        equal = $true
        status = 'equal'
      }
      recommendation = [ordered]@{
        code = 'aligned'
      }
      planeTransition = [ordered]@{
        from = 'upstream'
        to = 'origin'
        action = 'sync'
        via = 'priority:develop:sync'
        baseRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        headRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'
      }
    }
    ($parity | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $parityPath -Encoding utf8

    Push-Location -LiteralPath $script:RepoRoot
    try {
      & $script:ToolPath `
        -ResultsRoot $resultsDir `
        -OutputDir $outputDir `
        -ParityReportPath $parityPath `
        -SkipParityRefresh | Out-Null
    } finally {
      Pop-Location
    }

    $snapshot = Get-Content -LiteralPath (Join-Path $outputDir 'health-snapshot.json') -Raw | ConvertFrom-Json -Depth 30
    $snapshot.parity.verdict | Should -Be 'pass'
    $snapshot.parity.planeTransition.from | Should -Be 'upstream'
    $snapshot.parity.planeTransition.to | Should -Be 'origin'
    $snapshot.parity.planeTransition.via | Should -Be 'priority:develop:sync'

    $markdown = Get-Content -LiteralPath (Join-Path $outputDir 'health-snapshot.md') -Raw
    $markdown | Should -Match 'Plane transition: upstream->origin via priority:develop:sync'
  }

  It 'fails closed in the snapshot when plane-transition evidence is missing' {
    $resultsDir = Join-Path $TestDrive 'results-missing'
    $outputDir = Join-Path $TestDrive 'out-missing'
    $parityPath = Join-Path $outputDir 'origin-upstream-parity.json'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

    $sessionIndex = [ordered]@{
      schema = 'session-index/v1'
      branchProtection = [ordered]@{
        result = [ordered]@{
          status = 'ok'
        }
      }
    }
    ($sessionIndex | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Encoding utf8

    $parity = [ordered]@{
      schema = 'origin-upstream-parity@v1'
      status = 'ok'
      baseRef = 'upstream/develop'
      headRef = 'origin/develop'
      tipDiff = [ordered]@{
        fileCount = 0
      }
      treeParity = [ordered]@{
        equal = $true
        status = 'equal'
      }
      recommendation = [ordered]@{
        code = 'aligned'
      }
    }
    ($parity | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $parityPath -Encoding utf8

    Push-Location -LiteralPath $script:RepoRoot
    try {
      & $script:ToolPath `
        -ResultsRoot $resultsDir `
        -OutputDir $outputDir `
        -ParityReportPath $parityPath `
        -SkipParityRefresh | Out-Null
    } finally {
      Pop-Location
    }

    $snapshot = Get-Content -LiteralPath (Join-Path $outputDir 'health-snapshot.json') -Raw | ConvertFrom-Json -Depth 30
    $snapshot.parity.verdict | Should -Be 'fail'
    $snapshot.parity.planeTransition | Should -BeNullOrEmpty
    @($snapshot.degradedNotes) | Should -Contain 'Parity report is missing required plane-transition metadata.'
  }
}
