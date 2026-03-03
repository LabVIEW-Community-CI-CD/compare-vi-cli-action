#Requires -Version 7.0
param(
  [string]$BaseRef,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-MergeBase {
  param([string[]]$Candidates)
  foreach ($candidate in $Candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $rawRef = (& git rev-parse --verify $candidate 2>$null)
    if (-not $rawRef) { continue }
    $ref = $rawRef.Trim()
    if (-not $ref) { continue }
    $mergeBase = (& git merge-base HEAD $ref 2>$null)
    if ($mergeBase) {
      return $mergeBase.Trim()
    }
    return $ref
  }
  return $null
}

function Resolve-PullRequestRangeFromEvent {
  if ([string]::IsNullOrWhiteSpace($env:GITHUB_EVENT_PATH)) { return $null }
  if (-not (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH -PathType Leaf)) { return $null }
  try {
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -Depth 40
  } catch {
    return $null
  }
  if (-not $event) { return $null }
  if (-not ($event.PSObject.Properties.Name -contains 'pull_request')) { return $null }

  $pullRequest = $event.pull_request
  if (-not $pullRequest) { return $null }
  if (-not ($pullRequest.PSObject.Properties.Name -contains 'base')) { return $null }
  if (-not ($pullRequest.PSObject.Properties.Name -contains 'head')) { return $null }
  if (-not $pullRequest.base -or -not $pullRequest.head) { return $null }

  $baseSha = if ($pullRequest.base.PSObject.Properties.Name -contains 'sha') { [string]$pullRequest.base.sha } else { '' }
  $headSha = if ($pullRequest.head.PSObject.Properties.Name -contains 'sha') { [string]$pullRequest.head.sha } else { '' }
  if ([string]::IsNullOrWhiteSpace($baseSha) -or [string]::IsNullOrWhiteSpace($headSha)) {
    return $null
  }

  return [pscustomobject]@{
    BaseSha = $baseSha.Trim()
    HeadSha = $headSha.Trim()
  }
}

function Resolve-PullRequestFilesFromApi {
  if (-not $env:GITHUB_ACTIONS) { return @() }
  if ([string]::IsNullOrWhiteSpace($env:GITHUB_EVENT_PATH)) { return @() }
  if (-not (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH -PathType Leaf)) { return @() }

  try {
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -Depth 40
  } catch {
    return @()
  }

  $prNumber = $null
  if ($event.PSObject.Properties.Name -contains 'pull_request' -and $event.pull_request) {
    if ($event.pull_request.PSObject.Properties.Name -contains 'number') {
      $prNumber = $event.pull_request.number
    }
  }
  if (-not $prNumber) { return @() }

  $repository = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    $env:GITHUB_REPOSITORY
  } elseif (
    ($event.PSObject.Properties.Name -contains 'repository') -and
    $event.repository -and
    ($event.repository.PSObject.Properties.Name -contains 'full_name') -and
    $event.repository.full_name
  ) {
    [string]$event.repository.full_name
  } else {
    ''
  }
  if ([string]::IsNullOrWhiteSpace($repository)) { return @() }

  $token = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $env:GITHUB_TOKEN
  } elseif (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    $env:GH_TOKEN
  } else {
    ''
  }
  if ([string]::IsNullOrWhiteSpace($token)) { return @() }

  $apiBase = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_API_URL)) {
    $env:GITHUB_API_URL.TrimEnd('/')
  } else {
    'https://api.github.com'
  }

  $headers = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  $paths = New-Object System.Collections.Generic.List[string]
  $page = 1
  while ($true) {
    $uri = "{0}/repos/{1}/pulls/{2}/files?per_page=100&page={3}" -f $apiBase, $repository, $prNumber, $page
    try {
      $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
    } catch {
      break
    }
    if (-not $response) { break }
    foreach ($entry in $response) {
      $filename = [string]$entry.filename
      if (-not [string]::IsNullOrWhiteSpace($filename)) {
        $paths.Add($filename.Trim()) | Out-Null
      }
    }
    if ($response.Count -lt 100) { break }
    $page++
  }

  return @($paths | Sort-Object -Unique)
}

function Resolve-PullRequestFilesFromRefs {
  if (-not $env:GITHUB_ACTIONS) { return @() }
  if ([string]::IsNullOrWhiteSpace($env:GITHUB_BASE_REF)) { return @() }
  if ([string]::IsNullOrWhiteSpace($env:GITHUB_HEAD_REF)) { return @() }

  $baseRef = $env:GITHUB_BASE_REF.Trim()
  $headRef = $env:GITHUB_HEAD_REF.Trim()
  $remoteBase = "refs/remotes/origin/$baseRef"
  $remoteHead = "refs/remotes/origin/$headRef"

  $fetchBase = "+refs/heads/${baseRef}:$remoteBase"
  $fetchHead = "+refs/heads/${headRef}:$remoteHead"
  & git fetch --no-tags --depth=200 origin $fetchBase 2>$null | Out-Null
  & git fetch --no-tags --depth=200 origin $fetchHead 2>$null | Out-Null

  $rangeFiles = & git diff --name-only --diff-filter=ACMRTUXB "$remoteBase..$remoteHead" 2>$null
  return @($rangeFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Ensure-CommitAvailable {
  param([string]$Sha)
  if ([string]::IsNullOrWhiteSpace($Sha)) { return $false }

  & git cat-file -e "${Sha}^{commit}" 2>$null
  if ($LASTEXITCODE -eq 0) { return $true }

  & git fetch --no-tags --depth=1 origin $Sha 2>$null | Out-Null
  & git cat-file -e "${Sha}^{commit}" 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-ChangedFiles {
  param([string]$MergeBase)
  $files = New-Object System.Collections.Generic.List[string]

  $apiFiles = @(Resolve-PullRequestFilesFromApi)
  foreach ($item in $apiFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }

  if ($files.Count -eq 0) {
    $refFiles = @(Resolve-PullRequestFilesFromRefs)
    foreach ($item in $refFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }
  }

  $prRange = Resolve-PullRequestRangeFromEvent
  if ($files.Count -eq 0 -and $env:GITHUB_ACTIONS -and $prRange) {
    $baseReady = Ensure-CommitAvailable -Sha $prRange.BaseSha
    $headReady = Ensure-CommitAvailable -Sha $prRange.HeadSha
    if ($baseReady -and $headReady) {
      $eventRangeFiles = & git diff --name-only --diff-filter=ACMRTUXB "$($prRange.BaseSha)..$($prRange.HeadSha)" 2>$null
      foreach ($item in $eventRangeFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }
    }
  }

  $firstParent = (& git rev-parse --verify HEAD^1 2>$null | Select-Object -First 1)
  $secondParent = (& git rev-parse --verify HEAD^2 2>$null | Select-Object -First 1)
  $hasMergeParents = -not [string]::IsNullOrWhiteSpace($firstParent) -and -not [string]::IsNullOrWhiteSpace($secondParent)
  if ($files.Count -eq 0 -and $env:GITHUB_ACTIONS -and $hasMergeParents) {
    # On PR checks, GitHub checks out a synthetic merge commit. Diffing against HEAD^1
    # isolates only PR-head changes and avoids unrelated base-branch churn.
    $prMergeFiles = & git diff --name-only --diff-filter=ACMRTUXB "HEAD^1..HEAD" 2>$null
    foreach ($item in $prMergeFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }
  }

  if ($files.Count -eq 0 -and $MergeBase) {
    $rangeFiles = & git diff --name-only --diff-filter=ACMRTUXB "$MergeBase..HEAD" 2>$null
    foreach ($item in $rangeFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }
  }
  $worktreeFiles = & git diff --name-only --diff-filter=ACMRTUXB HEAD 2>$null
  foreach ($item in $worktreeFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }
  $stagedFiles = & git diff --name-only --cached --diff-filter=ACMRTUXB 2>$null
  foreach ($item in $stagedFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }

  $statusFiles = @()
  if ($files.Count -eq 0) {
    $statusFiles = @(Resolve-StatusChangedFiles)
    foreach ($item in $statusFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }
  }

  $isGitHubActions = -not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)
  $allowTrackedFallback = -not $isGitHubActions
  if ($files.Count -eq 0 -and $allowTrackedFallback) {
    # Fallback for pure line-ending drift that may not appear in `git diff --name-only`.
    $trackedEolFiles = Resolve-TrackedEolFiles
    foreach ($item in $trackedEolFiles) { if ($item) { $files.Add([string]$item) | Out-Null } }
  }

  return @(
    $files |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim() } |
      Sort-Object -Unique
  )
}

function Parse-EolRecord {
  param([string]$Line)
  if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
  $segments = $Line -split "`t", 2
  if ($segments.Count -lt 2) { return $null }
  $left = $segments[0].Trim()
  $path = $segments[1].Trim()
  if (-not ($left -match '^(?<index>\S+)\s+(?<working>\S+)\s+(?<attr>.+)$')) {
    return $null
  }
  return [pscustomobject]@{
    Index   = $Matches['index']
    Working = $Matches['working']
    Attr    = $Matches['attr'].Trim()
    Path    = $path
  }
}

function Resolve-StatusChangedFiles {
  $statusLines = & git status --porcelain=v1 --untracked-files=no 2>$null
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($line in $statusLines) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) { continue }
    $path = $line.Substring(3).Trim()
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    if ($path -match '\s+->\s+') {
      $path = ($path -split '\s+->\s+')[-1].Trim()
    }
    if ($path.StartsWith('"') -and $path.EndsWith('"')) {
      $path = $path.Substring(1, $path.Length - 2)
    }
    if (-not [string]::IsNullOrWhiteSpace($path)) {
      $paths.Add($path) | Out-Null
    }
  }

  return @($paths | Sort-Object -Unique)
}

function Resolve-TrackedEolFiles {
  $lines = & git ls-files --eol 2>$null
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    $record = Parse-EolRecord -Line $line
    if (-not $record) { continue }
    if ($record.Attr -match '\beol=(lf|crlf)\b') {
      $paths.Add($record.Path) | Out-Null
    }
  }

  return @($paths | Sort-Object -Unique)
}

$candidateRefs = @()
if ($BaseRef) { $candidateRefs += $BaseRef }
if ($env:GITHUB_BASE_SHA) { $candidateRefs += $env:GITHUB_BASE_SHA }
if ($env:GITHUB_BASE_REF) { $candidateRefs += "origin/$($env:GITHUB_BASE_REF)" }
$candidateRefs += @('origin/develop', 'origin/main', 'HEAD~1')

$mergeBase = Resolve-MergeBase -Candidates $candidateRefs
if (-not $mergeBase -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_BASE_REF)) {
  $baseRef = $env:GITHUB_BASE_REF.Trim()
  $remoteRef = "refs/remotes/origin/$baseRef"
  $fetchRefSpec = "+refs/heads/${baseRef}:$remoteRef"
  & git fetch --no-tags --depth=200 origin $fetchRefSpec 2>$null | Out-Null
  $mergeBase = Resolve-MergeBase -Candidates @($remoteRef, "origin/$baseRef", 'origin/develop', 'origin/main', 'HEAD~1')
}
$changedFiles = @(Resolve-ChangedFiles -MergeBase $mergeBase)

$violations = New-Object System.Collections.Generic.List[object]
$checkedCount = 0

foreach ($path in $changedFiles) {
  $line = (& git ls-files --eol -- $path 2>$null | Select-Object -First 1)
  if (-not $line) { continue }
  $record = Parse-EolRecord -Line $line
  if (-not $record) { continue }

  $expected = $null
  if ($record.Attr -match '\beol=lf\b') { $expected = 'w/lf' }
  elseif ($record.Attr -match '\beol=crlf\b') { $expected = 'w/crlf' }
  else { continue }

  $checkedCount++
  if ($record.Working -ne $expected) {
    $violations.Add([pscustomobject]@{
      Path     = $record.Path
      Attr     = $record.Attr
      Working  = $record.Working
      Expected = $expected
    }) | Out-Null
  }
}

$result = [ordered]@{
  schema         = 'line-ending-drift-check@v1'
  mergeBase      = $mergeBase
  changedCount   = @($changedFiles).Count
  checkedCount   = $checkedCount
  violationCount = $violations.Count
  violations     = $violations.ToArray()
}

$resultsDir = Join-Path (Get-Location) 'tests/results/lint'
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
$reportPath = Join-Path $resultsDir 'line-ending-drift.json'
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if ($GitHubOutputPath) {
  "eol-merge-base=$mergeBase" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  "eol-changed-count=$(@($changedFiles).Count)" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  "eol-checked-count=$checkedCount" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  "eol-violation-count=$($violations.Count)" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  "eol-report-path=$reportPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}

$summaryLines = @(
  '### Line Ending Drift Check',
  '',
  "- Merge base: $mergeBase",
  "- Changed files: $(@($changedFiles).Count)",
  "- Checked files: $checkedCount",
  "- Violations: $($violations.Count)",
  "- Report: $reportPath"
)

if ($violations.Count -gt 0) {
  $summaryLines += ''
  $summaryLines += '| Path | Attr | Working | Expected |'
  $summaryLines += '| --- | --- | --- | --- |'
  foreach ($item in $violations) {
    $summaryLines += "| $($item.Path) | $($item.Attr) | $($item.Working) | $($item.Expected) |"
  }
}

$summaryText = $summaryLines -join "`n"
Write-Host $summaryText
if ($StepSummaryPath) {
  $summaryText | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

if ($violations.Count -gt 0) {
  throw ("Line ending determinism check failed with {0} violation(s)." -f $violations.Count)
}
