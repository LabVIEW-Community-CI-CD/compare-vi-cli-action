Describe 'Invoke-PesterTests STUCK_GUARD (notice-only)' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:dispatcher = Join-Path $repoRoot 'Invoke-PesterTests.ps1'
  }

  It 'emits heartbeat file and partial log when STUCK_GUARD=1' {
    # Build a tiny test suite that completes quickly
    $troot = Join-Path $TestDrive 'guard'
    New-Item -ItemType Directory -Force -Path $troot | Out-Null
    @(
      "Describe 'Mini' {",
      "  It 'passes' { 1 | Should -Be 1 }",
      "}"
    ) | Set-Content -LiteralPath (Join-Path $troot 'Mini.Tests.ps1') -Encoding UTF8

    $results = Join-Path $troot 'results'
    New-Item -ItemType Directory -Force -Path $results | Out-Null
    $testsPath = (Resolve-Path -LiteralPath $troot).Path
    $resultsPath = (Resolve-Path -LiteralPath $results).Path
    $env:STUCK_GUARD = '1'
    try {
      pwsh -File $script:dispatcher -TestsPath $testsPath -ResultsPath $resultsPath -IntegrationMode exclude | Out-Null
    } finally {
      Remove-Item Env:\STUCK_GUARD -ErrorAction SilentlyContinue
    }

    $hb = Join-Path $resultsPath 'pester-heartbeat.ndjson'
    Test-Path $hb | Should -BeTrue -Because 'Heartbeat file should exist when STUCK_GUARD=1'
    $content = @(Get-Content -LiteralPath $hb)
    ($content.Count -ge 2) | Should -BeTrue -Because 'Heartbeat stream should record at least start/stop entries'
    $startEvents = @($content | Where-Object { $_ -like '*"type":"start"*' })
    $stopEvents  = @($content | Where-Object { $_ -like '*"type":"stop"*' })
    $startEvents.Count | Should -Be 1 -Because 'Heartbeat should include single start marker'
    $stopEvents.Count  | Should -Be 1 -Because 'Heartbeat should include single stop marker'

    $partial = Join-Path $resultsPath 'pester-partial.log'
    Test-Path $partial | Should -BeTrue -Because 'Partial log should be emitted for guard visibility'
  }
}
