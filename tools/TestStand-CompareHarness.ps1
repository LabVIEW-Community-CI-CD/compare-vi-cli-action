<#
.SYNOPSIS
  Thin wrapper for TestStand: warmup LabVIEW runtime, run LVCompare, and optionally close.

.DESCRIPTION
  Sequentially invokes Warmup-LabVIEWRuntime.ps1 (to ensure LabVIEW readiness), then
  Invoke-LVCompare.ps1 to perform a deterministic compare, and finally optional close helpers.
  Writes a session-index.json with pointers to emitted crumbs and artifacts.

.PARAMETER BaseVi
  Base VI path.

.PARAMETER HeadVi
  Head VI path.

.PARAMETER LabVIEWExePath
  Path to LabVIEW.exe (pinned version/bitness recommended).

.PARAMETER LVCompareExePath
  Path to LVCompare.exe (defaults to canonical install when omitted).

.PARAMETER OutputRoot
  Root folder for all outputs (default tests/results/teststand-session).

.PARAMETER RenderReport
  Generate compare-report.html during compare.

.PARAMETER CloseLabVIEW
  Attempt graceful LabVIEW close via tools/Close-LabVIEW.ps1 at the end.

.PARAMETER CloseLVCompare
  Attempt LVCompare cleanup via tools/Close-LVCompare.ps1 at the end.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BaseVi,
  [Parameter(Mandatory)][string]$HeadVi,
  [Alias('LabVIEWPath')]
  [string]$LabVIEWExePath,
  [Alias('LVCompareExePath')]
  [string]$LVComparePath,
  [string]$OutputRoot = 'tests/results/teststand-session',
  [switch]$RenderReport,
  [switch]$CloseLabVIEW,
  [switch]$CloseLVCompare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Dir([string]$p){ if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

$repo = (Resolve-Path '.').Path

# Resolve OutputRoot to absolute path for deterministic writes
if (-not ([System.IO.Path]::IsPathRooted($OutputRoot))) {
  $OutputRoot = Join-Path $repo $OutputRoot
}

$paths = [ordered]@{
  warmupDir = Join-Path $OutputRoot '_warmup'
  compareDir = Join-Path $OutputRoot 'compare'
}
New-Dir $paths.warmupDir
New-Dir $paths.compareDir

$warmupLog = Join-Path $paths.warmupDir 'labview-runtime.ndjson'
$compareLog = Join-Path $paths.compareDir 'compare-events.ndjson'
$capPath = Join-Path $paths.compareDir 'lvcompare-capture.json'
$reportStagingDir = Join-Path $paths.compareDir (Join-Path '_staging' 'compare')
$reportStagingPath = Join-Path $reportStagingDir 'compare-report.html'
$cap = $null
$err = $null

try {
  # 1) Warmup LabVIEW runtime
  $warmup = Join-Path $repo 'tools' 'Warmup-LabVIEWRuntime.ps1'
  if (-not (Test-Path -LiteralPath $warmup)) { throw "Warmup-LabVIEWRuntime.ps1 not found at $warmup" }
  if ($LabVIEWExePath) {
    & $warmup -LabVIEWPath $LabVIEWExePath -JsonLogPath $warmupLog | Out-Null
  } else {
    & $warmup -JsonLogPath $warmupLog | Out-Null
  }

  # 2) Invoke LVCompare (deterministic)
  $invoke = Join-Path $repo 'tools' 'Invoke-LVCompare.ps1'
  if (-not (Test-Path -LiteralPath $invoke)) { throw "Invoke-LVCompare.ps1 not found at $invoke" }
  $invokeParams = @{
    BaseVi      = $BaseVi
    HeadVi      = $HeadVi
    OutputDir   = $paths.compareDir
    JsonLogPath = $compareLog
    RenderReport= $RenderReport.IsPresent
    ReportStagingDir = $reportStagingDir
  }
  if ($LabVIEWExePath) { $invokeParams.LabVIEWExePath = $LabVIEWExePath }
  if ($LVComparePath) { $invokeParams.LVComparePath = $LVComparePath }
  & $invoke @invokeParams | Out-Null
  if (Test-Path -LiteralPath $capPath) { $cap = Get-Content -LiteralPath $capPath -Raw | ConvertFrom-Json }

  # 3) Optional closes
  if ($CloseLVCompare) {
    $closeLVCompare = Join-Path $repo 'tools' 'Close-LVCompare.ps1'
    if (Test-Path -LiteralPath $closeLVCompare) { try { & $closeLVCompare | Out-Null } catch {} }
  }
  if ($CloseLabVIEW) {
    $closeLabVIEW = Join-Path $repo 'tools' 'Close-LabVIEW.ps1'
    if (Test-Path -LiteralPath $closeLabVIEW) { try { & $closeLabVIEW -MinimumSupportedLVVersion '2025' -SupportedBitness '64' | Out-Null } catch {} }
  }
} catch { $err = $_.Exception.Message }

# 4) Session index (always write)
$index = [ordered]@{
  schema = 'teststand-compare-session/v1'
  at     = (Get-Date).ToString('o')
  warmup = @{ events = $warmupLog }
  compare= @{
    events        = $compareLog
    capture       = $capPath
    report        = $reportStagingPath
    reportExists  = (Test-Path -LiteralPath $reportStagingPath)
  }
  outcome= if ($cap) {
    @{ exitCode=[int]$cap.exitCode; seconds=[double]$cap.seconds; command=$cap.command; diff=([bool]($cap.exitCode -eq 1)) }
  } else { $null }
  error  = $err
}
$indexPath = Join-Path $OutputRoot 'session-index.json'
New-Dir $OutputRoot
$index | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $indexPath -Encoding utf8

$exitCode = if ($cap) { [int]$cap.exitCode } else { 1 }
Write-Host ("TestStand Compare Harness result: exit={0} diff={1} capture={2}" -f ($index.outcome.exitCode), ($index.outcome.diff), $capPath) -ForegroundColor Yellow

exit $exitCode
