<#
.SYNOPSIS
  Canonical headless entry point for VI compares (CLI-first, timeout-aware).

.DESCRIPTION
  Sets the safe LabVIEW environment toggles, defaults compare policy to cli-only,
  and then invokes TestStand-CompareHarness.ps1 with the requested parameters.
  Warmup is skipped by default (recommended for headless runs) but can be enabled.
  A timeout guard cancels hung compares and allows the harness cleanup to run.

.PARAMETER BaseVi
  Base VI path (resolved to an absolute path).

.PARAMETER HeadVi
  Head VI path (resolved to an absolute path).

.PARAMETER OutputRoot
  Root directory for harness outputs (defaults to tests/results/headless-compare).

.PARAMETER WarmupMode
  Warmup mode forwarded to the harness (`detect`, `spawn`, or `skip`). Default `skip`.

.PARAMETER RenderReport
  Request compare-report.html generation.

.PARAMETER TimeoutSeconds
  Timeout applied to warmup and compare stages (defaults to 600 seconds).

.PARAMETER DisableTimeout
  Disable timeout enforcement (use with caution).

.PARAMETER DisableCleanup
  Skip the harness close helpers (LabVIEW/LVCompare). Enabled by default.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BaseVi,
  [Parameter(Mandatory)][string]$HeadVi,
  [string]$OutputRoot = 'tests/results/headless-compare',
  [ValidateSet('detect','spawn','skip')]
  [string]$WarmupMode = 'skip',
  [switch]$RenderReport,
  [int]$TimeoutSeconds = 600,
  [switch]$DisableTimeout,
  [switch]$DisableCleanup,
  [switch]$UseRawPaths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
if (-not $scriptRoot) {
  $scriptRoot = (Resolve-Path '.').Path
}
$repoRoot = Split-Path -Parent $scriptRoot
if (-not $repoRoot) {
  $repoRoot = $scriptRoot
}
$harness = Join-Path $scriptRoot 'TestStand-CompareHarness.ps1'
$stageScript = Join-Path $scriptRoot 'Stage-CompareInputs.ps1'
if (-not (Test-Path -LiteralPath $harness -PathType Leaf)) {
  throw "TestStand-CompareHarness.ps1 not found at $harness"
}
if (-not $UseRawPaths.IsPresent -and -not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
  throw "Stage-CompareInputs.ps1 not found at $stageScript"
}

function Resolve-AbsolutePath {
  param([string]$InputPath, [string]$ParameterName)
  try {
    $resolved = Resolve-Path -LiteralPath $InputPath -ErrorAction Stop
    return $resolved.Path
  } catch {
    throw "Unable to resolve $ParameterName path: $InputPath"
  }
}

$basePath = Resolve-AbsolutePath -InputPath $BaseVi -ParameterName 'BaseVi'
$headPath = Resolve-AbsolutePath -InputPath $HeadVi -ParameterName 'HeadVi'
if (-not ([System.IO.Path]::IsPathRooted($OutputRoot))) {
  $OutputRoot = Join-Path $repoRoot $OutputRoot
}

$sameNameHint = [string]::Equals(
  (Split-Path -Path $basePath -Leaf),
  (Split-Path -Path $headPath -Leaf),
  [System.StringComparison]::OrdinalIgnoreCase
)

$stagingInfo = $null
$baseEffective = $basePath
$headEffective = $headPath
if (-not $UseRawPaths) {
  $stageParams = @{
    BaseVi = $basePath
    HeadVi = $headPath
  }
  $stagingInfo = & $stageScript @stageParams
  if (-not $stagingInfo) { throw 'Stage-CompareInputs.ps1 returned no staging information.' }
  $baseEffective = $stagingInfo.Base
  $headEffective = $stagingInfo.Head
  Write-Host "[headless-compare] Staging inputs under $($stagingInfo.Root)" -ForegroundColor DarkGray
}

$comparePolicy = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_POLICY')
if ([string]::IsNullOrWhiteSpace($comparePolicy)) {
  [System.Environment]::SetEnvironmentVariable('LVCI_COMPARE_POLICY', 'cli-only')
}
$compareMode = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_MODE')
if ([string]::IsNullOrWhiteSpace($compareMode)) {
  [System.Environment]::SetEnvironmentVariable('LVCI_COMPARE_MODE', 'labview-cli')
}

$envSettings = @{
  'LV_SUPPRESS_UI'           = '1';
  'LV_NO_ACTIVATE'           = '1';
  'LV_CURSOR_RESTORE'        = '1';
  'LV_IDLE_WAIT_SECONDS'     = '2';
  'LV_IDLE_MAX_WAIT_SECONDS' = '5'
}
foreach ($key in $envSettings.Keys) {
  [System.Environment]::SetEnvironmentVariable($key, $envSettings[$key])
}

$params = @{
  BaseVi        = $baseEffective
  HeadVi        = $headEffective
  OutputRoot    = $OutputRoot
  Warmup        = $WarmupMode
  TimeoutSeconds = $TimeoutSeconds
}
if (-not $DisableTimeout) { } else { $params.DisableTimeout = $true }
if ($RenderReport) { $params.RenderReport = $true }
if (-not $DisableCleanup) {
  $params.CloseLabVIEW = $true
  $params.CloseLVCompare = $true
}
if ($stagingInfo) {
  $params.StagingRoot = $stagingInfo.Root
}
if ($stagingInfo -and $stagingInfo.PSObject.Properties['AllowSameLeaf']) {
  try {
    if ([bool]$stagingInfo.AllowSameLeaf) { $params.AllowSameLeaf = $true }
  } catch {}
}
if ($sameNameHint) {
  $params.SameNameHint = $true
}

Write-Host "[headless-compare] Base: $basePath"
Write-Host "[headless-compare] Head: $headPath"
Write-Host "[headless-compare] Output: $OutputRoot"
Write-Host "[headless-compare] Warmup: $WarmupMode"
Write-Host "[headless-compare] Timeout: $TimeoutSeconds s (disable=$($DisableTimeout.IsPresent))"
Write-Host "[headless-compare] Harness: $harness"

try {
  & $harness @params
  $exit = $LASTEXITCODE
} finally {
  if ($stagingInfo -and $stagingInfo.Root) {
    try {
      if (Test-Path -LiteralPath $stagingInfo.Root -PathType Container) {
        Remove-Item -LiteralPath $stagingInfo.Root -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
}
exit $exit
