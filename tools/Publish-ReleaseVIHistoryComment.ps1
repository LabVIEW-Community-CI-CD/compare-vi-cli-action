#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ReviewIndexJsonPath,

  [Parameter(Mandatory = $true)]
  [string]$PolicySummaryJsonPath,

  [Parameter(Mandatory = $true)]
  [string]$Profile,

  [Parameter(Mandatory = $true)]
  [string]$RunUrl,

  [Parameter(Mandatory = $true)]
  [string]$BodyPath,

  [string]$RepoSlug,
  [int]$IssueNumber,
  [int]$PrNumber,
  [switch]$Post,

  [ValidateRange(2000, 65000)]
  [int]$MaxBodyLength = 58000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "JSON file not found: $Path"
  }
  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 40)
}

function Ensure-ParentDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function Get-OutcomeEmoji {
  param([string]$Outcome)
  switch (($Outcome ?? '').ToLowerInvariant()) {
    'pass' { return '✅' }
    'warn' { return '⚠️' }
    'fail' { return '❌' }
    default { return 'ℹ️' }
  }
}

$rows = @(Read-JsonFile -Path $ReviewIndexJsonPath)
$policy = Read-JsonFile -Path $PolicySummaryJsonPath

$outcome = [string]$policy.outcome
$mode = [string]$policy.mode
$rowCount = if ($policy.PSObject.Properties['rowCount']) { [int]$policy.rowCount } else { $rows.Count }
$violationCount = if ($policy.PSObject.Properties['violationCount']) { [int]$policy.violationCount } else { 0 }
$requiredScenarios = @()
if ($policy.PSObject.Properties['requiredScenarios']) {
  $requiredScenarios = @($policy.requiredScenarios | ForEach-Object { [string]$_ })
}
$violations = @()
if ($policy.PSObject.Properties['violations']) {
  $violations = @($policy.violations)
}

$summaryRows = @($rows | Sort-Object os, scenario)
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('### Release VI History Review') | Out-Null
$lines.Add('') | Out-Null
$lines.Add(('- Outcome: {0} **{1}**' -f (Get-OutcomeEmoji -Outcome $outcome), $outcome)) | Out-Null
$lines.Add(('- Profile: **{0}**' -f $Profile)) | Out-Null
$lines.Add(('- Policy mode: **{0}**' -f $mode)) | Out-Null
$lines.Add(('- Evaluated rows: **{0}**' -f $rowCount)) | Out-Null
$lines.Add(('- Violations: **{0}**' -f $violationCount)) | Out-Null
if ($requiredScenarios.Count -gt 0) {
  $lines.Add(('- Required scenarios: `{0}`' -f ($requiredScenarios -join ', '))) | Out-Null
}
$lines.Add('') | Out-Null
$lines.Add('| OS | Scenario | Status | Gate | Result Class | Compare Exit |') | Out-Null
$lines.Add('|---|---|---|---|---|---:|') | Out-Null
if ($summaryRows.Count -eq 0) {
  $lines.Add('| n/a | n/a | no-data | n/a | n/a | n/a |') | Out-Null
} else {
  foreach ($row in $summaryRows) {
    $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f [string]$row.os, [string]$row.scenario, [string]$row.status, [string]$row.gateOutcome, [string]$row.resultClass, [string]$row.compareExit)) | Out-Null
  }
}

if ($violations.Count -gt 0) {
  $lines.Add('') | Out-Null
  $lines.Add('<details><summary>Policy violations</summary>') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($violation in $violations) {
    $lines.Add(("- `{0}/{1}`: {2} ({3})" -f [string]$violation.os, [string]$violation.scenario, [string]$violation.reason, [string]$violation.detail)) | Out-Null
  }
  $lines.Add('') | Out-Null
  $lines.Add('</details>') | Out-Null
}

$lines.Add('') | Out-Null
$lines.Add(("Run details: [{0}]({0})" -f $RunUrl)) | Out-Null

$body = $lines -join [Environment]::NewLine
if ($body.Length -gt $MaxBodyLength) {
  $note = "`n`n> NOTE - Comment body truncated for GitHub size safety."
  $safeLength = [Math]::Max(0, $MaxBodyLength - $note.Length)
  $body = $body.Substring(0, $safeLength).TrimEnd() + $note
}

Ensure-ParentDirectory -Path $BodyPath
Set-Content -LiteralPath $BodyPath -Value $body -Encoding utf8

if (-not $Post) {
  Write-Host ("Comment body written to {0}" -f $BodyPath)
  return
}

if ([string]::IsNullOrWhiteSpace($RepoSlug)) {
  $RepoSlug = $env:GITHUB_REPOSITORY
}
if ([string]::IsNullOrWhiteSpace($RepoSlug)) {
  throw 'RepoSlug is required when -Post is set.'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI ('gh') is required when -Post is set."
}

if ($IssueNumber -gt 0) {
  & gh issue comment $IssueNumber --repo $RepoSlug --body-file $BodyPath
  if ($LASTEXITCODE -ne 0) {
    throw "gh issue comment failed with exit code $LASTEXITCODE"
  }
  Write-Host ("Posted release review comment to issue #{0}" -f $IssueNumber)
  return
}

if ($PrNumber -gt 0) {
  & gh pr comment $PrNumber --repo $RepoSlug --body-file $BodyPath
  if ($LASTEXITCODE -ne 0) {
    throw "gh pr comment failed with exit code $LASTEXITCODE"
  }
  Write-Host ("Posted release review comment to PR #{0}" -f $PrNumber)
  return
}

throw 'When -Post is set, provide either -IssueNumber or -PrNumber.'
