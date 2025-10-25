param(
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [Parameter(Mandatory = $true)]
  [string]$ModeSummaryJson,
  [Parameter(Mandatory = $true)]
  [string]$Issue,
  [string]$Repository = $env:GITHUB_REPOSITORY,
  [string]$GitHubToken,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
  throw ("Manifest not found at {0}" -f $ManifestPath)
}

$aggregate = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 16
if (-not $aggregate) {
  throw ("Unable to deserialize manifest: {0}" -f $ManifestPath)
}

$modeSummaries = @()
if (-not [string]::IsNullOrWhiteSpace($ModeSummaryJson)) {
  try {
    $parsed = $ModeSummaryJson | ConvertFrom-Json -Depth 8
    if ($parsed) {
      $modeSummaries = @($parsed)
    }
  } catch {
    Write-Warning ("Failed to parse mode summary JSON: {0}" -f $_.Exception.Message)
  }
}

if (-not $modeSummaries -and $aggregate.modes) {
  $modeSummaries = @($aggregate.modes)
}

if (-not $modeSummaries) {
  throw 'Mode summary data unavailable; cannot build stakeholder report.'
}

$targetPath = $aggregate.targetPath
$requestedStart = $aggregate.requestedStartRef
$resolvedStart = $aggregate.startRef
$endRef = $aggregate.endRef
$totalProcessed = $aggregate.stats.processed
$totalDiffs = $aggregate.stats.diffs
$totalMissing = $aggregate.stats.missing
$modeNames = ($modeSummaries | ForEach-Object { $_.mode ?? $_.name })

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("### Manual VI Compare summary")
$lines.Add("")
$lines.Add(("* Target: `{0}`" -f $targetPath))
if ($requestedStart -and $requestedStart -ne $resolvedStart) {
  $lines.Add(("* Requested start ref: `{0}`" -f $requestedStart))
  $lines.Add(("* Resolved start ref: `{0}`" -f $resolvedStart))
} else {
  $lines.Add(("* Start ref: `{0}`" -f $resolvedStart))
}
if ($endRef) {
  $lines.Add(("* End ref: `{0}`" -f $endRef))
}
$lines.Add(("* Modes: {0}" -f ([string]::Join(', ', $modeNames))))
$lines.Add(("* Total processed pairs: {0}" -f $totalProcessed))
$lines.Add(("* Total diffs: {0}" -f $totalDiffs))
$lines.Add(("* Total missing pairs: {0}" -f $totalMissing))
$lines.Add("")
$lines.Add("| Mode | Processed | Diffs | Missing | Last Diff | Status |")
$lines.Add("| --- | ---: | ---: | ---: | --- | --- |")

foreach ($mode in $modeSummaries) {
  $modeName = $mode.mode
  if (-not $modeName) { $modeName = $mode.name }
  $processed = $mode.processed
  if ($null -eq $processed -and $mode.stats) { $processed = $mode.stats.processed }
  $diffs = if ($mode.diffs -ne $null) { $mode.diffs } elseif ($mode.stats) { $mode.stats.diffs } else { 0 }
  $missing = if ($mode.missing -ne $null) { $mode.missing } elseif ($mode.stats) { $mode.stats.missing } else { 0 }
  $lastDiffIndex = if ($mode.lastDiffIndex -ne $null) { $mode.lastDiffIndex } elseif ($mode.stats) { $mode.stats.lastDiffIndex } else { $null }
  $lastDiffCommit = if ($mode.lastDiffCommit) { $mode.lastDiffCommit } elseif ($mode.stats) { $mode.stats.lastDiffCommit } else { $null }
  $status = if ($mode.status) { $mode.status } else { 'unknown' }

  $lastDiffCell = '—'
  if ($diffs -gt 0) {
    if ($lastDiffIndex) {
      $lastDiffCell = "#$lastDiffIndex"
      if ($lastDiffCommit) {
        $shortSha = if ($lastDiffCommit.Length -gt 12) { $lastDiffCommit.Substring(0, 12) } else { $lastDiffCommit }
        $lastDiffCell += " @$shortSha"
      }
    } else {
      $lastDiffCell = 'diff detected'
    }
  }

  $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $modeName, $processed, $diffs, $missing, $lastDiffCell, $status))
}

if ($totalDiffs -gt 0) {
  $lines.Add("")
  $lines.Add("Diff artifacts are available under the `vi-compare-diff-artifacts` upload.")
}

$body = $lines -join "`n"

if ($DryRun.IsPresent) {
  Write-Host "[dry-run] Would post comment to issue #$Issue:"
  Write-Host $body
  return
}

if (-not $Repository) {
  throw 'Repository not specified (set --Repository or GITHUB_REPOSITORY).'
}

if (-not $GitHubToken) {
  if ($env:GH_TOKEN) {
    $GitHubToken = $env:GH_TOKEN
  } elseif ($env:GITHUB_TOKEN) {
    $GitHubToken = $env:GITHUB_TOKEN
  }
}

if (-not $GitHubToken) {
  throw 'GitHub token not provided (set GH_TOKEN or GITHUB_TOKEN).'
}

$uri = "https://api.github.com/repos/$Repository/issues/$Issue/comments"
$headers = @{
  Authorization = "Bearer $GitHubToken"
  'User-Agent' = 'compare-vi-cli-action'
  Accept = 'application/vnd.github+json'
  'Content-Type' = 'application/json'
}
$payload = @{ body = $body } | ConvertTo-Json -Depth 4

Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $payload | Out-Null
