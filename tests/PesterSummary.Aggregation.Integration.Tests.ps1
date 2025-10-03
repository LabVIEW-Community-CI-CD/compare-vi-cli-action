<#
 Integration-focused minimal verification that aggregationHints block is emitted when the dispatcher is
 run with -EmitAggregationHints. Skips automatically if canonical LVCompare path or required env vars
 (LV_BASE_VI, LV_HEAD_VI) are missing to avoid false negatives on CI agents without LabVIEW.
#>

Describe 'AggregationHints (Integration)' -Tag 'Integration' {
  # NOTE: Variables needed by -Skip must exist at discovery time; compute them outside BeforeAll.
  $enableAggInt = ($env:ENABLE_AGG_INT -eq '1')
  $script:dispatcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-PesterTests.ps1'
  $script:canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
  $script:haveCli = Test-Path -LiteralPath $script:canonical
  $script:haveBase = -not [string]::IsNullOrWhiteSpace($env:LV_BASE_VI)
  $script:haveHead = -not [string]::IsNullOrWhiteSpace($env:LV_HEAD_VI)
  $script:shouldRun = $script:haveCli -and $script:haveBase -and $script:haveHead
  BeforeAll { }

  It 'emits aggregationHints block when enabled (smoke)' -Skip:((!$script:shouldRun) -or (-not $enableAggInt)) {
    # Create isolated mini test set (fast) so we exercise dispatcher end-to-end quickly.
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("agg-int-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
      $testsDir = Join-Path $tempDir 'tests'
      New-Item -ItemType Directory -Path $testsDir | Out-Null
      @(
        "Describe 'AggIntMini' -Tag Slow {",
        "  It 'baseline' { 1 | Should -Be 1 }",
        "  It 'baseline2' { 2 | Should -Be 2 }",
        "}"
      ) -join [Environment]::NewLine | Set-Content -LiteralPath (Join-Path $testsDir 'AggIntMini.Tests.ps1') -Encoding UTF8

      $resDir = Join-Path $tempDir 'results'
      & pwsh -NoLogo -NoProfile -File $script:dispatcher -TestsPath $testsDir -ResultsPath $resDir -EmitAggregationHints | Out-Null
      $exit = $LASTEXITCODE
      $summaryPath = Join-Path $resDir 'pester-summary.json'
      $exit | Should -Be 0
      Test-Path $summaryPath | Should -BeTrue
      $json = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
      ($json.PSObject.Properties.Name -contains 'aggregationHints') | Should -BeTrue
      $json.aggregationHints.strategy | Should -Be 'heuristic/v1'
    } finally {
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
}
