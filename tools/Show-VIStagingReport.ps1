#Requires -Version 7.0
<#
.SYNOPSIS
  Render a VI staging compare report summary for terminal sessions.

.DESCRIPTION
  Reads `vi-staging-compare.json` (from Run-StagedLVCompare) and prints a
  concise markdown table with per-pair status, exit code, report analysis, and
  artifact paths. This is intended for interactive agent/operator sessions.

.PARAMETER CompareJsonPath
  Path to `vi-staging-compare.json`.

.PARAMETER PairIndex
  Optional 1-based pair index filter.

.PARAMETER ShowHeadings
  Include first few difference headings extracted from HTML reports.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$CompareJsonPath,
  [int]$PairIndex = 0,
  [switch]$ShowHeadings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ReportSignals {
  param([string]$ReportPath)

  $result = [ordered]@{
    diffMarkerCount = 0
    diffDetailCount = 0
    diffImageCount  = 0
    headings        = @()
  }

  if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    return [pscustomobject]$result
  }
  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    return [pscustomobject]$result
  }

  $html = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($html)) {
    return [pscustomobject]$result
  }

  $result.diffMarkerCount = [regex]::Matches(
    $html,
    'summary[^>]+class="[^"]*\bdifference-heading\b[^"]*"',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  ).Count
  $result.diffDetailCount = [regex]::Matches(
    $html,
    'li[^>]+class="[^"]*\bdiff-detail(?:-cosmetic)?\b[^"]*"',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  ).Count
  $result.diffImageCount = [regex]::Matches(
    $html,
    '<img[^>]+class\s*=\s*["''][^"'']*difference-image',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  ).Count

  $headingMatches = [regex]::Matches(
    $html,
    '<summary[^>]+class="[^"]*\bdifference-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</summary>',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  $headings = New-Object System.Collections.Generic.List[string]
  foreach ($match in $headingMatches) {
    $text = [System.Net.WebUtility]::HtmlDecode($match.Groups['text'].Value)
    $text = [regex]::Replace($text, '<[^>]+>', ' ')
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $headings.Add(($text -replace '^\s*\d+\.\s*', '')) | Out-Null
  }
  $result.headings = @($headings | Select-Object -First 5)
  return [pscustomobject]$result
}

if (-not (Test-Path -LiteralPath $CompareJsonPath -PathType Leaf)) {
  throw "Compare JSON not found: $CompareJsonPath"
}

$raw = Get-Content -LiteralPath $CompareJsonPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($raw)) {
  throw "Compare JSON is empty: $CompareJsonPath"
}

$data = $raw | ConvertFrom-Json -Depth 12
$items = @($data)
if ($items.Count -eq 0) {
  throw "No compare entries found in $CompareJsonPath"
}

if ($PairIndex -gt 0) {
  if ($PairIndex -gt $items.Count) {
    throw ("PairIndex {0} is out of range (count={1})." -f $PairIndex, $items.Count)
  }
  $items = @($items[$PairIndex - 1])
}

$rows = New-Object System.Collections.Generic.List[pscustomobject]
$rowIndex = 0
foreach ($item in $items) {
  $rowIndex++
  $reportPath = $null
  $capturePath = $null
  $status = $null
  $exitCode = $null
  $target = $null

  if ($item.PSObject.Properties['reportPath']) { $reportPath = [string]$item.reportPath }
  if ($item.PSObject.Properties['capturePath']) { $capturePath = [string]$item.capturePath }
  if ($item.PSObject.Properties['status']) { $status = [string]$item.status }
  if ($item.PSObject.Properties['exitCode']) {
    try { $exitCode = [int]$item.exitCode } catch { $exitCode = $item.exitCode }
  }
  if ($item.PSObject.Properties['headPath']) { $target = [string]$item.headPath }
  if ([string]::IsNullOrWhiteSpace($target) -and $item.PSObject.Properties['basePath']) {
    $target = [string]$item.basePath
  }

  $signals = Get-ReportSignals -ReportPath $reportPath
  $rows.Add([pscustomobject]@{
    pair            = $rowIndex
    target          = $target
    status          = $status
    exitCode        = $exitCode
    diffMarkers     = [int]$signals.diffMarkerCount
    diffDetails     = [int]$signals.diffDetailCount
    diffImages      = [int]$signals.diffImageCount
    reportPath      = $reportPath
    capturePath     = $capturePath
    headings        = @($signals.headings)
  }) | Out-Null
}

Write-Host ("# VI Staging Report View") -ForegroundColor Cyan
Write-Host ("Compare JSON: {0}" -f $CompareJsonPath)
Write-Host ""
Write-Host "| Pair | Target | Status | Exit | Markers | Details | Images |"
Write-Host "| --- | --- | --- | --- | --- | --- | --- |"
foreach ($row in $rows) {
  Write-Host ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f `
    $row.pair, $row.target, $row.status, $row.exitCode, $row.diffMarkers, $row.diffDetails, $row.diffImages)
}

Write-Host ""
foreach ($row in $rows) {
  Write-Host ("## Pair {0}" -f $row.pair) -ForegroundColor DarkCyan
  Write-Host ("- Target: {0}" -f $row.target)
  Write-Host ("- Report: {0}" -f $row.reportPath)
  Write-Host ("- Capture: {0}" -f $row.capturePath)
  if ($ShowHeadings -and $row.headings -and $row.headings.Count -gt 0) {
    Write-Host "- Headings:"
    foreach ($heading in $row.headings) {
      Write-Host ("  - {0}" -f $heading)
    }
  }
  Write-Host ""
}
