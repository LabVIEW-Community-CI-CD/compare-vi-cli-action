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

  It 'projects expected required contexts from branch classes when explicit branch lists are absent' {
    $resultsDir = Join-Path $TestDrive 'results-projected'
    $outputDir = Join-Path $TestDrive 'out-projected'
    $parityPath = Join-Path $outputDir 'origin-upstream-parity.json'
    $policyPath = Join-Path $TestDrive 'branch-required-checks.json'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

    $sessionIndex = [ordered]@{
      schema = 'session-index/v1'
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
      }
    }
    ($parity | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $parityPath -Encoding utf8

    $policy = [ordered]@{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branchClassBindings = [ordered]@{
        develop = 'upstream-integration'
      }
      branchClassRequiredChecks = [ordered]@{
        'upstream-integration' = @('lint', 'session-index')
      }
    }
    ($policy | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $policyPath -Encoding utf8

    $ghTokenPrevious = $env:GH_TOKEN
    $githubTokenPrevious = $env:GITHUB_TOKEN
    try {
      Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
      Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue

      Push-Location -LiteralPath $script:RepoRoot
      try {
        & $script:ToolPath `
          -ResultsRoot $resultsDir `
          -OutputDir $outputDir `
          -ParityReportPath $parityPath `
          -Owner 'example-owner' `
          -Repository 'example-repo' `
          -BranchRequiredChecksPath $policyPath `
          -SkipParityRefresh | Out-Null
      } finally {
        Pop-Location
      }
    } finally {
      if ($null -eq $ghTokenPrevious) {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
      } else {
        $env:GH_TOKEN = $ghTokenPrevious
      }
      if ($null -eq $githubTokenPrevious) {
        Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
      } else {
        $env:GITHUB_TOKEN = $githubTokenPrevious
      }
    }

    $snapshot = Get-Content -LiteralPath (Join-Path $outputDir 'health-snapshot.json') -Raw | ConvertFrom-Json -Depth 30
    $snapshot.requiredContexts.verdict | Should -Be 'degraded'
    $snapshot.requiredContexts.source | Should -Be 'fallback'
    $snapshot.requiredContexts.expectedCount | Should -Be 2
    @($snapshot.requiredContexts.missing | Sort-Object) | Should -Be @('lint', 'session-index')
  }
}
