#Requires -Version 7.0
<#!
.SYNOPSIS
  Unify multiple telemetry JSON files into a single summary JSON and append a brief summary to step summary.
.PARAMETER Inputs
  Paths to telemetry JSON files.
.PARAMETER ResultsDir
  Directory under which to write unified-telemetry.json (default tests/results).
.PARAMETER Name
  Optional label for this unified set (e.g., 'dispatcher').
#>
[CmdletBinding()] param(
  [string[]] $Inputs,
  [string] $ResultsDir = 'tests/results',
  [string] $Name = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Dir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }

$items = @()
foreach ($p in $Inputs) {
  if (-not $p) { continue }
  if (-not (Test-Path -LiteralPath $p)) { continue }
  try { $obj = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
  $items += [pscustomobject]@{ path=$p; data=$obj }
}

$unified = [ordered]@{
  schema = 'unified-telemetry/v1'
  name   = $Name
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  sources = $items
}
$outDir = $ResultsDir
New-Dir -p $outDir
$outPath = Join-Path $outDir 'unified-telemetry.json'
$unified | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outPath -Encoding UTF8

# Append brief to step summary
$lines = @('### Unified Telemetry','')
if ($Name) { $lines += ("- Name: $Name") }
$lines += ("- Sources: {0}" -f ($items.Count))
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value (($lines -join [Environment]::NewLine) + [Environment]::NewLine) -Encoding UTF8 }
Write-Host ("unified telemetry: {0}" -f (Resolve-Path $outPath).Path)

