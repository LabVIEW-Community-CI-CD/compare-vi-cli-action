[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$WatcherJson,
  [string]$WatcherEvents
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Update-SessionIndexWithWatcher {
  param(
    [pscustomobject]$SessionIndex,
    [psobject]$WatcherPayload,
    [string]$SummaryLine
  )

  $watchersObject = $null
  if ($SessionIndex.PSObject.Properties.Name -contains 'watchers') {
    $watchersObject = $SessionIndex.watchers
  }
  if (-not $watchersObject) {
    $watchersObject = [pscustomobject]@{}
  }
  $watchersObject | Add-Member -NotePropertyName 'rest' -NotePropertyValue $WatcherPayload -Force
  $SessionIndex | Add-Member -NotePropertyName 'watchers' -NotePropertyValue $watchersObject -Force

  if ($SummaryLine -and $SessionIndex.PSObject.Properties.Name -contains 'stepSummary' -and $SessionIndex.stepSummary) {
    $summaryLines = @($SessionIndex.stepSummary, '', '### Watcher (REST)', $SummaryLine)
    if ($WatcherPayload.PSObject.Properties.Name -contains 'htmlUrl' -and $WatcherPayload.htmlUrl) {
      $summaryLines += "- URL: $($WatcherPayload.htmlUrl)"
    }
    if ($WatcherPayload.PSObject.Properties.Name -contains 'events' -and $WatcherPayload.events) {
      $summaryLines += ("- Events: {0} ({1} line(s))" -f $WatcherPayload.events.path, $WatcherPayload.events.count)
    }
    $SessionIndex.stepSummary = ($summaryLines -join "`n")
  }

  return $SessionIndex
}

function New-WatcherFallback {
  param(
    [string]$Status,
    [string]$Reason,
    [string]$PathHint,
    [string]$ParseError
  )

  $payload = [ordered]@{
    schema      = 'ci-watch/rest-v1'
    status      = $Status
    conclusion  = 'watcher-error'
    polledAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    jobs        = @()
    notes       = @($Reason)
  }
  if ($PathHint) {
    $payload['watcherPath'] = $PathHint
  }
  if ($ParseError) {
    $payload['parseError'] = $ParseError
  }
  return [pscustomobject]$payload
}

function Get-WatcherEventMetadata {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $metadata = [ordered]@{
    schema  = 'comparevi/runtime-event/v1'
    path    = $Path
    present = $false
    count   = 0
  }

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]$metadata
  }

  $metadata.present = $true
  try {
    $lineCount = 0
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        $lineCount++
      }
    }
    $metadata.count = $lineCount
  } catch {}

  return [pscustomobject]$metadata
}

function ConvertTo-SessionIndexWatcherEvents {
  param([psobject]$WatcherEvents)

  if (-not $WatcherEvents) {
    return $null
  }

  $eventPath = $null
  if ($WatcherEvents.PSObject.Properties.Name -contains 'path' -and $WatcherEvents.path) {
    $eventPath = [string]$WatcherEvents.path
  }
  if ([string]::IsNullOrWhiteSpace($eventPath)) {
    return $null
  }

  $count = 0
  if ($WatcherEvents.PSObject.Properties.Name -contains 'count' -and $WatcherEvents.count -ne $null) {
    try {
      $count = [int]$WatcherEvents.count
    } catch {
      $count = 0
    }
  }
  if ($count -lt 0) {
    $count = 0
  }

  $presentFromFs = Test-Path -LiteralPath $eventPath -PathType Leaf
  $present = $presentFromFs
  if ($WatcherEvents.PSObject.Properties.Name -contains 'present' -and $WatcherEvents.present -ne $null) {
    $present = $presentFromFs -and [bool]$WatcherEvents.present
  }

  return [pscustomobject]([ordered]@{
      schema  = 'comparevi/runtime-event/v1'
      path    = $eventPath
      present = $present
      count   = $count
    })
}

if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
}

$idxPath = Join-Path $ResultsDir 'session-index.json'
if (-not (Test-Path -LiteralPath $idxPath -PathType Leaf)) {
  try {
    pwsh -NoLogo -NoProfile -File ./tools/Ensure-SessionIndex.ps1 -ResultsDir $ResultsDir | Out-Null
  } catch {
    Write-Warning "[watcher-session] Ensure-SessionIndex failed: $_"
  }
}

if (-not (Test-Path -LiteralPath $idxPath -PathType Leaf)) {
  Write-Warning "[watcher-session] session-index.json still missing at $idxPath"
  return
}

try {
  $idx = Get-Content -LiteralPath $idxPath -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
  Write-Warning "[watcher-session] Failed to parse session-index.json: $_"
  return
}

$watch = $null
$summaryLine = $null

if (-not $WatcherJson) {
  Write-Warning '[watcher-session] WatcherJson path not provided; recording watcher status as missing-input.'
  $watch = New-WatcherFallback -Status 'missing-input' -Reason 'WatcherJson path not provided to Update-SessionIndexWatcher.'
  $summaryLine = '- Status: missing-input/watcher-error'
} elseif (-not (Test-Path -LiteralPath $WatcherJson -PathType Leaf)) {
  Write-Warning "[watcher-session] Watcher file not found: $WatcherJson"
  $watch = New-WatcherFallback -Status 'missing-file' -Reason 'Watcher summary file was not found.' -PathHint $WatcherJson
  $summaryLine = '- Status: missing-file/watcher-error'
} else {
  try {
    $watch = Get-Content -LiteralPath $WatcherJson -Raw | ConvertFrom-Json -ErrorAction Stop
    $status = if ($watch.PSObject.Properties.Name -contains 'status' -and $watch.status) { $watch.status } else { 'unknown' }
    $conclusion = if ($watch.PSObject.Properties.Name -contains 'conclusion' -and $watch.conclusion) { $watch.conclusion } else { 'unknown' }
    $summaryLine = "- Status: $status/$conclusion"
  } catch {
    $parseError = $_.Exception.Message
    Write-Warning "[watcher-session] Failed to parse watcher summary: $parseError"
    $watch = New-WatcherFallback -Status 'invalid-json' -Reason 'Watcher summary JSON could not be parsed.' -PathHint $WatcherJson -ParseError $parseError
    $summaryLine = '- Status: invalid-json/watcher-error'
  }
}

$events = $null
if ($WatcherEvents) {
  $events = Get-WatcherEventMetadata -Path $WatcherEvents
} elseif ($watch -and ($watch.PSObject.Properties.Name -contains 'events') -and $watch.events) {
  $events = ConvertTo-SessionIndexWatcherEvents -WatcherEvents $watch.events
}
if ($watch -and ($watch.PSObject.Properties.Name -contains 'events') -and -not $events) {
  [void]$watch.PSObject.Properties.Remove('events')
}
if ($watch -and $events) {
  $watch | Add-Member -NotePropertyName 'events' -NotePropertyValue $events -Force
}

$idx = Update-SessionIndexWithWatcher -SessionIndex $idx -WatcherPayload $watch -SummaryLine $summaryLine

$idx | ConvertTo-Json -Depth 10 | Out-File -FilePath $idxPath -Encoding utf8
Write-Verbose "[watcher-session] Updated session index with REST watcher summary."
