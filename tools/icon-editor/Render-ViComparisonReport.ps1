#Requires -Version 7.0

param(
  [string]$SummaryPath,
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try { return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim() } catch { return $StartPath }
}

function Format-Status {
  param([string]$Status)
  switch ($Status) {
    'same'      { return ':white_check_mark: same' }
    'different' { return ':warning: different' }
    'error'     { return ':x: error' }
    'skipped'   { return ':arrow_right: skipped' }
    'dry-run'   { return ':information_source: dry run' }
    default     { return $Status }
  }
}

function Format-Link {
  param([string]$Path, [string]$Label)
  if (-not $Path) { return $null }
  if (-not $Label) { $Label = Split-Path -Path $Path -Leaf }
  return "[$Label]($Path)"
}

function Get-ArtifactPath {
  param(
    [object]$Artifacts,
    [string]$PropertyName
  )
  if (-not $Artifacts -or [string]::IsNullOrWhiteSpace($PropertyName)) {
    return $null
  }

  if ($Artifacts -is [System.Collections.IDictionary]) {
    if ($Artifacts.Contains($PropertyName)) { return $Artifacts[$PropertyName] }
    return $null
  }

  $props = $Artifacts.PSObject.Properties
  if ($props[$PropertyName]) { return $props[$PropertyName].Value }
  return $null
}

$repoRoot = Resolve-RepoRoot
if (-not $SummaryPath) {
  $SummaryPath = Join-Path $repoRoot 'tests/results/_agent/icon-editor/vi-diff-captures/vi-comparison-summary.json'
}

if (-not (Test-Path -LiteralPath $SummaryPath -PathType Leaf)) {
  throw "Comparison summary not found at $SummaryPath"
}

$summary = Get-Content -LiteralPath $SummaryPath -Raw | ConvertFrom-Json -Depth 8
if (-not $summary) {
  throw "Unable to parse comparison summary at $SummaryPath"
}

if (-not $OutputPath) {
  $summaryDir = Split-Path -Path $SummaryPath -Parent
  $OutputPath = Join-Path $summaryDir 'vi-comparison-report.md'
}

$counts = $summary.counts
$requests = @($summary.requests)

$lines = @()
$lines += '## VI Comparison Report'
$lines += ''
$lines += ('- Generated: `{0}`' -f ($summary.generatedAt ?? (Get-Date).ToString('o')))
$lines += ('- Total requests: {0}' -f ($counts.total ?? $requests.Count))
$lines += ('- Compared: {0} (same: {1}, different: {2})' -f ($counts.compared ?? 0), ($counts.same ?? 0), ($counts.different ?? 0))
$lines += ('- Skipped: {0}' -f ($counts.skipped ?? 0))
if ($counts.dryRun) { $lines += ('- Dry run entries: {0}' -f $counts.dryRun) }
if ($counts.errors) { $lines += ('- Errors: {0}' -f $counts.errors) }
$lines += ''

if ($requests.Count -eq 0) {
  $lines += '_No VI comparison requests were processed._'
} else {
  $lines += '| VI | Status | Notes | Artifacts |'
  $lines += '| --- | --- | --- | --- |'
  foreach ($req in $requests) {
    $statusText = Format-Status $req.status
    $note = if ($req.message) { $req.message } else { '' }

    $artifactLinks = @()
    # Tolerate both PSCustomObject and IDictionary for request and its artifacts,
    # and also absence of an 'artifacts' member entirely
    $artifacts = $null
    if ($req -is [System.Collections.IDictionary]) {
      if ($req.Contains('artifacts')) { $artifacts = $req['artifacts'] }
    } else {
      $prop = $req.PSObject.Properties['artifacts']
      if ($prop) { $artifacts = $prop.Value }
    }

    if ($artifacts) {
      $link = Format-Link -Path (Get-ArtifactPath -Artifacts $artifacts -PropertyName 'sessionIndex') -Label 'session-index'
      if ($link) { $artifactLinks += $link }
      $link = Format-Link -Path (Get-ArtifactPath -Artifacts $artifacts -PropertyName 'captureJson') -Label 'capture'
      if ($link) { $artifactLinks += $link }
      $link = Format-Link -Path (Get-ArtifactPath -Artifacts $artifacts -PropertyName 'compareReport') -Label 'report'
      if ($link) { $artifactLinks += $link }
    }
    $artifactCell = if ($artifactLinks.Count -gt 0) { $artifactLinks -join '<br>' } else { '' }
    $viLabel = if ($req.relPath) { $req.relPath } elseif ($req.name) { $req.name } else { '(unnamed)' }
    $lines += ('| {0} | {1} | {2} | {3} |' -f $viLabel, $statusText, $note, $artifactCell)
  }
}

$markdown = ($lines -join "`n") + "`n"
$markdown | Set-Content -LiteralPath $OutputPath -Encoding utf8

return $markdown
