[CmdletBinding()]
param(
  [string]$RepoSlug = 'svelderrainruiz/compare-vi-cli-action',
  [long]$RunId,
  [string]$Tag,
  [string]$RunUrl,
  [string]$IndexJobUrl,
  [string]$PolicySummaryPath,
  [string]$TrackerPath = 'docs/RELEASE_VI_HISTORY_STABLE_ENFORCEMENT_MONITORING.md',
  [string]$DownloadRoot = 'tests/results/_agent/release-proof/monitoring-auto',
  [string]$DateUtc = ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestStableReleaseRun {
  param([string]$Repo)

  $runs = gh run list -R $Repo --workflow 'Release on tag' --limit 100 --json databaseId,displayTitle,headBranch,status,conclusion,url,createdAt | ConvertFrom-Json
  $stableRuns = @($runs | Where-Object {
      $candidate = [string]$(if ([string]::IsNullOrWhiteSpace($_.displayTitle)) { $_.headBranch } else { $_.displayTitle })
      $_.status -eq 'completed' -and $_.conclusion -eq 'success' -and $candidate -like 'v*' -and $candidate -notmatch '-'
    } | Sort-Object createdAt -Descending)

  if ($stableRuns.Count -eq 0) {
    throw "No successful stable Release on tag runs found in $Repo"
  }

  return $stableRuns[0]
}

function Get-RunDetails {
  param(
    [string]$Repo,
    [long]$Id
  )

  return gh run view -R $Repo $Id --json url,displayTitle,headBranch,jobs | ConvertFrom-Json
}

function Resolve-PolicyPathFromRun {
  param(
    [string]$Repo,
    [long]$Id,
    [string]$Root
  )

  $targetDir = Join-Path $Root ([string]$Id)
  if (Test-Path -LiteralPath $targetDir) {
    Remove-Item -LiteralPath $targetDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

  gh run download -R $Repo $Id -n release-vi-history-review-index -D $targetDir | Out-Null
  $policyFile = Get-ChildItem -Path $targetDir -Filter 'release-vi-history-policy.json' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $policyFile) {
    throw "release-vi-history-policy.json not found in downloaded artifact for run $Id"
  }
  return $policyFile.FullName
}

function Upsert-MonitoringRow {
  param(
    [string]$Path,
    [string]$Row,
    [string]$TagValue
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Tracker file not found: $Path"
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($line in Get-Content -LiteralPath $Path) { $lines.Add([string]$line) | Out-Null }

  $headerIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -like '| Date (UTC) | Tag |*') {
      $headerIndex = $i
      break
    }
  }
  if ($headerIndex -lt 0) {
    throw "Could not find evidence table header in $Path"
  }

  $firstRowIndex = $headerIndex + 2
  if ($firstRowIndex -ge $lines.Count) {
    $lines.Add($Row) | Out-Null
    $lines | Set-Content -LiteralPath $Path -Encoding utf8
    return 'appended-empty'
  }

  for ($i = $firstRowIndex; $i -lt $lines.Count; $i++) {
    $current = $lines[$i]
    if ($current -notlike '|*') {
      $lines.Insert($i, $Row)
      $lines | Set-Content -LiteralPath $Path -Encoding utf8
      return 'appended'
    }

    if ($current -match '\|\s*next-stable-tag\s*\|') {
      $lines[$i] = $Row
      $lines | Set-Content -LiteralPath $Path -Encoding utf8
      return 'replaced-placeholder'
    }

    if ($current -match "\|\s*$([regex]::Escape($TagValue))\s*\|") {
      $lines[$i] = $Row
      $lines | Set-Content -LiteralPath $Path -Encoding utf8
      return 'updated-existing-tag'
    }
  }

  $lines.Add($Row) | Out-Null
  $lines | Set-Content -LiteralPath $Path -Encoding utf8
  return 'appended-eof'
}

$effectiveRunId = $RunId
$effectiveTag = $Tag
$effectiveRunUrl = $RunUrl
$effectiveIndexJobUrl = $IndexJobUrl

if ([string]::IsNullOrWhiteSpace($PolicySummaryPath)) {
  if ($effectiveRunId -le 0) {
    $latest = Get-LatestStableReleaseRun -Repo $RepoSlug
    $effectiveRunId = [long]$latest.databaseId
    if ([string]::IsNullOrWhiteSpace($effectiveTag)) {
      $effectiveTag = [string]$(if ([string]::IsNullOrWhiteSpace($latest.displayTitle)) { $latest.headBranch } else { $latest.displayTitle })
    }
    if ([string]::IsNullOrWhiteSpace($effectiveRunUrl)) {
      $effectiveRunUrl = [string]$latest.url
    }
  }

  $details = Get-RunDetails -Repo $RepoSlug -Id $effectiveRunId
  if ([string]::IsNullOrWhiteSpace($effectiveTag)) {
    $effectiveTag = [string]$(if ([string]::IsNullOrWhiteSpace($details.displayTitle)) { $details.headBranch } else { $details.displayTitle })
  }
  if ([string]::IsNullOrWhiteSpace($effectiveRunUrl)) {
    $effectiveRunUrl = [string]$details.url
  }
  if ([string]::IsNullOrWhiteSpace($effectiveIndexJobUrl)) {
    $indexJob = @($details.jobs | Where-Object { [string]$_.name -eq 'release-vi-history-review-index' } | Select-Object -First 1)
    if ($indexJob) {
      $effectiveIndexJobUrl = [string]$indexJob.url
    }
  }

  $PolicySummaryPath = Resolve-PolicyPathFromRun -Repo $RepoSlug -Id $effectiveRunId -Root $DownloadRoot
}

if ([string]::IsNullOrWhiteSpace($effectiveTag)) {
  throw 'Tag is required (directly or from run metadata).'
}
if ([string]::IsNullOrWhiteSpace($effectiveRunUrl)) {
  $effectiveRunUrl = 'pending-run-url'
}
if ([string]::IsNullOrWhiteSpace($effectiveIndexJobUrl)) {
  $effectiveIndexJobUrl = 'pending-index-job-url'
}

$policyFieldsScript = Join-Path $PSScriptRoot 'Get-ReleaseVIHistoryPolicyFields.ps1'
$fields = & $policyFieldsScript -PolicySummaryPath $PolicySummaryPath

$tagClass = if ([string]::IsNullOrWhiteSpace([string]$fields.tagClass)) { if ($effectiveTag -match '-') { 'rc' } else { 'stable' } } else { [string]$fields.tagClass }
$note = "auto-harvested from run $effectiveRunId"
$row = "| $DateUtc | $effectiveTag | $tagClass | $effectiveRunUrl | $effectiveIndexJobUrl | $([string]$fields.enforcementSource) | $([string]$fields.enforcementMode) | $([string]$fields.rawOutcome) | $([string]$fields.outcome) | $note |"

$action = Upsert-MonitoringRow -Path $TrackerPath -Row $row -TagValue $effectiveTag

[pscustomobject]@{
  trackerPath = $TrackerPath
  action = $action
  tag = $effectiveTag
  runId = $effectiveRunId
  runUrl = $effectiveRunUrl
  indexJobUrl = $effectiveIndexJobUrl
  policySummaryPath = $PolicySummaryPath
  row = $row
}