Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path
Import-Module (Join-Path $repoRoot 'module' 'CompareLoop' 'CompareLoop.psd1') -Force

Describe 'Invoke-IntegrationCompareLoop aggregate metrics' -Tag 'Unit' {
  It 'produces stable percentile ordering and total histogram count equals iterations' {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("aggregate_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $base = Join-Path $tempDir 'VI1.vi'
    $head = Join-Path $tempDir 'VI2.vi'
    'x' | Out-File -FilePath $base -Encoding utf8
    'y' | Out-File -FilePath $head -Encoding utf8
    $script:seq = 0
    $exec = {
      param($CliPath,$Base,$Head,$CompareArgs)
      # Sequence of durations: short, medium, long, short, medium -- exit codes alternate diff/no diff
      $durations = 20,50,90,15,60
      $codes = 1,0,1,0,1
      $idx = $script:seq
      if ($idx -ge $durations.Count) { $idx = $durations.Count-1 }
      Start-Sleep -Milliseconds $durations[$idx]
      $code = $codes[$idx]
      $script:seq++
      return $code
    }
    $r = Invoke-IntegrationCompareLoop -Base $base -Head $head -MaxIterations 5 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
    $r.Iterations | Should -Be 5
    $r.Percentiles.p50 | Should -BeGreaterThan 0
  (($r.Percentiles.p90 -ge $r.Percentiles.p50)) | Should -BeTrue
  (($r.Percentiles.p99 -ge $r.Percentiles.p90)) | Should -BeTrue
    ($r.Histogram | Measure-Object).Count | Should -Be 5
    ($r.Histogram | Measure-Object -Property Count -Sum).Sum | Should -Be 5
  }
}
