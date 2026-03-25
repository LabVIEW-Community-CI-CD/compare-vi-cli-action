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
    Test-Path -LiteralPath (Join-Path $td 'session-index-v2.json') | Should -BeTrue
  }

  It 'backfills session-index-v2.json when v1 already exists' {
    $td = Join-Path $TestDrive 'results-existing-v1'
    New-Item -ItemType Directory -Force -Path $td | Out-Null
    $ps = @{
      total = 1; passed = 1; failed = 0; errors = 0; skipped = 0; duration_s = 0.5; schemaVersion = '1.0.0'
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $td 'pester-summary.json') -Value $ps -Encoding UTF8

    $v1 = @{
      schema = 'session-index/v1'
      schemaVersion = '1.0.0'
      generatedAtUtc = '2026-03-25T00:00:00.0000000Z'
      resultsDir = $td
      includeIntegration = $false
      integrationMode = $null
      integrationSource = $null
      files = @{}
      status = 'ok'
    } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $td 'session-index.json') -Value $v1 -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -SummaryJson 'pester-summary.json'

    Test-Path -LiteralPath (Join-Path $td 'session-index-v2.json') | Should -BeTrue
  }

  It 'forces session-index-v2.json regeneration even when SESSION_INDEX_V2_EMIT disables default emission' {
    $td = Join-Path $TestDrive 'results-force-v2'
    New-Item -ItemType Directory -Force -Path $td | Out-Null

    $v1 = @(
      '{',
      '  "schema": "session-index/v1",',
      '  "schemaVersion": "1.0.0",',
      '  "generatedAtUtc": "2026-03-25T00:00:00.0000000Z",',
      ('  "resultsDir": "{0}",' -f ($td -replace '\\', '\\\\')),
      '  "files": {},',
      '  "status": "ok"',
      '}'
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $td 'session-index.json') -Value $v1 -Encoding UTF8

    $root = (Get-Location).Path
    $previousToggle = $env:SESSION_INDEX_V2_EMIT
    try {
      $env:SESSION_INDEX_V2_EMIT = 'false'
      & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -ForceSessionIndexV2
    } finally {
      if ($null -eq $previousToggle) {
        Remove-Item Env:SESSION_INDEX_V2_EMIT -ErrorAction SilentlyContinue
      } else {
        $env:SESSION_INDEX_V2_EMIT = $previousToggle
      }
    }

    Test-Path -LiteralPath (Join-Path $td 'session-index-v2.json') | Should -BeTrue
  }

  It 'derives session-index-v2.json from v1 branch protection and artifact metadata without Node dependencies' {
    $td = Join-Path $TestDrive 'results-derived-v2'
    New-Item -ItemType Directory -Force -Path $td | Out-Null

    $v1 = [ordered]@{
      schema = 'session-index/v1'
      schemaVersion = '1.0.0'
      generatedAtUtc = '2026-03-25T00:00:00.0000000Z'
      resultsDir = $td
      includeIntegration = $false
      integrationMode = $null
      integrationSource = $null
      status = 'ok'
      files = [ordered]@{
        pesterSummaryJson = 'pester-summary.json'
        compareReportHtml = 'compare-report.html'
      }
      summary = [ordered]@{
        total = 3
        passed = 3
        failed = 0
        errors = 0
        skipped = 0
        duration_s = 2.5
        schemaVersion = '1.0.0'
      }
      runContext = [ordered]@{
        repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        workflow = 'Validate'
        job = 'session-index'
        ref = 'develop'
        commitSha = '0123456789abcdef0123456789abcdef01234567'
        runId = '12345'
        runAttempt = '2'
        runner = 'GitHub Actions 1'
        runnerOS = 'Linux'
        runnerImageVersion = 'ubuntu24/20260301.1'
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
        produced = @('Validate / lint', 'Validate / session-index')
        actual = [ordered]@{
          status = 'available'
          contexts = @('lint', 'session-index')
        }
        result = [ordered]@{
          status = 'ok'
          reason = 'aligned'
        }
        notes = @('Live branch protection query succeeded.')
        tags = @('bp-verify')
      }
    } | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $td 'session-index.json') -Value $v1 -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -ForceSessionIndexV2

    $v2Path = Join-Path $td 'session-index-v2.json'
    Test-Path -LiteralPath $v2Path | Should -BeTrue
    $v2 = Get-Content -LiteralPath $v2Path -Raw | ConvertFrom-Json -Depth 50
    $v2.schema | Should -Be 'session-index/v2'
    $v2.run.workflow | Should -Be 'Validate'
    $v2.run.job | Should -Be 'session-index'
    $v2.run.branch | Should -Be 'develop'
    $v2.run.repository | Should -Be 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    $v2.branchProtection.status | Should -Be 'ok'
    $v2.branchProtection.reason | Should -Be 'aligned'
    @($v2.branchProtection.expected) | Should -Be @('lint', 'session-index')
    @($v2.branchProtection.actual) | Should -Be @('lint', 'session-index')
    ($v2.artifacts | Where-Object { $_.name -eq 'session-index-v2' }).Count | Should -Be 1
    ($v2.artifacts | Where-Object { $_.name -eq 'pesterSummaryJson' }).path | Should -Be 'pester-summary.json'
    ($v2.artifacts | Where-Object { $_.name -eq 'compareReportHtml' }).kind | Should -Be 'report'

    $schemaScript = Join-Path $root 'tools/Invoke-JsonSchemaLite.ps1'
    $schemaPath = Join-Path $root 'docs/schema/generated/session-index-v2.schema.json'
    { & $schemaScript -JsonPath $v2Path -SchemaPath $schemaPath } | Should -Not -Throw
  }

  It 'preserves branch-protection API failure state instead of fabricating live actual contexts' {
    $td = Join-Path $TestDrive 'results-api-error-v2'
    New-Item -ItemType Directory -Force -Path $td | Out-Null

    $v1 = [ordered]@{
      schema = 'session-index/v1'
      schemaVersion = '1.0.0'
      generatedAtUtc = '2026-03-25T00:00:00.0000000Z'
      resultsDir = $td
      files = [ordered]@{}
      status = 'ok'
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
        produced = @('Validate / lint', 'Validate / session-index')
        actual = [ordered]@{
          status = 'error'
        }
        result = [ordered]@{
          status = 'ok'
          reason = 'aligned'
        }
        notes = @('Branch protection query failed with 403 Forbidden.')
        tags = @('bp-verify')
      }
    } | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $td 'session-index.json') -Value $v1 -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -ForceSessionIndexV2

    $v2 = Get-Content -LiteralPath (Join-Path $td 'session-index-v2.json') -Raw | ConvertFrom-Json -Depth 50
    $v2.branchProtection.status | Should -Be 'error'
    $v2.branchProtection.reason | Should -Be 'api_forbidden'
    @($v2.branchProtection.actual).Count | Should -Be 0
  }

  It 'treats legacy branch-protection payloads without a live actual query as unavailable instead of backfilling contexts' {
    $td = Join-Path $TestDrive 'results-legacy-branch-protection-v2'
    New-Item -ItemType Directory -Force -Path $td | Out-Null

    $v1 = [ordered]@{
      schema = 'session-index/v1'
      schemaVersion = '1.0.0'
      generatedAtUtc = '2026-03-25T00:00:00.0000000Z'
      resultsDir = $td
      files = [ordered]@{}
      status = 'ok'
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
        produced = @('Validate / lint', 'Validate / session-index')
        result = [ordered]@{
          status = 'ok'
          reason = 'aligned'
        }
        notes = @('Legacy session-index payload omitted live branch-protection query results.')
        tags = @('bp-verify')
      }
    } | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $td 'session-index.json') -Value $v1 -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -ForceSessionIndexV2

    $v2 = Get-Content -LiteralPath (Join-Path $td 'session-index-v2.json') -Raw | ConvertFrom-Json -Depth 50
    $v2.branchProtection.status | Should -Be 'warn'
    $v2.branchProtection.reason | Should -Be 'api_unavailable'
    @($v2.branchProtection.actual).Count | Should -Be 0
  }

  It 'preserves an existing branch-protection mismatch reason when live actual contexts are unavailable' {
    $td = Join-Path $TestDrive 'results-legacy-mismatch-v2'
    New-Item -ItemType Directory -Force -Path $td | Out-Null

    $v1 = [ordered]@{
      schema = 'session-index/v1'
      schemaVersion = '1.0.0'
      generatedAtUtc = '2026-03-25T00:00:00.0000000Z'
      resultsDir = $td
      files = [ordered]@{}
      status = 'warn'
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
        produced = @('Validate / lint')
        result = [ordered]@{
          status = 'warn'
          reason = 'missing_required'
        }
        notes = @('Legacy payload recorded the mismatch before live branch-protection contexts were queried.')
        tags = @('bp-verify')
      }
    } | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $td 'session-index.json') -Value $v1 -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -ForceSessionIndexV2

    $v2 = Get-Content -LiteralPath (Join-Path $td 'session-index-v2.json') -Raw | ConvertFrom-Json -Depth 50
    $v2.branchProtection.status | Should -Be 'warn'
    $v2.branchProtection.reason | Should -Be 'missing_required'
    @($v2.branchProtection.actual).Count | Should -Be 0
  }
}
