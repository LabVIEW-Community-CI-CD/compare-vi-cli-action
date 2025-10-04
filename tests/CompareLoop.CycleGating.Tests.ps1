Import-Module (Join-Path $PSScriptRoot '..' 'module' 'CompareLoop' 'CompareLoop.psd1') -Force

Describe 'Invoke-IntegrationCompareLoop cycle gating and handshake simulation' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:base = Join-Path $script:repoRoot 'VI1.vi'
    $script:head = Join-Path $script:repoRoot 'VI2.vi'
  }

  It 'enforces minimum total time with -CycleTargetMs and -UseHandshake (simulated)' {
    $env:LOOP_SIMULATE = '1'
    $env:LOOP_SIMULATE_EXIT_CODE = '0'
    $targetMs = 100
    $iters = 5
    $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations $iters -IntervalSeconds 0 -UseHandshake -CycleTargetMs $targetMs -BypassCliValidation -Quiet
    $r | Should -Not -BeNullOrEmpty
    $r.Iterations | Should -Be $iters
    # TotalSeconds should be at least target per cycle * iterations (allow small scheduler variance)
    [int]([math]::Round($r.TotalSeconds * 1000)) | Should -BeGreaterOrEqual ($targetMs * $iters - 20)
    $r.DiffCount | Should -Be 0
    $r.ErrorCount | Should -Be 0
  }

  It 'counts diffs when simulated exit code is 1' {
    $env:LOOP_SIMULATE = '1'
    $env:LOOP_SIMULATE_EXIT_CODE = '1'
    $iters = 3
    $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations $iters -IntervalSeconds 0 -UseHandshake -CycleTargetMs 10 -BypassCliValidation -Quiet
    # In simulate mode with exit code 1, every iteration should register a diff
    $r.DiffCount | Should -Be $iters
  }
}
