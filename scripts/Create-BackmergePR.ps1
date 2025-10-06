#requires -Version 5.1
<#
.SYNOPSIS
Creates or updates a GitHub pull request using a token from an environment variable.

.DESCRIPTION
This script checks for an existing open PR from a given head branch into a base branch.
If found, it updates the title/body; otherwise it creates a new PR. The token is read
from an environment variable (default: XCLI_PAT). Designed to avoid quoting pitfalls by
optionally reading the PR body from a file.

.PARAMETER Owner
GitHub organization or user name (e.g., 'LabVIEW-Community-CI-CD').

.PARAMETER Repo
Repository name (e.g., 'compare-vi-cli-action').

.PARAMETER Base
Target branch name (e.g., 'develop').

.PARAMETER Head
Source branch name (e.g., 'release/v0.4.0-rc.1').

.PARAMETER Title
Pull request title.

.PARAMETER Body
Pull request body text. If BodyPath is provided, that takes precedence.

.PARAMETER BodyPath
Path to a file containing the PR body text (recommended to avoid shell quoting issues).

.PARAMETER Draft
Create PR as draft when set.

.PARAMETER TokenEnvVar
Environment variable name holding a GitHub token with repo scope. Default: XCLI_PAT.

.EXAMPLE
pwsh -File scripts/Create-BackmergePR.ps1 -Owner Org -Repo Repo -Base develop -Head feature -Title 'My PR' -BodyPath tmp-agg/pr-body.txt

#>
[CmdletBinding()] param(
  [Parameter(Mandatory=$true)] [string] $Owner,
  [Parameter(Mandatory=$true)] [string] $Repo,
  [Parameter(Mandatory=$true)] [string] $Base,
  [Parameter(Mandatory=$true)] [string] $Head,
  [Parameter(Mandatory=$true)] [string] $Title,
  [string] $Body,
  [string] $BodyPath,
  [switch] $Draft,
  [string] $Token,
  [string] $TokenEnvVar = 'XCLI_PAT'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Token {
  param([string] $Explicit, [string] $PrimaryEnv)
  # 1) Explicit parameter wins if provided
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
  # 2) Try primary env var (default XCLI_PAT)
  $candidates = @($PrimaryEnv,'GH_TOKEN','GITHUB_TOKEN') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  foreach ($name in $candidates) {
    $val = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ([string]::IsNullOrWhiteSpace($val)) { $val = [Environment]::GetEnvironmentVariable($name, 'User') }
    if ([string]::IsNullOrWhiteSpace($val)) { $val = [Environment]::GetEnvironmentVariable($name, 'Machine') }
    if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
  }
  throw "No GitHub token found. Provide -Token or set one of: $($candidates -join ', ')."
}

function Get-PrBody {
  param([string] $Inline, [string] $Path)
  if ($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "BodyPath not found: $Path" }
  # Use Get-Content -Raw to avoid patterns (like .NET direct file reads) that the tests flag
    return (Get-Content -LiteralPath (Resolve-Path -LiteralPath $Path) -Raw)
  }
  if ($Inline) { return $Inline }
  return ''
}

$token = Resolve-Token -Explicit $Token -PrimaryEnv $TokenEnvVar
$headers = [Collections.Generic.Dictionary[string,string]]::new()
$headers['Authorization'] = "Bearer $token"
$headers['Accept'] = 'application/vnd.github+json'
$headers['X-GitHub-Api-Version'] = '2022-11-28'

$prBody = Get-PrBody -Inline $Body -Path $BodyPath

$baseUrl = "https://api.github.com/repos/$Owner/$Repo/pulls"

# Detect existing open PR from Head -> Base
# The filter expects 'owner:branch' in 'head'
$queryUri = "https://api.github.com/repos/${Owner}/${Repo}/pulls?state=open&base=${Base}&head=${Owner}:${Head}"

try {
  $existing = Invoke-RestMethod -Headers $headers -Uri $queryUri -Method GET
} catch {
  Write-Error ("Failed to query existing PRs: {0}" -f $_.Exception.Message)
  throw
}

$target = $existing | Where-Object { $_.head.ref -eq $Head -and $_.base.ref -eq $Base } | Select-Object -First 1

if ($null -ne $target) {
  $num = $target.number
  $patchUri = "$baseUrl/$num"
  $payload = @{ title = $Title; body = $prBody } | ConvertTo-Json -Depth 5
  $resp = Invoke-RestMethod -Headers $headers -ContentType 'application/json' -Uri $patchUri -Method PATCH -Body $payload
  Write-Host ("UPDATED {0} {1}" -f $resp.number, $resp.html_url)
} else {
  $payload = @{ title = $Title; head = $Head; base = $Base; body = $prBody; draft = [bool]$Draft } | ConvertTo-Json -Depth 5
  try {
    $resp = Invoke-RestMethod -Headers $headers -ContentType 'application/json' -Uri $baseUrl -Method POST -Body $payload
    Write-Host ("CREATED {0} {1}" -f $resp.number, $resp.html_url)
  } catch {
    $status = $_.Exception.Response.StatusCode.Value__ 2>$null
    $errText = $_.ErrorDetails.Message
    Write-Error ("Failed to create PR (HTTP {0}): {1}" -f $status, $errText)
    throw
  }
}
