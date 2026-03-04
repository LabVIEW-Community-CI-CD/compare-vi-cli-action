[CmdletBinding()]
param(
  [string]$PolicySummaryPath,
  [string]$SearchRoot = 'tests/results/_agent/release-proof',
  [switch]$AsJson,
  [switch]$AppendStepSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PolicyPath {
  param(
    [string]$ExplicitPath,
    [string]$Root
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
    if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
      throw "Policy summary file not found: $ExplicitPath"
    }
    return (Resolve-Path -LiteralPath $ExplicitPath).Path
  }

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Search root not found: $Root"
  }

  $candidate = Get-ChildItem -Path $Root -Filter 'release-vi-history-policy.json' -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

  if (-not $candidate) {
    throw "No release-vi-history-policy.json found under $Root"
  }

  return $candidate.FullName
}

$resolvedPath = Resolve-PolicyPath -ExplicitPath $PolicySummaryPath -Root $SearchRoot
$policy = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json -Depth 20

$result = [pscustomobject]@{
  tagClass = [string]$policy.tagClass
  enforcementSource = [string]$policy.enforcementSource
  enforcementMode = [string]$policy.enforcementMode
  rawOutcome = [string]$policy.rawOutcome
  outcome = [string]$policy.outcome
  policyPath = $resolvedPath
}

if ($AppendStepSummary -and $env:GITHUB_STEP_SUMMARY) {
  @(
    '### Release VI History Policy Fields',
    '',
    "- tagClass: $($result.tagClass)",
    "- enforcementSource: $($result.enforcementSource)",
    "- enforcementMode: $($result.enforcementMode)",
    "- rawOutcome: $($result.rawOutcome)",
    "- outcome: $($result.outcome)",
    "- policyPath: $($result.policyPath)"
  ) -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($AsJson) {
  $result | ConvertTo-Json -Depth 8 | Write-Output
} else {
  $result
}