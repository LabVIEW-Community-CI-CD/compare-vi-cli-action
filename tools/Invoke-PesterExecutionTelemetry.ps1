[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ResultsDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonObject {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
    throw "JSON file not found: $PathValue"
  }

  return (Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)]$Payload
  )

  $dir = Split-Path -Parent $PathValue
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PathValue -Encoding UTF8
}

function Get-SafeDateTime {
  param(
    [string]$Value,
    [datetime]$Fallback
  )

  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    try {
      return [datetime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {}
  }

  return $Fallback
}

function Get-ExecutionIdentity {
  param(
    $SessionIndex,
    $Summary
  )

  $executionPack = $null
  $executionPackSource = $null
  $integrationMode = $null
  $integrationSource = $null

  if ($null -ne $SessionIndex) {
    if ($SessionIndex.PSObject.Properties['executionPack']) { $executionPack = [string]$SessionIndex.executionPack }
    if ($SessionIndex.PSObject.Properties['executionPackSource']) { $executionPackSource = [string]$SessionIndex.executionPackSource }
    if ($SessionIndex.PSObject.Properties['integrationMode']) { $integrationMode = [string]$SessionIndex.integrationMode }
    if ($SessionIndex.PSObject.Properties['integrationSource']) { $integrationSource = [string]$SessionIndex.integrationSource }
  }

  if ([string]::IsNullOrWhiteSpace($executionPack) -and $null -ne $Summary -and $Summary.PSObject.Properties['executionPack']) {
    $executionPack = [string]$Summary.executionPack
  }

  return [pscustomobject]@{
    executionPack = $executionPack
    executionPackSource = $executionPackSource
    integrationMode = $integrationMode
    integrationSource = $integrationSource
  }
}

$resolvedResultsDir = [System.IO.Path]::GetFullPath($ResultsDir)
if (-not (Test-Path -LiteralPath $resolvedResultsDir -PathType Container)) {
  throw "Results directory not found: $resolvedResultsDir"
}

$eventsPath = Join-Path $resolvedResultsDir 'dispatcher-events.ndjson'
$sessionIndexPath = Join-Path $resolvedResultsDir 'session-index.json'
$summaryPath = Join-Path $resolvedResultsDir 'pester-summary.json'
$telemetryPath = Join-Path $resolvedResultsDir 'pester-execution-telemetry.json'

$sessionIndex = if (Test-Path -LiteralPath $sessionIndexPath -PathType Leaf) {
  Read-JsonObject -PathValue $sessionIndexPath
} else {
  $null
}
$summary = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
  Read-JsonObject -PathValue $summaryPath
} else {
  $null
}

$events = @()
$phaseTable = [ordered]@{}
$parseErrors = @()
$firstEventAt = $null
$lastEventAt = $null
$lastEvent = $null

if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
  foreach ($line in (Get-Content -LiteralPath $eventsPath -ErrorAction Stop)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    try {
      $event = $line | ConvertFrom-Json -ErrorAction Stop
      $eventAt = Get-SafeDateTime -Value ([string]$event.tsUtc) -Fallback ([datetime]::UtcNow)
      $phase = if ($event.PSObject.Properties['phase']) { [string]$event.phase } else { 'unknown' }
      $level = if ($event.PSObject.Properties['level']) { [string]$event.level } else { 'info' }
      $message = if ($event.PSObject.Properties['message']) { [string]$event.message } else { '' }
      $record = [pscustomobject]@{
        tsUtc = $eventAt.ToUniversalTime().ToString('o')
        phase = $phase
        level = $level
        message = $message
      }
      $events += $record

      if ($null -eq $firstEventAt -or $eventAt -lt $firstEventAt) { $firstEventAt = $eventAt }
      if ($null -eq $lastEventAt -or $eventAt -ge $lastEventAt) {
        $lastEventAt = $eventAt
        $lastEvent = $record
      }

      if (-not $phaseTable.Contains($phase)) {
        $phaseTable[$phase] = [ordered]@{
          phase = $phase
          count = 0
          firstAtUtc = $record.tsUtc
          lastAtUtc = $record.tsUtc
          lastLevel = $level
          lastMessage = $message
        }
      }

      $phaseRecord = $phaseTable[$phase]
      $phaseRecord.count = [int]$phaseRecord.count + 1
      $phaseRecord.lastAtUtc = $record.tsUtc
      $phaseRecord.lastLevel = $level
      $phaseRecord.lastMessage = $message
    } catch {
      $parseErrors += $_.Exception.Message
    }
  }
}

$handshakeFiles = @(Get-ChildItem -Path $resolvedResultsDir -Recurse -Filter 'handshake-*.json' -File -ErrorAction SilentlyContinue)
$handshakeMarkers = @()
$lastHandshake = $null
$lastHandshakeAt = $null
foreach ($file in $handshakeFiles) {
  $fallbackAt = $file.LastWriteTimeUtc
  try {
    $payload = Read-JsonObject -PathValue $file.FullName
    $phase = if ($payload.PSObject.Properties['name']) { [string]$payload.name } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) -replace '^handshake-', '' }
    $status = if ($payload.PSObject.Properties['status']) { [string]$payload.status } else { $null }
    $markerAt = Get-SafeDateTime -Value ([string]$payload.atUtc) -Fallback $fallbackAt
  } catch {
    $phase = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) -replace '^handshake-', ''
    $status = $null
    $markerAt = $fallbackAt
  }

  $marker = [pscustomobject]@{
    path = $file.FullName
    phase = $phase
    status = $status
    atUtc = $markerAt.ToUniversalTime().ToString('o')
  }
  $handshakeMarkers += $marker

  if ($null -eq $lastHandshakeAt -or $markerAt -ge $lastHandshakeAt) {
    $lastHandshakeAt = $markerAt
    $lastHandshake = $marker
  }
}

$identity = Get-ExecutionIdentity -SessionIndex $sessionIndex -Summary $summary
$telemetryStatus = if ($events.Count -gt 0) {
  if ($parseErrors.Count -gt 0) { 'telemetry-partial' } else { 'telemetry-available' }
} elseif ($handshakeMarkers.Count -gt 0) {
  'telemetry-handshake-only'
} else {
  'telemetry-missing'
}

$lastKnownPhase = $null
$lastKnownPhaseSource = $null
$lastKnownStatus = $null
if ($null -ne $lastEvent -and ($null -eq $lastHandshakeAt -or $lastEventAt -ge $lastHandshakeAt)) {
  $lastKnownPhase = $lastEvent.phase
  $lastKnownPhaseSource = 'dispatcher-events'
} elseif ($null -ne $lastHandshake) {
  $lastKnownPhase = $lastHandshake.phase
  $lastKnownPhaseSource = 'handshake'
  $lastKnownStatus = $lastHandshake.status
}

$report = [ordered]@{
  schema = 'pester-execution-telemetry@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  resultsDir = $resolvedResultsDir
  telemetryStatus = $telemetryStatus
  dispatcherEventsPath = if (Test-Path -LiteralPath $eventsPath -PathType Leaf) { $eventsPath } else { $null }
  sessionIndexPath = if (Test-Path -LiteralPath $sessionIndexPath -PathType Leaf) { $sessionIndexPath } else { $null }
  summaryPath = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { $summaryPath } else { $null }
  executionPack = $identity.executionPack
  executionPackSource = $identity.executionPackSource
  integrationMode = $identity.integrationMode
  integrationSource = $identity.integrationSource
  eventCount = $events.Count
  parseErrorCount = $parseErrors.Count
  firstEventAtUtc = if ($firstEventAt) { $firstEventAt.ToUniversalTime().ToString('o') } else { $null }
  lastEventAtUtc = if ($lastEventAt) { $lastEventAt.ToUniversalTime().ToString('o') } else { $null }
  lastKnownPhase = $lastKnownPhase
  lastKnownPhaseSource = $lastKnownPhaseSource
  lastKnownStatus = $lastKnownStatus
  lastEvent = $lastEvent
  phases = @($phaseTable.Values)
  handshake = [ordered]@{
    count = $handshakeMarkers.Count
    lastPhase = if ($lastHandshake) { $lastHandshake.phase } else { $null }
    lastStatus = if ($lastHandshake) { $lastHandshake.status } else { $null }
    lastAtUtc = if ($lastHandshake) { $lastHandshake.atUtc } else { $null }
    markerPaths = @($handshakeMarkers | ForEach-Object { $_.path })
  }
  parseErrors = @($parseErrors)
}

Write-JsonFile -PathValue $telemetryPath -Payload $report

if ($env:GITHUB_OUTPUT) {
  "path=$telemetryPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "status=$telemetryStatus" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "last_known_phase=$lastKnownPhase" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "event_count=$($events.Count)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester execution telemetry' -ForegroundColor Cyan
Write-Host ("status      : {0}" -f $telemetryStatus)
Write-Host ("events      : {0}" -f $events.Count)
Write-Host ("last phase  : {0}" -f $lastKnownPhase)
Write-Host ("report      : {0}" -f $telemetryPath)

exit 0
