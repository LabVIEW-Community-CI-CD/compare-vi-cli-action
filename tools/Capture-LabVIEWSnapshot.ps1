<#
.SYNOPSIS
  Capture a snapshot of active LabVIEW.exe processes for diagnostics.

.DESCRIPTION
  Enumerates LabVIEW.exe processes (if any) and writes a JSON report capturing
  timing and memory metadata. Designed to run after warm-up or before teardown
  so future agents can decide whether to keep or close LabVIEW.

.PARAMETER OutputPath
  Destination JSON file. Default: tests/results/_warmup/labview-processes.json

.PARAMETER Quiet
  Suppress informational console output.
#>
[CmdletBinding()]
param(
  [string]$OutputPath = 'tests/results/_warmup/labview-processes.json',
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
  param([string]$Message)
  if (-not $Quiet) { Write-Host "[labview-snapshot] $Message" }
}

$outputFullPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
  [System.IO.Path]::GetFullPath($OutputPath)
} else {
  [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputPath))
}
$directory = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $directory)) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}

Write-Info ("Writing LabVIEW process snapshot to {0}" -f $outputFullPath)

$labviewProcesses = @()
try {
  $labviewProcesses = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
} catch {
  Write-Info "Unable to enumerate LabVIEW processes: $($_.Exception.Message)"
  $labviewProcesses = @()
}

$labviewItems = @(
foreach ($proc in $labviewProcesses) {
  $startIso = $null
  try { $startIso = $proc.StartTime.ToUniversalTime().ToString('o') } catch {}
  $totalCpu = $null
  try { $totalCpu = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 3) } catch {}
  [pscustomobject][ordered]@{
    pid                = $proc.Id
    processName        = $proc.ProcessName
    startTimeUtc       = $startIso
    responding         = $proc.Responding
    workingSetBytes    = $proc.WorkingSet64
    privateMemoryBytes = $proc.PrivateMemorySize64
    totalCpuSeconds    = $totalCpu
    userName           = $null
  }
})

$lvcompareProcesses = @()
try {
  $lvcompareProcesses = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue)
} catch {
  Write-Info "Unable to enumerate LVCompare processes: $($_.Exception.Message)"
  $lvcompareProcesses = @()
}

$lvcompareItems = @(
foreach ($proc in $lvcompareProcesses) {
  $startIso = $null
  try { $startIso = $proc.StartTime.ToUniversalTime().ToString('o') } catch {}
  $totalCpu = $null
  try { $totalCpu = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 3) } catch {}
  [pscustomobject][ordered]@{
    pid                = $proc.Id
    processName        = $proc.ProcessName
    startTimeUtc       = $startIso
    responding         = $proc.Responding
    workingSetBytes    = $proc.WorkingSet64
    privateMemoryBytes = $proc.PrivateMemorySize64
    totalCpuSeconds    = $totalCpu
    userName           = $null
  }
})

$snapshot = [pscustomobject][ordered]@{
  schema      = 'labview-process-snapshot/v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  machine     = $env:COMPUTERNAME
  user        = $env:USERNAME
  processCount = $labviewItems.Count
  processes   = $labviewItems
  labview     = [pscustomobject][ordered]@{
    count     = $labviewItems.Count
    processes = $labviewItems
  }
  lvcompare   = [pscustomobject][ordered]@{
    count     = $lvcompareItems.Count
    processes = $lvcompareItems
  }
}

$snapshot | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputFullPath -Encoding utf8

Write-Info ("Snapshot complete. LabVIEW={0} LVCompare={1}." -f $labviewItems.Count, $lvcompareItems.Count)
