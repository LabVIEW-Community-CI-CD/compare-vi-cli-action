#Requires -Version 7.0
<#
.SYNOPSIS
  Emit LV closure telemetry crumbs when enabled.

.DESCRIPTION
  When `EMIT_LV_CLOSURE_CRUMBS` is truthy, this script records the current
  LabVIEW/LVCompare process state to `tests/results/_diagnostics/lv-closure.ndjson`.
  Each invocation appends a single JSON record with phase metadata so that
  orchestrated runs can trace when processes are observed and when they are gone.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$Phase = 'unknown',
  [string[]]$ProcessNames = @('LabVIEW','LVCompare')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvTruth([string]$Name){
  $val = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($val)) { return $false }
  return $val -match '^(?i:1|true|yes|on)$'
}

if (-not (Get-EnvTruth 'EMIT_LV_CLOSURE_CRUMBS')) { exit 0 }

try {
  if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
  }
  $diagDir = Join-Path $ResultsDir '_diagnostics'
  if (-not (Test-Path -LiteralPath $diagDir -PathType Container)) {
    New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
  }
  $logPath = Join-Path $diagDir 'lv-closure.ndjson'
  if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    New-Item -ItemType File -Path $logPath -Force | Out-Null
  }

  $all = @()
  foreach ($name in $ProcessNames) {
    try {
      $list = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
      foreach ($proc in $list) {
        $startUtc = $null
        try { $startUtc = $proc.StartTime.ToUniversalTime().ToString('o') } catch {}
        $all += [ordered]@{
          name = $proc.ProcessName
          pid = $proc.Id
          startTime = $startUtc
          mainWindow = $proc.MainWindowTitle
        }
      }
    } catch {
      # ignore lookup failures
    }
  }

  $record = [ordered]@{
    schema = 'lv-closure/v1'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    phase = $Phase
    runId = [Environment]::GetEnvironmentVariable('GITHUB_RUN_ID')
    job = [Environment]::GetEnvironmentVariable('GITHUB_JOB')
    computer = [Environment]::GetEnvironmentVariable('COMPUTERNAME')
    processCount = $all.Count
    processes = $all
  }
  try {
    $record.closed = ($all.Count -eq 0)
  } catch {}

  $json = $record | ConvertTo-Json -Depth 5 -Compress
  Add-Content -LiteralPath $logPath -Value $json -Encoding utf8
  exit 0
} catch {
  Write-Host "::warning::Emit-LVClosureCrumb failed ($Phase): $($_.Exception.Message)"
  exit 0
}
