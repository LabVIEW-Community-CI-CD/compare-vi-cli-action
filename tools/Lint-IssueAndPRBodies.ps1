#Requires -Version 7.0
<#!
.SYNOPSIS
  Lint PR or Issue bodies for structure and readability.
.DESCRIPTION
  Validates the presence of common sections and patterns to help downstream
  agents and humans consume bodies predictably. Can lint local files or
  fetch remote bodies via gh CLI.
.PARAMETER Repo
  owner/name. Inferred from git remote when omitted.
.PARAMETER PR
  Pull request number to lint (fetches remote body).
.PARAMETER Issue
  Issue number to lint (fetches remote body).
.PARAMETER File
  Body file path to lint (local).
.PARAMETER Kind
  'pr' or 'issue' when -File is used (selects rule set). Default: 'pr'.
.PARAMETER WarnOnly
  Do not fail the process on errors; print findings only.
#>
[CmdletBinding()] param(
  [string] $Repo,
  [int] $PR,
  [int] $Issue,
  [string] $File,
  [ValidateSet('pr','issue')] [string] $Kind = 'pr',
  [switch] $WarnOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoFromGit {
  try {
    $u = git config --get remote.origin.url 2>$null
    if ($u -match 'github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$') { return "{0}/{1}" -f $Matches[1], $Matches[2] }
  } catch {}
  return $null
}
function Ensure-GhAuth { gh auth status -h github.com | Out-Null }

function Get-Body {
  if ($File) { return (Get-Content -LiteralPath $File -Raw) }
  if ($PR)   { return ((gh pr view -R $Repo $PR --json body | ConvertFrom-Json).body) }
  if ($Issue){ return ((gh issue view -R $Repo $Issue --json body | ConvertFrom-Json).body) }
  throw 'Provide -File or -PR or -Issue.'
}

if (-not $Repo) { $Repo = Resolve-RepoFromGit }
if (($PR -or $Issue) -and -not $Repo) { throw 'Repo not resolved; set -Repo.' }
if ($PR -or $Issue) { Ensure-GhAuth }

$text = Get-Body
$lines = @($text -split "`r?`n")

# Rules
$requiredSections = if ($PR) { @('Summary','Acceptance','Validation','Risks','Links') } elseif ($Issue) { @('Scope','Acceptance','References') } else { if ($Kind -eq 'pr') { @('Summary','Acceptance','Validation','Risks','Links') } else { @('Scope','Acceptance','References') } }
$findings = @()

# Check headings (case-insensitive, allow punctuation)
foreach ($sec in $requiredSections) {
  if (-not ($lines -match "(?i)^\s*#+\s*$sec")) { $findings += "Missing section heading: $sec" }
}

if ($PR -or $Kind -eq 'pr') {
  if (-not ($text -match '(?mi)^Closes\s+#\d+')) { $findings += "PR body missing 'Closes #<issue>' linkage." }
}

# Basic readability heuristics
if ($text.Length -lt 200) { $findings += 'Body length is short (<200 chars); consider adding more detail.' }
if (-not ($text -match '(?m)^- \[ \]')) { $findings += 'No checklists found; consider adding a validation checklist.' }

if ($findings.Count -eq 0) {
  Write-Host 'Issue/PR body lints: OK'
  exit 0
}

$findings | ForEach-Object { Write-Host "- $_" }
if ($WarnOnly) { exit 0 } else { exit 3 }

