<#
.SYNOPSIS
  Guard to observe LabVIEW/LVCompare process presence around phases.

.DESCRIPTION
  Samples pwsh process list for LabVIEW.exe and LVCompare.exe, writes/updates
  a compact JSON at <ResultsDir>/labview-persistence.json and appends a
  concise note to the GitHub Step Summary when available. Optionally polls for
  a short duration to detect an early closure of LabVIEW after a critical step.

.PARAMETER ResultsDir
  Directory where labview-persistence.json will be written. Default: results/fixture-drift

.PARAMETER Phase
  Label for this sampling event (e.g., before-compare, after-compare, after-report).

.PARAMETER PollForCloseSeconds
  When > 0, poll every 200ms up to the given seconds and mark closedEarly=true
  if LabVIEW disappears during the poll window.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'results/fixture-drift',
  [Parameter(Mandatory)][string]$Phase,
  [int]$PollForCloseSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Dir([string]$p){ if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Get-Procs([string]$name){ try { return @(Get-Process -Name $name -ErrorAction SilentlyContinue) } catch { @() } }

$now = (Get-Date).ToUniversalTime().ToString('o')
$dir = $ResultsDir
New-Dir $dir
$outPath = Join-Path $dir 'labview-persistence.json'

$lv1 = Get-Procs 'LabVIEW'
$lvc1 = Get-Procs 'LVCompare'
$present1 = ($lv1.Count -gt 0)

$closedEarly = $false
if ($PollForCloseSeconds -gt 0) {
  $deadline = (Get-Date).AddSeconds([Math]::Max(1,$PollForCloseSeconds))
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $lvNow = Get-Procs 'LabVIEW'
    if ($present1 -and $lvNow.Count -eq 0) { $closedEarly = $true; break }
  }
}

$event = [ordered]@{
  schema    = 'labview-persistence/v1'
  at        = $now
  phase     = $Phase
  labview   = [ordered]@{ count=$lv1.Count; pids=@($lv1 | Select-Object -ExpandProperty Id) }
  lvcompare = [ordered]@{ count=$lvc1.Count; pids=@($lvc1 | Select-Object -ExpandProperty Id) }
  closedEarly = $closedEarly
}

# Append to JSON array file (create if missing)
try {
  if (-not (Test-Path -LiteralPath $outPath)) { '[]' | Out-File -FilePath $outPath -Encoding utf8 }
  $arr = @()
  try { $arr = (Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json -Depth 6) } catch { $arr = @() }
  if ($arr -isnot [System.Collections.IList]) { $arr = @() }
  $arr += (New-Object psobject -Property $event)
  $arr | ConvertTo-Json -Depth 6 | Out-File -FilePath $outPath -Encoding utf8
} catch { Write-Warning "Guard-LabVIEWPersistence: failed to write $outPath: $_" }

if ($env:GITHUB_STEP_SUMMARY) {
  $line = ('- Guard [{0}]: LabVIEW={1} ({2}); LVCompare={3} ({4}); closedEarly={5}' -f $Phase,$event.labview.count,($event.labview.pids -join ','),$event.lvcompare.count,($event.lvcompare.pids -join ','),$closedEarly)
  $line | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

