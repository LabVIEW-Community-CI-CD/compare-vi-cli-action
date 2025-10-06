<#
.SYNOPSIS
  Removes transient local development and test artifacts (Pester result XML/JSON, loop status files, temp results) without touching source.

.DESCRIPTION
  Targets directories and files that are produced by running the dispatcher, integration loops, or ad-hoc debug scripts.
  Provides -WhatIf / -Confirm support (inherited via ShouldProcess) and a -ListOnly mode for dry enumeration.

.USAGE
  pwsh -File scripts/Clean-DevArtifacts.ps1 -Verbose
  pwsh -File scripts/Clean-DevArtifacts.ps1 -ListOnly
  pwsh -File scripts/Clean-DevArtifacts.ps1 -IncludeAllVariants

.NOTES
  Safe defaults: preserves placeholder .gitkeep files and never removes *.vi.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param(
  [switch]$ListOnly,
  [switch]$IncludeAllVariants, # include secondary result dirs like tests/results-maxtestfiles, tmp-timeout, delta history, etc.
  [switch]$IncludeLoopArtifacts  # include loop final status JSON files at repo root
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-MatchObject {
  param([string]$Path,[string]$Type,[int]$Depth)
  [pscustomobject]@{ Path=$Path; Type=$Type; Depth=$Depth }
}

$repoRoot = Split-Path -Parent $PSCommandPath | Split-Path -Parent
Write-Verbose "Repository root resolved to: $repoRoot"

# Always-clean patterns (files)
$filePatterns = @(
  'pester-results.xml',
  'pester-summary.txt',
  'pester-summary.json',
  'pester-failures.json',
  'pester-artifacts.json',
  'pester-selected-files.txt',
  'delta.json', 'delta-history.jsonl', 'flaky-delta.json', 'flaky-demo-state.txt'
)

if ($IncludeLoopArtifacts) { $filePatterns += 'final.json' }

# Result directories to optionally purge completely (except .gitkeep)
$baseResultDirs = @('tests/results')
if ($IncludeAllVariants) { $baseResultDirs += 'tests/results-maxtestfiles','tests/tmp-timeout/results' }

$targets = [System.Collections.Generic.List[object]]::new()

foreach ($dir in $baseResultDirs) {
  $abs = Join-Path $repoRoot $dir
  if (Test-Path $abs) {
    Get-ChildItem -LiteralPath $abs -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' -and $filePatterns -contains $_.Name } | ForEach-Object {
      $targets.Add( (New-MatchObject -Path $_.FullName -Type 'File' -Depth 1) )
    }
    # Also pick stray files matching patterns but not enumerated (globs)
    foreach ($pattern in $filePatterns) {
      Get-ChildItem -LiteralPath $abs -Filter $pattern -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object {
        if (-not $targets.Path -contains $_.FullName) { $targets.Add( (New-MatchObject -Path $_.FullName -Type 'File' -Depth 1) ) }
      }
    }
  }
}

# Root-level strays (e.g., final.json, testResults.xml) if present
$rootStrays = @('testResults.xml')
if ($IncludeLoopArtifacts) { $rootStrays += 'final.json' }
foreach ($n in $rootStrays) {
  $p = Join-Path $repoRoot $n
  if (Test-Path $p) { $targets.Add( (New-MatchObject -Path $p -Type 'File' -Depth 0) ) }
}

if (-not $targets.Count) {
  Write-Host 'No transient artifacts found.' -ForegroundColor Yellow
  return
}

if ($ListOnly) {
  Write-Host 'Transient artifacts (list only):' -ForegroundColor Cyan
  $targets | Sort-Object Depth, Path | Format-Table -AutoSize
  return
}

$deleted = 0
foreach ($t in ($targets | Sort-Object Depth -Descending)) { # deepest first if dirs later (future extension)
  if ($PSCmdlet.ShouldProcess($t.Path,'Remove transient artifact')) {
    try { Remove-Item -LiteralPath $t.Path -Force -ErrorAction Stop; $deleted++ }
    catch { Write-Warning "Failed to delete $($t.Path): $($_.Exception.Message)" }
  }
}

Write-Host "Removed $deleted transient artifact file(s)." -ForegroundColor Green