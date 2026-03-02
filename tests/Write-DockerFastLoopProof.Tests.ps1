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
      source = [ordered]@{
        summaryPath = $summaryPath
        statusPath = $statusPath
      }
      lanes = [ordered]@{
        windows = [ordered]@{ status = 'success'; diffDetected = $true; failureClass = 'none' }
        linux = [ordered]@{ status = 'success'; diffDetected = $true; failureClass = 'none' }
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
    $proof.hashes.readinessSha256 | Should -Not -BeNullOrEmpty
    $proof.hashes.summarySha256 | Should -Not -BeNullOrEmpty
    $proof.hashes.statusSha256 | Should -Not -BeNullOrEmpty
    $proof.lanes.windows.diffDetected | Should -BeTrue
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
    $proof.hashes.readinessSha256 | Should -Not -BeNullOrEmpty
    $proof.hashes.summarySha256 | Should -Be $null
    $proof.hashes.statusSha256 | Should -Be $null
  }

  It 'writes GitHub output path for proof artifact' {
    $work = Join-Path $TestDrive 'proof-github-output'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $summaryPath = Join-Path $work 'docker-runtime-fastloop-20260301070707.json'
    $statusPath = Join-Path $work 'docker-runtime-fastloop-status.json'
    $readinessPath = Join-Path $work 'docker-runtime-fastloop-readiness.json'
    $proofPath = Join-Path $work 'docker-fast-loop-proof.json'
    $ghOut = Join-Path $work 'github-output.txt'

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
      schema = 'vi-history/docker-fast-loop-readiness@v1'
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      verdict = 'ready-to-push'
      recommendation = 'push'
      source = [ordered]@{
        summaryPath = $summaryPath
        statusPath = $statusPath
      }
    } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $readinessPath -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ReadinessPath $readinessPath `
      -OutputPath $proofPath `
      -GitHubOutputPath $ghOut 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    Test-Path -LiteralPath $ghOut | Should -BeTrue
    $outText = Get-Content -LiteralPath $ghOut -Raw
    $outText | Should -Match 'docker-fast-loop-proof-path='
  }
}
