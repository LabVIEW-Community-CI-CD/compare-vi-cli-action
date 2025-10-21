#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [int]$LookBackSeconds = 900,
  [switch]$FailOnRogue = $true,
  [switch]$Kill = $true,
  [switch]$AppendToStepSummary,
  [string]$DetectScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $DetectScriptPath) {
  $DetectScriptPath = Join-Path $PSScriptRoot 'Detect-RogueLV.ps1'
}

if (-not (Test-Path -LiteralPath $DetectScriptPath -PathType Leaf)) {
  throw "Detect-RogueLV script not found at: $DetectScriptPath"
}

$detectArgs = @(
  '-NoLogo','-NoProfile',
  '-File', $DetectScriptPath,
  '-ResultsDir', $ResultsDir,
  '-LookBackSeconds', $LookBackSeconds,
  '-Quiet'
)
if ($AppendToStepSummary) { $detectArgs += '-AppendToStepSummary' }

$detectOutput = & pwsh @detectArgs
$exitCode = $LASTEXITCODE

if ($exitCode -notin 0,3) {
  throw ("Detect-RogueLV failed (exit {0}). Output: {1}" -f $exitCode, ($detectOutput -join "`n"))
}

try {
  $result = $detectOutput | ConvertFrom-Json -ErrorAction Stop
} catch {
  throw ("Failed to parse Detect-RogueLV output: {0}" -f $_.Exception.Message)
}

$rogueLV = @($result.rogue.labview)
$rogueLC = @($result.rogue.lvcompare)
$rogueCount = $rogueLV.Count + $rogueLC.Count

if ($rogueCount -eq 0) {
  Write-Host '[rogue-lv] No rogue LabVIEW/LVCompare processes detected.'
  return
}

Write-Warning ("[rogue-lv] Rogue processes detected. LabVIEW={0} LVCompare={1}" -f ($rogueLV -join ','), ($rogueLC -join ','))

if ($Kill) {
  $killed = @()
  foreach ($pid in ($rogueLV + $rogueLC | Sort-Object -Unique)) {
    try {
      Stop-Process -Id $pid -Force -ErrorAction Stop
      $killed += $pid
    } catch {
      Write-Warning ("[rogue-lv] Failed to terminate PID {0}: {1}" -f $pid, $_.Exception.Message)
    }
  }
  if ($killed.Count -gt 0) {
    Write-Host ("[rogue-lv] Terminated rogue PIDs: {0}" -f ($killed -join ','))
  }
}

if ($FailOnRogue) {
  throw ("Rogue LabVIEW/LVCompare processes detected (LabVIEW={0}; LVCompare={1})." -f ($rogueLV -join ','), ($rogueLC -join ','))
}
