#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path -Parent $PSCommandPath) 'VendorTools.psm1'
Import-Module $modulePath -Force

function New-LaneReport {
  param(
    [string]$Name,
    [array]$Requirements
  )

  $missing = @()
  foreach ($req in $Requirements) {
    if (-not $req.ok) { $missing += $req }
  }

  $status = if ($missing.Count -eq 0) { 'ready' } else { 'missing' }
  return [pscustomobject]@{
    name = $Name
    status = $status
    requirements = $Requirements
    missing = $missing
  }
}

function New-Requirement {
  param(
    [string]$Key,
    $Value
  )

  [pscustomobject]@{
    key   = $Key
    value = $Value
    ok    = [bool]$Value
  }
}

$lv2021x86 = Find-LabVIEWVersionExePath -Version 2021 -Bitness 32
$lv2021x64 = Find-LabVIEWVersionExePath -Version 2021 -Bitness 64
$gCliPath  = Resolve-GCliPath

$sourceLane = New-LaneReport -Name 'source' -Requirements @(
  (New-Requirement -Key 'LabVIEW 2021 (32-bit)' -Value $lv2021x86),
  (New-Requirement -Key 'LabVIEW 2021 (64-bit)' -Value $lv2021x64),
  (New-Requirement -Key 'G-CLI' -Value $gCliPath)
)

$lv2025x64 = Find-LabVIEWVersionExePath -Version 2025 -Bitness 64
$labviewCli = Resolve-LabVIEWCLIPath -Version 2025 -Bitness 64
if (-not $labviewCli) {
  # fall back to 32-bit CLI if 64-bit is not available
  $labviewCli = Resolve-LabVIEWCLIPath -Version 2025 -Bitness 32
}
$lvCompare = Resolve-LVComparePath

$reportLane = New-LaneReport -Name 'report' -Requirements @(
  (New-Requirement -Key 'LabVIEW 2025 (64-bit)' -Value $lv2025x64),
  (New-Requirement -Key 'LabVIEWCLI.exe' -Value $labviewCli),
  (New-Requirement -Key 'LVCompare.exe' -Value $lvCompare)
)

$vipmPath = Resolve-VIPMPath
$packagingLane = New-LaneReport -Name 'packaging' -Requirements @(
  (New-Requirement -Key 'LabVIEW 2021 (32-bit)' -Value $lv2021x86),
  (New-Requirement -Key 'VIPM' -Value $vipmPath)
)

$lanes = @($sourceLane, $reportLane, $packagingLane)

if ($Json) {
  $lanes | ConvertTo-Json -Depth 5
  exit 0
}

foreach ($lane in $lanes) {
  $statusColor = if ($lane.status -eq 'ready') { 'Green' } else { 'Yellow' }
  Write-Host ("[{0}] {1}" -f $lane.status.ToUpper(), $lane.name) -ForegroundColor $statusColor
  foreach ($req in $lane.requirements) {
    $color = if ($req.ok) { 'DarkGreen' } else { 'Red' }
    $valueText = if ($req.value) { $req.value } else { '<missing>' }
    Write-Host ("  - {0}: {1}" -f $req.key, $valueText) -ForegroundColor $color
  }
  Write-Host ''
}

$hasMissing = $lanes | Where-Object { $_.status -ne 'ready' }
if ($hasMissing) {
  Write-Warning 'One or more lanes are missing prerequisites. Install the required toolchains or update configs/labview-paths*.json.'
  exit 1
}
else {
  Write-Host 'All lanes are ready.' -ForegroundColor DarkGreen
  exit 0
}
