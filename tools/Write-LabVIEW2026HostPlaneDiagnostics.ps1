#Requires -Version 7.0
<#
.SYNOPSIS
  Writes a deterministic host-plane diagnostics report for LabVIEW 2026 native lanes.
#>
[CmdletBinding()]
param(
  [string]$LabVIEW64Path = '',
  [string]$LabVIEW32Path = '',
  [string]$LabVIEWCli64Path = '',
  [string]$LabVIEWCli32Path = '',
  [string]$LVComparePath = '',
  [string]$OutputPath = 'tests/results/_agent/host-planes/labview-2026-host-plane-report.json',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'VendorTools.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LabVIEW2026HostPlaneDiagnostics.psm1') -Force

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Ensure-ParentDirectory {
  param([Parameter(Mandatory)][string]$Path)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  Ensure-ParentDirectory -Path $Path
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    New-Item -ItemType File -Path $Path -Force | Out-Null
  }

  Add-Content -LiteralPath $Path -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

$effectiveLabVIEW64Path = if ([string]::IsNullOrWhiteSpace($LabVIEW64Path)) {
  Find-LabVIEWVersionExePath -Version 2026 -Bitness 64
} else {
  $LabVIEW64Path
}

$effectiveLabVIEW32Path = if ([string]::IsNullOrWhiteSpace($LabVIEW32Path)) {
  Find-LabVIEWVersionExePath -Version 2026 -Bitness 32
} else {
  $LabVIEW32Path
}

$sharedCliPath = if ([string]::IsNullOrWhiteSpace($LabVIEWCli64Path) -and [string]::IsNullOrWhiteSpace($LabVIEWCli32Path)) {
  $resolved64 = Resolve-LabVIEWCLIPath -Version 2026 -Bitness 64
  if (-not [string]::IsNullOrWhiteSpace($resolved64)) {
    $resolved64
  } else {
    Resolve-LabVIEWCLIPath -Version 2026 -Bitness 32
  }
} else {
  ''
}

$effectiveCli64Path = if ([string]::IsNullOrWhiteSpace($LabVIEWCli64Path)) { $sharedCliPath } else { $LabVIEWCli64Path }
$effectiveCli32Path = if ([string]::IsNullOrWhiteSpace($LabVIEWCli32Path)) { $sharedCliPath } else { $LabVIEWCli32Path }
$effectiveComparePath = if ([string]::IsNullOrWhiteSpace($LVComparePath)) { Resolve-LVComparePath } else { $LVComparePath }
$outputResolved = Resolve-AbsolutePath -Path $OutputPath

$report = Get-LabVIEW2026HostPlaneReport `
  -LabVIEW64Path $effectiveLabVIEW64Path `
  -LabVIEW32Path $effectiveLabVIEW32Path `
  -LabVIEWCli64Path $effectiveCli64Path `
  -LabVIEWCli32Path $effectiveCli32Path `
  -LVComparePath $effectiveComparePath

Ensure-ParentDirectory -Path $outputResolved
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-LabVIEW2026HostPlaneConsole -Report $report
Write-Host ("[host-plane-split][report] {0}" -f $outputResolved) -ForegroundColor DarkCyan

Write-GitHubOutput -Key 'labview-2026-host-plane-report-path' -Value $outputResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-2026-native-64-status' -Value ([string]$report.native.planes.x64.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-2026-native-32-status' -Value ([string]$report.native.planes.x32.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-2026-native-parallel-supported' -Value ([string][bool]$report.native.parallelLabVIEWSupported) -Path $GitHubOutputPath

if ($PassThru) {
  Write-Output $report
} else {
  Write-Output $outputResolved
}
