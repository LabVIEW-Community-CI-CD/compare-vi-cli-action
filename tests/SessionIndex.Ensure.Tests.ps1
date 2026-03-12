Describe 'Ensure-SessionIndex' -Tag 'Unit' {
  It 'creates a fallback session-index.json with status ok from pester-summary.json' {
    # Arrange
    $td = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $td | Out-Null
    $ps = @{
      total = 2; passed = 2; failed = 0; errors = 0; skipped = 0; duration_s = 1.23; schemaVersion = '1.0.0'
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $td 'pester-summary.json') -Value $ps -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -SummaryJson 'pester-summary.json'

    # Assert
    $idxPath = Join-Path $td 'session-index.json'
    Test-Path -LiteralPath $idxPath | Should -BeTrue
    $idx = Get-Content -LiteralPath $idxPath -Raw | ConvertFrom-Json
    $idx.schema | Should -Be 'session-index/v1'
    $idx.status | Should -Be 'ok'
    $idx.includeIntegration | Should -BeFalse
    $idx.PSObject.Properties.Name | Should -Contain 'integrationMode'
    $idx.PSObject.Properties.Name | Should -Contain 'integrationSource'
    $idx.integrationMode | Should -BeNullOrEmpty
    $idx.integrationSource | Should -BeNullOrEmpty
    $idx.summary.total | Should -Be 2
    $idx.summary.passed | Should -Be 2
    $idx.summary.failed | Should -Be 0
    $idx.summary.errors | Should -Be 0
    $idx.summary.skipped | Should -Be 0
  }

  It 'emits a real session-index-v2.json from the current v1 payload instead of a sample' {
    $td = Join-Path $TestDrive 'results-v2'
    New-Item -ItemType Directory -Force -Path $td | Out-Null
    $v1 = [ordered]@{
      schema = 'session-index/v1'
      schemaVersion = '1.0.0'
      generatedAtUtc = '2026-03-11T00:00:00.000Z'
      resultsDir = $td
      includeIntegration = $false
      integrationMode = $null
      integrationSource = $null
      status = 'ok'
      files = [ordered]@{
        pesterSummaryJson = 'pester-summary.json'
      }
      summary = [ordered]@{
        total = 4
        passed = 4
        failed = 0
        errors = 0
        skipped = 0
        duration_s = 2.5
        schemaVersion = '1.0.0'
      }
      runContext = [ordered]@{
        repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        ref = 'refs/heads/develop'
        commitSha = '1234567890abcdef1234567890abcdef12345678'
        workflow = 'Validate'
        runId = '100'
        runAttempt = '2'
        job = 'session-index'
      }
      branchProtection = [ordered]@{
        contract = [ordered]@{
          id = 'bp-verify'
          version = '1'
          issue = 118
          mappingPath = 'tools/policy/branch-required-checks.json'
          mappingDigest = 'abc123'
        }
        branch = 'develop'
        expected = @('lint', 'session-index')
        produced = @('lint', 'session-index')
        actual = [ordered]@{
          status = 'available'
          contexts = @('lint', 'session-index')
        }
        result = [ordered]@{
          status = 'ok'
          reason = 'aligned'
        }
        notes = @('aligned')
        tags = @('bp-verify')
      }
    }
    Set-Content -LiteralPath (Join-Path $td 'session-index.json') -Value ($v1 | ConvertTo-Json -Depth 12) -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -RefreshSessionIndexV2

    $v2Path = Join-Path $td 'session-index-v2.json'
    Test-Path -LiteralPath $v2Path | Should -BeTrue
    $v2 = Get-Content -LiteralPath $v2Path -Raw | ConvertFrom-Json
    $v2.schema | Should -Be 'session-index/v2'
    $v2.run.workflow | Should -Be 'Validate'
    $v2.run.branch | Should -Be 'develop'
    $v2.branchProtection.status | Should -Be 'ok'
    @($v2.branchProtection.actual) | Should -Be @('lint', 'session-index')
    $v2.tests.summary.total | Should -Be 4
    @($v2.artifacts | ForEach-Object { $_.name }) | Should -Contain 'session-index-v1'
  }
}
