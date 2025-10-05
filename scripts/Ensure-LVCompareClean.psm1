Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LVCompareProcesses {
  try {
    $list = Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -eq 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe' }
    if ($null -eq $list) { @() } else { @($list) }
  } catch { @() }
}

function Stop-LVCompareProcesses {
  [CmdletBinding()] param([switch]$Quiet)
  $procs = @(Get-LVCompareProcesses)
  foreach ($p in $procs) {
    try {
      Stop-Process -Id $p.Id -Force -ErrorAction Stop
      if (-not $Quiet) { Write-Host "Stopped stray LVCompare.exe (PID $($p.Id))" -ForegroundColor Yellow }
    } catch {
      if (-not $Quiet) { Write-Warning "Failed to stop LVCompare.exe PID $($p.Id): $($_.Exception.Message)" }
    }
  }
  $count = ($procs | Measure-Object).Count
  if (-not $Quiet) { Write-Host "LVCompare cleanup complete (count=$count)" -ForegroundColor DarkGray }
  return $count
}

function Get-LabVIEWProcesses {
  try {
    $list = Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue
    if ($null -eq $list) { @() } else { @($list) }
  } catch { @() }
}

function Stop-LabVIEWProcesses {
  [CmdletBinding()] param([switch]$Quiet)
  $procs = @(Get-LabVIEWProcesses)
  foreach ($p in $procs) {
    try {
      Stop-Process -Id $p.Id -Force -ErrorAction Stop
      if (-not $Quiet) { Write-Host "Stopped stray LabVIEW.exe (PID $($p.Id))" -ForegroundColor Yellow }
    } catch {
      if (-not $Quiet) { Write-Warning "Failed to stop LabVIEW.exe PID $($p.Id): $($_.Exception.Message)" }
    }
  }
  $count = ($procs | Measure-Object).Count
  if (-not $Quiet) { Write-Host "LabVIEW cleanup complete (count=$count)" -ForegroundColor DarkGray }
  return $count
}

Export-ModuleMember -Function Get-LVCompareProcesses,Stop-LVCompareProcesses,Get-LabVIEWProcesses,Stop-LabVIEWProcesses

