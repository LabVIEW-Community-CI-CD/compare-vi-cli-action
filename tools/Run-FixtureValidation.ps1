[CmdletBinding()]
param(
  [switch]$NoticeOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validationPath = 'fixture-validation.json'
$deltaPath = 'fixture-validation-delta.json'
$summaryPath = 'fixture-summary.md'
$prevPath = 'fixture-validation-prev.json'

if (Test-Path -LiteralPath $prevPath) {
  Write-Host ("Using baseline: {0}" -f (Resolve-Path $prevPath))
} else {
  Write-Host 'No baseline found; will compute snapshot only.'
}

$validationPath = Join-Path (Get-Location) 'fixture-validation.json'
$deltaPath = Join-Path (Get-Location) 'fixture-validation-delta.json'
$summaryPath = Join-Path (Get-Location) 'fixture-summary.md'

$validateOutput = & pwsh -NoLogo -NoProfile -File ./tools/Validate-Fixtures.ps1 -Json -MinBytes 32
$validateExit = $LASTEXITCODE
if ($validateOutput) {
  $text = $null
  if ($validateOutput -is [string]) {
    $text = $validateOutput
  } elseif ($validateOutput -is [System.Collections.IEnumerable]) {
    $text = ($validateOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  }
  Set-Content -LiteralPath $validationPath -Encoding utf8 -Value $text
}

if ($validateExit -ne 0) {
  if ($NoticeOnly) {
    Write-Warning "Validate-Fixtures.ps1 returned exit code $validateExit (continuing in notice-only mode)."
  } else {
    Write-Error "Validate-Fixtures.ps1 failed with exit code $validateExit"
    exit $validateExit
  }
}

if (-not (Test-Path -LiteralPath $validationPath)) {
  Write-Error "Failed to produce $validationPath"
  exit 2
}

try {
  & pwsh -NoLogo -NoProfile -File ./tools/Invoke-JsonSchemaLite.ps1 -JsonPath $validationPath -SchemaPath 'docs/schemas/fixture-validation-v1.schema.json'
} catch {
  Write-Host '::notice::Snapshot schema-lite failed (non-blocking).'
}

$deltaWritten = $false
if (Test-Path -LiteralPath $prevPath) {
  $deltaOutput = & pwsh -NoLogo -NoProfile -File ./tools/Diff-FixtureValidationJson.ps1 -Baseline $prevPath -Current $validationPath -FailOnNewStructuralIssue
  $deltaExit = $LASTEXITCODE
  if ($deltaExit -eq 3 -and $NoticeOnly) {
    Write-Host 'New structural fixture issues detected (local notice-only). Continuing.'
    $deltaExit = 0
  }
  if ($deltaExit -ne 0) {
    exit $deltaExit
  }
  if ($deltaOutput) {
    ($deltaOutput -join "`n") | Set-Content -LiteralPath $deltaPath -Encoding utf8
    $deltaWritten = $true
  }
  if (Test-Path -LiteralPath $deltaPath) {
    & pwsh -NoLogo -NoProfile -File ./tools/Test-FixtureValidationDeltaSchema.ps1 -DeltaJsonPath $deltaPath | Out-Host
    & pwsh -NoLogo -NoProfile -File ./tools/Invoke-JsonSchemaLite.ps1 -JsonPath $deltaPath -SchemaPath 'docs/schemas/fixture-validation-delta-v1.schema.json' | Out-Host
  }
}

& pwsh -NoLogo -NoProfile -File ./tools/Write-FixtureValidationSummary.ps1 -ValidationJson $validationPath -DeltaJson $deltaPath -SummaryPath $summaryPath | Out-Host

Copy-Item -LiteralPath $validationPath -Destination $prevPath -Force
