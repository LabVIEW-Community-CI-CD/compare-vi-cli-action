param(
  [int]$iters=5,
  [int]$cycleMs=50,
  [int]$simExit=0
)
$ErrorActionPreference='Stop'
$env:LOOP_SIMULATE='1'
$env:LOOP_SIMULATE_EXIT_CODE=[string]$simExit
Import-Module (Join-Path $PSScriptRoot 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
$r = Invoke-IntegrationCompareLoop -Base (Join-Path $PSScriptRoot 'VI1.vi') -Head (Join-Path $PSScriptRoot 'VI2.vi') -MaxIterations $iters -IntervalSeconds 0 -UseHandshake -CycleTargetMs $cycleMs -BypassCliValidation -Quiet
"Iterations=$($r.Iterations) DiffCount=$($r.DiffCount) ErrorCount=$($r.ErrorCount) AvgMs=" + [int]([math]::Round($r.AverageSeconds*1000)) + " TotalMs=" + [int]([math]::Round($r.TotalSeconds*1000))