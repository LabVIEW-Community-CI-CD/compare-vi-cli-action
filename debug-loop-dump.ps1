param([int]$iters=3,[int]$cycleMs=20,[int]$simExit=0)
$ErrorActionPreference='Stop'
$env:LOOP_SIMULATE='1'
$env:LOOP_SIMULATE_EXIT_CODE=[string]$simExit
Import-Module (Join-Path $PSScriptRoot 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
$r = Invoke-IntegrationCompareLoop -Base (Join-Path $PSScriptRoot 'VI1.vi') -Head (Join-Path $PSScriptRoot 'VI2.vi') -MaxIterations $iters -IntervalSeconds 0 -UseHandshake -CycleTargetMs $cycleMs -BypassCliValidation -Quiet
$r | Select-Object Iterations,DiffCount,ErrorCount,AverageSeconds,TotalSeconds,HandshakeEnabled | ConvertTo-Json -Depth 3 -Compress | Set-Content -Path (Join-Path $PSScriptRoot 'debug-loop-summary.json') -Encoding utf8
$r.Records | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path (Join-Path $PSScriptRoot 'debug-loop-records.json') -Encoding utf8