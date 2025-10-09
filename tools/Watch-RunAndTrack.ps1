<#
.SYNOPSIS
  Dispatch a GitHub workflow and monitor its jobs until completion.

.DESCRIPTION
  Wraps `gh workflow run` and `tools/Track-WorkflowRun.ps1`. The script:
    1. Triggers the specified workflow (default: Validate).
    2. Polls the run list to find the new run ID (supports repeated triggers).
    3. Invokes Track-WorkflowRun to monitor job-level progress.
    4. Optionally writes a JSON snapshot to disk for hand-offs.

  Requires GitHub CLI (`gh`) with appropriate authentication.

.PARAMETER Workflow
  Workflow file name or ID (default: validate.yml). Passed to `gh workflow run`.

.PARAMETER Ref
  Git ref (branch/SHA) to run against (default: current branch).

.PARAMETER Repo
  Repository owner/name (default: inferred from env or git remote).

.PARAMETER PollSeconds
  Poll interval when searching for the new run (default 10s).

.PARAMETER MonitorPollSeconds
  Poll interval for the job tracker (default 20s).

.PARAMETER TimeoutSeconds
  Overall timeout for locating the new run before monitoring (default 300s).

.PARAMETER OutputPath
  Path to save the final job snapshot JSON (passed to Track-WorkflowRun).

.PARAMETER Quiet
  Suppress informational messages (still emits tracker output unless `-TrackQuiet`).

.PARAMETER TrackQuiet
  Pass `-Quiet` to Track-WorkflowRun (suppresses job table output).

.PARAMETER DisableCheckRuns
  Opt-out of the enhanced check-run table emitted by Track-WorkflowRun.
#>
[CmdletBinding()]
param(
  [string]$Workflow = 'validate.yml',
  [string]$Ref,
  [string]$Repo,
  [int]$PollSeconds = 10,
  [int]$MonitorPollSeconds = 20,
  [int]$TimeoutSeconds = 300,
  [string]$OutputPath,
  [switch]$Quiet,
  [switch]$TrackQuiet,
  [switch]$DisableCheckRuns
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Repo {
  param([string]$RepoParam)
  if ($RepoParam) { return $RepoParam }
  if ($env:GITHUB_REPOSITORY) { return $env:GITHUB_REPOSITORY }
  try {
    $remote = git config --get remote.origin.url 2>$null
    if ($remote -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
      return "$($matches.owner)/$($matches.repo)"
    }
  } catch {}
  throw "Unable to resolve repository. Provide -Repo owner/name explicitly."
}

function Write-Info {
  param([string]$Message)
  if (-not $Quiet) { Write-Host "[run-watch] $Message" }
}

$repoFull = Resolve-Repo -RepoParam $Repo
Write-Info ("Repository: {0}" -f $repoFull)

# Trigger workflow
$runArgs = @('workflow','run',$Workflow,'--repo',$repoFull)
if ($Ref) { $runArgs += @('--ref',$Ref) }
Write-Info ("Dispatching workflow: gh {0}" -f ($runArgs -join ' '))
gh @runArgs | Out-Null

# Determine ref if not provided (use current branch)
if (-not $Ref) {
  $Ref = (git rev-parse --abbrev-ref HEAD).Trim()
  Write-Info ("Using current branch as ref: {0}" -f $Ref)
}

# Poll run list to find the new run
$deadline = (Get-Date).AddSeconds([Math]::Max(30,$TimeoutSeconds))
$newRunId = $null
do {
  $runs = gh run list --workflow $Workflow --branch $Ref --limit 5 --repo $repoFull --json databaseId,createdAt,headSha,conclusion 2>$null
  if ($runs) {
    $parsed = $runs | ConvertFrom-Json
    if ($parsed) {
      $candidate = $parsed | Sort-Object { [DateTime]::Parse($_.createdAt) } -Descending | Select-Object -First 1
      if ($candidate) {
        $newRunId = $candidate.databaseId
        Write-Info ("Detected latest run: {0} (created {1})" -f $newRunId, $candidate.createdAt)
        break
      }
    }
  }
  if ((Get-Date) -ge $deadline) {
    throw "Timeout waiting for workflow run to appear."
  }
  Start-Sleep -Seconds ([Math]::Max(1,$PollSeconds))
} while ($true)

# Monitor job status
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$trackerPath = Join-Path $scriptDir 'Track-WorkflowRun.ps1'
if (-not (Test-Path -LiteralPath $trackerPath)) {
  throw "Track-WorkflowRun.ps1 not found at $trackerPath"
}

$trackerParams = @{
  RunId       = [long]$newRunId
  Repo        = $repoFull
  PollSeconds = $MonitorPollSeconds
}
if ($OutputPath) { $trackerParams['OutputPath'] = $OutputPath }
if ($TrackQuiet) { $trackerParams['Quiet'] = $true }
if (-not $DisableCheckRuns) { $trackerParams['IncludeCheckRuns'] = $true }

Write-Info ("Starting job monitor for run {0}" -f $newRunId)
& $trackerPath @trackerParams
