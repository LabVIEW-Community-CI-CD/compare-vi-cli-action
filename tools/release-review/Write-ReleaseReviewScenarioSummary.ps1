#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$Os,
  [Parameter(Mandatory)]
  [string]$Tag,
  [string]$ScenarioSet = 'core',
  [string]$ChecksumOutcome = 'none',
  [string]$SmokeOutcome = 'none',
  [Parameter(Mandatory)]
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-OutcomeToStatus {
  param([string]$Outcome)
  $normalized = if ([string]::IsNullOrWhiteSpace($Outcome)) { 'none' } else { $Outcome.Trim().ToLowerInvariant() }
  switch ($normalized) {
    'success' { return 'pass' }
    'failure' { return 'fail' }
    'cancelled' { return 'fail' }
    'skipped' { return 'skipped' }
    default { return 'skipped' }
  }
}

$checksumStatus = Convert-OutcomeToStatus -Outcome $ChecksumOutcome
$smokeStatus = Convert-OutcomeToStatus -Outcome $SmokeOutcome

$scenarioRows = @(
  [ordered]@{
    id = 'checksum'
    status = $checksumStatus
    sourceOutcome = if ([string]::IsNullOrWhiteSpace($ChecksumOutcome)) { 'none' } else { $ChecksumOutcome.Trim().ToLowerInvariant() }
  },
  [ordered]@{
    id = 'smoke-cli'
    status = $smokeStatus
    sourceOutcome = if ([string]::IsNullOrWhiteSpace($SmokeOutcome)) { 'none' } else { $SmokeOutcome.Trim().ToLowerInvariant() }
  }
)

$overall = if (@($scenarioRows | Where-Object { $_.status -eq 'fail' }).Count -gt 0) {
  'fail'
} elseif (@($scenarioRows | Where-Object { $_.status -eq 'pass' }).Count -eq $scenarioRows.Count) {
  'pass'
} elseif (@($scenarioRows | Where-Object { $_.status -eq 'pass' }).Count -gt 0) {
  'mixed'
} else {
  'skipped'
}

$payload = [ordered]@{
  schema = 'release-review-scenario-summary-v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  tag = $Tag
  os = $Os
  scenarioSet = $ScenarioSet
  overall = $overall
  scenarios = $scenarioRows
}

$outDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host ("Release review scenario summary written: {0}" -f $OutputPath)
