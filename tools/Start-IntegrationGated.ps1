#Requires -Version 7.0
<#
.SYNOPSIS
  Gate starting an orchestrated integration by requiring an allowed Issue selection.

.DESCRIPTION
  This script serves as a deterministic gate: it requires the caller to select a pre-defined
  GitHub issue number (from a local policy file) before dispatching the orchestrated workflow.
  It uses GH CLI when available or falls back to the GitHub REST API with GH_TOKEN/GITHUB_TOKEN.

.PARAMETER Issue
  Required issue number (e.g., 88). Must be present in tools/policy/allowed-integration-issues.json.

.PARAMETER Strategy
  Orchestrated strategy to use: 'single' or 'matrix'. Default: single.

.PARAMETER IncludeIntegration
  Pass 'true' or 'false' to the workflow input include_integration.

.PARAMETER Ref
  Branch/ref to run against. Default: 'develop' (fast path for #88).

.PARAMETER Repo
  Optional owner/repo slug override. Auto-detected from gh or git when omitted.

.PARAMETER Token
  Optional token (admin recommended). If omitted, GH_TOKEN or GITHUB_TOKEN is used.

.EXAMPLE
  pwsh -File tools/Start-IntegrationGated.ps1 -Issue 88 -Strategy single -IncludeIntegration true
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][int]$Issue,
  [ValidateSet('single','matrix')][string]$Strategy = 'single',
  [ValidateSet('true','false')][string]$IncludeIntegration = 'true',
  [string]$Ref = 'develop',
  [string]$Repo,
  [string]$Token,
  [switch]$Watch,
  [switch]$AllowDirty,
  [switch]$AutoPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tokenFileDefault = 'C:\github_token.txt'

function Get-Policy {
  $path = Join-Path $PSScriptRoot 'policy/allowed-integration-issues.json'
  if (-not (Test-Path -LiteralPath $path)) { throw "Policy file not found: $path" }
  try {
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    throw "Invalid policy JSON at ${path}: $($_.Exception.Message)"
  }
}

function Resolve-TokenValue {
  param([string]$Explicit, [string]$EnvGh, [string]$EnvGithub, [string]$FilePath)
  if ($Explicit) { return [pscustomobject]@{ Value = $Explicit; Source = 'param' } }
  if ($EnvGh) { return [pscustomobject]@{ Value = $EnvGh; Source = 'env:GH_TOKEN' } }
  if ($EnvGithub) { return [pscustomobject]@{ Value = $EnvGithub; Source = 'env:GITHUB_TOKEN' } }
  if ($FilePath -and (Test-Path -LiteralPath $FilePath)) {
    try {
      $val = (Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop).Trim()
      if ($val) { return [pscustomobject]@{ Value = $val; Source = "file:$FilePath" } }
    } catch {
      Write-Verbose ("Failed to read token file {0}: {1}" -f $FilePath, $_.Exception.Message)
    }
  }
  return $null
}

function Get-RepoSlug {
  param([string]$RepoParam)
  if ($RepoParam) { return $RepoParam }
  try { $r = (gh repo view --json nameWithOwner --jq .nameWithOwner 2>$null); if ($r) { return $r.Trim() } } catch {}
  if ($env:GITHUB_REPOSITORY) { return $env:GITHUB_REPOSITORY }
  try {
    $url = (& git config --get remote.origin.url 2>$null)
    if ($url -match 'github\.com[:/]([^/]+/[^/.]+)(?:\.git)?$') { return $Matches[1] }
  } catch {}
  throw "Unable to determine repository slug. Pass -Repo 'owner/repo' or login gh."
}

function Invoke-GitPushWithToken {
  param([string]$RepoSlug,[string]$Branch,[string]$Tok)
  if (-not $RepoSlug) { throw 'Invoke-GitPushWithToken: missing RepoSlug' }
  if (-not $Branch)   { throw 'Invoke-GitPushWithToken: missing Branch' }
  if (-not $Tok)      { throw 'Invoke-GitPushWithToken: missing Token' }
  $remoteUrl = "https://github.com/$RepoSlug.git"
  $authUrl   = "https://x-access-token:$Tok@github.com/$RepoSlug.git"
  Write-Host ("Pushing branch '{0}' to origin with token (masked)" -f $Branch) -ForegroundColor Green
  $pushArgs = @('push','--set-upstream',$authUrl,"HEAD:refs/heads/$Branch")
  & git @pushArgs | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "git push failed for $RepoSlug:$Branch (exit $LASTEXITCODE)"
  }
}

function Get-AuthHeaders {
  param([string]$Tok)
  if (-not $Tok) { throw "An auth token is required. Provide -Token or set GH_TOKEN/GITHUB_TOKEN." }
  return @{ Authorization = "Bearer $Tok"; 'X-GitHub-Api-Version' = '2022-11-28'; Accept = 'application/vnd.github+json' }
}

function Invoke-GitHubApiJson {
  param([string]$Method='GET',[string]$Uri,[hashtable]$Headers,[object]$Body)
  if ($Body) { return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 5) -ContentType 'application/json' }
  return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
}

function New-SampleId {
  $dt = Get-Date -Format 'yyyyMMdd-HHmmss'
  $rand = -join ((48..57 + 97..122) | Get-Random -Count 3 | ForEach-Object {[char]$_})
  return "ts-$dt-$rand"
}

$policy = Get-Policy
if (-not $policy.issues -or ($Issue -notin $policy.issues)) {
  throw "Issue #$Issue is not allowed by policy. Allowed: $($policy.issues -join ', ')"
}

$statusOutput = (& git status --porcelain 2>$null)
if (-not $AllowDirty -and $statusOutput -and ($statusOutput.Trim().Length -gt 0)) {
  throw "Working tree has unstaged changes. Commit/stash before dispatch or pass -AllowDirty to override."
}

$repoSlug = Get-RepoSlug -RepoParam $Repo
$detectedRef = $null
try { $detectedRef = (& git rev-parse --abbrev-ref HEAD 2>$null).Trim() } catch {}
if ($Ref -eq '__CURRENT_BRANCH__') { if ($detectedRef) { $Ref = $detectedRef } else { throw 'Unable to resolve current branch name for -Ref.' } }
$Ref = $Ref.Trim()
$useGh = $false
if (Get-Command gh -ErrorAction SilentlyContinue) { $useGh = $true }
$tokenInfo = Resolve-TokenValue -Explicit $Token -EnvGh $env:GH_TOKEN -EnvGithub $env:GITHUB_TOKEN -FilePath $tokenFileDefault
$tok = if ($tokenInfo) { $tokenInfo.Value } else { $null }
$tokenSource = if ($tokenInfo) { $tokenInfo.Source } else { 'none' }
if (-not $tok -and -not $useGh) { throw 'No GH CLI and no token found. Set GH_TOKEN or install gh.' }
if ($tok -and -not $env:GH_TOKEN) { $env:GH_TOKEN = $tok }

# Lookup issue title (for logging) – best-effort
$issueTitle = "#${Issue}"
try {
  if ($useGh) {
    $issueTitle = (gh issue view $Issue -R $repoSlug --json title --jq .title)
  } elseif ($tok) {
    $h = Get-AuthHeaders -Tok $tok
    $d = Invoke-GitHubApiJson -Uri ("https://api.github.com/repos/{0}/issues/{1}" -f $repoSlug,$Issue) -Headers $h
    if ($d.title) { $issueTitle = $d.title }
  }
} catch {}

Write-Host ("Gated integration start for issue #{0}: {1}" -f $Issue, $issueTitle) -ForegroundColor Cyan

$workflowKey = 'ci-orchestrated.yml'
$workflowName = 'CI Orchestrated (deterministic chain)'
$sampleId = New-SampleId
$dispatchStamp = Get-Date

# Optionally auto-push current branch prior to dispatch
if ($AutoPush) {
  try {
    $branch = $Ref
    if ($Ref -eq '__CURRENT_BRANCH__' -and $detectedRef) { $branch = $detectedRef }
    Invoke-GitPushWithToken -RepoSlug $repoSlug -Branch $branch -Tok $tok
  } catch {
    throw "Auto-push failed: $($_.Exception.Message)"
  }
}

if ($useGh) {
  if ($tok) { $env:GH_TOKEN = $tok }
  $cmd = @('workflow','run',$workflowKey,'-R',$repoSlug,'-r',$Ref,'-f',"sample_id=$sampleId",'-f',"include_integration=$IncludeIntegration",'-f',"strategy=$Strategy")
  Write-Host ("Dispatching orchestrated via gh: gh {0}" -f ($cmd -join ' ')) -ForegroundColor Green
  gh @cmd | Out-Null
} else {
  $h = Get-AuthHeaders -Tok $tok
  $uri = "https://api.github.com/repos/$repoSlug/actions/workflows/$workflowKey/dispatches"
  $body = @{ ref = $Ref; inputs = @{ sample_id = $sampleId; include_integration = $IncludeIntegration; strategy = $Strategy } }
  Write-Host ("Dispatching orchestrated via REST: {0} (ref={1})" -f $workflowKey,$Ref) -ForegroundColor Green
  Invoke-GitHubApiJson -Method 'POST' -Uri $uri -Headers $h -Body $body | Out-Null
}

Write-Host ("Dispatched: sample_id={0}, strategy={1}, include_integration={2}" -f $sampleId,$Strategy,$IncludeIntegration)

$runEnvelope = $null
$runId = $null
$runUrl = $null
try {
  Start-Sleep -Seconds 6
  if ($useGh) {
    $listJson = gh run list --workflow $workflowName --json databaseId,createdAt,headBranch,status,conclusion,url --limit 20 2>$null
    if ($listJson) {
      $runs = $listJson | ConvertFrom-Json
      if ($runs) {
        $runEnvelope = $runs | Where-Object {
            $_.headBranch -eq $Ref -and $_.createdAt -and ([datetime]$_.createdAt) -ge $dispatchStamp.AddMinutes(-5)
        } |
          Sort-Object { [datetime]$_.createdAt } -Descending |
          Select-Object -First 1
      }
    }
  } else {
    $h = Get-AuthHeaders -Tok $tok
    $runsResponse = Invoke-GitHubApiJson -Uri ("https://api.github.com/repos/{0}/actions/workflows/{1}/runs?per_page=20" -f $repoSlug,$workflowKey) -Headers $h
    if ($runsResponse.workflow_runs) {
      $runEnvelope = $runsResponse.workflow_runs |
        Where-Object {
            $_.head_branch -eq $Ref -and $_.created_at -and ([datetime]$_.created_at) -ge $dispatchStamp.AddMinutes(-5)
        } |
        Sort-Object { [datetime]$_.created_at } -Descending |
        Select-Object -First 1
    }
  }
  if ($runEnvelope) {
    $runId = if ($runEnvelope.databaseId) { [string]$runEnvelope.databaseId } elseif ($runEnvelope.id) { [string]$runEnvelope.id } else { $null }
    $runUrl = if ($runEnvelope.url) { $runEnvelope.url } elseif ($runEnvelope.html_url) { $runEnvelope.html_url } else { $null }
  }
} catch {
  Write-Verbose ("Failed to detect run id: {0}" -f $_.Exception.Message)
}

if ($runId) {
  Write-Host ("Detected orchestrated run id: {0}" -f $runId) -ForegroundColor Green
  if ($runUrl) { Write-Host ("Run URL: {0}" -f $runUrl) -ForegroundColor Cyan }
  if (-not $Watch) {
    Write-Host 'Copy/paste to watch this run (Docker):' -ForegroundColor Yellow
    Write-Host ("  pwsh -File tools/Watch-InDocker.ps1 -RunId {0} -Repo {1}" -f $runId,$repoSlug)
    Write-Host 'VS Code task: Run → Run Task → "Integration (#88): Watch existing run (Docker)"' -ForegroundColor Yellow
  }
} else {
  Write-Warning 'Could not automatically determine run id yet. Use gh run list or GitHub UI to locate it, then run tools/Watch-InDocker.ps1.'
}

if ($runId) {
  try {
    $workspace = (Get-Location).Path
    $scratch = Join-Path $workspace (".tmp/watch-run/{0}" -f $runId)
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    $meta = [ordered]@{
      issue          = $Issue
      strategy       = $Strategy
      includeIntegration = $IncludeIntegration
      ref            = $Ref
      repo           = $repoSlug
      sampleId       = $sampleId
      runId          = $runId
      runUrl         = $runUrl
      dispatchedAt   = $dispatchStamp.ToString('o')
      tokenSource    = $tokenSource
      allowDirty     = [bool]$AllowDirty
      workingTreeClean = -not ($statusOutput -and ($statusOutput.Trim().Length -gt 0))
    }
    $metaPath = Join-Path $scratch 'dispatch.json'
    $meta | ConvertTo-Json -Depth 4 | Out-File -FilePath $metaPath -Encoding utf8
  } catch {
    Write-Warning ("Failed to write dispatch metadata: {0}" -f $_.Exception.Message)
  }
}

if ($Watch) {
  if ($runId) {
    $watchScript = Join-Path $PSScriptRoot 'Watch-InDocker.ps1'
    if (-not (Test-Path -LiteralPath $watchScript)) {
      Write-Warning "Watcher script not found at $watchScript"
    } else {
      Write-Host 'Launching Docker watcher (blocking until dispatcher completes)...' -ForegroundColor Cyan
      $watchArgs = @('-NoLogo','-NoProfile','-File', $watchScript,'-RunId',"$runId",'-Repo',"$repoSlug")
      if ($tok) { $watchArgs += @('-Token', $tok) }
      & pwsh @watchArgs
      $watchExit = $LASTEXITCODE
      if ($watchExit -ne 0) {
        Write-Warning ("Watcher exited with code {0}. Inspect output above for details." -f $watchExit)
      }
    }
  } else {
    Write-Warning 'Watcher not started because the run id could not be determined.'
  }
}
