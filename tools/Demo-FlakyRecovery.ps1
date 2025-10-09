[CmdletBinding()]
param(
  [string]$DeltaJsonPath = 'tests/results/flaky-demo-delta.json',
  [int]$RerunFailedAttempts = 2,
  [switch]$Quiet
)

<#!
.SYNOPSIS
  Demonstrate Watch-Pester flaky retry recovery using the Flaky Demo test.
.DESCRIPTION
  Ensures the flaky demo state file is reset, enables the demo via environment
  variable, then invokes Watch-Pester in single-run mode with retries.
  Prints a concise summary of recovery classification and flaky metadata.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$watch = Join-Path (Resolve-Path .) 'tools/Watch-Pester.ps1'
if (-not (Test-Path $watch)) { throw "Watch script not found at $watch" }

# Reset demo state so first attempt purposely fails.
$state = Join-Path (Resolve-Path .) 'tests/results/flaky-demo-state.txt'
if (Test-Path $state) { Remove-Item -LiteralPath $state -Force }

$env:ENABLE_FLAKY_DEMO = '1'

$watchDir = Split-Path -Parent $DeltaJsonPath
if (-not $watchDir -or $watchDir -eq '') { $watchDir = Join-Path (Resolve-Path '.').Path 'tests/results/_watch' }
if (-not (Test-Path -LiteralPath $watchDir)) { New-Item -ItemType Directory -Force -Path $watchDir | Out-Null }
$env:WATCH_RESULTS_DIR = $watchDir
$historyPath = Join-Path $watchDir 'watch-log.ndjson'
$cmd = "& '$watch' -SingleRun -RerunFailedAttempts $RerunFailedAttempts -DeltaJsonPath '$DeltaJsonPath' -DeltaHistoryPath '$historyPath' -Tag FlakyDemo"
if ($Quiet) { $cmd += ' -Quiet' }
Write-Host "Invoking: $cmd" -ForegroundColor Cyan
Invoke-Expression $cmd

if (-not (Test-Path $DeltaJsonPath)) { throw "Delta JSON not produced: $DeltaJsonPath" }
$json = Get-Content -LiteralPath $DeltaJsonPath -Raw | ConvertFrom-Json

$flaky = $json.flaky
if (-not $Quiet) {
  Write-Host "Status: $($json.status)  Classification: $($json.classification)" -ForegroundColor Green
  if ($flaky) {
    Write-Host ("Flaky: enabled attempts={0} recoveredAfter={1} initialFailedFiles={2}" -f $flaky.attempts,$flaky.recoveredAfter,$flaky.initialFailedFiles)
    if ($flaky.initialFailedFileNames) { Write-Host "Initial failing files: $($flaky.initialFailedFileNames -join ', ')" }
  }
}

if ($json.classification -ne 'improved' -or -not $flaky -or -not $flaky.recoveredAfter) {
  Write-Warning 'Expected improved classification with recovery; verify no unrelated failing tests are tagged FlakyDemo.'
}
