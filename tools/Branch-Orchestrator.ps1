#Requires -Version 7.0
[CmdletBinding()]
param(
  [int]$Issue,
  [switch]$Execute,
  [string]$Base = 'develop',
  [string]$BranchPrefix = 'issue',
  [string]$PushTarget = 'standing'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
  (Resolve-Path '.').Path
}

function Get-GitDefaultBranch {
  try { (& git symbolic-ref refs/remotes/origin/HEAD).Split('/')[-1] } catch { 'develop' }
}

function New-BranchName([int]$Number,[string]$Title) {
  $slug = ($Title -replace '[^a-zA-Z0-9\- ]','' -replace '\s+','-' ).ToLowerInvariant()
  if (-not $slug) { $slug = 'work' }
  return '{0}/{1}-{2}' -f $BranchPrefix,$Number,$slug
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

function Update-PRBodyWithDigest([int]$Number,[string]$Digest,[string]$SnapshotPath) {
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if (-not $gh) { Write-Warning 'gh not found; skipping PR update'; return }
  try {
    $body = "Standing priority snapshot digest: `$`$Digest`nSnapshot: $SnapshotPath"
    & $gh.Source 'pr' 'edit' '--body' $body | Out-Null
  } catch { Write-Warning "Failed to update PR body: $($_.Exception.Message)" }
}

$repo = Get-RepoRoot
if (-not $Issue) {
  # Try resolve from router/snapshot
  $snapDir = Join-Path $repo 'tests/results/_agent/issue'
  $latest = $null
  if (Test-Path -LiteralPath $snapDir -PathType Container) {
    $latest = Get-ChildItem -LiteralPath $snapDir -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  if (-not $latest) { throw 'Issue not specified and no snapshot found.' }
  $snap = Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
  $Issue = [int]$snap.number
}

Write-Host ("[orchestrator] Issue: #{0}" -f $Issue)

# Read snapshot for title/digest
$snapPath = Join-Path $repo 'tests/results/_agent/issue' ("{0}.json" -f $Issue)
$digestPath = Join-Path $repo 'tests/results/_agent/issue' ("{0}.digest" -f $Issue)
$title = 'work'
$digest = $null
try { $snap = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json -ErrorAction Stop; $title = $snap.title; $digest = $snap.digest } catch {}
if (-not $title) { $title = 'work' }

$defaultBase = Get-GitDefaultBranch
if (-not $Base) { $Base = $defaultBase }
Write-Host ("[orchestrator] Base: {0}" -f $Base)

$branchName = New-BranchName -Number $Issue -Title $title
Write-Host ("[orchestrator] Branch: {0}" -f $branchName)

$ok = Ensure-Branch -Name $branchName -Base $Base
if (-not $ok) { throw 'Failed to ensure branch' }

if ($Execute) {
  Write-Host '[orchestrator] Executing remote ops (push/PR).'
  $preArgs = @(
    '-NoLogo', '-NoProfile',
    '-File', (Join-Path $repo 'tools' 'Ensure-AgentPushTarget.ps1'),
    '-RepositoryRoot', $repo,
    '-SkipTrackingCheck'
  )
  if ($PushTarget) {
    $preArgs += '-Target'
    $preArgs += $PushTarget
  }
  & pwsh @preArgs
  if ($LASTEXITCODE -ne 0) { throw 'Push target contract failed (pre-push).' }

  & git push -u origin $branchName
  if ($LASTEXITCODE -ne 0) { throw "Push failed with exit code $LASTEXITCODE." }

  $postArgs = @(
    '-NoLogo', '-NoProfile',
    '-File', (Join-Path $repo 'tools' 'Ensure-AgentPushTarget.ps1'),
    '-RepositoryRoot', $repo
  )
  if ($PushTarget) {
    $postArgs += '-Target'
    $postArgs += $PushTarget
  }
  & pwsh @postArgs
  if ($LASTEXITCODE -ne 0) { throw 'Push target contract failed (post-push).' }

  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    try { & $gh.Source 'pr' 'create' '--fill' '--base' $Base '--head' $branchName | Out-Host } catch { Write-Warning 'PR create failed or already exists.' }
    if ($digest) { Update-PRBodyWithDigest -Number $Issue -Digest $digest -SnapshotPath $snapPath }
  } else {
    Write-Warning 'gh not found; cannot open PR automatically.'
  }
} else {
  Write-Host '[orchestrator] Dry run - no remote operations performed.'
}
