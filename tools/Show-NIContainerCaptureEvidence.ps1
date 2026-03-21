#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$CapturePath,
  [string]$BasePath = '',
  [ValidateRange(1, 200)][int]$TailLineCount = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Resolve-DisplayPath {
  param(
    [string]$Path,
    [string]$BasePath
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return '<none>'
  }

  $resolved = $Path
  try {
    $resolved = Resolve-AbsolutePath -Path $Path
  } catch {}

  if ([string]::IsNullOrWhiteSpace($BasePath)) {
    return $resolved
  }

  try {
    $resolvedBase = Resolve-AbsolutePath -Path $BasePath
    $relative = [System.IO.Path]::GetRelativePath($resolvedBase, $resolved)
    if (-not [string]::IsNullOrWhiteSpace($relative) -and -not $relative.StartsWith('..')) {
      return $relative
    }
  } catch {}

  return $resolved
}

function Get-JsonString {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory)][string]$PropertyName,
    [string]$Default = ''
  )

  if ($null -eq $InputObject) {
    return $Default
  }

  if ($InputObject.PSObject.Properties[$PropertyName]) {
    $value = $InputObject.PSObject.Properties[$PropertyName].Value
    if ($null -eq $value) {
      return $Default
    }
    return ([string]$value).Trim()
  }

  return $Default
}

function Write-ArtifactTail {
  param(
    [Parameter(Mandatory)][string]$Label,
    [string]$Path,
    [int]$TailLineCount,
    [string]$BasePath
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Host ("[ni-container-evidence] {0}=<none>" -f $Label) -ForegroundColor DarkGray
    return
  }

  $resolved = Resolve-AbsolutePath -Path $Path
  Write-Host ("[ni-container-evidence] {0}={1}" -f $Label, (Resolve-DisplayPath -Path $resolved -BasePath $BasePath)) -ForegroundColor DarkGray

  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    Write-Host ("::warning::{0} artifact not found at {1}" -f $Label, $resolved)
    return
  }

  $lines = @(Get-Content -LiteralPath $resolved -ErrorAction Stop)
  if ($lines.Count -eq 0) {
    Write-Host ("[ni-container-evidence][{0}] <empty>" -f $Label) -ForegroundColor DarkGray
    return
  }

  $tail = @($lines | Select-Object -Last $TailLineCount)
  foreach ($line in $tail) {
    Write-Host ("[ni-container-evidence][{0}] {1}" -f $Label, $line)
  }
}

$resolvedCapturePath = Resolve-AbsolutePath -Path $CapturePath
if (-not (Test-Path -LiteralPath $resolvedCapturePath -PathType Leaf)) {
  throw ("Container capture not found: {0}" -f $resolvedCapturePath)
}

$capture = Get-Content -LiteralPath $resolvedCapturePath -Raw | ConvertFrom-Json -Depth 16
$runtimeDeterminism = if ($capture.PSObject.Properties['runtimeDeterminism']) { $capture.runtimeDeterminism } else { $null }
$runtimeObserved = if ($runtimeDeterminism -and $runtimeDeterminism.PSObject.Properties['observed']) { $runtimeDeterminism.observed } else { $null }

$dockerHost = Get-JsonString -InputObject $capture -PropertyName 'observedDockerHost'
if ([string]::IsNullOrWhiteSpace($dockerHost)) {
  $dockerHost = Get-JsonString -InputObject $runtimeObserved -PropertyName 'dockerHost'
}
$dockerContext = Get-JsonString -InputObject $capture -PropertyName 'dockerContext'
if ([string]::IsNullOrWhiteSpace($dockerContext)) {
  $dockerContext = Get-JsonString -InputObject $runtimeObserved -PropertyName 'context'
}
$dockerServerOs = Get-JsonString -InputObject $capture -PropertyName 'dockerServerOs'
if ([string]::IsNullOrWhiteSpace($dockerServerOs)) {
  $dockerServerOs = Get-JsonString -InputObject $runtimeObserved -PropertyName 'osType'
}

$status = Get-JsonString -InputObject $capture -PropertyName 'status'
$gateOutcome = Get-JsonString -InputObject $capture -PropertyName 'gateOutcome'
$resultClass = Get-JsonString -InputObject $capture -PropertyName 'resultClass'
$containerName = Get-JsonString -InputObject $capture -PropertyName 'containerName'
$image = Get-JsonString -InputObject $capture -PropertyName 'image'
$reportPath = Get-JsonString -InputObject $capture -PropertyName 'reportPath'
$stdoutPath = Get-JsonString -InputObject $capture -PropertyName 'stdoutPath'
$stderrPath = Get-JsonString -InputObject $capture -PropertyName 'stderrPath'

Write-Host ("[ni-container-evidence] capture={0} status={1} gateOutcome={2} resultClass={3} container={4} image={5}" -f (Resolve-DisplayPath -Path $resolvedCapturePath -BasePath $BasePath), ($status ?? '<null>'), ($gateOutcome ?? '<null>'), ($resultClass ?? '<null>'), ($containerName ?? '<null>'), ($image ?? '<null>')) -ForegroundColor Cyan
Write-Host ("[ni-container-evidence] observedDockerHost={0} dockerContext={1} dockerServerOs={2}" -f (($dockerHost ?? '<null>')), (($dockerContext ?? '<null>')), (($dockerServerOs ?? '<null>'))) -ForegroundColor DarkCyan

if (-not [string]::IsNullOrWhiteSpace($reportPath)) {
  Write-Host ("[ni-container-evidence] report={0}" -f (Resolve-DisplayPath -Path $reportPath -BasePath $BasePath)) -ForegroundColor DarkGray
}

Write-ArtifactTail -Label 'stdout' -Path $stdoutPath -TailLineCount $TailLineCount -BasePath $BasePath
Write-ArtifactTail -Label 'stderr' -Path $stderrPath -TailLineCount $TailLineCount -BasePath $BasePath
