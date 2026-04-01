[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$ResultsDir = 'tests/results',

  [Parameter(Mandatory = $false)]
  [string]$SummaryPath = 'pester-summary.json',

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = 'pester-totals.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedResultsDir = [System.IO.Path]::GetFullPath($ResultsDir)
if (-not (Test-Path -LiteralPath $resolvedResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resolvedResultsDir -Force | Out-Null
}

$summaryJsonPath = if ([System.IO.Path]::IsPathRooted($SummaryPath)) {
  [System.IO.Path]::GetFullPath($SummaryPath)
} else {
  Join-Path $resolvedResultsDir $SummaryPath
}
$totalsPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
  [System.IO.Path]::GetFullPath($OutputPath)
} else {
  Join-Path $resolvedResultsDir $OutputPath
}

$payload = [ordered]@{
  schema = 'pester-totals/v1'
  includeIntegration = $null
  status = 'missing-summary'
}

if (Test-Path -LiteralPath $summaryJsonPath -PathType Leaf) {
  try {
    $summary = Get-Content -LiteralPath $summaryJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $payload.total = $summary.total
    $payload.passed = $summary.passed
    $payload.failed = $summary.failed
    $payload.errors = $summary.errors
    $payload.duration_s = $summary.duration_s
    $payload.status = if (([int]$summary.failed + [int]$summary.errors) -gt 0) { 'fail' } else { 'ok' }
  } catch {
    $payload.status = 'unknown'
  }
}

$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $totalsPath -Encoding UTF8

if ($env:GITHUB_OUTPUT) {
  "path=$totalsPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "status=$($payload.status)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester totals' -ForegroundColor Cyan
Write-Host ("status : {0}" -f $payload.status)
Write-Host ("path   : {0}" -f $totalsPath)

exit 0
