Import-Module ./module/CompareLoop/CompareLoop.psm1 -Force
$base='VI1.vi'
$head='VI2.vi'
$rand=[System.Random]::new(1)
$exec={ param($cli,$b,$h,$lvArgs) $ms=2+$rand.NextDouble()*8; Start-Sleep -Milliseconds ([int]$ms); 0 }
$r=Invoke-IntegrationCompareLoop -Base $base -Head $head -MaxIterations 120 -IntervalSeconds 0 -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -Quiet -QuantileStrategy StreamingP2 -StreamCapacity 60 -ReconcileEvery 50
Write-Host ("Iterations={0} Strategy={1} Window={2} p50={3} p90={4} p99={5}" -f $r.Iterations,$r.QuantileStrategy,$r.StreamingWindowCount,$r.Percentiles.p50,$r.Percentiles.p90,$r.Percentiles.p99)