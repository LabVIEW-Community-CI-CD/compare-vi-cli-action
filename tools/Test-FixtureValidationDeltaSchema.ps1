param(
  [Parameter(Mandatory)][string]$DeltaJsonPath,
  [string]$SchemaPath = (Join-Path (Join-Path $PSScriptRoot '..' 'docs' 'schemas') 'fixture-validation-delta-v1.schema.json')
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DeltaJsonPath)) { Write-Error "Delta JSON not found: $DeltaJsonPath"; exit 2 }
if (-not (Test-Path -LiteralPath $SchemaPath)) { Write-Error "Schema file not found: $SchemaPath"; exit 2 }

try { $delta = Get-Content -LiteralPath $DeltaJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop }
catch { Write-Error "Failed to parse delta JSON: $($_.Exception.Message)"; exit 2 }

# Lightweight validation (no external JSON Schema engine): assert required keys & types
$required = 'schema','baselinePath','currentPath','generatedAt','baselineOk','currentOk','deltaCounts','changes','newStructuralIssues','failOnNewStructuralIssue','willFail'
$missing = @($required | Where-Object { $delta.PSObject.Properties.Name -notcontains $_ })
if ($missing) { Write-Error "Missing required delta fields: $($missing -join ', ')"; exit 3 }
if ($delta.schema -ne 'fixture-validation-delta-v1') { Write-Error "Unexpected schema value: $($delta.schema)"; exit 3 }
if (-not ($delta.changes -is [System.Array])) { Write-Error 'changes is not an array'; exit 3 }
if (-not ($delta.newStructuralIssues -is [System.Array])) { Write-Error 'newStructuralIssues is not an array'; exit 3 }

# Spot check change entries
foreach ($c in $delta.changes) {
  foreach ($rk in 'category','baseline','current','delta') { if ($c.PSObject.Properties.Name -notcontains $rk) { Write-Error "Change missing field $rk"; exit 3 } }
}

Write-Host 'Delta schema basic validation passed.'
exit 0
