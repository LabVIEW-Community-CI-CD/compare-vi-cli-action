#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  Manual helper to run fixture drift orchestration end-to-end safely.

.DESCRIPTION
  Generates strict/override validator JSON (unless provided), invokes the orchestrator
  to produce drift artifacts, optionally simulates LVCompare, and validates the
  drift-summary.json against the schema. Designed to avoid quoting pitfalls of one-liners.

.PARAMETER OutputDir
  Target directory for artifacts. Defaults to results/fixture-drift/manual/<utc>.
.PARAMETER StrictJson
  Optional path to an existing strict validator JSON. If not specified, one is generated.
.PARAMETER OverrideJson
  Optional path to an existing override validator JSON. If not specified, one is generated.
.PARAMETER BasePath
  Base VI path. Defaults to ./VI1.vi
.PARAMETER HeadPath
  Head VI path. Defaults to ./VI2.vi
.PARAMETER LvCompareArgs
  Additional LVCompare args. Defaults to recommended baseline filters.
.PARAMETER RenderReport
  If specified, enables compare-report.html generation when LVCompare (or simulation) runs.
.PARAMETER SimulateCompare
  If specified, simulates LVCompare within the orchestrator (test-only path).
.PARAMETER Clean
  If specified and OutputDir exists, deletes it first.
.PARAMETER NoSchemaValidation
  If specified, skips schema-lite validation of the drift summary.

.EXAMPLE
  pwsh -File scripts/Debug-FixtureDrift.ps1 -SimulateCompare -RenderReport
#>

param(
  [string]$OutputDir,
  [string]$StrictJson,
  [string]$OverrideJson,
  [string]$BasePath,
  [string]$HeadPath,
  [string]$LvCompareArgs = '-nobdcosm -nofppos -noattr',
  [switch]$RenderReport,
  [switch]$SimulateCompare,
  [switch]$Clean,
  [switch]$NoSchemaValidation
)

function New-UtcStamp { (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') }

if ($IsWindows -ne $true) { throw 'This helper requires Windows (PowerShell 7+).' }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
$validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
$orchestrator = Join-Path $repoRoot 'scripts' 'On-FixtureValidationFail.ps1'
$schemaLite = Join-Path $repoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
$schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'fixture-drift-summary-v1.schema.json'

foreach ($req in @($validator,$orchestrator)) { if (-not (Test-Path -LiteralPath $req)) { throw "Missing dependency: $req" } }

if (-not $OutputDir) {
  $manualRoot = Join-Path $repoRoot 'results' | Join-Path -ChildPath 'fixture-drift' | Join-Path -ChildPath 'manual'
  if (-not (Test-Path $manualRoot)) { New-Item -ItemType Directory -Path $manualRoot | Out-Null }
  $OutputDir = Join-Path $manualRoot (New-UtcStamp)
}
if (Test-Path $OutputDir) {
  if ($Clean) { Remove-Item $OutputDir -Recurse -Force }
  else { Write-Host "OutputDir exists: $OutputDir (use -Clean to delete)" -ForegroundColor Yellow }
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# Resolve default Base/Head paths if not provided
if (-not $BasePath) { $BasePath = Join-Path (Get-Location) 'VI1.vi' }
if (-not $HeadPath) { $HeadPath = Join-Path (Get-Location) 'VI2.vi' }

# Generate validator JSONs unless provided
$strictPath = $StrictJson
if (-not $strictPath) { $strictPath = Join-Path $OutputDir 'strict.json'; & $validator -Json | Out-File -FilePath $strictPath -Encoding utf8 }
$overridePath = $OverrideJson
if (-not $overridePath) { $overridePath = Join-Path $OutputDir 'override.json'; & $validator -Json -TestAllowFixtureUpdate | Out-File -FilePath $overridePath -Encoding utf8 }

Write-Host "Strict JSON:    $strictPath" -ForegroundColor Cyan
Write-Host "Override JSON:  $overridePath" -ForegroundColor Cyan
Write-Host "OutputDir:      $OutputDir" -ForegroundColor Cyan

$invokeArgs = @('-StrictJson',$strictPath,'-OverrideJson',$overridePath,'-OutputDir',$OutputDir,'-BasePath',$BasePath,'-HeadPath',$HeadPath,'-LvCompareArgs',$LvCompareArgs)
if ($RenderReport) { $invokeArgs += '-RenderReport' }
if ($SimulateCompare) { $invokeArgs += '-SimulateCompare' }

& $orchestrator @invokeArgs
$orchestratorExit = $LASTEXITCODE
if ($orchestratorExit -ne 0) { Write-Host "Orchestrator exit != 0 (expected if drift/structural)" -ForegroundColor Yellow }

$summaryPath = Join-Path $OutputDir 'drift-summary.json'
if (Test-Path $summaryPath) {
  Write-Host "Summary:        $summaryPath" -ForegroundColor Green
  try {
    $j = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    Write-Host ("Status:         {0}" -f $j.status)
    if ($j.categories) { Write-Host ("Categories:     {0}" -f ($j.categories -join ', ')) }
  } catch { Write-Host "Failed to parse summary JSON: $($_.Exception.Message)" -ForegroundColor Yellow }
  if (-not $NoSchemaValidation -and (Test-Path $schemaLite) -and (Test-Path $schemaPath)) {
    Write-Host "Validating summary against schema..." -ForegroundColor DarkCyan
    & $schemaLite -JsonPath $summaryPath -SchemaPath $schemaPath
    if ($LASTEXITCODE -ne 0) { Write-Host "Schema-lite returned $LASTEXITCODE" -ForegroundColor Yellow }
  }
} else {
  Write-Host "No drift-summary.json found in: $OutputDir" -ForegroundColor Yellow
}

exit $orchestratorExit
