[CmdletBinding()]
param(
  [string]$TestsPath = 'tests',
  [string]$ResultsRoot = 'tests/results',
  [string]$OutDir = 'tests/results/_agent/verification',
  [string]$TraceMatrixPath,
  [string]$BaselinePolicyPath = 'tools/policy/requirements-verification-baseline.json',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path '.').Path
if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$resolvedTracePath = $null
if ($TraceMatrixPath) {
  if (-not (Test-Path -LiteralPath $TraceMatrixPath -PathType Leaf)) {
    throw "Trace matrix path does not exist: $TraceMatrixPath"
  }
  $resolvedTracePath = (Resolve-Path -LiteralPath $TraceMatrixPath).Path
} else {
  $traceScript = Join-Path $repoRoot 'tools/Traceability-Matrix.ps1'
  if (-not (Test-Path -LiteralPath $traceScript -PathType Leaf)) {
    throw "Traceability matrix script not found: $traceScript"
  }

  pwsh -NoLogo -NoProfile -File $traceScript -TestsPath $TestsPath -ResultsRoot $ResultsRoot -OutDir $OutDir -RenderHtml | Out-Host

  $generatedTracePath = Join-Path $OutDir 'trace-matrix.json'
  if (-not (Test-Path -LiteralPath $generatedTracePath -PathType Leaf)) {
    throw "Traceability matrix output missing: $generatedTracePath"
  }
  $resolvedTracePath = (Resolve-Path -LiteralPath $generatedTracePath).Path
}

if (-not (Test-Path -LiteralPath $BaselinePolicyPath -PathType Leaf)) {
  throw "Baseline policy path does not exist: $BaselinePolicyPath"
}

$trace = Get-Content -LiteralPath $resolvedTracePath -Raw | ConvertFrom-Json -Depth 20
$baselineResolvedPath = (Resolve-Path -LiteralPath $BaselinePolicyPath).Path
$baseline = Get-Content -LiteralPath $baselineResolvedPath -Raw | ConvertFrom-Json -Depth 10

if (-not $baseline.allowlist) {
  throw "Baseline policy is missing 'allowlist': $BaselinePolicyPath"
}
if (-not ($baseline.allowlist.PSObject.Properties.Name -contains 'unknownRequirementIds')) {
  throw "Baseline policy is missing allowlist.unknownRequirementIds: $BaselinePolicyPath"
}
if (-not ($baseline.allowlist.PSObject.Properties.Name -contains 'uncoveredRequirementIds')) {
  throw "Baseline policy is missing allowlist.uncoveredRequirementIds: $BaselinePolicyPath"
}

$allowedUnknown = @($baseline.allowlist.unknownRequirementIds | ForEach-Object { [string]$_ })
$allowedUncovered = @($baseline.allowlist.uncoveredRequirementIds | ForEach-Object { [string]$_ })
$currentUnknown = @($trace.gaps.unknownRequirementIds | ForEach-Object { [string]$_ } | Sort-Object -Unique)
$currentUncovered = @($trace.gaps.requirementsWithoutTests | ForEach-Object { [string]$_ } | Sort-Object -Unique)

$newUnknown = @($currentUnknown | Where-Object { $_ -notin $allowedUnknown })
$newUncovered = @($currentUncovered | Where-Object { $_ -notin $allowedUncovered })

$gateStatus = if ($newUnknown.Count -eq 0 -and $newUncovered.Count -eq 0) { 'pass' } else { 'fail' }
$gateKind = if ($gateStatus -eq 'pass') { 'requirements_coverage_ok' } else { 'requirements_coverage_regression' }

$summary = [ordered]@{
  schema = 'requirements-verification/v1'
  schemaVersion = '1.0.0'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  traceMatrixPath = [IO.Path]::GetRelativePath($repoRoot, $resolvedTracePath).Replace('\\', '/')
  baselinePolicyPath = [IO.Path]::GetRelativePath($repoRoot, $baselineResolvedPath).Replace('\\', '/')
  traceSource = if ($TraceMatrixPath) { 'provided' } else { 'generated' }
  metrics = [ordered]@{
    requirementTotal = [int]$trace.summary.requirements.total
    requirementCovered = [int]$trace.summary.requirements.covered
    requirementUncovered = [int]$trace.summary.requirements.uncovered
    unknownRequirementIds = @($currentUnknown)
  }
  deltas = [ordered]@{
    newUnknownRequirementIds = @($newUnknown)
    newUncoveredRequirementIds = @($newUncovered)
  }
  outcome = [ordered]@{
    status = $gateStatus
    kind = $gateKind
  }
}

$summaryPath = Join-Path $OutDir 'verification-summary.json'
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8

if ($GitHubOutputPath) {
  "verification-summary-path=$summaryPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  "verification-status=$gateStatus" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}

if ($StepSummaryPath) {
  $lines = @(
    '## Requirements Verification Gate',
    '',
    "- Status: **$gateStatus**",
    "- Kind: $gateKind",
    "- Summary: $([IO.Path]::GetRelativePath($repoRoot, $summaryPath).Replace('\\', '/'))",
    "- Trace Matrix: $($summary.traceMatrixPath)",
    "- Requirements covered: $($summary.metrics.requirementCovered)/$($summary.metrics.requirementTotal)",
    "- Unknown requirement IDs: $($currentUnknown.Count)",
    "- New unknown requirement IDs: $($newUnknown.Count)",
    "- New uncovered requirement IDs: $($newUncovered.Count)"
  )

  if ($newUnknown.Count -gt 0) {
    $lines += ''
    $lines += '### New Unknown Requirement IDs'
    foreach ($id in $newUnknown) { $lines += "- $id" }
  }

  if ($newUncovered.Count -gt 0) {
    $lines += ''
    $lines += '### New Uncovered Requirement IDs'
    foreach ($id in $newUncovered) { $lines += "- $id" }
  }

  ($lines -join "`n") | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

Write-Host "[verification] status=$gateStatus summary=$summaryPath" -ForegroundColor Cyan
if ($gateStatus -ne 'pass') {
  Write-Error '[verification] requirements verification gate failed due to regression.'
  exit 1
}
