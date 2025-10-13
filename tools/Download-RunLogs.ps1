#Requires -Version 7.0
<#
.SYNOPSIS
  Download and unpack job logs for a GitHub Actions run.

.DESCRIPTION
  Fetches the job list for a workflow run, downloads each job log in parallel order,
  and writes them under a structured directory:

    <OutputDir>/
      job-<id>-<name>/job.log
      job-<id>-<name>/steps/<files from archive>

  Plain-text responses are normalised to UTF-8 .log files; ZIP payloads are extracted
  automatically. A manifest.json file summarises the run metadata.

.PARAMETER RunId
  The numeric run ID (databaseId) of the workflow run.

.PARAMETER Repo
  Optional owner/name repository slug. When omitted, the script uses
  $env:GITHUB_REPOSITORY, gh repo view, or the local git remote.

.PARAMETER OutputDir
  Destination directory for logs. Defaults to "run-logs-<RunId>" under the current
  working directory.

.PARAMETER Force
  Overwrite any existing output directory.

.EXAMPLE
  pwsh -File tools/Download-RunLogs.ps1 -RunId 18448868980

.EXAMPLE
  pwsh -File tools/Download-RunLogs.ps1 -RunId 18448868980 -Repo owner/repo -OutputDir .\logs -Force
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$RunId,
  [string]$Repo,
  [string]$OutputDir,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Repo([string]$Explicit) {
  if ($Explicit) { return $Explicit }
  if ($env:GITHUB_REPOSITORY) { return $env:GITHUB_REPOSITORY }
  try {
    $repo = gh repo view --json nameWithOwner --jq .nameWithOwner 2>$null
    if ($repo) { return $repo.Trim() }
  } catch {}
  try {
    $url = git remote get-url origin 2>$null
    if ($url -match 'github\.com[:/](.+?/.+?)(?:\.git)?$') { return $Matches[1] }
  } catch {}
  throw 'Unable to determine repository. Provide -Repo or configure gh/git.'
}

function Get-GitHubToken {
  if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
  try {
    $token = gh auth token 2>$null
    if ($token) { return $token.Trim() }
  } catch {}
  throw 'Unable to resolve a GitHub token. Authenticate with gh auth login or set GITHUB_TOKEN.'
}

function Get-RunJobs([string]$Repo,[string]$RunId,[hashtable]$Headers) {
  $jobs = @()
  $page = 1
  while ($true) {
    $uri = "https://api.github.com/repos/$Repo/actions/runs/$RunId/jobs?per_page=100&page=$page"
    $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get
    if (-not $resp.jobs) { break }
    $jobs += $resp.jobs
    if ($resp.jobs.Count -lt 100) { break }
    $page++
  }
  return $jobs
}

function New-SafeName([string]$Name) {
  if (-not $Name) { return 'job' }
  $safe = ($Name -replace '[^\w\.\-]+','-').Trim('-')
  if (-not $safe) { $safe = 'job' }
  if ($safe.Length -gt 48) { $safe = $safe.Substring(0,48) }
  return $safe
}

function Expand-Zip([string]$ZipPath,[string]$Destination) {
  if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination, $true)
  } else {
    Expand-Archive -Path $ZipPath -DestinationPath $Destination -Force
  }
}

function Write-Manifest([string]$Path,$Repo,$RunId,$Jobs) {
  $manifest = [ordered]@{
    schema    = 'run-logs/v1'
    generated = (Get-Date).ToString('o')
    repo      = $Repo
    runId     = $RunId
    jobs      = @()
  }
  foreach ($job in $Jobs) {
    $manifest.jobs += [ordered]@{
      id          = $job.id
      name        = $job.name
      status      = $job.status
      conclusion  = $job.conclusion
      attempt     = $job.run_attempt
      startedAt   = $job.started_at
      completedAt = $job.completed_at
      url         = $job.html_url
      outputDir   = ("job-{0}-{1}" -f $job.id, (New-SafeName $job.name))
    }
  }
  $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding utf8
}

$repoSlug = Resolve-Repo -Explicit $Repo
$token = Get-GitHubToken
$headers = @{
  Authorization = "Bearer $token"
  Accept        = 'application/vnd.github+json'
  'User-Agent'  = 'compare-vi-cli-tools'
}

$jobs = Get-RunJobs -Repo $repoSlug -RunId $RunId -Headers $headers
if (-not $jobs -or $jobs.Count -eq 0) {
  throw "No jobs found for run $RunId in $repoSlug."
}

if (-not $OutputDir) {
  $OutputDir = Join-Path (Get-Location) ("run-logs-$RunId")
}
if (Test-Path -LiteralPath $OutputDir) {
  if (-not $Force) { throw "Output directory already exists: $OutputDir (use -Force to overwrite)" }
  Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem

foreach ($job in $jobs) {
  $safeName = New-SafeName $job.name
  $jobDir = Join-Path $OutputDir ("job-{0}-{1}" -f $job.id, $safeName)
  New-Item -ItemType Directory -Force -Path $jobDir | Out-Null

  $logUri = "https://api.github.com/repos/$repoSlug/actions/jobs/$($job.id)/logs"
  $handler = [System.Net.Http.HttpClientHandler]::new()
  $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
  $client = [System.Net.Http.HttpClient]::new($handler)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('compare-vi-cli-tools')
  $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token)

  try {
    $response = $client.GetAsync($logUri).Result
    if (-not $response.IsSuccessStatusCode) {
      throw "HTTP $($response.StatusCode.value__) downloading job $($job.id) logs."
    }
    $bytes = $response.Content.ReadAsByteArrayAsync().Result
    $tmpPath = Join-Path $jobDir 'job-log.bin'
    [System.IO.File]::WriteAllBytes($tmpPath, $bytes)

    $isZip = $bytes.Length -ge 4 -and $bytes[0] -eq 80 -and $bytes[1] -eq 75
    if ($isZip) {
      $stepsDir = Join-Path $jobDir 'steps'
      New-Item -ItemType Directory -Force -Path $stepsDir | Out-Null
      try {
        Expand-Zip -ZipPath $tmpPath -Destination $stepsDir
        $logFile = Get-ChildItem -Path $stepsDir -Filter '*.log' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($logFile) {
          Copy-Item -LiteralPath $logFile.FullName -Destination (Join-Path $jobDir 'job.log') -Force
        }
      } catch {
        Write-Warning "Failed to expand archive for job $($job.id): $_"
        Move-Item -LiteralPath $tmpPath -Destination (Join-Path $jobDir 'job.log') -Force
        continue
      }
      Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
    } else {
      Move-Item -LiteralPath $tmpPath -Destination (Join-Path $jobDir 'job.log') -Force
    }
  } finally {
    $client.Dispose()
    $handler.Dispose()
  }
}

Write-Manifest -Path (Join-Path $OutputDir 'manifest.json') -Repo $repoSlug -RunId $RunId -Jobs $jobs

Write-Host ("Downloaded {0} job log(s) for run {1} into {2}" -f $jobs.Count, $RunId, (Resolve-Path $OutputDir))
