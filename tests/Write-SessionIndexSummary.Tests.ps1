Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Write-SessionIndexSummary' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:toolPath = Join-Path $repoRoot 'tools' 'Write-SessionIndexSummary.ps1'
  }

  BeforeEach {
    $script:summaryPath = Join-Path $TestDrive 'summary.md'
    $env:GITHUB_STEP_SUMMARY = $script:summaryPath
    $script:resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $script:resultsDir | Out-Null
  }

  AfterEach {
    Remove-Item Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
  }

  It 'writes expected lines for a complete session index' {
    $json = [ordered]@{
      schema = 'session-index/v1'
      status = 'ok'
      total = 5
      passed = 5
      failed = 0
      errors = 0
      skipped = 0
      duration_s = 12.34
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $script:resultsDir 'session-index.json') -Value $json -Encoding utf8

    & $script:toolPath -ResultsDir $script:resultsDir

    Test-Path -LiteralPath $script:summaryPath | Should -BeTrue
    $content = Get-Content -LiteralPath $script:summaryPath -Raw
    $content | Should -Match '### Session'
    $content | Should -Match '- Status: ok'
    $content | Should -Match '- Total: 5'
    $content | Should -Match '- Duration \(s\): 12\.34'
  }

  It 'handles missing optional properties without throwing' {
    # Write minimal JSON without status/total to ensure StrictMode-safe property access.
    $json = [ordered]@{
      schema = 'session-index/v1'
      files = @{}
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $script:resultsDir 'session-index.json') -Value $json -Encoding utf8

    { & $script:toolPath -ResultsDir $script:resultsDir } | Should -Not -Throw

    $content = Get-Content -LiteralPath $script:summaryPath -Raw
    $content | Should -Match '### Session'
    $content | Should -Match '- File:'
  }

  It 'reports parse failures gracefully' {
    Set-Content -LiteralPath (Join-Path $script:resultsDir 'session-index.json') -Value '{ invalid json' -Encoding utf8

    & $script:toolPath -ResultsDir $script:resultsDir

    $content = Get-Content -LiteralPath $script:summaryPath -Raw
    $content | Should -Match 'failed to parse'
  }
}
