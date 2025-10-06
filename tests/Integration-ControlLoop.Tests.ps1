Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# These are unit-style tests for the loop function with an injected executor.
# They DO NOT require the real LVCompare; we bypass canonical path validation.
# Auto-run suppression: script checks INTEGRATION_LOOP_SUPPRESS_AUTORUN.
$env:INTEGRATION_LOOP_SUPPRESS_AUTORUN = '1'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path
$modulePath = Join-Path $repoRoot 'module' 'CompareLoop' 'CompareLoop.psd1'
Import-Module $modulePath -Force

Describe 'Invoke-IntegrationCompareLoop (DI executor)' -Tag 'Unit' {
  BeforeAll {
    $script:tempDir = Join-Path ([IO.Path]::GetTempPath()) ("loopTest_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    $script:base = Join-Path $script:tempDir 'VI1.vi'
    $script:head = Join-Path $script:tempDir 'VI2.vi'
    'base' | Out-File -FilePath $script:base -Encoding utf8
    'head' | Out-File -FilePath $script:head -Encoding utf8
  }

  AfterAll {
    if (Test-Path -LiteralPath $script:tempDir) { Remove-Item -LiteralPath $script:tempDir -Recurse -Force }
  }

  It 'runs zero-diff single iteration with executor exit code 0' {
    $exec = {
      param($CliPath,$Base,$Head,$CompareArgs)
      return 0
    }
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 1 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
    $r.Iterations | Should -Be 1
    $r.DiffCount | Should -Be 0
    $r.ErrorCount | Should -Be 0
    $r.Records.Count | Should -Be 1
    $r.Records[0].diff | Should -BeFalse
  }

  It 'counts a diff when executor returns 1' {
  $exec = { param($CliPath,$Base,$Head,$CompareArgs) return 1 }
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 2 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
    $r.DiffCount | Should -BeGreaterThan 0
    $r.ErrorCount | Should -Be 0
    ($r.Records | Where-Object diff).Count | Should -Be $r.DiffCount
  }

  It 'records an error for unexpected exit code' {
    $script:sequence = 0
    $exec = {
      param($CliPath,$Base,$Head,$CompareArgs)
      # First iteration produce unsupported exit code, second normal diff
      if ($script:sequence -eq 0) { $script:sequence = 1; return 5 } else { return 1 }
    }
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 2 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
    $r.ErrorCount | Should -Be 1
    $r.DiffCount | Should -Be 1
    ($r.Records | Where-Object status -eq 'ERROR').Count | Should -Be 1
  }

  It 'respects -FailOnDiff (terminates after first diff)' {
  $exec = { param($CliPath,$Base,$Head,$CompareArgs) return 1 }
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 5 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -FailOnDiff
    $r.Iterations | Should -Be 1
    $r.DiffCount | Should -Be 1
  }

  It 'emits percentile metrics and histogram with correct ordering and bin counts' {
    $script:seq = 0
    $exec = {
      param($CliPath,$Base,$Head,$CompareArgs)
      $durations = 20,55,90,15,60
      $codes = 1,0,1,0,1
      $i = $script:seq
      if ($i -ge $durations.Count) { $i = $durations.Count-1 }
      Start-Sleep -Milliseconds $durations[$i]
      $code = $codes[$i]
      $script:seq++
      return $code
    }
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 5 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
    $r.Iterations | Should -Be 5
    $r.Percentiles | Should -Not -BeNullOrEmpty
    $r.Percentiles.p50 | Should -BeGreaterThan 0
    (($r.Percentiles.p90 -ge $r.Percentiles.p50)) | Should -BeTrue
    (($r.Percentiles.p99 -ge $r.Percentiles.p90)) | Should -BeTrue
    $r.Histogram | Should -Not -BeNullOrEmpty
    ($r.Histogram | Measure-Object).Count | Should -Be 5
    ($r.Histogram | Measure-Object -Property Count -Sum).Sum | Should -Be 5
    foreach ($bin in $r.Histogram) { ($bin.Count -ge 0) | Should -BeTrue }
  }

  It 'supports fractional interval sleeps (sub-second) without error' {
    $exec = { param($CliPath,$Base,$Head,$CompareArgs) Start-Sleep -Milliseconds 15; return 0 }
    $start = Get-Date
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 2 -IntervalSeconds 0.05 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
    $elapsed = (Get-Date) - $start
    $r.Iterations | Should -Be 2
    # Elapsed should be at least total executor time (~30ms) plus fractional sleep (~50ms)
    $elapsed.TotalMilliseconds | Should -BeGreaterThan 60
  }

  It 'respects custom histogram bin count' {
    $script:seq = 0
    $exec = { param($CliPath,$Base,$Head,$CompareArgs) $script:seq++; Start-Sleep -Milliseconds (10 + ($script:seq*5)); return 0 }
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 4 -IntervalSeconds 0 -HistogramBins 3 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
    ($r.Histogram | Measure-Object).Count | Should -Be 3
    (($r.Histogram | Measure-Object -Property Count -Sum).Sum) | Should -Be 4
  }

  It 'emits metrics snapshot file at configured cadence' {
  $snap = Join-Path $script:tempDir 'snapshots.jsonl'
    if (Test-Path -LiteralPath $snap) { Remove-Item -LiteralPath $snap -Force }
  $exec = { param($CliPath,$Base,$Head,$CompareArgs) Start-Sleep -Milliseconds 5; return 0 }
    $caught = $null
    try {
      Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 4 -IntervalSeconds 0 -MetricsSnapshotEvery 2 -MetricsSnapshotPath $snap -CompareExecutor $exec -BypassCliValidation -Quiet | Out-Null
    } catch { $caught = $_ }
    $caught | Should -Be $null
    Start-Sleep -Milliseconds 20
    Test-Path -LiteralPath $snap | Should -BeTrue
    $lines = Get-Content -LiteralPath $snap -ErrorAction Stop
    ($lines | Measure-Object).Count | Should -Be 2
  # Expect new schema version v2 after enrichment changes
  ($lines | Select-String 'metrics-snapshot-v2').Count | Should -Be 2
  }

}
