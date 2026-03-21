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
  [string]$SummaryPath = '',
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

function Format-PlanePairList {
  param($Pairs)

  if (-not $Pairs) {
    return 'none'
  }

  $formattedPairs = @()
  foreach ($pair in @($Pairs)) {
    if ($null -eq $pair) { continue }
    $left = if ($pair.PSObject.Properties['left']) { [string]$pair.left } else { '' }
    $right = if ($pair.PSObject.Properties['right']) { [string]$pair.right } else { '' }
    if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) { continue }
    $formattedPairs += ("{0} + {1}" -f $left, $right)
  }

  if ($formattedPairs.Count -eq 0) {
    return 'none'
  }

  return ($formattedPairs -join '; ')
}

function Get-ObjectValue {
  param(
    $Object,
    [Parameter(Mandatory)][string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  if ($Object -is [System.Collections.IDictionary]) {
    return $Object[$Name]
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($property) {
    return $property.Value
  }

  return $null
}

function New-HostPlaneSummaryMarkdown {
  param(
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)][string]$ReportPath
  )

  $runner = Get-ObjectValue -Object $Report -Name 'runner'
  $native = Get-ObjectValue -Object $Report -Name 'native'
  $executionPolicy = Get-ObjectValue -Object $Report -Name 'executionPolicy'
  $policy = Get-ObjectValue -Object $Report -Name 'policy'
  $nativePlanes = Get-ObjectValue -Object $native -Name 'planes'
  $x64Plane = Get-ObjectValue -Object $nativePlanes -Name 'x64'
  $x32Plane = Get-ObjectValue -Object $nativePlanes -Name 'x32'
  $candidateParallelPairs = Get-ObjectValue -Object $executionPolicy -Name 'candidateParallelPairs'
  $mutuallyExclusivePairSet = Get-ObjectValue -Object $executionPolicy -Name 'mutuallyExclusivePairs'
  $shadowPolicy = Get-ObjectValue -Object $policy -Name 'hostNativeShadowPlane'

  $candidatePairs = if ($candidateParallelPairs) {
    Format-PlanePairList -Pairs (Get-ObjectValue -Object $candidateParallelPairs -Name 'pairs')
  } else {
    'none'
  }
  $mutuallyExclusivePairs = if ($mutuallyExclusivePairSet) {
    Format-PlanePairList -Pairs (Get-ObjectValue -Object $mutuallyExclusivePairSet -Name 'pairs')
  } else {
    'none'
  }

  return @(
    '# LabVIEW 2026 Host Plane Summary',
    '',
    ('- Report: `{0}`' -f $ReportPath),
    ('- Runner: `{0}` (hostIsRunner={1})' -f ([string](Get-ObjectValue -Object $runner -Name 'runnerName')), ([string][bool](Get-ObjectValue -Object $runner -Name 'hostIsRunner'))),
    ('- Native 64-bit: `{0}`' -f ([string](Get-ObjectValue -Object $x64Plane -Name 'status'))),
    ('- Native 32-bit: `{0}`' -f ([string](Get-ObjectValue -Object $x32Plane -Name 'status'))),
    ('- Parallel native support: `{0}`' -f ([string][bool](Get-ObjectValue -Object $native -Name 'parallelLabVIEWSupported'))),
    ('- Host-native 32-bit shadow: `{0}` (manual={1}, authoritative={2}, hostedCiAllowed={3})' -f `
        ([string](Get-ObjectValue -Object $shadowPolicy -Name 'role')), `
        ([string](Get-ObjectValue -Object $shadowPolicy -Name 'executionMode')), `
        ([string][bool](Get-ObjectValue -Object $shadowPolicy -Name 'authoritative')), `
        ([string][bool](Get-ObjectValue -Object $shadowPolicy -Name 'hostedCiAllowed'))),
    ('- Candidate parallel pairs: {0}' -f $candidatePairs),
    ('- Mutually exclusive pairs: {0}' -f $mutuallyExclusivePairs)
  ) -join "`n"
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
$summaryResolved = if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
  $summaryDirectory = Split-Path -Parent $outputResolved
  Resolve-AbsolutePath -Path (Join-Path $summaryDirectory 'labview-2026-host-plane-summary.md')
} else {
  Resolve-AbsolutePath -Path $SummaryPath
}

$report = Get-LabVIEW2026HostPlaneReport `
  -LabVIEW64Path $effectiveLabVIEW64Path `
  -LabVIEW32Path $effectiveLabVIEW32Path `
  -LabVIEWCli64Path $effectiveCli64Path `
  -LabVIEWCli32Path $effectiveCli32Path `
  -LVComparePath $effectiveComparePath

Ensure-ParentDirectory -Path $outputResolved
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputResolved -Encoding utf8
Ensure-ParentDirectory -Path $summaryResolved
New-HostPlaneSummaryMarkdown -Report $report -ReportPath $outputResolved | Set-Content -LiteralPath $summaryResolved -Encoding utf8

Write-LabVIEW2026HostPlaneConsole -Report $report
Write-Host ("[host-plane-split][report] {0}" -f $outputResolved) -ForegroundColor DarkCyan
Write-Host ("[host-plane-split][summary] {0}" -f $summaryResolved) -ForegroundColor DarkCyan

Write-GitHubOutput -Key 'labview-2026-host-plane-report-path' -Value $outputResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-2026-host-plane-summary-path' -Value $summaryResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-2026-native-64-status' -Value ([string]$report.native.planes.x64.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-2026-native-32-status' -Value ([string]$report.native.planes.x32.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-2026-native-parallel-supported' -Value ([string][bool]$report.native.parallelLabVIEWSupported) -Path $GitHubOutputPath

if ($PassThru) {
  Write-Output $report
} else {
  Write-Output $outputResolved
}
