#Requires -Version 7.0
<#!
.SYNOPSIS
  Create a GitHub issue to track a PR and print its number/URL.
.DESCRIPTION
  Opens (or reuses) a tracking issue on the target repository. By adding
  "Closes #<issue>" to the PR body, the issue will auto-close on merge.
  Branch protections ensure checks are green before merge, so closure implies green.
.PARAMETER Repo
  owner/name form. If omitted, inferred from git remote.
.PARAMETER Title
  Issue title (required).
.PARAMETER Body
  Issue body text. Use -BodyPath to read from file.
.PARAMETER BodyPath
  Path to a file containing the issue body.
.PARAMETER Labels
  One or more label names (e.g., tracking,ci).
.PARAMETER Assignees
  One or more assignee login names.
.PARAMETER OutputNumberPath
  Optional file to write the created issue number to.
.PARAMETER Token
  Explicit token. Otherwise uses GH_ADMIN_TOKEN, GH_TOKEN, XCLI_PAT, or GITHUB_TOKEN.
#>
[CmdletBinding()] param(
  [string] $Repo,
  [Parameter(Mandatory)] [string] $Title,
  [string] $Body,
  [string] $BodyPath,
  [string[]] $Labels,
  [string[]] $Assignees,
  [string] $OutputNumberPath,
  [string] $Token
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoFromGit {
  try {
    $url = git config --get remote.origin.url 2>$null
    if (-not $url) { return $null }
    if ($url -match 'github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$') { return "{0}/{1}" -f $Matches[1], $Matches[2] }
  } catch {}
  return $null
}
function Resolve-Token {
  param([string] $Explicit)
  if ($Explicit) { return $Explicit }
  foreach ($name in 'GH_ADMIN_TOKEN','GH_TOKEN','XCLI_PAT','GITHUB_TOKEN') {
    $v = [Environment]::GetEnvironmentVariable($name,'Process')
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  }
  throw 'No GitHub token available. Set GH_ADMIN_TOKEN or GH_TOKEN or GITHUB_TOKEN.'
}
function Read-Body {
  param([string] $Inline, [string] $Path)
  if ($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "BodyPath not found: $Path" }
    return (Get-Content -LiteralPath (Resolve-Path -LiteralPath $Path) -Raw)
  }
  return ($Inline ?? '')
}

if (-not $Repo) { $Repo = Resolve-RepoFromGit }
if (-not $Repo) { throw 'Repo not resolved. Provide -Repo or run inside a git clone.' }
$token = Resolve-Token -Explicit $Token
$body  = Read-Body -Inline $Body -Path $BodyPath
$owner, $name = $Repo.Split('/')

$headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28' }
$payload = @{ title = $Title; body = $body }
if ($Labels)    { $payload.labels    = @($Labels) }
if ($Assignees) { $payload.assignees = @($Assignees) }
$json = $payload | ConvertTo-Json -Depth 6

try {
  $resp = Invoke-RestMethod -Headers $headers -ContentType 'application/json' -Uri "https://api.github.com/repos/$owner/$name/issues" -Method POST -Body $json
} catch {
  Write-Error ("Failed to create issue: {0}" -f $_.Exception.Message)
  throw
}

if ($OutputNumberPath) {
  $dir = Split-Path -Parent $OutputNumberPath
  if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -LiteralPath $OutputNumberPath -Value ([string]$resp.number) -Encoding UTF8
}
Write-Host ("CREATED #{0} {1}" -f $resp.number, $resp.html_url)

