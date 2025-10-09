<#
.SYNOPSIS
  Monitor a GitHub Actions workflow run and display per-job status in real time.

.DESCRIPTION
  Polls the GitHub API (via `gh api`) for a given workflow run ID, printing a
  concise table of job status (name, status, conclusion, started/completed
  timestamps, duration). Designed for local monitoring of long-running runs.

  The tool can optionally emit a JSON snapshot or append updates to a file so
  future agents can inspect historical job states.

.PARAMETER RunId
  Numeric workflow run identifier (e.g., 18327092270).

.PARAMETER Repo
  Repository in owner/name form. If omitted we attempt to infer it from
  $env:GITHUB_REPOSITORY or git remote origin.

.PARAMETER PollSeconds
  Interval between API polls (default 15).

.PARAMETER TimeoutSeconds
  Max seconds to wait for the run to complete (default 1800). When the timeout
  elapses we print the latest snapshot and exit with code 1.

.PARAMETER Json
  Emit the final snapshot as JSON to stdout.

.PARAMETER OutputPath
  If supplied, write the final snapshot JSON to this path.

.PARAMETER Quiet
  Suppress console table output; useful when only JSON/file output is desired.

.PARAMETER IncludeCheckRuns
  When set, fetch and display check run details for the workflow run's head commit.

#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][long]$RunId,
  [string]$Repo,
  [int]$PollSeconds = 15,
  [int]$TimeoutSeconds = 1800,
  [switch]$Json,
  [string]$OutputPath,
  [switch]$Quiet,
  [switch]$IncludeCheckRuns
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Repo {
  param([string]$RepoParam)
  if ($RepoParam) { return $RepoParam }
  if ($env:GITHUB_REPOSITORY) { return $env:GITHUB_REPOSITORY }
  try {
    $remote = git config --get remote.origin.url 2>$null
    if ($remote) {
      if ($remote -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
        return "$($matches.owner)/$($matches.repo)"
      }
    }
  } catch {}
  throw "Unable to resolve repository. Provide -Repo owner/name explicitly."
}

function Invoke-GhApi {
  param([string]$Path)
  $raw = gh api $Path --header "Accept: application/vnd.github+json" 2>$null
  if (-not $raw) { return $null }
  return $raw | ConvertFrom-Json
}

function Get-CheckRuns {
  param(
    [string]$RepoFull,
    [string]$Sha
  )

  if (-not $Sha) { return @() }

  $page = 1
  $collected = @()
  do {
    $path = "repos/{0}/commits/{1}/check-runs?per_page=100&page={2}" -f $RepoFull, $Sha, $page
    $response = Invoke-GhApi -Path $path
    if (-not $response) { break }
    if ($response.check_runs) {
      $collected += @($response.check_runs)
    }
    if ($response.total_count -le $collected.Count) { break }
    $page += 1
  } while ($true)

  return $collected
}

function Write-Info {
  param([string]$Message)
  if (-not $Quiet) { Write-Host "[run-tracker] $Message" }
}

$repoFull = Resolve-Repo -RepoParam $Repo
Write-Info ("Tracking workflow run {0} on {1}" -f $RunId, $repoFull)
$deadline = (Get-Date).AddSeconds([Math]::Max(5,$TimeoutSeconds))

$lastJobIds = @()
$snapshot = $null

do {
  $run = Invoke-GhApi -Path ("repos/{0}/actions/runs/{1}" -f $repoFull,$RunId)
  if (-not $run) { throw "Failed to query run $RunId via gh api." }

  $jobsResult = Invoke-GhApi -Path ("repos/{0}/actions/runs/{1}/jobs?per_page=100" -f $repoFull,$RunId)
  $jobEntries = @()
  if ($jobsResult -and $jobsResult.jobs) {
    $jobEntries = @($jobsResult.jobs)
  }

  $snapshot = [ordered]@{
    schema    = 'workflow-run-snapshot/v1'
    capturedAt= (Get-Date).ToUniversalTime().ToString('o')
    repository= $repoFull
    run       = [ordered]@{
      id          = $RunId
      workflowId  = $run.workflow_id
      name        = $run.name
      displayTitle= $run.display_title
      headBranch  = $run.head_branch
      headSha     = $run.head_sha
      status      = $run.status
      conclusion  = $run.conclusion
      createdAt   = $run.created_at
      updatedAt   = $run.updated_at
      event       = $run.event
      actor       = if ($run.actor) { $run.actor.login } else { $null }
      htmlUrl     = $run.html_url
    }
    jobs      = @()
    checkRuns = @()
  }

  $tableRows = @()
  foreach ($job in $jobEntries) {
    $duration = $null
    if ($job.started_at -and $job.completed_at) {
      try {
        $start = [DateTime]::Parse($job.started_at)
        $end = [DateTime]::Parse($job.completed_at)
        $duration = [math]::Round(($end - $start).TotalSeconds,2)
      } catch {}
    }
    $entry = [ordered]@{
      id         = $job.id
      name       = $job.name
      status     = $job.status
      conclusion = $job.conclusion
      startedAt  = $job.started_at
      completedAt= $job.completed_at
      duration_s = $duration
      recreateUrl= $job.html_url
    }
    $snapshot.jobs += $entry
    $tableRows += [pscustomobject]@{
      Id      = $job.id
      Name    = $job.name
      Status  = $job.status
      Result  = $job.conclusion
      Duration= if ($duration) { "$duration s" } else { '' }
    }
  }

  $checkRows = @()
  if ($IncludeCheckRuns) {
    $checks = Get-CheckRuns -RepoFull $repoFull -Sha $run.head_sha
    foreach ($check in $checks) {
      $checkDuration = $null
      if ($check.started_at -and $check.completed_at) {
        try {
          $start = [DateTime]::Parse($check.started_at)
          $end = [DateTime]::Parse($check.completed_at)
          $checkDuration = [math]::Round(($end - $start).TotalSeconds,2)
        } catch {}
      }

      $snapshot.checkRuns += [ordered]@{
        id          = $check.id
        name        = $check.name
        status      = $check.status
        conclusion  = $check.conclusion
        startedAt   = $check.started_at
        completedAt = $check.completed_at
        duration_s  = $checkDuration
        detailsUrl  = $check.details_url
        externalId  = $check.external_id
        app         = if ($check.app) { $check.app.name } else { $null }
        checkSuiteId= if ($check.check_suite) { $check.check_suite.id } else { $null }
        summary     = if ($check.output) { $check.output.summary } else { $null }
        text        = if ($check.output) { $check.output.text } else { $null }
        title       = if ($check.output) { $check.output.title } else { $null }
      }

      $checkRows += [pscustomobject]@{
        Name      = $check.name
        Status    = $check.status
        Result    = $check.conclusion
        App       = if ($check.app) { $check.app.name } else { '' }
        Duration  = if ($checkDuration) { "$checkDuration s" } else { '' }
      }
    }
  }

  if (-not $Quiet) {
    Write-Host ''
    $runConclusionDisplay = if ($null -ne $run.conclusion -and $run.conclusion -ne '') { $run.conclusion } else { 'n/a' }
    Write-Host ("Run status: {0} (conclusion: {1})" -f $run.status, $runConclusionDisplay)
    if ($tableRows.Count -gt 0) {
      $tableRows | Format-Table -AutoSize | Out-String | Write-Host
    } else {
      Write-Host "(no jobs reported yet)"
    }

    if ($IncludeCheckRuns) {
      Write-Host ''
      $shaDisplay = if ($run.head_sha) { $run.head_sha } else { '(unknown sha)' }
      Write-Host ("Check runs for head SHA {0}:" -f $shaDisplay)
      if ($checkRows.Count -gt 0) {
        $checkRows | Sort-Object Name | Format-Table -AutoSize | Out-String | Write-Host
      } else {
        Write-Host "(no check runs reported yet)"
      }
    }
  }

  if ($run.status -eq 'completed') { break }
  if ((Get-Date) -ge $deadline) {
    Write-Info "Timeout reached before run completed."
    $snapshot['timedOut'] = $true
    break
  }

  Start-Sleep -Seconds ([Math]::Max(1,$PollSeconds))
} while ($true)

if ($Json) {
  $snapshot | ConvertTo-Json -Depth 6
}

if ($OutputPath) {
  $target = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    [System.IO.Path]::GetFullPath($OutputPath)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputPath))
  }
  $dir = Split-Path -Parent $target
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $target -Encoding utf8
  Write-Info ("Snapshot written to {0}" -f $target)
}

if ($snapshot -and $snapshot.Contains('timedOut') -and $snapshot['timedOut']) {
  exit 1
}
