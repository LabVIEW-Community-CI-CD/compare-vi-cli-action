#Requires -Version 7.0
[CmdletBinding()]
param(
  [int]$Issue,
  [switch]$Execute,
  [string]$Base = 'develop',
  [string]$BranchPrefix = 'issue',
  [string]$PRTemplate = 'default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GitHubIntake.psm1') -Force

function Get-RepoRoot {
  (Resolve-Path '.').Path
}

function Get-GitDefaultBranch {
  try { (& git symbolic-ref refs/remotes/origin/HEAD).Split('/')[-1] } catch { 'develop' }
}

function Read-JsonFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Get-NoStandingReason {
  param([string]$RepoRoot)

  $cachePath = Join-Path $RepoRoot '.agent_priority_cache.json'
  $cache = Read-JsonFile -Path $cachePath
  if ($cache -and
    ($cache.PSObject.Properties.Name -contains 'state') -and
    ([string]$cache.state).Trim().ToUpperInvariant() -eq 'NONE' -and
    ($cache.PSObject.Properties.Name -contains 'noStandingReason')) {
    $reason = ([string]$cache.noStandingReason).Trim().ToLowerInvariant()
    if ($reason) { return $reason }
  }

  $reportPath = Join-Path $RepoRoot 'tests/results/_agent/issue/no-standing-priority.json'
  $report = Read-JsonFile -Path $reportPath
  if ($report -and ($report.PSObject.Properties.Name -contains 'reason')) {
    $reason = ([string]$report.reason).Trim().ToLowerInvariant()
    if ($reason) { return $reason }
  }

  return $null
}

function Ensure-Branch([string]$Name,[string]$Base) {
  $current = (& git rev-parse --abbrev-ref HEAD).Trim()
  if ($current -eq $Name) { return $true }
  try {
    & git fetch origin $Base | Out-Null
  } catch {}
  try {
    & git show-ref --verify --quiet ('refs/heads/' + $Name)
    if ($LASTEXITCODE -eq 0) { & git checkout $Name | Out-Null; return $true }
  } catch {}
  & git checkout -b $Name $Base | Out-Null
  return $true
}

function New-RenderedPRBody([string]$Repo,[int]$Issue,[pscustomobject]$Snapshot,[string]$Base,[string]$Branch,[string]$Template) {
  $rendererPath = Join-Path $Repo 'tools' 'New-PullRequestBody.ps1'
  if (-not (Test-Path -LiteralPath $rendererPath -PathType Leaf)) {
    throw "PR body renderer not found: $rendererPath"
  }

  $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-pr-body-{0}.md" -f $Issue)
  $isStandingPriority = $false
  if ($Snapshot -and $Snapshot.PSObject.Properties.Match('labels').Count -gt 0 -and $Snapshot.labels) {
    $isStandingPriority = @($Snapshot.labels) -contains 'standing-priority'
  }

  $params = @{
    Template   = $Template
    Issue      = $Issue
    IssueTitle = if ($Snapshot -and $Snapshot.PSObject.Properties.Match('title').Count -gt 0) { [string]$Snapshot.title } else { '' }
    IssueUrl   = if ($Snapshot -and $Snapshot.PSObject.Properties.Match('url').Count -gt 0) { [string]$Snapshot.url } else { '' }
    Base       = $Base
    Branch     = $Branch
    OutputPath = $tempPath
  }
  if ($isStandingPriority) { $params['StandingPriority'] = $true }

  & $rendererPath @params
  return $tempPath
}

$repo = Get-RepoRoot
$null = Resolve-GitHubPullRequestTemplate -TemplateName $PRTemplate
if (-not $Issue) {
  # Try resolve from router/snapshot
  $snapDir = Join-Path $repo 'tests/results/_agent/issue'
  $router = $null
  $latest = $null
  if (Test-Path -LiteralPath $snapDir -PathType Container) {
    $router = Read-JsonFile -Path (Join-Path $snapDir 'router.json')
    if ($router -and ($router.PSObject.Properties.Name -contains 'issue')) {
      [int]$routerIssue = 0
      if ([int]::TryParse([string]$router.issue, [ref]$routerIssue) -and $routerIssue -gt 0) {
        $Issue = $routerIssue
      }
    }
    if (-not $Issue) {
      $latest = Get-ChildItem -LiteralPath $snapDir -Filter '*.json' |
        Where-Object { $_.BaseName -match '^\d+$' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    }
  }
  if (-not $Issue -and -not $latest) {
    $noStandingReason = Get-NoStandingReason -RepoRoot $repo
    if ($noStandingReason -eq 'queue-empty') {
      throw 'Standing-priority queue is empty; create or label the next issue before running Branch-Orchestrator.'
    }
    throw 'Issue not specified and no snapshot found.'
  }
  if (-not $Issue) {
    $snap = Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
    $Issue = [int]$snap.number
  }
}

Write-Host ("[orchestrator] Issue: #{0}" -f $Issue)

# Read snapshot for title/URL context
$snapPath = Join-Path $repo 'tests/results/_agent/issue' ("{0}.json" -f $Issue)
$snap = $null
$title = 'work'
try { $snap = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json -ErrorAction Stop; $title = $snap.title } catch {}
if (-not $title) { $title = 'work' }

$defaultBase = Get-GitDefaultBranch
if (-not $Base) { $Base = $defaultBase }
Write-Host ("[orchestrator] Base: {0}" -f $Base)

$currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
$branchName = Resolve-IssueBranchName -Number $Issue -Title $title -BranchPrefix $BranchPrefix -CurrentBranch $currentBranch
Write-Host ("[orchestrator] Branch: {0}" -f $branchName)
Write-Host ("[orchestrator] PR template: {0}" -f $PRTemplate)

$ok = Ensure-Branch -Name $branchName -Base $Base
if (-not $ok) { throw 'Failed to ensure branch' }

if ($Execute) {
  Write-Host '[orchestrator] Executing remote ops (push/PR)…'
  try { & git push -u origin $branchName } catch { Write-Warning 'Push failed.' }
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    $bodyPath = $null
    try {
      $prTitle = Resolve-PullRequestTitle -Issue $Issue -IssueTitle $title -Base $Base
      $bodyPath = New-RenderedPRBody -Repo $repo -Issue $Issue -Snapshot $snap -Base $Base -Branch $branchName -Template $PRTemplate
      $existingJson = & $gh.Source 'pr' 'view' $branchName '--json' 'number' 2>$null
      if ($LASTEXITCODE -eq 0 -and $existingJson) {
        $pr = $existingJson | ConvertFrom-Json
        & $gh.Source 'pr' 'edit' $pr.number '--title' $prTitle '--body-file' $bodyPath | Out-Host
      } else {
        & $gh.Source 'pr' 'create' '--title' $prTitle '--base' $Base '--head' $branchName '--body-file' $bodyPath | Out-Host
      }
    } catch {
      Write-Warning 'PR create/edit failed.'
      Write-Warning $_.Exception.Message
    } finally {
      if ($bodyPath -and (Test-Path -LiteralPath $bodyPath -PathType Leaf)) {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
      }
    }
  } else {
    Write-Warning 'gh not found; cannot open PR automatically.'
  }
} else {
  Write-Host '[orchestrator] Dry run — no remote operations performed.'
}
