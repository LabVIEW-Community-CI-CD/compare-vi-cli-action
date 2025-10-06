#Requires -Version 7.0
<#!
.SYNOPSIS
  Verifies key preconditions from TAG_PREP_CHECKLIST.md prior to tagging a release.

.DESCRIPTION
  Performs a series of non-destructive validations:
    * Branch naming & cleanliness
    * CHANGELOG presence of target version & date format
    * action.yml outputs vs docs/action-outputs.md synchronization
    * Presence of migration helper files (PR_NOTES.md, TAG_PREP_CHECKLIST.md, etc.)
    * Markdown lint (npm run lint:md) status
    * Unit test dispatcher run (always) + optional integration run if canonical LVCompare + VI assets detected or -ForceIntegration specified
    * Verification of shortCircuitedIdentical output key
  Emits structured JSON summary and human readable console output.

.PARAMETER Version
  Target semantic version (e.g. 0.4.0). Required.

.PARAMETER EmitJsonPath
  Optional path to write JSON summary (default: ./release-verify-summary.json)

.PARAMETER ForceIntegration
  Force attempt to run integration tests even if canonical prerequisites not auto-detected.

.PARAMETER SkipTests
  Skip invoking Pester tests (lint & static checks only).

.PARAMETER Quiet
  Suppress most console output (JSON still written if requested). Overall pass/fail still printed.

.EXAMPLE
  pwsh -File scripts/Verify-ReleaseChecklist.ps1 -Version 0.4.0

.EXAMPLE
  pwsh -File scripts/Verify-ReleaseChecklist.ps1 -Version 0.4.0 -ForceIntegration -EmitJsonPath out.json

.NOTES
  - Integration tests require canonical LVCompare path:
      C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe
  - This script does not mutate repository state.
  - Only a heuristic YAML parse is performed (no external module dependency) to keep footprint minimal.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Version,
  [string]$EmitJsonPath = './release-verify-summary.json',
  [switch]$ForceIntegration,
  [switch]$SkipTests,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
  param([string]$Title)
  if (-not $Quiet) { Write-Host "=== $Title ===" -ForegroundColor Cyan }
}

function Get-GitOutput {
  param([string]$ArgLine)
  try {
    if (-not $ArgLine) { return $null }
  $tokens = $ArgLine -split '\s+' | Where-Object { $_ -ne '' }
    git @tokens 2>$null
  } catch { $null }
}

$summary = [ordered]@{
  version                         = $Version
  branchName                      = $null
  branchMatchesReleasePattern     = $false
  workingDirectoryClean           = $false
  changelogVersionFound           = $false
  changelogDateLooksValid         = $false
  actionOutputs                   = @()
  actionOutputsCount              = 0
  actionOutputsDocMissing         = @()
  actionOutputsDocExtra           = @()
  shortCircuitedIdenticalPresent  = $false
  helperFilesPresent              = @()
  helperFilesMissing              = @()
  markdownLintExitCode            = $null
  unitTestExitCode                = $null
  integrationTestAttempted        = $false
  integrationTestExitCode         = $null
  integrationPrereqsDetected      = $false
  errors                          = @()
  overallStatus                   = 'PENDING'
  timestampUtc                    = [DateTime]::UtcNow.ToString('o')
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot
try {
  Write-Section 'Branch'
  $branch = Get-GitOutput 'rev-parse --abbrev-ref HEAD' | Select-Object -First 1
  $summary.branchName = $branch
  if ($branch -match "^release\/v$([regex]::Escape($Version))(?:-|$)") { $summary.branchMatchesReleasePattern = $true }
  $statusOutput = Get-GitOutput 'status --porcelain'
  $summary.workingDirectoryClean = -not ($statusOutput | Where-Object { $_ })

  Write-Section 'CHANGELOG'
  $changelogPath = Join-Path $repoRoot 'CHANGELOG.md'
  if (-not (Test-Path $changelogPath)) { $summary.errors += 'CHANGELOG.md missing' }
  else {
    $clLines = Get-Content $changelogPath -Raw -Encoding UTF8
    $regexVersion = "## \[v?$([regex]::Escape($Version))\]\s*-\s*(\d{4}-\d{2}-\d{2})"
    $match = [regex]::Match($clLines,$regexVersion)
    if ($match.Success) {
      $summary.changelogVersionFound = $true
      $dateStr = $match.Groups[1].Value
  $outDate = [DateTime]::MinValue
  if ([DateTime]::TryParse($dateStr, [ref]$outDate)) { $summary.changelogDateLooksValid = $true }
    }
  }

  Write-Section 'action.yml Outputs'
  $actionPath = Join-Path $repoRoot 'action.yml'
  if (-not (Test-Path $actionPath)) { $summary.errors += 'action.yml missing' }
  else {
    $lines = Get-Content $actionPath -Encoding UTF8
    $outputsSection = $false
    $outputs = @()
    foreach ($line in $lines) {
      if ($line -match '^outputs:\s*$') { $outputsSection = $true; continue }
      if ($outputsSection) {
        if ($line -match '^[^\s]') { break } # left section
        if ($line -match '^\s{2,}([A-Za-z0-9_]+):\s*$') { $outputs += $Matches[1] }
      }
    }
    $summary.actionOutputs = $outputs
    $summary.actionOutputsCount = $outputs.Count
    if ($outputs -contains 'shortCircuitedIdentical') { $summary.shortCircuitedIdenticalPresent = $true }

    # Doc presence validation
    $docPath = Join-Path $repoRoot 'docs' 'action-outputs.md'
    if (Test-Path $docPath) {
      $docText = Get-Content $docPath -Raw -Encoding UTF8
      foreach ($o in $outputs) {
        if ($docText -notmatch "\b$([regex]::Escape($o))\b") { $summary.actionOutputsDocMissing += $o }
      }
      # Heuristic extras: capture fenced code or list markers like `outputName`
      $docWords = [regex]::Matches($docText,'`([A-Za-z0-9_]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
      foreach ($dw in $docWords) {
        if ($dw -notin $outputs -and $dw -match '^[a-z]') { $summary.actionOutputsDocExtra += $dw }
      }
    } else { $summary.errors += 'docs/action-outputs.md missing' }
  }

  Write-Section 'Helper Files'
  $helpers = 'PR_NOTES.md','TAG_PREP_CHECKLIST.md','POST_RELEASE_FOLLOWUPS.md','ROLLBACK_PLAN.md'
  foreach ($h in $helpers) {
    $rootPath = Join-Path $repoRoot $h
    $relocated = Join-Path $repoRoot (Join-Path 'docs/releases' $h)
    if (Test-Path $rootPath) { $summary.helperFilesPresent += $h }
    elseif (Test-Path $relocated) { $summary.helperFilesPresent += (Join-Path 'docs/releases' $h) }
    else { $summary.helperFilesMissing += $h }
  }

  Write-Section 'Markdown Lint'
  $lintExit = $null
  try {
  & npm run lint:md 2>$null | Out-String | Out-Null
  $lintExit = $LASTEXITCODE
  } catch { $lintExit = -1; $summary.errors += 'markdown lint invocation failed' }
  $summary.markdownLintExitCode = $lintExit
  if ($lintExit -ne 0) { $summary.errors += 'markdown lint failed' }

  if (-not $SkipTests) {
    Write-Section 'Unit Tests'
    try {
      & (Join-Path $repoRoot 'Invoke-PesterTests.ps1') | Out-Null
      $summary.unitTestExitCode = $LASTEXITCODE
      if ($LASTEXITCODE -ne 0) { $summary.errors += 'unit tests failed' }
    } catch { $summary.unitTestExitCode = -1; $summary.errors += 'unit test invocation failed' }
  }
  else {
    $summary.unitTestExitCode = $null
  }

  # Integration detection
  $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
  $haveCanonical = Test-Path $canonical -PathType Leaf
  $haveBase = $env:LV_BASE_VI -and (Test-Path $env:LV_BASE_VI -PathType Leaf)
  $haveHead = $env:LV_HEAD_VI -and (Test-Path $env:LV_HEAD_VI -PathType Leaf)
  $summary.integrationPrereqsDetected = ($haveCanonical -and $haveBase -and $haveHead)

  if (-not $SkipTests -and ($ForceIntegration -or $summary.integrationPrereqsDetected)) {
    $summary.integrationTestAttempted = $true
    Write-Section 'Integration Tests'
    try {
      & (Join-Path $repoRoot 'Invoke-PesterTests.ps1') -IncludeIntegration true | Out-Null
      $summary.integrationTestExitCode = $LASTEXITCODE
      if ($LASTEXITCODE -ne 0) { $summary.errors += 'integration tests failed' }
    } catch { $summary.integrationTestExitCode = -1; $summary.errors += 'integration test invocation failed' }
  }

  # Final status
  if ($summary.errors.Count -eq 0) { $summary.overallStatus = 'PASS' } else { $summary.overallStatus = 'FAIL' }

  if (-not $Quiet) {
    Write-Host ''
    Write-Host '=== Summary ===' -ForegroundColor Green
    $summary.GetEnumerator() | ForEach-Object { Write-Host ("{0} = {1}" -f $_.Key, ($(if ($_.Value -is [System.Collections.IEnumerable] -and -not ($_.Value -is [string])) { ($_.Value -join ',') } else { $_.Value })) ) }
  }

  $json = $summary | ConvertTo-Json -Depth 6
  Set-Content -Path $EmitJsonPath -Value $json -Encoding UTF8
  if (-not $Quiet) { Write-Host "JSON summary written: $EmitJsonPath" -ForegroundColor DarkGreen }
}
finally {
  Pop-Location
}

if ($summary.overallStatus -eq 'FAIL') { exit 1 } else { exit 0 }
