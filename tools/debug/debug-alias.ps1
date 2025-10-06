Import-Module ./module/CompareLoop/CompareLoop.psm1 -Force
$base='VI1.vi'
$head='VI2.vi'
$rand=[System.Random]::new(42)
$exec={ param($cli,$b,$h,$lvArgs) $ms=2+$rand.NextDouble()*18; Start-Sleep -Milliseconds ([int]$ms); 0 }
$r=Invoke-IntegrationCompareLoop -Base $base -Head $head -MaxIterations 50 -IntervalSeconds 0 -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -Quiet -QuantileStrategy StreamingP2 -StreamCapacity 40
Write-Host "Reported strategy: $($r.QuantileStrategy) (expected StreamingReservoir)"