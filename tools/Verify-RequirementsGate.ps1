[CmdletBinding()]
param(
  [string]$TestsPath = 'tests',
  [string]$ResultsRoot = 'tests/results',
  [string]$OutDir = 'tests/results/_agent/verification',
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

$traceScript = Join-Path $repoRoot 'tools/Traceability-Matrix.ps1'
if (-not (Test-Path -LiteralPath $traceScript -PathType Leaf)) {
  throw "Traceability matrix script not found: $traceScript"
}

pwsh -NoLogo -NoProfile -File $traceScript -TestsPath $TestsPath -ResultsRoot $ResultsRoot -OutDir $OutDir -RenderHtml | Out-Host

$tracePath = Join-Path $OutDir 'trace-matrix.json'
if (-not (Test-Path -LiteralPath $tracePath -PathType Leaf)) {
  throw "Traceability matrix output missing: $tracePath"
}

$trace = Get-Content -LiteralPath $tracePath -Raw | ConvertFrom-Json -Depth 20
$baseline = Get-Content -LiteralPath $BaselinePolicyPath -Raw | ConvertFrom-Json -Depth 10

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
  traceMatrixPath = [IO.Path]::GetRelativePath($repoRoot, (Resolve-Path -LiteralPath $tracePath).Path).Replace('\\', '/')
  baselinePolicyPath = [IO.Path]::GetRelativePath($repoRoot, (Resolve-Path -LiteralPath $BaselinePolicyPath).Path).Replace('\\', '/')
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
