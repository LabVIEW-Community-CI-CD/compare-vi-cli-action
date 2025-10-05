#Requires -Version 7.0
<#!
.SYNOPSIS
  Create/update a PR, open a tracking issue, append closing keyword, and share links.
.DESCRIPTION
  Drives an end-to-end PR → tracking issue flow using gh CLI.
  - Verifies gh auth session
  - Creates/updates PR (base/head/title/body)
  - Opens a tracking issue with labels and body
  - Appends "Closes #N" to the PR body and updates it
  - Prints links and lists recent runs for the branch
.PARAMETER Base
  Base branch (default: develop).
.PARAMETER Head
  Head branch (default: current branch).
.PARAMETER Title
  PR title (required when creating).
.PARAMETER PrBodyPath
  Path to PR body file.
.PARAMETER IssueTitle
  Tracking issue title (required to create issue).
.PARAMETER IssueBodyPath
  Path to tracking issue body file.
.PARAMETER IssueLabels
  Comma-separated labels for the issue (default: ci,documentation).
.PARAMETER Open
  Open PR in browser when done.
#>
[CmdletBinding()] param(
  [string] $Base = 'develop',
  [string] $Head,
  [string] $Title,
  [string] $PrBodyPath,
  [string] $IssueTitle,
  [string] $IssueBodyPath,
  [string] $IssueLabels = 'ci,documentation',
  [string] $PrLabels,
  [string] $Assignees,
  [string] $Milestone,
  [switch] $Draft,
  [switch] $SkipIssue,
  [switch] $DryRun,
  [switch] $Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CurrentBranch { git rev-parse --abbrev-ref HEAD }

function Ensure-GhAuth {
  $out = gh auth status -h github.com 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Not authenticated with gh: $out" }
  $out | Write-Host
}

function Ensure-File([string] $path, [string] $name) {
  if ($path -and -not (Test-Path -LiteralPath $path)) { throw "$name not found: $path" }
}

Ensure-GhAuth
if (-not $Head) { $Head = Get-CurrentBranch }
Ensure-File -path $PrBodyPath -name 'PR body'
if (-not $SkipIssue) { Ensure-File -path $IssueBodyPath -name 'Issue body' }

if ($DryRun) {
  Write-Host "[DRY-RUN] Base=$Base Head=$Head Title=$Title Draft=$Draft"
  Write-Host "[DRY-RUN] PR Body=$PrBodyPath PR Labels=$PrLabels Assignees=$Assignees Milestone=$Milestone"
  if (-not $SkipIssue) { Write-Host "[DRY-RUN] Issue Title=$IssueTitle Issue Body=$IssueBodyPath Labels=$IssueLabels" }
}

# Create or update PR
$prExists = $false
try {
  $prJson = gh pr view $Head --json number,url,title 2>$null | ConvertFrom-Json
  if ($prJson.number) { $prExists = $true }
} catch {}

if ($prExists) {
  if ($DryRun) { Write-Host "[DRY-RUN] Update PR #$($prJson.number)" } else {
    if ($PrBodyPath) { gh pr edit $prJson.number --body-file $PrBodyPath | Out-Null }
    if ($Title)      { gh pr edit $prJson.number --title $Title       | Out-Null }
    if ($PrLabels)   { gh pr edit $prJson.number --add-label $PrLabels | Out-Null }
    if ($Assignees)  { gh pr edit $prJson.number --add-assignee $Assignees | Out-Null }
    if ($Milestone)  { gh pr edit $prJson.number --milestone $Milestone | Out-Null }
  }
  $prUrl = $prJson.url
  $prNum = [int]$prJson.number
} else {
  if (-not $Title) { throw 'PR Title is required when creating a PR.' }
  if ($DryRun) {
    Write-Host "[DRY-RUN] Create PR -B $Base -H $Head --title '$Title' --body-file $PrBodyPath --draft:$Draft"
  } else {
    $args = @('pr','create','-B', $Base, '-H', $Head, '--title', $Title, '--body-file', $PrBodyPath)
    if ($Draft) { $args += '--draft' }
    $created = gh @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to create PR: $created" }
    $view = gh pr view $Head --json number,url | ConvertFrom-Json
    $prUrl = $view.url; $prNum = [int]$view.number
    if ($PrLabels)  { gh pr edit $prNum --add-label $PrLabels | Out-Null }
    if ($Assignees) { gh pr edit $prNum --add-assignee $Assignees | Out-Null }
    if ($Milestone) { gh pr edit $prNum --milestone $Milestone | Out-Null }
  }
}

if (-not $SkipIssue) {
  # Create tracking issue
  $labels = @($IssueLabels.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $args = @('issue','create','-t', $IssueTitle, '-F', $IssueBodyPath)
  foreach ($l in $labels) { $args += @('-l', $l) }
  if ($DryRun) {
    Write-Host "[DRY-RUN] gh $($args -join ' ')"
    $issueUrl = ''
    $issueNum = $null
  } else {
    $issueOut = gh @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to create issue: $issueOut" }
    $issueUrl = ($issueOut | Select-String -Pattern '/issues/\d+' -AllMatches).Matches.Value | Select-Object -Last 1
    if (-not $issueUrl) { throw "Could not parse issue URL from: $issueOut" }
    $issueNum = [int]($issueUrl.Split('/')[-1])
  }
}

# Append "Closes #N" to PR body and update
if ($PrBodyPath -and -not $SkipIssue -and $issueNum) {
  $body = Get-Content -LiteralPath $PrBodyPath -Raw
  if ($body -notmatch '(?mi)^Closes\s+#\d+') {
    $body = "$body`n`nCloses #$issueNum"
    if ($DryRun) { Write-Host "[DRY-RUN] Append 'Closes #$issueNum' to PR body" } else {
      Set-Content -LiteralPath $PrBodyPath -Value $body -Encoding UTF8
      gh pr edit $prNum --body-file $PrBodyPath | Out-Null
    }
  }
}

Write-Host ("PR: {0}" -f $prUrl)
Write-Host ("Issue: {0}" -f $issueUrl)

# Share runs
try {
  gh run list -b $Head -L 10 | Write-Host
} catch { Write-Host '::notice::gh run list failed (optional).' }

if ($Open) { try { gh pr view $prNum --web } catch {} }
