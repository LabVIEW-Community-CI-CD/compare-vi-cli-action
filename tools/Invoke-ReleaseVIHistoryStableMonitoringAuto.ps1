[CmdletBinding()]
param(
  [long]$RunId,
  [switch]$SkipPost,
  [switch]$PassThru,
  [string]$TrackerPath = 'docs/RELEASE_VI_HISTORY_STABLE_ENFORCEMENT_MONITORING.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-RemoteUrlToRepoSlug {
  param([string]$RemoteUrl)

  if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    return $null
  }

  $value = $RemoteUrl.Trim()
  if ($value -match 'github\.com[:/](?<slug>[^/]+/[^/.]+?)(?:\.git)?$') {
    return [string]$Matches.slug
  }

  return $null
}

function Resolve-RepoSlugFromRemote {
  param([string]$RemoteName)

  $url = ''
  try {
    $url = (& git remote get-url $RemoteName 2>$null)
  } catch {
    $url = ''
  }

  return Convert-RemoteUrlToRepoSlug -RemoteUrl $url
}

$originSlug = Resolve-RepoSlugFromRemote -RemoteName 'origin'
if ([string]::IsNullOrWhiteSpace($originSlug)) {
  throw 'Could not resolve origin GitHub repo slug from git remote.'
}

$upstreamSlug = Resolve-RepoSlugFromRemote -RemoteName 'upstream'
$prRepoSlug = if ([string]::IsNullOrWhiteSpace($upstreamSlug)) { $originSlug } else { $upstreamSlug }
$branch = (& git rev-parse --abbrev-ref HEAD).Trim()

$originOwner = ($originSlug -split '/')[0]
$headSelector = "${originOwner}:$branch"
$resolvedPrNumber = 0

$prCandidates = @()
try {
  $prCandidates = @(gh pr list -R $prRepoSlug --head $headSelector --state open --json number,updatedAt | ConvertFrom-Json)
} catch {
  $prCandidates = @()
}

if ($prCandidates.Count -gt 0) {
  $resolvedPrNumber = [int]($prCandidates | Sort-Object updatedAt -Descending | Select-Object -First 1 -ExpandProperty number)
}

$updateScript = Join-Path $PSScriptRoot 'Update-ReleaseVIHistoryStableMonitoring.ps1'
$invokeParams = @{
  RepoSlug = $originSlug
  TrackerPath = $TrackerPath
  EmitPrCommentBody = $true
}
if ($RunId -gt 0) {
  $invokeParams.RunId = $RunId
}

if (-not $SkipPost -and $resolvedPrNumber -gt 0) {
  $invokeParams.PostPrComment = $true
  $invokeParams.PrRepoSlug = $prRepoSlug
  $invokeParams.PrNumber = $resolvedPrNumber
}

$result = & $updateScript @invokeParams

if (-not $SkipPost -and $resolvedPrNumber -le 0) {
  Write-Warning "No open PR found for head '$headSelector' in '$prRepoSlug'. Tracker updated and comment body emitted only."
}

if ($PassThru) {
  $result
}