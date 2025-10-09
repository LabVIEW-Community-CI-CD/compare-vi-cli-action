param(
  [string[]]$IncludePatterns,
  [switch]$IncludeIntegration,
  [string]$Profile = 'quick',
  [string]$TestsPath = 'tests',
  [string]$ResultsPath = 'tests/results',
  [switch]$EmitFailuresJsonAlways
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path

Push-Location $repoRoot
try {
  Write-Host "=== Local Run Tests ===" -ForegroundColor Cyan
  Write-Host ("Repository: {0}" -f $repoRoot) -ForegroundColor Gray

  # Ensure local-friendly environment (no session locks or GH-only toggles)
  foreach ($name in @(
      'SESSION_LOCK_ENABLED',
      'SESSION_LOCK_FORCE',
      'SESSION_LOCK_STRICT',
      'CLAIM_PESTER_LOCK',
      'STUCK_GUARD',
      'WIRE_PROBES',
      'SEND_CTRL_C'
    )) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
  }
  $env:SESSION_LOCK_STRICT = '0'
  $env:STUCK_GUARD = '0'
  $env:LOCAL_DISPATCHER = '1'

  $profiles = @{
    quick    = @(
      'RunnerInvoker.*',
      'CompareVI.ArgumentPreview.Tests.ps1',
      'OnFixtureValidationFail.DiffDetails.Tests.ps1',
      'Invoker.Basic.Tests.ps1'
    )
    invoker  = @('RunnerInvoker.*','Invoker.Basic.Tests.ps1')
    compare  = @('CompareVI.*.ps1')
    fixtures = @('OnFixtureValidationFail.*.ps1')
    loop     = @('CompareLoop.*.ps1','Integration-ControlLoop*.ps1','LoopMetrics.Tests.ps1')
    full     = @() # no filters
  }

  $invokeParams = @{
    TestsPath        = $TestsPath
    ResultsPath      = $ResultsPath
    IncludeIntegration = if ($IncludeIntegration.IsPresent) { 'true' } else { 'false' }
  }
  $effectivePatterns = @()
  if ($IncludePatterns -and $IncludePatterns.Count -gt 0) {
    $effectivePatterns = $IncludePatterns
  } else {
    $profileKey = ($Profile ?? 'quick').ToLowerInvariant()
    if ($profiles.ContainsKey($profileKey)) {
      $effectivePatterns = $profiles[$profileKey]
    } else {
      Write-Warning "Unknown profile '$Profile'; running full suite."
      $effectivePatterns = @()
    }
  }
  if ($effectivePatterns -and $effectivePatterns.Count -gt 0) {
    $invokeParams.IncludePatterns = $effectivePatterns
  }

  if ($EmitFailuresJsonAlways) {
    $invokeParams.EmitFailuresJsonAlways = $true
  }

  Write-Host "Dispatching Invoke-PesterTests.ps1 with parameters:" -ForegroundColor Gray
  $invokeParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0} = {1}" -f $_.Key, ($_.Value -join ', ')) -ForegroundColor DarkGray
  }

  . "$repoRoot/Invoke-PesterTests.ps1" @invokeParams
  exit $LASTEXITCODE
}
finally {
  Remove-Item Env:LOCAL_DISPATCHER -ErrorAction SilentlyContinue
  Pop-Location
}
