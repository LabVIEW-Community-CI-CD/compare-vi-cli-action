#Requires -Version 7.0
<#!
.SYNOPSIS
  List recent GitHub Actions runs for a branch and share links.
.DESCRIPTION
  Queries the GitHub REST API for workflow runs on a repository/branch.
  Prefers GH_ADMIN_TOKEN for auth, falls back to GH_TOKEN, XCLI_PAT, or GITHUB_TOKEN.
.PARAMETER Repo
  Repository in owner/name form. Defaults to parsing the current git remote.
.PARAMETER Branch
  Branch name. Defaults to current git branch.
.PARAMETER Limit
  Max runs to fetch (per_page). Default: 10.
.PARAMETER Name
  Optional workflow name filter (wildcards allowed).
.PARAMETER Status
  Optional status filter (queued|in_progress|completed).
.PARAMETER Conclusion
  Optional conclusion filter (success|failure|cancelled|skipped|timed_out|...)
.PARAMETER Raw
  Output the raw JSON from the API.
.PARAMETER Open
  Open the newest matching run in the default browser.
#>
[CmdletBinding()] param(
  [string] $Repo,
  [string] $Branch,
  [int] $Limit = 10,
  [string] $Name,
  [ValidateSet('queued','in_progress','completed')]
  [string] $Status,
  [string] $Conclusion,
  [switch] $Raw,
  [switch] $Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoFromGit {
  try {
    $url = git config --get remote.origin.url 2>$null
    if (-not $url) { return $null }
    # https://github.com/owner/repo.git OR git@github.com:owner/repo.git
    if ($url -match 'github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$') {
      return ("{0}/{1}" -f $Matches[1], $Matches[2])
    }
  } catch {}
  return $null
}

function Resolve-BranchFromGit {
  try { return (git rev-parse --abbrev-ref HEAD 2>$null) } catch { return $null }
}

if (-not $Repo) { $Repo = Resolve-RepoFromGit }
if (-not $Repo) { throw 'Repo not resolved. Provide -Repo owner/name or run inside a git clone.' }
if (-not $Branch) { $Branch = Resolve-BranchFromGit }
if (-not $Branch) { throw 'Branch not resolved. Provide -Branch or run inside a git branch.' }

$token = $env:GH_ADMIN_TOKEN
if (-not $token) { $token = $env:GH_TOKEN }
if (-not $token) { $token = $env:XCLI_PAT }
if (-not $token) { $token = $env:GITHUB_TOKEN }

$hdr = @{ 'User-Agent'='list-branch-runs'; 'Accept'='application/vnd.github+json' }
if ($token) { $hdr['Authorization'] = "Bearer $token" }

$owner, $nameOnly = $Repo.Split('/')
$base = "https://api.github.com/repos/$owner/$nameOnly/actions/runs?branch=$Branch&per_page=$Limit"

try { $resp = Invoke-RestMethod -Method Get -Uri $base -Headers $hdr } catch {
  Write-Error ("Failed to query runs: {0}" -f $_.Exception.Message)
  throw
}

$runs = @($resp.workflow_runs)
if ($Name)       { $runs = $runs | Where-Object { $_.name -like $Name } }
if ($Status)     { $runs = $runs | Where-Object { $_.status -eq $Status } }
if ($Conclusion) { $runs = $runs | Where-Object { $_.conclusion -eq $Conclusion } }

if ($Raw) { $resp | ConvertTo-Json -Depth 6; return }

if (-not $runs -or $runs.Count -eq 0) {
  Write-Host ("No runs found for {0}@{1}" -f $Repo, $Branch) -ForegroundColor Yellow
  return
}

$rows = $runs | Select-Object name,status,conclusion,run_number,head_branch,html_url
$rows | Format-Table -AutoSize | Out-String | Write-Host

# Also print plain URLs for quick copy
$runs | ForEach-Object { $_.html_url } | Write-Output

if ($Open) {
  $u = $runs[0].html_url
  if ($u) {
    try {
      if ($IsWindows) { Start-Process $u } else { & xdg-open $u 2>$null }
    } catch { Write-Host "::notice::Failed to open browser: $_" }
  }
}

