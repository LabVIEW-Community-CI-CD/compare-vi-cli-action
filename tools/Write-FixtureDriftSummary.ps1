<#
.SYNOPSIS
  Append a concise Fixture Drift block from drift-summary.json (best-effort).
#>
[CmdletBinding()]
param(
  [string]$Dir = 'results/fixture-drift',
  [string]$SummaryFile = 'drift-summary.json',
  [string]$DockerRuntimeManagerContextFile = 'docker-runtime-manager-context.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_STEP_SUMMARY) { return }

$path = if ($Dir) { Join-Path $Dir $SummaryFile } else { $SummaryFile }
if (-not (Test-Path -LiteralPath $path)) {
  ("### Fixture Drift`n- Summary: (missing) {0}" -f $path) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  return
}
try {
  $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
  ("### Fixture Drift`n- Summary: failed to parse: {0}" -f $path) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  return
}

$lines = @('### Fixture Drift','')
$lines += ('- Summary: {0}' -f $path)
function AddCounts($obj){
  if (-not $obj) { return }
  foreach ($k in ($obj.PSObject.Properties.Name | Sort-Object)) {
    $v = $obj.$k
    $lines += ('- {0}: {1}' -f $k,$v)
  }
}
if ($json.summaryCounts) { AddCounts $json.summaryCounts }
elseif ($json.counts) { AddCounts $json.counts }

if ($json.notes) {
  $n = $json.notes
  if ($n -is [array]) { foreach ($x in $n) { $lines += ('- Note: {0}' -f $x) } }
  else { $lines += ('- Note: {0}' -f $n) }
}

if ($json.PSObject.Properties['labviewPidTracker']) {
  $tracker = $json.labviewPidTracker
  $lines += ''
  $lines += '- LabVIEW PID Tracker:'
  $lines += ('  - Enabled: {0}' -f ([bool]$tracker.enabled))
  if ($tracker.PSObject.Properties['path'] -and $tracker.path) {
    $lines += ('  - Path: {0}' -f $tracker.path)
  }
  if ($tracker.PSObject.Properties['relativePath'] -and $tracker.relativePath) {
    $lines += ('  - Relative Path: {0}' -f $tracker.relativePath)
  }
  if ($tracker.PSObject.Properties['initial'] -and $tracker.initial) {
    $initial = $tracker.initial
    $ip = if ($initial.PSObject.Properties['pid'] -and $null -ne $initial.pid) { $initial.pid } else { 'none' }
    $ir = if ($initial.PSObject.Properties['running']) { [bool]$initial.running } else { $false }
    $ireused = if ($initial.PSObject.Properties['reused']) { [bool]$initial.reused } else { $false }
    $lines += ('  - Initial: pid={0}, running={1}, reused={2}' -f $ip,$ir,$ireused)
  }
  if ($tracker.PSObject.Properties['final'] -and $tracker.final) {
    $final = $tracker.final
    $fp = if ($final.PSObject.Properties['pid'] -and $null -ne $final.pid) { $final.pid } else { 'none' }
    $frun = if ($final.PSObject.Properties['running']) { [bool]$final.running } else { $false }
    $freused = if ($final.PSObject.Properties['reused'] -and $null -ne $final.reused) { [bool]$final.reused } else { $false }
    $lines += ('  - Final: pid={0}, running={1}, reused={2}' -f $fp,$frun,$freused)
    if ($final.PSObject.Properties['context'] -and $final.context -and $final.context.PSObject.Properties['stage']) {
      $lines += ('  - Final Stage: {0}' -f $final.context.stage)
    }
    if ($final.PSObject.Properties['context'] -and $final.context -and $final.context.PSObject.Properties['status']) {
      $lines += ('  - Final Status: {0}' -f $final.context.status)
    }
    if ($final.PSObject.Properties['context'] -and $final.context -and $final.context.PSObject.Properties['trackerExists']) {
      $lines += ('  - Tracker Exists: {0}' -f ([bool]$final.context.trackerExists))
    }
    if ($final.PSObject.Properties['context'] -and $final.context -and $final.context.PSObject.Properties['trackerLastWriteTimeUtc'] -and $final.context.trackerLastWriteTimeUtc) {
      $lines += ('  - Tracker Last Write: {0}' -f $final.context.trackerLastWriteTimeUtc)
    }
    if ($final.PSObject.Properties['context'] -and $final.context -and $final.context.PSObject.Properties['trackerLength'] -and $null -ne $final.context.trackerLength) {
      $lines += ('  - Tracker Length: {0}' -f $final.context.trackerLength)
    }
    if ($final.PSObject.Properties['contextSource'] -and $final.contextSource) {
      $detail = if ($final.PSObject.Properties['contextSourceDetail'] -and $final.contextSourceDetail -and $final.contextSourceDetail -ne $final.contextSource) { ' (detail: ' + $final.contextSourceDetail + ')' } else { '' }
      $lines += ('  - Context Source: {0}{1}' -f $final.contextSource,$detail)
    } elseif ($final.PSObject.Properties['contextSourceDetail'] -and $final.contextSourceDetail) {
      $lines += ('  - Context Source Detail: {0}' -f $final.contextSourceDetail)
    }
  }
}

# Optional handshake excerpt
try {
  $hs = Join-Path $Dir '_handshake'
  if (Test-Path -LiteralPath $hs) {
    $ready = Join-Path $hs 'ready.json'
    $end   = Join-Path $hs 'end.json'
    $hsLines = @()
    if (Test-Path -LiteralPath $ready) {
      $r = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json -ErrorAction Stop
      $hsLines += ('- Handshake ready: {0} ({1})' -f ($r.status), ($r.at ?? ''))
      if ($r.reason) { $hsLines += ('- Reason: {0}' -f $r.reason) }
    }
    if (Test-Path -LiteralPath $end) {
      $e = Get-Content -LiteralPath $end -Raw | ConvertFrom-Json -ErrorAction Stop
      $hsLines += ('- Handshake end: {0} ({1})' -f ($e.status), ($e.at ?? ''))
    }
    if ($hsLines.Count -gt 0) { $lines += ''; $lines += $hsLines }
  }
} catch {}

$dockerContextPath = if ([System.IO.Path]::IsPathRooted($DockerRuntimeManagerContextFile)) {
  $DockerRuntimeManagerContextFile
} elseif ([string]::IsNullOrWhiteSpace($Dir)) {
  $DockerRuntimeManagerContextFile
} else {
  Join-Path $Dir $DockerRuntimeManagerContextFile
}
if (Test-Path -LiteralPath $dockerContextPath -PathType Leaf) {
  try {
    $dockerContext = Get-Content -LiteralPath $dockerContextPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $manager = if ($dockerContext.PSObject.Properties['manager']) { $dockerContext.manager } else { $dockerContext }
    $lines += ''
    $lines += '- Docker Runtime Manager:'
    if ($manager.PSObject.Properties['status']) { $lines += ('  - Status: {0}' -f $manager.status) }
    if ($manager.PSObject.Properties['startContext']) { $lines += ('  - Start Context: {0}' -f $manager.startContext) }
    if ($manager.PSObject.Properties['finalContext']) { $lines += ('  - Final Context: {0}' -f $manager.finalContext) }
    if ($manager.PSObject.Properties['windowsImageDigest']) { $lines += ('  - Windows Digest: {0}' -f $manager.windowsImageDigest) }
    if ($manager.PSObject.Properties['linuxImageDigest']) { $lines += ('  - Linux Digest: {0}' -f $manager.linuxImageDigest) }
    if ($manager.PSObject.Properties['summaryPath'] -and $manager.summaryPath) { $lines += ('  - Summary Path: {0}' -f $manager.summaryPath) }
    $lines += ('  - Context JSON: {0}' -f $dockerContextPath)
  } catch {
    $lines += ('- Docker Runtime Manager context parse failed: {0}' -f $dockerContextPath)
  }
}

$lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
