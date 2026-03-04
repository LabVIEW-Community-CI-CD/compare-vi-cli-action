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
  [string]$DateUtc = ((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')),
  [switch]$EmitPrCommentBody,
  [string]$CommentBodyPath = 'tests/results/_agent/release-proof/monitoring-auto/pr-comment.md',
  [switch]$PostPrComment,
  [int]$PrNumber,
  [string]$PrRepoSlug
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StableReleaseRuns {
  param([string]$Repo)

  $runs = gh run list -R $Repo --workflow 'Release on tag' --limit 100 --json databaseId,displayTitle,headBranch,status,conclusion,url,createdAt | ConvertFrom-Json
  $stableRuns = @($runs | Where-Object {
      $displayTitle = [string]$_.displayTitle
      $headBranch = [string]$_.headBranch
      $isStableTag = (($displayTitle -like 'v*' -and $displayTitle -notmatch '-') -or ($headBranch -like 'v*' -and $headBranch -notmatch '-'))
      $_.status -eq 'completed' -and $_.conclusion -eq 'success' -and $isStableTag
    } | Sort-Object createdAt -Descending)

  return $stableRuns
}

function Get-RunDetails {
  param(
    [string]$Repo,
    [long]$Id
  )

  return gh run view -R $Repo $Id --json url,displayTitle,headBranch,jobs | ConvertFrom-Json
}

function Resolve-TagFromRunMetadata {
  param(
    [string]$DisplayTitle,
    [string]$HeadBranch
  )

  $candidates = @([string]$HeadBranch, [string]$DisplayTitle)
  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -like 'v*') {
      return $candidate
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($HeadBranch)) {
    return [string]$HeadBranch
  }

  return [string]$DisplayTitle
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

function Build-PrCommentBody {
  param(
    [string]$TagValue,
    [string]$RunUrlValue,
    [string]$IndexJobUrlValue,
    [string]$RowValue,
    [object]$FieldsValue,
    [string]$TrackerValue,
    [string]$ActionValue
  )

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add('Stable enforcement monitoring row updated.') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Tag: `{0}`' -f $TagValue)) | Out-Null
  $lines.Add(('- Run: {0}' -f $RunUrlValue)) | Out-Null
  $lines.Add(('- Index job: {0}' -f $IndexJobUrlValue)) | Out-Null
  $lines.Add(('- Tracker action: `{0}`' -f $ActionValue)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('Extracted policy fields:') | Out-Null
  $lines.Add(('- tagClass: `{0}`' -f [string]$FieldsValue.tagClass)) | Out-Null
  $lines.Add(('- enforcementSource: `{0}`' -f [string]$FieldsValue.enforcementSource)) | Out-Null
  $lines.Add(('- enforcementMode: `{0}`' -f [string]$FieldsValue.enforcementMode)) | Out-Null
  $lines.Add(('- rawOutcome: `{0}`' -f [string]$FieldsValue.rawOutcome)) | Out-Null
  $lines.Add(('- outcome: `{0}`' -f [string]$FieldsValue.outcome)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Tracker file: `{0}`' -f $TrackerValue)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('Appended row:') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('`{0}`' -f $RowValue)) | Out-Null

  return ($lines -join [Environment]::NewLine)
}

$effectiveRunId = $RunId
$effectiveTag = $Tag
$effectiveRunUrl = $RunUrl
$effectiveIndexJobUrl = $IndexJobUrl

if ([string]::IsNullOrWhiteSpace($PolicySummaryPath)) {
  if ($effectiveRunId -le 0) {
    $stableRuns = @(Get-StableReleaseRuns -Repo $RepoSlug)
    if ($stableRuns.Count -eq 0) {
      throw "No successful stable Release on tag runs found in $RepoSlug"
    }

    $selectedDetails = $null
    foreach ($stableRun in $stableRuns) {
      $candidateRunId = [long]$stableRun.databaseId
      try {
        $candidatePolicyPath = Resolve-PolicyPathFromRun -Repo $RepoSlug -Id $candidateRunId -Root $DownloadRoot
        $selectedDetails = Get-RunDetails -Repo $RepoSlug -Id $candidateRunId
        $effectiveRunId = $candidateRunId
        $PolicySummaryPath = $candidatePolicyPath
        if ([string]::IsNullOrWhiteSpace($effectiveTag)) {
          $effectiveTag = Resolve-TagFromRunMetadata -DisplayTitle ([string]$selectedDetails.displayTitle) -HeadBranch ([string]$selectedDetails.headBranch)
        }
        if ([string]::IsNullOrWhiteSpace($effectiveRunUrl)) {
          $effectiveRunUrl = [string]$selectedDetails.url
        }
        if ([string]::IsNullOrWhiteSpace($effectiveIndexJobUrl)) {
          $indexJob = @($selectedDetails.jobs | Where-Object { [string]$_.name -eq 'release-vi-history-review-index' } | Select-Object -First 1)
          if ($indexJob) {
            $effectiveIndexJobUrl = [string]$indexJob.url
          }
        }
        break
      } catch {
        Write-Verbose "Skipping stable run ${candidateRunId}: $($_.Exception.Message)"
      }
    }

    if ([string]::IsNullOrWhiteSpace($PolicySummaryPath)) {
      throw "No successful stable Release on tag runs with release-vi-history-policy.json artifact found in $RepoSlug"
    }
  }

  if ($effectiveRunId -gt 0 -and [string]::IsNullOrWhiteSpace($PolicySummaryPath)) {
    $details = Get-RunDetails -Repo $RepoSlug -Id $effectiveRunId
    if ([string]::IsNullOrWhiteSpace($effectiveTag)) {
      $effectiveTag = Resolve-TagFromRunMetadata -DisplayTitle ([string]$details.displayTitle) -HeadBranch ([string]$details.headBranch)
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

$commentBody = Build-PrCommentBody `
  -TagValue $effectiveTag `
  -RunUrlValue $effectiveRunUrl `
  -IndexJobUrlValue $effectiveIndexJobUrl `
  -RowValue $row `
  -FieldsValue $fields `
  -TrackerValue $TrackerPath `
  -ActionValue $action

if ($EmitPrCommentBody -or $PostPrComment) {
  $commentDir = Split-Path -Parent $CommentBodyPath
  if (-not [string]::IsNullOrWhiteSpace($commentDir) -and -not (Test-Path -LiteralPath $commentDir -PathType Container)) {
    New-Item -ItemType Directory -Path $commentDir -Force | Out-Null
  }
  Set-Content -LiteralPath $CommentBodyPath -Value $commentBody -Encoding utf8
}

if ($PostPrComment) {
  if ($PrNumber -le 0) {
    throw 'PrNumber is required when -PostPrComment is set.'
  }
  if ([string]::IsNullOrWhiteSpace($PrRepoSlug)) {
    throw 'PrRepoSlug is required when -PostPrComment is set.'
  }
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') is required when -PostPrComment is set."
  }

  & gh pr comment $PrNumber --repo $PrRepoSlug --body-file $CommentBodyPath
  if ($LASTEXITCODE -ne 0) {
    throw "gh pr comment failed with exit code $LASTEXITCODE"
  }
}

[pscustomobject]@{
  trackerPath = $TrackerPath
  action = $action
  tag = $effectiveTag
  runId = $effectiveRunId
  runUrl = $effectiveRunUrl
  indexJobUrl = $effectiveIndexJobUrl
  policySummaryPath = $PolicySummaryPath
  row = $row
  commentBodyPath = if ($EmitPrCommentBody -or $PostPrComment) { $CommentBodyPath } else { '' }
}