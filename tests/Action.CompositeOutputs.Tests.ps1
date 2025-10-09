# Requires -Version 5.1
# Pester tests validating composite action script-level behavior via direct function invocation
# (We cannot invoke the composite action YAML directly in-process, but we can emulate what it does.)

BeforeDiscovery {
  $script:SkipResolveTests = -not (Get-Command Resolve-Cli -ErrorAction SilentlyContinue)
}

BeforeAll {
  $here = Split-Path -Parent $PSCommandPath
  $root = Resolve-Path (Join-Path $here '..')
  . (Join-Path $root 'scripts' 'CompareVI.ps1')
}

Describe 'Composite action output shape (emulated)' -Tag 'Unit' {
  It 'produces all expected duration-related outputs' -Skip:$script:SkipResolveTests {
    # Arrange: create two temp files to act as .vi placeholders
    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'a.vi'
    $b = Join-Path $vis 'b.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    New-Item -ItemType File -Path $b -Force | Out-Null

    # Mock Resolve-Cli so we don't depend on real installation
    $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
    Mock -CommandName Resolve-Cli -MockWith { $canonical }

    # Act
    $res = Invoke-CompareVI -Base $a -Head $b -FailOnDiff:$false -Executor { 1 }

    # Assert
    $res | Should -Not -BeNullOrEmpty
    $res.CompareDurationSeconds | Should -BeGreaterOrEqual 0
    $res.CompareDurationNanoseconds | Should -BeGreaterOrEqual 0
    $res.CompareDurationNanoseconds | Should -BeGreaterThan 0  # expect non-zero elapsed even if near instantaneous
    $res.ExitCode | Should -Be 1
    $res.Diff | Should -BeTrue
  }

  It 'writes both duration outputs to a mock GITHUB_OUTPUT file' -Skip:$script:SkipResolveTests {
    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'a.vi'
    $b = Join-Path $vis 'b.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    New-Item -ItemType File -Path $b -Force | Out-Null

    $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
    Mock -CommandName Resolve-Cli -MockWith { $canonical }

    $outPath = Join-Path $TestDrive 'gout.txt'
    $sumPath = Join-Path $TestDrive 'summary.md'
    $res = Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $outPath -GitHubStepSummaryPath $sumPath -FailOnDiff:$false -Executor { 1 }

    $content = Get-Content $outPath -Raw
    $content | Should -Match 'compareDurationSeconds='
    $content | Should -Match 'compareDurationNanoseconds='
  $content | Should -Match 'diff=true'
  $content | Should -Match 'shortCircuitedIdentical=false'
    (Get-Content $sumPath -Raw) | Should -Match 'Duration \(s\):'
    (Get-Content $sumPath -Raw) | Should -Match 'Duration \(ns\):'
  }

  It 'short-circuits identical path and marks output object flag' -Skip:$script:SkipResolveTests {
    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'same.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    Mock -CommandName Resolve-Cli -MockWith { 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe' }
    $res = Invoke-CompareVI -Base $a -Head $a -FailOnDiff:$false -Executor { 0 }
    $res.ShortCircuitedIdenticalPath | Should -BeTrue
    $res.Diff | Should -BeFalse
    $res.ExitCode | Should -Be 0
  }

  It 'emits shortCircuitedIdentical output line when identical and using GitHubOutputPath' -Skip:$script:SkipResolveTests {
    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'same2.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    Mock -CommandName Resolve-Cli -MockWith { 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe' }
    $outPath = Join-Path $TestDrive 'gout_identical.txt'
    Invoke-CompareVI -Base $a -Head $a -GitHubOutputPath $outPath -FailOnDiff:$false -Executor { 0 } | Out-Null
    $content = Get-Content -LiteralPath $outPath -Raw
    $content | Should -Match 'shortCircuitedIdentical=true'
  }

  It 'loop mode emits percentile and loop outputs (simulated executor)' {
    # Arrange
    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'a.vi'
    $b = Join-Path $vis 'b.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    New-Item -ItemType File -Path $b -Force | Out-Null

    # Import loop module
    $modulePath = Join-Path (Split-Path -Parent $PSCommandPath) '..' 'module' 'CompareLoop' 'CompareLoop.psd1'
    Import-Module $modulePath -Force

    # Simulate a short loop
    $loopRes = Invoke-IntegrationCompareLoop -Base $a -Head $b -MaxIterations 5 -IntervalSeconds 0 -CompareExecutor { param($cli,$ba,$he,$args) Start-Sleep -Milliseconds 2; return 1 } -Quiet -SkipValidation -PassThroughPaths -BypassCliValidation -QuantileStrategy StreamingReservoir -StreamCapacity 40
    $loopRes | Should -Not -BeNullOrEmpty
    $loopRes.Iterations | Should -Be 5
    $loopRes.DiffCount | Should -BeGreaterThan 0
    $loopRes.Percentiles | Should -Not -BeNullOrEmpty
    $loopRes.Percentiles.p50 | Should -BeGreaterOrEqual 0
    $loopRes.StreamingWindowCount | Should -BeGreaterThan 0
  }
}
