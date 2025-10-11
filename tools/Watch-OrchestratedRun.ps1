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
  [int]$PollSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GhJson {
  param([string[]]$GhArgs)
  if (-not $GhArgs -or $GhArgs.Count -eq 0) {
    throw "Invoke-GhJson called without arguments."
  }
  Write-Verbose ("[gh] {0}" -f ($GhArgs -join ' '))
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

function Get-LatestRunId {
  param([string]$Branch)
  $runs = Invoke-GhJson @('run','list','--limit','25','--workflow','CI Orchestrated (deterministic chain)','--json','databaseId,headBranch,status,conclusion,url')
  $match = $runs | Where-Object { $_.headBranch -eq $Branch } | Select-Object -First 1
  if (-not $match) {
    throw "Could not find a recent orchestrated run for branch '$Branch'."
  }
  Write-Host ("Latest orchestrated run for branch '{0}' is {1}" -f $Branch, $match.databaseId) -ForegroundColor Cyan
  return [string]$match.databaseId
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI (gh) is required."
}

if (-not $RunId) {
  $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
  if (-not $branch) {
    throw "Unable to detect current branch; please supply -RunId."
  }
  $RunId = Get-LatestRunId -Branch $branch
}

Write-Host ("Inspecting orchestrated run {0}" -f $RunId) -ForegroundColor Green

$runInfo = $null
while ($true) {
  $runInfo = Invoke-GhJson @('run','view',$RunId,'--json','status,conclusion,jobs,url,headBranch')
  $dispatcher = $runInfo.jobs | Where-Object { $_.name -eq 'pester-category (dispatcher)' } | Select-Object -First 1
  if (-not $dispatcher) {
    Write-Host "Dispatcher job not yet scheduled. Waiting..." -ForegroundColor Yellow
  } elseif ($dispatcher.status -eq 'completed' -and $runInfo.status -eq 'completed') {
    break
  } else {
    Write-Host ("Run status: {0} | Dispatcher status: {1} (conclusion={2}) - polling again in {3}s" -f $runInfo.status, $dispatcher.status, $dispatcher.conclusion, $PollSeconds) -ForegroundColor Yellow
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
for ($attempt = 1; $attempt -le 40; $attempt++) {
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
if (-not $logFetched) {
  Write-Warning "Dispatcher log not yet available; continuing without direct job log."
}

$artifactDir = Join-Path $scratch "artifacts"
Write-Host ("Downloading dispatcher artifacts to {0}" -f $artifactDir) -ForegroundColor Cyan
$artifactFetched = $false
for ($attempt = 1; $attempt -le 20 -and -not $artifactFetched; $attempt++) {
  try {
    & gh run download $RunId --name 'orchestrated-pester-results-dispatcher' --dir $artifactDir *>$null
    $artifactFetched = $true
  } catch {
    if ($dispatcher.conclusion -in @('success','failure','cancelled','skipped')) {
      Start-Sleep -Seconds 5
    } else {
      break
    }
  }
}
if (-not $artifactFetched) {
  Write-Warning "Dispatcher artifacts not yet available."
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
