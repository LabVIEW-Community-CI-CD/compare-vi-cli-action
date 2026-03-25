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
}
