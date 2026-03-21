[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$LaneName,
  [string]$RuntimeSnapshotPath = '',
  [string]$PreflightPath = '',
  [string]$CapturePath = '',
  [string]$StdOutPath = '',
  [string]$StdErrPath = '',
  [int]$TailLines = 40,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ''
  }

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Read-JsonArtifact {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = Resolve-AbsolutePath -Path $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 32)
  } catch {
    Write-Host ("::warning::Unable to parse JSON artifact {0}: {1}" -f $resolved, $_.Exception.Message)
    return $null
  }
}

function Get-PropertyValue {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory)][string]$Name
  )

  if ($null -eq $InputObject) {
    return $null
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) {
      return $InputObject[$Name]
    }
    return $null
  }

  $property = $InputObject.PSObject.Properties[$Name]
  if ($property) {
    return $property.Value
  }

  return $null
}

function Normalize-Text {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return ''
  }

  return ([string]$Value).Trim()
}

function Append-SummaryLines {
  param([string[]]$Lines)

  if ([string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    return
  }

  $resolved = Resolve-AbsolutePath -Path $StepSummaryPath
  $parent = Split-Path -Parent $resolved
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $Lines -join "`n" | Out-File -LiteralPath $resolved -Encoding utf8 -Append
}

function Show-FileTail {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Label
  )

  $resolved = Resolve-AbsolutePath -Path $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    Write-Host ("[vi-history-evidence] {0} missing at {1}" -f $Label, $resolved) -ForegroundColor Yellow
    return
  }

  Write-Host ("::group::{0} tail ({1})" -f $Label, $resolved)
  $lines = @(Get-Content -LiteralPath $resolved -ErrorAction SilentlyContinue)
  if ($lines.Count -eq 0) {
    Write-Host ("[{0}] (empty)" -f $Label) -ForegroundColor DarkGray
  } else {
    $startIndex = [Math]::Max(0, $lines.Count - [Math]::Max(1, $TailLines))
    for ($index = $startIndex; $index -lt $lines.Count; $index++) {
      Write-Host ("[{0}] {1}" -f $Label, [string]$lines[$index])
    }
  }
  Write-Host '::endgroup::'
}

$runtimeSnapshotResolved = if ([string]::IsNullOrWhiteSpace($RuntimeSnapshotPath)) { '' } else { Resolve-AbsolutePath -Path $RuntimeSnapshotPath }
$preflightPathResolved = if ([string]::IsNullOrWhiteSpace($PreflightPath)) { '' } else { Resolve-AbsolutePath -Path $PreflightPath }
$capturePathResolved = if ([string]::IsNullOrWhiteSpace($CapturePath)) { '' } else { Resolve-AbsolutePath -Path $CapturePath }

$runtime = Read-JsonArtifact -Path $runtimeSnapshotResolved
$preflight = Read-JsonArtifact -Path $preflightPathResolved
$capture = Read-JsonArtifact -Path $capturePathResolved

$observedDockerHost = ''
$dockerContext = ''
$dockerServerOs = ''
$runtimeStatus = ''
$runtimeReason = ''
$runtimeSource = ''
$captureStatus = ''
$gateOutcome = ''
$resultClass = ''
$reportPath = ''

if ($runtime) {
  $observed = Get-PropertyValue -InputObject $runtime -Name 'observed'
  $result = Get-PropertyValue -InputObject $runtime -Name 'result'
  $observedDockerHost = Normalize-Text (Get-PropertyValue -InputObject $observed -Name 'dockerHost')
  $dockerContext = Normalize-Text (Get-PropertyValue -InputObject $observed -Name 'context')
  $dockerServerOs = Normalize-Text (Get-PropertyValue -InputObject $observed -Name 'osType')
  $runtimeStatus = Normalize-Text (Get-PropertyValue -InputObject $result -Name 'status')
  $runtimeReason = Normalize-Text (Get-PropertyValue -InputObject $result -Name 'reason')
  $runtimeSource = 'runtime-snapshot'
}

if ($preflight) {
  if ([string]::IsNullOrWhiteSpace($observedDockerHost)) {
    $observedDockerHost = Normalize-Text (Get-PropertyValue -InputObject $preflight -Name 'dockerHost')
  }
  $contexts = Get-PropertyValue -InputObject $preflight -Name 'contexts'
  if ([string]::IsNullOrWhiteSpace($dockerContext)) {
    $dockerContext = Normalize-Text (Get-PropertyValue -InputObject $contexts -Name 'final')
  }
  if ([string]::IsNullOrWhiteSpace($dockerServerOs)) {
    $dockerServerOs = Normalize-Text (Get-PropertyValue -InputObject $contexts -Name 'finalOsType')
  }
  $preflightRuntime = Get-PropertyValue -InputObject $preflight -Name 'runtimeDeterminism'
  if ([string]::IsNullOrWhiteSpace($runtimeStatus)) {
    $runtimeStatus = Normalize-Text (Get-PropertyValue -InputObject $preflightRuntime -Name 'status')
  }
  if ([string]::IsNullOrWhiteSpace($runtimeReason)) {
    $runtimeReason = Normalize-Text (Get-PropertyValue -InputObject $preflightRuntime -Name 'reason')
  }
  if ([string]::IsNullOrWhiteSpace($runtimeSource)) {
    $runtimeSource = 'preflight'
  }
}

if ($capture) {
  if ([string]::IsNullOrWhiteSpace($observedDockerHost)) {
    $observedDockerHost = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'observedDockerHost')
  }
  if ([string]::IsNullOrWhiteSpace($observedDockerHost)) {
    $observedDockerHost = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'dockerHost')
  }
  if ([string]::IsNullOrWhiteSpace($dockerContext)) {
    $dockerContext = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'dockerContext')
  }
  if ([string]::IsNullOrWhiteSpace($dockerServerOs)) {
    $dockerServerOs = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'dockerServerOs')
  }
  $captureStatus = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'status')
  $gateOutcome = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'gateOutcome')
  $resultClass = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'resultClass')
  $reportPath = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'reportPath')
  if ([string]::IsNullOrWhiteSpace($StdOutPath)) {
    $StdOutPath = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'stdoutPath')
  }
  if ([string]::IsNullOrWhiteSpace($StdErrPath)) {
    $StdErrPath = Normalize-Text (Get-PropertyValue -InputObject $capture -Name 'stderrPath')
  }
}

$resolvedStdOutPath = if ([string]::IsNullOrWhiteSpace($StdOutPath)) { '' } else { Resolve-AbsolutePath -Path $StdOutPath }
$resolvedStdErrPath = if ([string]::IsNullOrWhiteSpace($StdErrPath)) { '' } else { Resolve-AbsolutePath -Path $StdErrPath }
$resolvedReportPath = if ([string]::IsNullOrWhiteSpace($reportPath)) { '' } else { Resolve-AbsolutePath -Path $reportPath }

Write-Host ("[vi-history-evidence] lane={0} observedDockerHost={1} dockerContext={2} dockerServerOs={3} runtimeStatus={4} runtimeSource={5}" -f `
  $LaneName, `
  ($(if ([string]::IsNullOrWhiteSpace($observedDockerHost)) { '<null>' } else { $observedDockerHost })), `
  ($(if ([string]::IsNullOrWhiteSpace($dockerContext)) { '<null>' } else { $dockerContext })), `
  ($(if ([string]::IsNullOrWhiteSpace($dockerServerOs)) { '<null>' } else { $dockerServerOs })), `
  ($(if ([string]::IsNullOrWhiteSpace($runtimeStatus)) { '<null>' } else { $runtimeStatus })), `
  ($(if ([string]::IsNullOrWhiteSpace($runtimeSource)) { 'none' } else { $runtimeSource }))) -ForegroundColor Cyan

Write-Host ("[vi-history-evidence] lane={0} capture={1} report={2} stdout={3} stderr={4} status={5} gateOutcome={6} resultClass={7}" -f `
  $LaneName, `
  ($(if ([string]::IsNullOrWhiteSpace($capturePathResolved)) { '<null>' } else { $capturePathResolved })), `
  ($(if ([string]::IsNullOrWhiteSpace($resolvedReportPath)) { '<null>' } else { $resolvedReportPath })), `
  ($(if ([string]::IsNullOrWhiteSpace($resolvedStdOutPath)) { '<null>' } else { $resolvedStdOutPath })), `
  ($(if ([string]::IsNullOrWhiteSpace($resolvedStdErrPath)) { '<null>' } else { $resolvedStdErrPath })), `
  ($(if ([string]::IsNullOrWhiteSpace($captureStatus)) { '<null>' } else { $captureStatus })), `
  ($(if ([string]::IsNullOrWhiteSpace($gateOutcome)) { '<null>' } else { $gateOutcome })), `
  ($(if ([string]::IsNullOrWhiteSpace($resultClass)) { '<null>' } else { $resultClass }))) -ForegroundColor DarkCyan

$summaryLines = @(
  ("### VI History Lane Evidence ({0})" -f $LaneName),
  '',
  ('- observedDockerHost: `{0}`' -f ($(if ([string]::IsNullOrWhiteSpace($observedDockerHost)) { '' } else { $observedDockerHost }))),
  ('- docker_context: `{0}`' -f $dockerContext),
  ('- docker_server_os: `{0}`' -f $dockerServerOs),
  ('- runtime_status: `{0}`' -f $runtimeStatus),
  ('- runtime_source: `{0}`' -f $runtimeSource),
  ('- capture_status: `{0}`' -f $captureStatus),
  ('- gate_outcome: `{0}`' -f $gateOutcome),
  ('- result_class: `{0}`' -f $resultClass)
)

if (-not [string]::IsNullOrWhiteSpace($runtimeReason)) {
  $summaryLines += ('- runtime_reason: `{0}`' -f ($runtimeReason -replace '`', "'"))
}
if (-not [string]::IsNullOrWhiteSpace($runtimeSnapshotResolved)) {
  $summaryLines += ('- runtime_snapshot: `{0}`' -f $runtimeSnapshotResolved)
}
if (-not [string]::IsNullOrWhiteSpace($preflightPathResolved)) {
  $summaryLines += ('- preflight_receipt: `{0}`' -f $preflightPathResolved)
}
if (-not [string]::IsNullOrWhiteSpace($capturePathResolved)) {
  $summaryLines += ('- capture_receipt: `{0}`' -f $capturePathResolved)
}
if (-not [string]::IsNullOrWhiteSpace($resolvedReportPath)) {
  $summaryLines += ('- report_path: `{0}`' -f $resolvedReportPath)
}
if (-not [string]::IsNullOrWhiteSpace($resolvedStdOutPath)) {
  $summaryLines += ('- stdout_path: `{0}`' -f $resolvedStdOutPath)
}
if (-not [string]::IsNullOrWhiteSpace($resolvedStdErrPath)) {
  $summaryLines += ('- stderr_path: `{0}`' -f $resolvedStdErrPath)
}
Append-SummaryLines -Lines $summaryLines

if (-not [string]::IsNullOrWhiteSpace($resolvedStdOutPath)) {
  Show-FileTail -Path $resolvedStdOutPath -Label ("{0}-stdout" -f $LaneName)
}
if (-not [string]::IsNullOrWhiteSpace($resolvedStdErrPath)) {
  Show-FileTail -Path $resolvedStdErrPath -Label ("{0}-stderr" -f $LaneName)
}
