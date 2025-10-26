param(
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [Parameter(Mandatory = $true)]
  [string]$ModeSummaryJson,
  [string]$HistoryReportPath,
  [string]$HistoryReportHtmlPath,
  [Parameter(Mandatory = $true)]
  [string]$Issue,
  [string]$Repository = $env:GITHUB_REPOSITORY,
  [string]$GitHubToken,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ObjectPropertyValue {
  param(
    [Parameter()]
    $InputObject,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName,
    $Default = $null
  )

  if ($null -eq $InputObject) {
    return $Default
  }

  $property = $InputObject.PSObject.Properties[$PropertyName]
  if ($property) {
    return $property.Value
  }

  return $Default
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
  throw ("Manifest not found at {0}" -f $ManifestPath)
}

$aggregate = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 16
if (-not $aggregate) {
  throw ("Unable to deserialize manifest: {0}" -f $ManifestPath)
}

$historyReportResolved = $null
if (-not [string]::IsNullOrWhiteSpace($HistoryReportPath)) {
  if (Test-Path -LiteralPath $HistoryReportPath -PathType Leaf) {
    $historyReportResolved = (Resolve-Path -LiteralPath $HistoryReportPath).Path
  } else {
    Write-Warning ("History report Markdown not found at {0}" -f $HistoryReportPath)
  }
}

$historyReportHtmlResolved = $null
if (-not [string]::IsNullOrWhiteSpace($HistoryReportHtmlPath)) {
  if (Test-Path -LiteralPath $HistoryReportHtmlPath -PathType Leaf) {
    $historyReportHtmlResolved = (Resolve-Path -LiteralPath $HistoryReportHtmlPath).Path
  } else {
    Write-Warning ("History report HTML not found at {0}" -f $HistoryReportHtmlPath)
  }
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

$aggregateModes = Get-ObjectPropertyValue -InputObject $aggregate -PropertyName 'modes'
if (-not $modeSummaries -and $aggregateModes) {
  $modeSummaries = @($aggregateModes)
}

if (-not $modeSummaries) {
  throw 'Mode summary data unavailable; cannot build stakeholder report.'
}

$targetPath = Get-ObjectPropertyValue -InputObject $aggregate -PropertyName 'targetPath'
$requestedStart = Get-ObjectPropertyValue -InputObject $aggregate -PropertyName 'requestedStartRef'
$resolvedStart = Get-ObjectPropertyValue -InputObject $aggregate -PropertyName 'startRef'
$endRef = Get-ObjectPropertyValue -InputObject $aggregate -PropertyName 'endRef'
$aggregateStats = Get-ObjectPropertyValue -InputObject $aggregate -PropertyName 'stats'
if (-not $aggregateStats) {
  $aggregateStats = [ordered]@{
    processed = 0
    diffs     = 0
    missing   = 0
  }
}
$totalProcessed = Get-ObjectPropertyValue -InputObject $aggregateStats -PropertyName 'processed' -Default 0
$totalDiffs = Get-ObjectPropertyValue -InputObject $aggregateStats -PropertyName 'diffs' -Default 0
$totalMissing = Get-ObjectPropertyValue -InputObject $aggregateStats -PropertyName 'missing' -Default 0

$modeNames = @()
foreach ($mode in $modeSummaries) {
  $modeName = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'mode'
  if (-not $modeName) {
    $modeName = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'name'
  }
  if (-not $modeName) {
    $modeName = '(unnamed)'
  }
  $modeNames += $modeName
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("### Manual VI Compare summary")
$lines.Add("")
$lines.Add(('* Target: `{0}`' -f $targetPath))
if ($requestedStart -and $requestedStart -ne $resolvedStart) {
  $lines.Add(('* Requested start ref: `{0}`' -f $requestedStart))
  $lines.Add(('* Resolved start ref: `{0}`' -f $resolvedStart))
} else {
  $lines.Add(('* Start ref: `{0}`' -f $resolvedStart))
}
if ($endRef) {
  $lines.Add(('* End ref: `{0}`' -f $endRef))
}
$lines.Add(('* Modes: {0}' -f ([string]::Join(', ', $modeNames))))
$lines.Add(('* Total processed pairs: {0}' -f $totalProcessed))
$lines.Add(('* Total diffs: {0}' -f $totalDiffs))
$lines.Add(('* Total missing pairs: {0}' -f $totalMissing))
if ($historyReportResolved) {
  $lines.Add(('* History report: `{0}`' -f $historyReportResolved))
}
if ($historyReportHtmlResolved) {
  $lines.Add(('* History report (HTML): `{0}`' -f $historyReportHtmlResolved))
}
$lines.Add("")
$lines.Add("| Mode | Processed | Diffs | Missing | Last Diff | Status |")
$lines.Add("| --- | ---: | ---: | ---: | --- | --- |")

foreach ($mode in $modeSummaries) {
  $modeName = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'mode'
  if (-not $modeName) {
    $modeName = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'name'
  }
  if (-not $modeName) {
    $modeName = '(unnamed)'
  }

  $modeStats = $null
  if ($mode -and $mode.PSObject.Properties['stats']) {
    $modeStats = $mode.stats
  }

  $processed = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'processed'
  if ($null -eq $processed -and $modeStats) {
    $processed = Get-ObjectPropertyValue -InputObject $modeStats -PropertyName 'processed'
  }
  if ($null -eq $processed) { $processed = 0 }

  $diffs = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'diffs'
  if ($null -eq $diffs -and $modeStats) {
    $diffs = Get-ObjectPropertyValue -InputObject $modeStats -PropertyName 'diffs'
  }
  if ($null -eq $diffs) { $diffs = 0 }

  $missing = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'missing'
  if ($null -eq $missing -and $modeStats) {
    $missing = Get-ObjectPropertyValue -InputObject $modeStats -PropertyName 'missing'
  }
  if ($null -eq $missing) { $missing = 0 }

  $lastDiffIndex = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'lastDiffIndex'
  if ($null -eq $lastDiffIndex -and $modeStats) {
    $lastDiffIndex = Get-ObjectPropertyValue -InputObject $modeStats -PropertyName 'lastDiffIndex'
  }

  $lastDiffCommit = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'lastDiffCommit'
  if (-not $lastDiffCommit -and $modeStats) {
    $lastDiffCommit = Get-ObjectPropertyValue -InputObject $modeStats -PropertyName 'lastDiffCommit'
  }

  $status = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'status' -Default 'unknown'
  if (-not $status) { $status = 'unknown' }

  $lastDiffCell = '-'
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
  $lines.Add('Diff artifacts are available under the `vi-compare-diff-artifacts` upload.')
}

$lines.Add("")
$lines.Add("#### Attribute coverage")
$attributeCoverageAdded = $false
foreach ($mode in $modeSummaries) {
  $modeName = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'mode'
  if (-not $modeName) {
    $modeName = Get-ObjectPropertyValue -InputObject $mode -PropertyName 'name'
  }
  if (-not $modeName) {
    $modeName = '(unnamed)'
  }

  $attributeMap = @{}
  if ($mode -and $mode.PSObject.Properties['comparisons']) {
    foreach ($comparison in @($mode.comparisons)) {
      if (-not $comparison) { continue }

      $resultNode = $null
      if ($comparison.PSObject.Properties['result']) {
        $resultNode = $comparison.result
      }
      if (-not $resultNode) { continue }

      $cliNode = $null
      if ($resultNode.PSObject.Properties['cli']) {
        $cliNode = $resultNode.cli
      }
      if (-not $cliNode) { continue }

      $includedAttributes = $null
      if ($cliNode.PSObject.Properties['includedAttributes']) {
        $includedAttributes = $cliNode.includedAttributes
      }
      if (-not $includedAttributes) { continue }

      foreach ($entry in @($includedAttributes)) {
        if (-not $entry) { continue }
        $attrName = Get-ObjectPropertyValue -InputObject $entry -PropertyName 'name'
        if (-not $attrName) { continue }

        $included = Get-ObjectPropertyValue -InputObject $entry -PropertyName 'included'
        $includedBool = [bool]$included

        if (-not $attributeMap.ContainsKey($attrName)) {
          $attributeMap[$attrName] = $includedBool
        } elseif ($includedBool) {
          $attributeMap[$attrName] = $true
        }
      }
    }
  }

  if ($attributeMap.Count -eq 0) { continue }

  $attributeCoverageAdded = $true
  $segments = @()
  foreach ($kvp in ($attributeMap.GetEnumerator() | Sort-Object Name)) {
    $label = if ($kvp.Value) { 'Yes' } else { 'No' }
    $segments += ("{0}: {1}" -f $kvp.Name, $label)
  }

  $lines.Add(("- **{0}**: {1}" -f $modeName, ($segments -join '; ')))
}

if (-not $attributeCoverageAdded) {
  $lines.Add("- *(Attribute coverage unavailable in manifest)*")
}

$body = $lines -join "`n"

if ($DryRun.IsPresent) {
  Write-Host "[dry-run] Would post comment to issue #${Issue}:"
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
