<#
.SYNOPSIS
  Validates an integration runbook JSON file against the v1 schema & ordering rules.
.DESCRIPTION
  Performs lightweight structural validation (no external dependency) plus deterministic
  phase ordering assertion (phases must appear in canonical order subset).

.PARAMETER Path
  Path to JSON file produced by Invoke-IntegrationRunbook.ps1

.EXIT CODES
  0 success
  1 validation failure
#>
[CmdletBinding()]param(
  [Parameter(Mandatory)][string]$Path
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

if (-not (Test-Path $Path)) { Write-Error "File not found: $Path"; exit 1 }
$raw = Get-Content $Path -Raw | ConvertFrom-Json

if ($raw.schema -ne 'integration-runbook-v1') { Write-Error 'schema mismatch'; exit 1 }
if (-not $raw.phases) { Write-Error 'no phases array'; exit 1 }

$canonical = @('Prereqs','CanonicalCli','ViInputs','Compare','Tests','Loop','Diagnostics')
$names = @($raw.phases | ForEach-Object name)

# Ensure each reported phase is in canonical list
$bad = $names | Where-Object { $_ -notin $canonical }
if ($bad) { Write-Error "unknown phase(s): $($bad -join ', ')"; exit 1 }

# Deterministic ordering: sequence must be a prefix-respecting subsequence
$lastIndex = -1
for ($i=0; $i -lt $names.Count; $i++) {
  $idx = [Array]::IndexOf($canonical,$names[$i])
  if ($idx -lt $lastIndex) { Write-Error "phase ordering violation near '$($names[$i])'"; exit 1 }
  $lastIndex = $idx
}

# Basic field presence per phase
foreach ($p in $raw.phases) {
  if (-not $p.status) { Write-Error "phase '$($p.name)' missing status"; exit 1 }
  if (-not $p.details) { Write-Error "phase '$($p.name)' missing details object"; exit 1 }
}

Write-Host "Runbook JSON validation passed" -ForegroundColor Green
exit 0