Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path
Import-Module (Join-Path $repoRoot 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
. "$PSScriptRoot/TestHelpers.Schema.ps1"

Describe 'Invoke-IntegrationCompareLoop run summary JSON emission' -Tag 'Unit' {
  It 'writes a run summary JSON with expected schema and fields (default percentiles)' {
    . "$PSScriptRoot/TestHelpers.Schema.ps1"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("runsum_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  # Migrated fixtures
  $base = Join-Path $tmp 'VI1.vi'; 'a' | Out-File -FilePath $base
  $head = Join-Path $tmp 'VI2.vi'; 'b' | Out-File -FilePath $head
    $summaryPath = Join-Path $tmp 'run-summary.json'
    $exec = { param($cli,$b,$h,$argList) Start-Sleep -Milliseconds (5 + (Get-Random -Max 5)); 0 }
    Invoke-IntegrationCompareLoop -Base $base -Head $head -MaxIterations 15 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -RunSummaryJsonPath $summaryPath | Out-Null
    Test-Path $summaryPath | Should -BeTrue
  # Validate via generic schema helper (RunSummary spec validates structural shape)
  Assert-JsonShape -Path $summaryPath -Spec 'RunSummary' | Should -BeTrue
  $json = Get-Content $summaryPath -Raw | ConvertFrom-Json
  $json.iterations | Should -Be 15
  $json.percentiles.p90 | Should -BeGreaterThan 0
  $json.percentiles.p99 | Should -BeGreaterThan 0
  }

  It 'writes run summary reflecting custom percentile list' {
    . "$PSScriptRoot/TestHelpers.Schema.ps1"
    $tmp2 = Join-Path ([IO.Path]::GetTempPath()) ("runsum_pct_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp2 -Force | Out-Null
  # Migrated fixtures
  $base2 = Join-Path $tmp2 'VI1.vi'; 'a' | Out-File -FilePath $base2
  $head2 = Join-Path $tmp2 'VI2.vi'; 'b' | Out-File -FilePath $head2
    $summaryPath2 = Join-Path $tmp2 'run-summary.json'
    $exec2 = { param($cli,$b,$h,$argList) Start-Sleep -Milliseconds (6 + (Get-Random -Max 4)); 0 }
    Invoke-IntegrationCompareLoop -Base $base2 -Head $head2 -MaxIterations 12 -IntervalSeconds 0 -CompareExecutor $exec2 -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -RunSummaryJsonPath $summaryPath2 -CustomPercentiles '50,75,90,97.5,99.9' | Out-Null
    Test-Path $summaryPath2 | Should -BeTrue
    Assert-JsonShape -Path $summaryPath2 -Spec 'RunSummary' | Should -BeTrue
    $json2 = Get-Content $summaryPath2 -Raw | ConvertFrom-Json
    $json2.requestedPercentiles | Should -Contain 75
    $json2.percentiles.p75 | Should -BeGreaterThan 0
    $json2.percentiles.'p97_5' | Should -BeGreaterThan 0
    $json2.percentiles.'p99_9' | Should -BeGreaterThan 0
  }
}
