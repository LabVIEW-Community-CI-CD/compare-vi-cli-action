#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('windows', 'linux')]
  [string]$Plane,
  [string]$ContractPath = (Join-Path (Join-Path (Split-Path -Parent $PSCommandPath) 'policy') 'labview-container-shell-contract.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
  throw ("LabVIEW container shell contract not found: {0}" -f $ContractPath)
}

try {
  $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json -Depth 10 -ErrorAction Stop
} catch {
  throw ("Failed to parse LabVIEW container shell contract '{0}': {1}" -f $ContractPath, $_.Exception.Message)
}

if ([string]$contract.schema -ne 'labview-container-shell-contract/v1') {
  throw ("Unexpected LabVIEW container shell contract schema in {0}: {1}" -f $ContractPath, [string]$contract.schema)
}

if ([string]::IsNullOrWhiteSpace([string]$contract.hostWrapperShell)) {
  throw ("LabVIEW container shell contract is missing hostWrapperShell in {0}" -f $ContractPath)
}

$planeContract = $null
if ($contract.PSObject.Properties.Name -contains 'planes' -and $contract.planes) {
  $planeContract = $contract.planes.$Plane
}
if (-not $planeContract) {
  throw ("LabVIEW container shell contract is missing plane '{0}' in {1}" -f $Plane, $ContractPath)
}

if ([string]::IsNullOrWhiteSpace([string]$planeContract.executable)) {
  throw ("LabVIEW container shell contract plane '{0}' is missing executable in {1}" -f $Plane, $ContractPath)
}
if ([string]::IsNullOrWhiteSpace([string]$planeContract.family)) {
  throw ("LabVIEW container shell contract plane '{0}' is missing family in {1}" -f $Plane, $ContractPath)
}
if (-not ($planeContract.PSObject.Properties.Name -contains 'encodedCommand')) {
  throw ("LabVIEW container shell contract plane '{0}' is missing encodedCommand in {1}" -f $Plane, $ContractPath)
}
if (-not ($planeContract.PSObject.Properties.Name -contains 'pwshRequired')) {
  throw ("LabVIEW container shell contract plane '{0}' is missing pwshRequired in {1}" -f $Plane, $ContractPath)
}

[pscustomobject][ordered]@{
  plane = $Plane
  executable = [string]$planeContract.executable
  family = [string]$planeContract.family
  encodedCommand = [bool]$planeContract.encodedCommand
  pwshRequired = [bool]$planeContract.pwshRequired
  hostWrapperShell = [string]$contract.hostWrapperShell
}
