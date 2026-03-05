param(
  [Parameter()][string]$PullRequest,
  [Parameter()][string]$Repository,
  [Parameter()][int]$IntervalSeconds = 20,
  [Parameter()][int]$HeartbeatPolls = 6,
  [Parameter()][int]$MaxPolls = 0,
  [Parameter()][switch]$RequiredOnly,
  [Parameter()][switch]$FailFast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-GhPath {
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    return $gh.Source
  }

  $fallback = 'C:\Program Files\GitHub CLI\gh.exe'
  if (Test-Path -LiteralPath $fallback) {
    return $fallback
  }

  throw 'GitHub CLI (gh) was not found. Install gh or add it to PATH.'
}

function Invoke-GhJson {
  param(
    [Parameter(Mandatory)][string]$GhPath,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  $output = & $GhPath @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ("gh command failed (exit {0}): gh {1}`n{2}" -f $LASTEXITCODE, ($Arguments -join ' '), ($output -join "`n"))
  }

  if (-not $output) {
    return @()
  }

  $jsonText = ($output -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    return @()
  }

  $parsed = $jsonText | ConvertFrom-Json -Depth 20
  if ($parsed -is [System.Array]) {
    return $parsed
  }

  if ($null -eq $parsed) {
    return @()
  }

  return @($parsed)
}

function Resolve-PullRequestNumber {
  param(
    [Parameter(Mandatory)][string]$GhPath,
    [Parameter()][string]$ExplicitPullRequest,
    [Parameter()][string]$Repository
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitPullRequest)) {
    return $ExplicitPullRequest
  }

  $args = @('pr', 'view', '--json', 'number', '--jq', '.number')
  if (-not [string]::IsNullOrWhiteSpace($Repository)) {
    $args += @('--repo', $Repository)
  }

  $number = & $GhPath @args 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($number)) {
    throw 'Unable to determine pull request number. Pass -PullRequest <number>.'
  }

  return $number.Trim()
}

function Get-PrChecksSnapshot {
  param(
    [Parameter(Mandatory)][string]$GhPath,
    [Parameter(Mandatory)][string]$PullRequest,
    [Parameter()][string]$Repository,
    [Parameter()][switch]$RequiredOnly
  )

  $args = @('pr', 'checks', $PullRequest, '--json', 'name,state,workflow,bucket,link')
  if ($RequiredOnly) {
    $args += '--required'
  }
  if (-not [string]::IsNullOrWhiteSpace($Repository)) {
    $args += @('--repo', $Repository)
  }

  $checks = Invoke-GhJson -GhPath $GhPath -Arguments $args
  return @($checks | ForEach-Object {
      [pscustomobject]@{
        Workflow = [string]$_.workflow
        Name = [string]$_.name
        Bucket = [string]$_.bucket
        State = [string]$_.state
        Link = [string]$_.link
      }
    })
}

function Get-BucketCount {
  param(
    [Parameter(Mandatory)][System.Collections.IEnumerable]$Checks,
    [Parameter(Mandatory)][string]$Bucket
  )

  $items = @($Checks)
  return @($items | Where-Object { $_.Bucket -eq $Bucket }).Count
}

function Get-CheckMap {
  param([Parameter(Mandatory)][System.Collections.IEnumerable]$Checks)
  $map = @{}
  foreach ($check in $Checks) {
    $key = "{0}/{1}" -f $check.Workflow, $check.Name
    $map[$key] = [string]$check.Bucket
  }
  return $map
}

function Write-SummaryLine {
  param(
    [Parameter(Mandatory)][int]$Iteration,
    [Parameter(Mandatory)][System.Collections.IEnumerable]$Checks
  )

  $items = @($Checks)
  $pass = Get-BucketCount -Checks $items -Bucket 'pass'
  $fail = Get-BucketCount -Checks $items -Bucket 'fail'
  $pending = Get-BucketCount -Checks $items -Bucket 'pending'
  $skipping = Get-BucketCount -Checks $items -Bucket 'skipping'
  $cancel = Get-BucketCount -Checks $items -Bucket 'cancel'
  $stamp = (Get-Date).ToString('u')

  Write-Host ("[{0}] poll={1} pass={2} fail={3} pending={4} skip={5} cancel={6}" -f $stamp, $Iteration, $pass, $fail, $pending, $skipping, $cancel)
}

if ($IntervalSeconds -lt 5) {
  throw '-IntervalSeconds must be >= 5 to avoid excessive polling.'
}
if ($HeartbeatPolls -lt 1) {
  throw '-HeartbeatPolls must be >= 1.'
}
if ($MaxPolls -lt 0) {
  throw '-MaxPolls must be >= 0.'
}

$ghPath = Resolve-GhPath
$targetPr = Resolve-PullRequestNumber -GhPath $ghPath -ExplicitPullRequest $PullRequest -Repository $Repository

Write-Host ("Monitoring PR #{0} with snapshot polling (interval={1}s, requiredOnly={2}, failFast={3})." -f $targetPr, $IntervalSeconds, [bool]$RequiredOnly, [bool]$FailFast)
Write-Host 'Using gh pr checks --json snapshots (no --watch).'

$previousMap = $null
$poll = 0

while ($true) {
  $poll += 1
  $checks = @(Get-PrChecksSnapshot -GhPath $ghPath -PullRequest $targetPr -Repository $Repository -RequiredOnly:$RequiredOnly)
  $currentMap = Get-CheckMap -Checks $checks

  if ($null -eq $previousMap) {
    Write-SummaryLine -Iteration $poll -Checks $checks
  } else {
    $changed = @()
    foreach ($key in $currentMap.Keys) {
      if (-not $previousMap.ContainsKey($key) -or $previousMap[$key] -ne $currentMap[$key]) {
        $changed += [pscustomobject]@{ Key = $key; Bucket = $currentMap[$key] }
      }
    }
    foreach ($key in $previousMap.Keys) {
      if (-not $currentMap.ContainsKey($key)) {
        $changed += [pscustomobject]@{ Key = $key; Bucket = 'removed' }
      }
    }

    if ($changed.Count -gt 0) {
      Write-SummaryLine -Iteration $poll -Checks $checks
      foreach ($entry in ($changed | Sort-Object Key | Select-Object -First 12)) {
        Write-Host ("  - {0} => {1}" -f $entry.Key, $entry.Bucket)
      }
      if ($changed.Count -gt 12) {
        Write-Host ("  - ... {0} additional change(s)" -f ($changed.Count - 12))
      }
    } elseif (($poll % $HeartbeatPolls) -eq 0) {
      Write-SummaryLine -Iteration $poll -Checks $checks
      Write-Host '  (no state changes since last poll)'
    }
  }

  $failCount = Get-BucketCount -Checks $checks -Bucket 'fail'
  $pendingCount = Get-BucketCount -Checks $checks -Bucket 'pending'

  if ($FailFast -and $failCount -gt 0) {
    Write-Host 'Fail-fast: at least one check failed.'
    exit 1
  }

  if ($pendingCount -eq 0) {
    if ($failCount -gt 0) {
      Write-Host 'Completed with failures.'
      exit 1
    }
    Write-Host 'All tracked checks completed successfully.'
    exit 0
  }

  if ($MaxPolls -gt 0 -and $poll -ge $MaxPolls) {
    Write-Host ("Reached MaxPolls={0} with pending checks still present." -f $MaxPolls)
    exit 8
  }

  $previousMap = $currentMap
  Start-Sleep -Seconds $IntervalSeconds
}
