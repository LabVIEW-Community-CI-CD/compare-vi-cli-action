[CmdletBinding()]
param(
  [switch]$Apply,
  [string]$ResultsDir = 'tests/results/_agent/policy',
  [string]$ReportFile = 'policy-drift-report.json',
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-OutputPath {
  param(
    [Parameter(Mandatory)][string]$BaseDir,
    [Parameter(Mandatory)][string]$ChildPath
  )

  if ([System.IO.Path]::IsPathRooted($ChildPath)) {
    return $ChildPath
  }
  return Join-Path $BaseDir $ChildPath
}

$workspaceRoot = (Get-Location).Path
$resolvedResultsDir = Resolve-OutputPath -BaseDir $workspaceRoot -ChildPath $ResultsDir
New-Item -ItemType Directory -Path $resolvedResultsDir -Force | Out-Null

$reportPath = Resolve-OutputPath -BaseDir $resolvedResultsDir -ChildPath $ReportFile

$args = @(
  'tools/priority/check-policy.mjs',
  '--report',
  $reportPath
)
if ($Apply) {
  $args += '--apply'
}

Write-Host "[policy-sync] Running: node $($args -join ' ')"
& node @args
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
  throw "Policy sync/check failed (exit=$exitCode)."
}

if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
  throw "Policy report not found: $reportPath"
}

$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$branchUpdates = @($report.applied.branches)
$rulesetUpdates = @($report.applied.rulesets)
$branchSummary = if ($branchUpdates.Count -gt 0) { $branchUpdates -join ', ' } else { '(none)' }
$rulesetSummary = if ($rulesetUpdates.Count -gt 0) { $rulesetUpdates -join ', ' } else { '(none)' }

Write-Host "[policy-sync] Result: $($report.result)"
Write-Host "[policy-sync] Total diffs: $($report.summary.totalDiffCount)"
Write-Host "[policy-sync] Branch updates: $branchSummary"
Write-Host "[policy-sync] Ruleset updates: $rulesetSummary"
Write-Host "[policy-sync] Report: $reportPath"

if ($StepSummaryPath) {
  $summary = @(
    '### Branch Protection Policy Sync',
    '',
    "- Result: $($report.result)",
    "- Apply mode: $($report.apply)",
    "- Repository: $($report.repository)",
    "- Total diffs: $($report.summary.totalDiffCount)",
    "- Branch updates: $branchSummary",
    "- Ruleset updates: $rulesetSummary",
    "- Report path: $reportPath"
  ) -join "`n"
  $summary | Out-File -FilePath $StepSummaryPath -Append -Encoding utf8
}
