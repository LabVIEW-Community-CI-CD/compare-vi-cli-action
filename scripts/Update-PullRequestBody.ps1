<#!
.SYNOPSIS
  Updates the current PR body with a generated Markdown snippet (sticky markers supported).
.DESCRIPTION
  Reads a Markdown file (e.g., from Generate-PullRequestCompareReport.ps1) and inserts/replaces
  a section in the PR body between markers. Works in GitHub Actions using GITHUB_TOKEN.

  Required environment in Actions:
  - GITHUB_REPOSITORY (owner/repo)
  - GITHUB_TOKEN (repo-scoped token with pull-requests: write)
  - GITHUB_EVENT_PATH (pull_request event payload) OR provide -PRNumber

.PARAMETER MarkdownPath
  Path to the Markdown snippet to insert.
.PARAMETER PRNumber
  Pull request number (optional; inferred from event payload when omitted).
.PARAMETER StartMarker
  Start marker string. Default: '<!-- vi-compare:start -->'
.PARAMETER EndMarker
  End marker string. Default: '<!-- vi-compare:end -->'
# Note: If markers are not found in the existing PR body, this script will append a new section at the end.
#>
[CmdletBinding()] param(
  [Parameter(Mandatory)] [string]$MarkdownPath,
  [int]$PRNumber,
  [string]$StartMarker = '<!-- vi-compare:start -->',
  [string]$EndMarker   = '<!-- vi-compare:end -->'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $MarkdownPath -PathType Leaf)) { throw "MarkdownPath not found: $MarkdownPath" }
$md = Get-Content -LiteralPath $MarkdownPath -Raw

$repo = $env:GITHUB_REPOSITORY
if (-not $repo -or -not ($repo -match '/')) { throw 'GITHUB_REPOSITORY env missing or invalid (expected owner/repo)' }
$owner,$name = $repo.Split('/')

$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GH_TOKEN }
if (-not $token) { throw 'GITHUB_TOKEN (or GH_TOKEN) is required to update PR body' }

if (-not $PRNumber) {
  $eventPath = $env:GITHUB_EVENT_PATH
  if (-not $eventPath -or -not (Test-Path -LiteralPath $eventPath -PathType Leaf)) { throw 'PRNumber not provided and GITHUB_EVENT_PATH missing; cannot infer PR number' }
  $evt = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
  if ($evt.pull_request.number) { $PRNumber = [int]$evt.pull_request.number }
  else { throw 'Unable to infer PR number from event payload' }
}

function Invoke-GitHubApi([string]$method,[string]$url,[object]$bodyObj){
  $headers = @{ Authorization = "Bearer $token"; 'User-Agent' = 'vi-compare-action'; Accept = 'application/vnd.github+json' }
  if ($bodyObj) { $json = $bodyObj | ConvertTo-Json -Depth 10 } else { $json = $null }
  try {
    if ($method -eq 'GET') { return Invoke-RestMethod -Method Get -Uri $url -Headers $headers }
    else { return Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $json -ContentType 'application/json' }
  } catch {
    throw "GitHub API call failed ($method $url): $_"
  }
}

$baseUrl = 'https://api.github.com'
$getUrl = "$baseUrl/repos/$owner/$name/pulls/$PRNumber"
$pr = Invoke-GitHubApi 'GET' $getUrl $null
$body = [string]$pr.body
if (-not $body) { $body = '' }

# Compose new section content with markers; embed snippet as-is
$section = @()
$section += $StartMarker
$section += ''
$section += $md.TrimEnd()
$section += ''
$section += $EndMarker
$sectionText = ($section -join "`n")

# Replace existing block or append
$newBody = $null
if ($body -and $body.Contains($StartMarker) -and $body.Contains($EndMarker)) {
  $pattern = [regex]::Escape($StartMarker) + '.*?' + [regex]::Escape($EndMarker)
  $newBody = [regex]::Replace($body, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $sectionText }, 'Singleline')
} else {
  if ($body -and -not $body.EndsWith("`n")) { $body += "`n" }
  $newBody = $body + "`n" + $sectionText + "`n"
}

if ($newBody.Length -gt 65000) { Write-Warning 'PR body exceeds typical size; consider trimming the snippet.' }

$patchUrl = $getUrl
$payload = @{ body = $newBody }
Invoke-GitHubApi 'PATCH' $patchUrl $payload | Out-Null
Write-Host "PR #$PRNumber body updated with VI Compare snippet." -ForegroundColor Green