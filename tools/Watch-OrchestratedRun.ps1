<#
.SYNOPSIS
  Poll an orchestrated CI workflow run and surface invoker failures without the UI.
.DESCRIPTION
  Given a workflow run id (or inferred from the current branch), this script waits for the
  `pester-category (dispatcher)` job to complete, downloads its log/artifacts, and prints the
  invoker-related failure lines (including ping retry details and boot log excerpts).
.PARAMETER RunId
  Workflow run id (from the Actions URL). If omitted, the script selects the most recent
  "CI Orchestrated (deterministic chain)" run for the current branch.
.PARAMETER PollSeconds
  Seconds between status checks while the run is in progress (default: 15).
.EXAMPLE
  pwsh -File tools/Watch-OrchestratedRun.ps1 -RunId 18435836406
.EXAMPLE
  pwsh -File tools/Watch-OrchestratedRun.ps1
  # automatically inspects the latest orchestrated run for the current branch.
#>
[CmdletBinding()]
param(
  [string]$RunId,
  [int]$PollSeconds = 15,
  [string]$Token,
  [string]$Repo,
  [int]$StallMinutes = 10,
  [int]$KeepHistory = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stallMinutes = [Math]::Max(1,$StallMinutes)
$stallWindow = [TimeSpan]::FromMinutes($stallMinutes)

function Get-Sha256String {
  param([string]$Input)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Input)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
  } finally {
    $sha.Dispose()
  }
}

function Get-Sha256File {
  param([string]$FilePath)
  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $null }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
  } finally {
    $sha.Dispose()
  }
}

function Prune-WatchHistory {
  param([string]$Root,[int]$Keep)
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
  $dirs = Get-ChildItem -LiteralPath $Root -Directory | Sort-Object LastWriteTime -Descending
  $excess = $dirs | Select-Object -Skip $Keep
  foreach ($dir in $excess) {
    try { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop } catch {}
  }
}

function Invoke-GhJson {
  param([string[]]$GhArgs)
  if (-not $GhArgs -or $GhArgs.Count -eq 0) {
    throw "Invoke-GhJson called without arguments."
  }
  Write-Verbose ("[gh] {0}" -f ($GhArgs -join ' '))
  if ($script:__GhToken) { $env:GH_TOKEN = $script:__GhToken }
  $out = & gh @GhArgs
  if ($LASTEXITCODE -ne 0) {
    throw "gh command failed: gh $($GhArgs -join ' ')"
  }
  if (-not $out) { return $null }
  try {
    return $out | ConvertFrom-Json
  } catch {
    throw "Expected JSON from 'gh $($GhArgs -join ' ')', but received:`n$out"
  }
}

function Get-AuthHeaders {
  param([string]$Tok)
  if (-not $Tok) { throw "An auth token is required for REST fallback. Provide -Token or set GH_TOKEN/GITHUB_TOKEN." }
  return @{ Authorization = "Bearer $Tok"; 'X-GitHub-Api-Version' = '2022-11-28'; Accept = 'application/vnd.github+json' }
}

function Get-RepoSlug {
  param([string]$RepoParam)
  if ($RepoParam) { return $RepoParam }
  if ($env:GITHUB_REPOSITORY) { return $env:GITHUB_REPOSITORY }
  try {
    $url = (& git config --get remote.origin.url).Trim()
    if ($url -match '[:/]([^/]+/[^/.]+)(?:\.git)?$') { return $Matches[1] }
  } catch {}
  throw "Unable to determine repository slug. Pass -Repo 'owner/repo' or set GITHUB_REPOSITORY."
}

function Invoke-GitHubApiJson {
  param(
    [string]$Method = 'GET',
    [string]$Uri,
    [hashtable]$Headers
  )
  $resp = Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ErrorAction Stop
  return $resp
}

function Get-WorkflowIdByName {
  param([string]$RepoSlug,[string]$Name,[hashtable]$Headers)
  $wf = Invoke-GitHubApiJson -Uri "https://api.github.com/repos/$RepoSlug/actions/workflows" -Headers $Headers
  ($wf.workflows | Where-Object { $_.name -eq $Name } | Select-Object -First 1).id
}

function Get-LatestRunId {
  param([string]$Branch)
  if ($script:__UseGh) {
    $runs = Invoke-GhJson @('run','list','--limit','25','--workflow','CI Orchestrated (deterministic chain)','--json','databaseId,headBranch,status,conclusion,url')
    $match = $runs | Where-Object { $_.headBranch -eq $Branch } | Select-Object -First 1
    if (-not $match) { throw "Could not find a recent orchestrated run for branch '$Branch'." }
    Write-Host ("Latest orchestrated run for branch '{0}' is {1}" -f $Branch, $match.databaseId) -ForegroundColor Cyan
    return [string]$match.databaseId
  }
  $repoSlug = Get-RepoSlug -RepoParam $script:__RepoSlug
  $wfId = Get-WorkflowIdByName -RepoSlug $repoSlug -Name 'CI Orchestrated (deterministic chain)' -Headers $script:__Headers
  if (-not $wfId) { throw "Unable to locate orchestrated workflow id in $repoSlug." }
  $runs = Invoke-GitHubApiJson -Uri ("https://api.github.com/repos/{0}/actions/workflows/{1}/runs?per_page=25&branch={2}" -f $repoSlug,$wfId,$Branch) -Headers $script:__Headers
  $match = $runs.workflow_runs | Select-Object -First 1
  if (-not $match) { throw "Could not find a recent orchestrated run for branch '$Branch'." }
  Write-Host ("Latest orchestrated run for branch '{0}' is {1}" -f $Branch, $match.id) -ForegroundColor Cyan
  return [string]$match.id
}

# Resolve auth/tooling
$script:__GhToken = $null
$script:__UseGh = $false
$script:__RepoSlug = $Repo
if ($Token) { $script:__GhToken = $Token }
elseif ($env:GH_TOKEN) { $script:__GhToken = $env:GH_TOKEN }
elseif ($env:GITHUB_TOKEN) { $script:__GhToken = $env:GITHUB_TOKEN }

if (Get-Command gh -ErrorAction SilentlyContinue) {
  # Prefer gh when available
  $script:__UseGh = $true
} else {
  # REST fallback requires Repo + Token
  $script:__RepoSlug = Get-RepoSlug -RepoParam $Repo
  $script:__Headers = Get-AuthHeaders -Tok $script:__GhToken
}

if (-not $RunId) {
  $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
  if (-not $branch) {
    throw "Unable to detect current branch; please supply -RunId."
  }
  $RunId = Get-LatestRunId -Branch $branch
}

Write-Host ("Inspecting orchestrated run {0}" -f $RunId) -ForegroundColor Green

$historyRoot = Join-Path (Get-Location).Path '.tmp\watch-run'
Prune-WatchHistory -Root $historyRoot -Keep ([Math]::Max(1,$KeepHistory))

$runInfo = $null
$lastSignature = $null
$lastSignatureChange = Get-Date
while ($true) {
  if ($script:__UseGh) {
    $runInfo = Invoke-GhJson @('run','view',$RunId,'--json','status,conclusion,jobs,url,headBranch')
    $dispatcher = $runInfo.jobs | Where-Object { $_.name -eq 'pester-category (dispatcher)' } | Select-Object -First 1
  } else {
    $repoSlug = $script:__RepoSlug
    $r = Invoke-GitHubApiJson -Uri ("https://api.github.com/repos/{0}/actions/runs/{1}" -f $repoSlug,$RunId) -Headers $script:__Headers
    $jobs = Invoke-GitHubApiJson -Uri ("https://api.github.com/repos/{0}/actions/runs/{1}/jobs?per_page=100" -f $repoSlug,$RunId) -Headers $script:__Headers
    $runInfo = [pscustomobject]@{ status=$r.status; conclusion=$r.conclusion; url=$r.html_url; headBranch=$r.head_branch; jobs=$jobs.jobs }
    $dispatcher = $jobs.jobs | Where-Object { $_.name -eq 'pester-category (dispatcher)' } | Select-Object -First 1
  }
  if (-not $dispatcher) {
    Write-Host "Dispatcher job not yet scheduled. Waiting..." -ForegroundColor Yellow
  } elseif ($dispatcher.status -eq 'completed' -and $runInfo.status -eq 'completed') {
    break
  } else {
    Write-Host ("Run status: {0} | Dispatcher status: {1} (conclusion={2}) - polling again in {3}s" -f $runInfo.status, $dispatcher.status, $dispatcher.conclusion, $PollSeconds) -ForegroundColor Yellow
  }
  $signature = "{0}|{1}|{2}" -f $runInfo.status, ($dispatcher.status ?? 'pending'), ($dispatcher.conclusion ?? '')
  if ($signature -ne $lastSignature) {
    $lastSignature = $signature
    $lastSignatureChange = Get-Date
  } else {
    if ((Get-Date) - $lastSignatureChange -ge $stallWindow) {
      Write-Warning ("No status change detected for {0} minute(s) (run={1}, dispatcher={2}). Possible stall." -f $stallMinutes,$runInfo.status,($dispatcher.status ?? 'pending'))
      $lastSignatureChange = Get-Date
    }
  }
  Start-Sleep -Seconds ([math]::Max(5,$PollSeconds))
}

Write-Host ("Dispatcher job concluded with status={0} conclusion={1}" -f $dispatcher.status, $dispatcher.conclusion) -ForegroundColor Green

$workspace = (Get-Location).Path
$scratch = Join-Path $workspace ".tmp\watch-run\$RunId"
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$logPath = Join-Path $scratch "dispatcher.log"

Write-Host ("Fetching job log into {0}" -f $logPath) -ForegroundColor Cyan
$logFetched = $false
if ($script:__UseGh) {
  for ($attempt = 1; $attempt -le 40; $attempt++) {
    if ($script:__GhToken) { $env:GH_TOKEN = $script:__GhToken }
    $logOut = & gh run view $RunId --job $dispatcher.databaseId --log 2>&1
    if ($LASTEXITCODE -eq 0 -and $logOut -and ($logOut -notmatch 'logs will be available when it is complete')) {
      $logOut | Out-File -FilePath $logPath -Encoding utf8
      $logFetched = $true
      break
    }
    if ($dispatcher.conclusion -in @('success','failure','cancelled','skipped') -and $logOut -match 'logs will be available') {
      Start-Sleep -Seconds 5
    } elseif ($LASTEXITCODE -ne 0) {
      Write-Warning ("Failed to fetch log (attempt #{0}): {1}" -f $attempt, ($logOut | Select-Object -First 1))
      Start-Sleep -Seconds 5
    } else {
      Start-Sleep -Seconds 5
    }
  }
} else {
  try {
    $repoSlug = $script:__RepoSlug
    $jobId = $dispatcher.id
    $uri = "https://api.github.com/repos/$repoSlug/actions/jobs/$jobId/logs"
    $logRaw = Invoke-WebRequest -Uri $uri -Headers $script:__Headers -ErrorAction Stop
    $content = $logRaw.Content
    if ([string]::IsNullOrWhiteSpace($content)) { throw "empty log content" }
    $content | Out-File -FilePath $logPath -Encoding utf8
    $logFetched = $true
  } catch {
    Write-Warning ("Failed to fetch dispatcher job log via REST: {0}" -f $_.Exception.Message)
  }
}
if (-not $logFetched) { Write-Warning "Dispatcher log not yet available; continuing without direct job log." }

$artifactDir = Join-Path $scratch "artifacts"
Write-Host ("Downloading dispatcher artifacts to {0}" -f $artifactDir) -ForegroundColor Cyan
$artifactFetched = $false
if ($script:__UseGh) {
  for ($attempt = 1; $attempt -le 20 -and -not $artifactFetched; $attempt++) {
    try {
      if ($script:__GhToken) { $env:GH_TOKEN = $script:__GhToken }
      & gh run download $RunId --name 'orchestrated-pester-results-dispatcher' --dir $artifactDir *>$null
      $artifactFetched = $true
    } catch {
      if ($dispatcher.conclusion -in @('success','failure','cancelled','skipped')) { Start-Sleep -Seconds 5 } else { break }
    }
  }
} else {
  try {
    $repoSlug = $script:__RepoSlug
    $arts = Invoke-GitHubApiJson -Uri ("https://api.github.com/repos/{0}/actions/runs/{1}/artifacts" -f $repoSlug,$RunId) -Headers $script:__Headers
    $disp = $arts.artifacts | Where-Object { $_.name -eq 'orchestrated-pester-results-dispatcher' } | Select-Object -First 1
    if ($disp) {
      New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
      $zipPath = Join-Path $artifactDir 'dispatcher.zip'
      $zipUri = ("https://api.github.com/repos/{0}/actions/artifacts/{1}/zip" -f $repoSlug,$disp.id)
      Invoke-WebRequest -Uri $zipUri -Headers $script:__Headers -OutFile $zipPath -ErrorAction Stop
      Expand-Archive -Path $zipPath -DestinationPath $artifactDir -Force
      Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
      $artifactFetched = $true
    }
  } catch {
    Write-Warning ("Failed to fetch dispatcher artifacts via REST: {0}" -f $_.Exception.Message)
  }
}
if (-not $artifactFetched) { Write-Warning "Dispatcher artifacts not yet available." }

if ($logFetched -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
  $digest = Get-Sha256File -FilePath $logPath
  if ($digest) {
    $digestRecord = Join-Path $historyRoot 'last-dispatcher.sha256'
    if (Test-Path -LiteralPath $digestRecord -PathType Leaf) {
      $prevDigest = Get-Content -LiteralPath $digestRecord -Raw -ErrorAction SilentlyContinue
      if ($prevDigest -and $prevDigest.Trim() -eq $digest) {
        Write-Warning "Dispatcher log digest matches previous run (possible repeated failure)."
      }
    }
    $digest | Out-File -FilePath $digestRecord -Encoding ascii
  }
}

Write-Host "`n=== Invoker ping log excerpt ===" -ForegroundColor Magenta
$patterns = @('Invoker ping attempt','# ping failed','Invoker ping failed after','Failed to spawn invoker')
if ($logFetched) {
  $matches = Select-String -Path $logPath -Pattern $patterns -SimpleMatch
  if ($matches) {
    $matches | ForEach-Object { $_.Line } | ForEach-Object { Write-Host $_ }
  } else {
    Write-Host "(no invoker ping lines detected in job log)" -ForegroundColor Yellow
  }
} else {
  Write-Host "(job log unavailable)" -ForegroundColor Yellow
}

$bootLog = Get-ChildItem -Path $artifactDir -Recurse -Filter 'boot.log' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($bootLog) {
  Write-Host "`n=== _invoker/boot.log tail ===" -ForegroundColor Magenta
  Get-Content -Path $bootLog.FullName | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
} else {
  Write-Host "`n(no boot.log found in artifacts)" -ForegroundColor Yellow
}

Write-Host "`nRun URL: $($runInfo.url)" -ForegroundColor Cyan
