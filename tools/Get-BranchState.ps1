#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$AsJson,
  [switch]$IncludeUntracked
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [switch]$AllowNonZero
  )

  $output = & git @Arguments 2>&1
  if ($LASTEXITCODE -ne 0 -and -not $AllowNonZero) {
    $joined = $Arguments -join ' '
    throw "git $joined failed (exit=$LASTEXITCODE): $output"
  }
  return $output
}

function Normalize-GitOutput {
  param([string[]]$Value)
  return ($Value -join "`n").Trim()
}

# Ensure we are inside a Git repository
try {
  $repoRoot = Normalize-GitOutput (Invoke-Git @('rev-parse', '--show-toplevel'))
} catch {
  throw 'Not inside a Git repository.'
}
if (-not $repoRoot) {
  throw 'Not inside a Git repository.'
}

$branch = Normalize-GitOutput (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD'))

$upstream = $null
try {
  $upstream = Normalize-GitOutput (Invoke-Git @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'))
  if ([string]::IsNullOrWhiteSpace($upstream)) {
    $upstream = $null
  }
} catch {
  $upstream = $null
}

$ahead = 0
$behind = 0
if ($upstream) {
  $countsRaw = Normalize-GitOutput (Invoke-Git @('rev-list', '--left-right', '--count', "HEAD...$upstream"))
  if ($countsRaw) {
    $parts = $countsRaw -split '\s+'
    if ($parts.Length -ge 2) {
      $ahead = [int]$parts[0]
      $behind = [int]$parts[1]
    }
  }
}

$statusLines = Invoke-Git @('status', '--porcelain') -AllowNonZero
if ($LASTEXITCODE -ne 0 -and -not $statusLines) {
  throw 'Unable to query git status.'
}
$statusLines = ($statusLines | Where-Object { $_ -and $_.Trim().Length -gt 0 })
$isClean = -not $statusLines
$untrackedLines = @()
foreach ($line in $statusLines) {
  if ($line.StartsWith('??')) {
    $untrackedLines += $line.Substring(3)
  }
}
$hasUntracked = $untrackedLines.Count -gt 0
$untrackedOutput = if ($IncludeUntracked) { [string[]]$untrackedLines } else { @() }

$summaryParts = @()
if ($upstream) {
  if ($ahead -eq 0 -and $behind -eq 0) {
    $summaryParts += "up-to-date with $upstream"
  } else {
    if ($ahead -gt 0) { $summaryParts += "ahead $ahead of $upstream" }
    if ($behind -gt 0) { $summaryParts += "behind $behind from $upstream" }
  }
} else {
  $summaryParts += 'no upstream configured'
}
if (-not $isClean) {
  $dirtyInfo = if ($hasUntracked) { 'dirty (includes untracked files)' } else { 'dirty' }
  $summaryParts += $dirtyInfo
}
if (-not $summaryParts) {
  $summaryParts += 'status unknown'
}
$summary = "Branch ${branch}: " + ($summaryParts -join '; ')

$result = [pscustomobject]@{
  RepositoryRoot = $repoRoot
  Branch         = $branch
  Upstream       = $upstream
  Ahead          = $ahead
  Behind         = $behind
  HasUpstream    = [bool]$upstream
  IsClean        = [bool]$isClean
  HasUntracked   = $hasUntracked
  Untracked      = $untrackedOutput
  TimestampUtc   = (Get-Date -AsUtc)
  Summary        = $summary
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 4
} else {
  Write-Host "[branch-state] $summary" -ForegroundColor Cyan
  return $result
}
