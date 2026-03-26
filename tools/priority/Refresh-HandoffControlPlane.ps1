[CmdletBinding()]
param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path,
  [string]$ResultsRoot = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path 'tests/results'),
  [string]$HelperRepoRoot,
  [string]$WorkingDirectory,
  [string]$ContinuitySummaryPath,
  [string]$OperatorSteeringEventPath,
  [string]$QueueEmptyReportPath,
  [string]$CostRollupPath,
  [string]$EpisodeDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-HandoffControlPlaneNodeScript {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptRelativePath,
    [string[]]$Arguments = @(),
    [string]$RepoRootPath,
    [string]$HelperRootPath,
    [string]$WorkingDirectoryPath
  )

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    throw 'node not found; cannot refresh handoff control-plane surfaces.'
  }

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($HelperRootPath)) {
    $candidates += (Join-Path $HelperRootPath $ScriptRelativePath)
  }
  if (-not [string]::IsNullOrWhiteSpace($RepoRootPath) -and $RepoRootPath -ne $HelperRootPath) {
    $candidates += (Join-Path $RepoRootPath $ScriptRelativePath)
  }

  $scriptPath = $null
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $scriptPath = (Resolve-Path -LiteralPath $candidate).Path
      break
    }
  }

  if (-not $scriptPath) {
    throw "Unable to locate $ScriptRelativePath in helper root or repo root."
  }

  Push-Location $WorkingDirectoryPath
  try {
    & $nodeCmd.Source $scriptPath @Arguments | Out-Host
  } finally {
    Pop-Location
  }
}

$resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$resolvedResultsRoot = $ResultsRoot
if (-not [System.IO.Path]::IsPathRooted($resolvedResultsRoot)) {
  $resolvedResultsRoot = Join-Path $resolvedRepoRoot $resolvedResultsRoot
}
$resolvedResultsRoot = [System.IO.Path]::GetFullPath($resolvedResultsRoot)
$resolvedHelperRepoRoot = if ([string]::IsNullOrWhiteSpace($HelperRepoRoot)) {
  $resolvedRepoRoot
} else {
  (Resolve-Path -LiteralPath $HelperRepoRoot).Path
}
$resolvedWorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
  $resolvedRepoRoot
} else {
  (Resolve-Path -LiteralPath $WorkingDirectory).Path
}

$promotionDir = Join-Path $resolvedResultsRoot '_agent/promotion'
$releaseDir = Join-Path $resolvedResultsRoot '_agent/release'
$handoffDir = Join-Path $resolvedResultsRoot '_agent/handoff'
New-Item -ItemType Directory -Force -Path $promotionDir | Out-Null
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

$resolvedQueueEmptyReportPath = if ([string]::IsNullOrWhiteSpace($QueueEmptyReportPath)) {
  Join-Path $resolvedRepoRoot 'tests/results/_agent/issue/no-standing-priority.json'
} else {
  $QueueEmptyReportPath
}
$resolvedContinuitySummaryPath = if ([string]::IsNullOrWhiteSpace($ContinuitySummaryPath)) {
  Join-Path $handoffDir 'continuity-summary.json'
} else {
  $ContinuitySummaryPath
}
$resolvedOperatorSteeringEventPath = if ([string]::IsNullOrWhiteSpace($OperatorSteeringEventPath)) {
  Join-Path $handoffDir 'operator-steering-event.json'
} else {
  $OperatorSteeringEventPath
}
$resolvedCostRollupPath = if ([string]::IsNullOrWhiteSpace($CostRollupPath)) {
  Join-Path $resolvedResultsRoot '_agent/cost/agent-cost-rollup.json'
} else {
  $CostRollupPath
}
$resolvedEpisodeDirectory = if ([string]::IsNullOrWhiteSpace($EpisodeDirectory)) {
  Join-Path $resolvedResultsRoot '_agent/memory/subagent-episodes'
} else {
  $EpisodeDirectory
}

$templateVerificationSeedPath = Join-Path $promotionDir 'template-agent-verification-report.json'
$templateVerificationOverlayPath = Join-Path $promotionDir 'template-agent-verification-report.local.json'
$templateVerificationSyncPath = Join-Path $promotionDir 'template-agent-verification-sync.json'
$templatePivotGatePath = Join-Path $promotionDir 'template-pivot-gate-report.json'
$releaseConductorReportPath = Join-Path $releaseDir 'release-conductor-report.json'
$releasePublishedBundleObserverPath = Join-Path $releaseDir 'release-published-bundle-observer.json'
$releaseSigningReadinessPath = Join-Path $releaseDir 'release-signing-readiness.json'
$entrypointStatusPath = Join-Path $handoffDir 'entrypoint-status.json'
$repoGraphTruthPath = Join-Path $handoffDir 'downstream-repo-graph-truth.json'
$monitoringModePath = Join-Path $handoffDir 'monitoring-mode.json'
$treasuryLedgerPath = Join-Path $handoffDir 'treasury-ledger.json'
$treasuryRuntimePath = Join-Path $resolvedResultsRoot '_agent/capital/treasury-ledger.json'
$governorSummaryPath = Join-Path $handoffDir 'autonomous-governor-summary.json'
$governorPortfolioSummaryPath = Join-Path $handoffDir 'autonomous-governor-portfolio-summary.json'
$contextConcentratorPath = Join-Path $handoffDir 'sagan-context-concentrator.json'

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/downstream-repo-graph-truth.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--output', $repoGraphTruthPath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/sync-template-agent-verification-report.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--local-report', $templateVerificationSeedPath, '--local-overlay-report', $templateVerificationOverlayPath, '--output', $templateVerificationSyncPath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/template-pivot-gate.mjs' `
  -Arguments @('--queue-empty-report', $resolvedQueueEmptyReportPath, '--handoff-entrypoint', $entrypointStatusPath, '--template-agent-verification-report', $templateVerificationSeedPath, '--output', $templatePivotGatePath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/handoff-monitoring-mode.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--repo-graph-truth', $repoGraphTruthPath, '--queue-empty-report', $resolvedQueueEmptyReportPath, '--continuity-summary', $resolvedContinuitySummaryPath, '--template-pivot-gate', $templatePivotGatePath, '--output', $monitoringModePath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/release-published-bundle-observer.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--output', $releasePublishedBundleObserverPath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/release-signing-readiness.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--release-conductor-report', $releaseConductorReportPath, '--release-published-bundle-observer', $releasePublishedBundleObserverPath, '--output', $releaseSigningReadinessPath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/treasury-ledger.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--cost-rollup', $resolvedCostRollupPath, '--operator-steering-event', $resolvedOperatorSteeringEventPath, '--output', $treasuryRuntimePath, '--handoff-output', $treasuryLedgerPath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/autonomous-governor-summary.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--queue-empty-report', $resolvedQueueEmptyReportPath, '--continuity-summary', $resolvedContinuitySummaryPath, '--monitoring-mode', $monitoringModePath, '--release-signing-readiness', $releaseSigningReadinessPath, '--output', $governorSummaryPath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/autonomous-governor-portfolio-summary.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--compare-governor-summary', $governorSummaryPath, '--monitoring-mode', $monitoringModePath, '--repo-graph-truth', $repoGraphTruthPath, '--output', $governorPortfolioSummaryPath)

Invoke-HandoffControlPlaneNodeScript `
  -RepoRootPath $resolvedRepoRoot `
  -HelperRootPath $resolvedHelperRepoRoot `
  -WorkingDirectoryPath $resolvedWorkingDirectory `
  -ScriptRelativePath 'tools/priority/sagan-context-concentrator.mjs' `
  -Arguments @('--repo-root', $resolvedRepoRoot, '--priority-cache', (Join-Path $resolvedRepoRoot '.agent_priority_cache.json'), '--governor-summary', $governorSummaryPath, '--governor-portfolio-summary', $governorPortfolioSummaryPath, '--monitoring-mode', $monitoringModePath, '--operator-steering-event', $resolvedOperatorSteeringEventPath, '--episode-directory', $resolvedEpisodeDirectory, '--output', $contextConcentratorPath)
