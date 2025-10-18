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
    $env:STUCK_GUARD = '1'
    try {
      pwsh -File $script:dispatcher -TestsPath $troot -ResultsPath $results -IntegrationMode exclude | Out-Null
    } finally {
      Remove-Item Env:\STUCK_GUARD -ErrorAction SilentlyContinue
    }

    $hb = Join-Path $results 'pester-heartbeat.ndjson'
    Test-Path $hb | Should -BeTrue
    $content = @(Get-Content -LiteralPath $hb)
    ($content.Count -ge 2) | Should -BeTrue
    ($content | Where-Object { $_ -like '*"type":"start"*' }).Count | Should -Be 1
    ($content | Where-Object { $_ -like '*"type":"stop"*' }).Count | Should -Be 1

    $partial = Join-Path $results 'pester-partial.log'
    Test-Path $partial | Should -BeTrue
  }
}
