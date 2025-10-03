Import-Module ./module/CompareLoop/CompareLoop.psm1 -Force
$base='VI1.vi'
$head='VI2.vi'
$rand=[System.Random]::new(42)
$exec={ param($cli,$b,$h,$lvArgs) $ms=2+$rand.NextDouble()*18; Start-Sleep -Milliseconds ([int]$ms); 0 }
$common=@{ Base=$base; Head=$head; MaxIterations=50; IntervalSeconds=0; CompareExecutor=$exec; SkipValidation=$true; PassThroughPaths=$true; BypassCliValidation=$true; Quiet=$true }
Write-Host 'Running exact'
$exact=Invoke-IntegrationCompareLoop @common -QuantileStrategy Exact -ErrorAction Stop
Write-Host 'Exact done'
Write-Host 'Running streaming'
try {
  $stream=Invoke-IntegrationCompareLoop @common -QuantileStrategy StreamingP2 -ErrorAction Stop
  Write-Host 'Streaming done'
  $stream | Select-Object Iterations,Percentiles,QuantileStrategy
} catch {
  Write-Host 'Streaming failed with error:' -ForegroundColor Red
  $_ | Format-List * -Force
  if ($_.InvocationInfo) { $_.InvocationInfo | Format-List * -Force }
  if ($_.Exception) { $_.Exception | Format-List * -Force }
}