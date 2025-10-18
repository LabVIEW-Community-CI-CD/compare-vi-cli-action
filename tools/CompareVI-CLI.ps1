param(
  [Parameter(Mandatory)][string]$Operation,
  [string]$Provider,
  [string]$ParametersPath,
  [hashtable]$Parameters,
  [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'providers' 'ProviderRouter.psm1'
Import-Module -Name $modulePath -Force

function Merge-ParameterTables {
  param(
    [hashtable]$Primary,
    [hashtable]$Override
  )
  $result = @{}
  if ($Primary) {
    foreach ($key in $Primary.Keys) { $result[$key] = $Primary[$key] }
  }
  if ($Override) {
    foreach ($key in $Override.Keys) { $result[$key] = $Override[$key] }
  }
  return $result
}

$fromFile = @{}
if ($ParametersPath) {
  if (-not (Test-Path -LiteralPath $ParametersPath -PathType Leaf)) {
    throw "Parameters file not found: $ParametersPath"
  }
  $json = Get-Content -LiteralPath $ParametersPath -Raw
  if ($json) {
    $fromFile = $json | ConvertFrom-Json -Depth 10 -AsHashtable
  }
}

$cliParameters = $Parameters
if ($cliParameters -and -not ($cliParameters -is [hashtable])) {
  throw '-Parameters must be supplied as a hashtable.'
}

$mergedParameters = Merge-ParameterTables -Primary $fromFile -Override $cliParameters

$plan = Get-CompareVIProviderPlan -Operation $Operation -Provider $Provider -Parameters $mergedParameters

if ($PlanOnly) {
  $plan | ConvertTo-Json -Depth 10
  return
}

# Placeholder for future execution support (actual invocation will be implemented in subsequent tasks).
$plan | ConvertTo-Json -Depth 10
