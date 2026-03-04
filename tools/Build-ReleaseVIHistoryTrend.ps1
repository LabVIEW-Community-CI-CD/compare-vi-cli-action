#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ReviewIndexJsonPath,

  [Parameter(Mandatory = $true)]
  [string]$PolicySummaryJsonPath,

  [Parameter(Mandatory = $true)]
  [string]$Tag,

  [Parameter(Mandatory = $true)]
  [string]$Profile,

  [Parameter(Mandatory = $true)]
  [string]$RunUrl,

  [Parameter(Mandatory = $true)]
  [string]$OutputDir,

  [int]$MaxHistoryItems = 20,
  [string]$HistoryGlob = 'history/summary-*.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "JSON file not found: $Path"
  }
  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 50)
}

if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$historyDir = Join-Path $OutputDir 'history'
if (-not (Test-Path -LiteralPath $historyDir -PathType Container)) {
  New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
}

$rows = @(Read-JsonFile -Path $ReviewIndexJsonPath)
$policy = Read-JsonFile -Path $PolicySummaryJsonPath

$statusCounts = [ordered]@{}
$gateCounts = [ordered]@{}
$resultClassCounts = [ordered]@{}
foreach ($row in $rows) {
  $status = [string]$row.status
  $gate = [string]$row.gateOutcome
  $resultClass = [string]$row.resultClass
  if (-not $statusCounts.Contains($status)) { $statusCounts[$status] = 0 }
  if (-not $gateCounts.Contains($gate)) { $gateCounts[$gate] = 0 }
  if (-not $resultClassCounts.Contains($resultClass)) { $resultClassCounts[$resultClass] = 0 }
  $statusCounts[$status] = [int]$statusCounts[$status] + 1
  $gateCounts[$gate] = [int]$gateCounts[$gate] + 1
  $resultClassCounts[$resultClass] = [int]$resultClassCounts[$resultClass] + 1
}

$summary = [ordered]@{
  schema = 'release-vi-history/summary@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  tag = $Tag
  profile = $Profile
  runUrl = $RunUrl
  policyOutcome = [string]$policy.outcome
  policyMode = [string]$policy.mode
  violationCount = [int]$policy.violationCount
  rowCount = $rows.Count
  statusCounts = $statusCounts
  gateCounts = $gateCounts
  resultClassCounts = $resultClassCounts
}

$safeTag = ($Tag -replace '[^A-Za-z0-9._-]', '_')
$summaryPath = Join-Path $historyDir ("summary-{0}.json" -f $safeTag)
$summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $summaryPath -Encoding utf8

$historyFiles = @(Get-ChildItem -Path $OutputDir -Filter 'summary-*.json' -Recurse -File -ErrorAction SilentlyContinue)
if ($historyFiles.Count -eq 0) {
  $historyFiles = @(Get-ChildItem -Path $historyDir -Filter 'summary-*.json' -File -ErrorAction SilentlyContinue)
}

$historyItems = foreach ($file in $historyFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $MaxHistoryItems) {
  try { Read-JsonFile -Path $file.FullName } catch { $null }
}
$historyItems = @($historyItems | Where-Object { $_ })

$latestFailures = @($historyItems | Where-Object { [string]$_.policyOutcome -eq 'fail' })
$latestWarnings = @($historyItems | Where-Object { [string]$_.policyOutcome -eq 'warn' })

$trend = [ordered]@{
  schema = 'release-vi-history/trend@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  currentTag = $Tag
  currentProfile = $Profile
  historyCount = $historyItems.Count
  outcomes = [ordered]@{
    pass = @($historyItems | Where-Object { [string]$_.policyOutcome -eq 'pass' }).Count
    warn = $latestWarnings.Count
    fail = $latestFailures.Count
  }
  latest = [ordered]@{
    tag = $summary.tag
    policyOutcome = $summary.policyOutcome
    violationCount = $summary.violationCount
    rowCount = $summary.rowCount
  }
}

$trendJsonPath = Join-Path $OutputDir 'release-vi-history-trend.json'
$trend | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $trendJsonPath -Encoding utf8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Release VI History Trend') | Out-Null
$lines.Add('') | Out-Null
$lines.Add(("- Current tag: {0}" -f $Tag)) | Out-Null
$lines.Add(("- Profile: {0}" -f $Profile)) | Out-Null
$lines.Add(("- Policy outcome: **{0}**" -f $summary.policyOutcome)) | Out-Null
$lines.Add(("- Violations: **{0}**" -f $summary.violationCount)) | Out-Null
$lines.Add(("- Rows evaluated: **{0}**" -f $summary.rowCount)) | Out-Null
$lines.Add(("- History items considered: **{0}**" -f $historyItems.Count)) | Out-Null
$lines.Add('') | Out-Null
$lines.Add('| Outcome | Count |') | Out-Null
$lines.Add('|---|---:|') | Out-Null
$lines.Add(("| pass | {0} |" -f $trend.outcomes.pass)) | Out-Null
$lines.Add(("| warn | {0} |" -f $trend.outcomes.warn)) | Out-Null
$lines.Add(("| fail | {0} |" -f $trend.outcomes.fail)) | Out-Null
$lines.Add('') | Out-Null
$lines.Add(("Run details: [{0}]({0})" -f $RunUrl)) | Out-Null

$trendMdPath = Join-Path $OutputDir 'release-vi-history-trend.md'
$lines -join [Environment]::NewLine | Set-Content -LiteralPath $trendMdPath -Encoding utf8

Write-Host ("Wrote summary: {0}" -f $summaryPath)
Write-Host ("Wrote trend JSON: {0}" -f $trendJsonPath)
Write-Host ("Wrote trend markdown: {0}" -f $trendMdPath)
