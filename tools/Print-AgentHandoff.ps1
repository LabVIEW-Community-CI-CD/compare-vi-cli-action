[CmdletBinding()]
param(
  [switch]$ApplyToggles,
  [switch]$OpenDashboard,
  [string]$Group = 'pester-selfhosted',
  [string]$ResultsRoot = (Join-Path (Resolve-Path '.').Path 'tests/results')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$handoff = Join-Path (Resolve-Path '.').Path 'AGENT_HANDOFF.txt'
if (-not (Test-Path -LiteralPath $handoff)) { throw "Handoff file not found: $handoff" }

if ($ApplyToggles) {
  $env:LV_SUPPRESS_UI = '1'
  $env:LV_NO_ACTIVATE = '1'
  $env:LV_CURSOR_RESTORE = '1'
  $env:LV_IDLE_WAIT_SECONDS = '2'
  $env:LV_IDLE_MAX_WAIT_SECONDS = '5'
  if (-not $env:WATCH_RESULTS_DIR) {
    $env:WATCH_RESULTS_DIR = Join-Path (Resolve-Path '.').Path 'tests/results/_watch'
  }
}

Get-Content -LiteralPath $handoff

if ($OpenDashboard) {
  $cli = Join-Path (Resolve-Path '.').Path 'tools/Dev-Dashboard.ps1'
  if (Test-Path -LiteralPath $cli) {
    & $cli -Group $Group -ResultsRoot $ResultsRoot -Html -Json | Out-Null
    Write-Host "Dashboard generated under: $ResultsRoot" -ForegroundColor Cyan
  } else {
    Write-Warning "Dev-Dashboard.ps1 not found at: $cli"
  }
}
