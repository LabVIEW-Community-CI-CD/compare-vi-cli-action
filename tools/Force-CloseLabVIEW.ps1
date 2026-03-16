param(
  [string[]]$ProcessName = @('LabVIEW','LVCompare'),
  [int[]]$ProcessId,
  [switch]$DryRun,
  [int]$WaitSeconds = 5,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
  param([string]$Message)
  if (-not $Quiet) { Write-Host $Message -ForegroundColor DarkGray }
}

function Write-Warn {
  param([string]$Message)
  Write-Warning $Message
}

function Get-ProcessExecutableBaseName {
  param([Parameter(Mandatory)][object]$Process)

  if ($Process.Path) {
    try {
      return [System.IO.Path]::GetFileNameWithoutExtension($Process.Path)
    } catch {}
  }

  try {
    $cim = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $Process.Id) -ErrorAction SilentlyContinue
    if ($cim -and $cim.ExecutablePath) {
      return [System.IO.Path]::GetFileNameWithoutExtension($cim.ExecutablePath)
    }
  } catch {}

  return $null
}

function Test-MatchingProcessSurface {
  param(
    [Parameter(Mandatory)][object]$Process,
    [string[]]$AllowedNames
  )

  if (-not $AllowedNames -or $AllowedNames.Count -eq 0) {
    return $true
  }

  foreach ($name in $AllowedNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if ($Process.ProcessName -ieq $name) { return $true }
    $baseName = Get-ProcessExecutableBaseName -Process $Process
    if ($baseName -and $baseName -ieq $name) {
      return $true
    }
  }

  return $false
}

$names = @()
foreach ($name in $ProcessName) {
  if (-not [string]::IsNullOrWhiteSpace($name)) {
    $names += $name.Trim()
  }
}
if ($names.Count -eq 0) {
  Write-Warn 'No process names supplied; nothing to do.'
  exit 0
}

$targetIds = @()
foreach ($id in @($ProcessId)) {
  if ($null -ne $id -and [int]$id -gt 0) {
    $targetIds += [int]$id
  }
}
$targetIds = @($targetIds | Sort-Object -Unique)

$initial = @()
if ($targetIds.Count -gt 0) {
  foreach ($id in $targetIds) {
    try {
      $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($proc -and (Test-MatchingProcessSurface -Process $proc -AllowedNames $names)) {
        $initial += @($proc)
      }
    } catch {}
  }
} else {
  foreach ($name in $names) {
    try {
      $initial += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    } catch {}
  }
}

if ($initial.Count -eq 0) {
  if ($targetIds.Count -gt 0) {
    Write-Info ("Force-CloseLabVIEW: no matching processes found for PID(s) {0}." -f ($targetIds -join ','))
  } else {
    Write-Info ("Force-CloseLabVIEW: no matching processes found for {0}." -f ($names -join ','))
  }
  exit 0
}

$summary = [ordered]@{
  schema    = 'force-close-labview/v1'
  generated = (Get-Date).ToString('o')
  dryRun    = $DryRun.IsPresent
  targets   = @(
    $initial | Select-Object @{n='name';e={$_.ProcessName}}, @{n='pid';e={$_.Id}}
  )
}

if ($DryRun) {
  $summary['result'] = 'skipped'
  $summary | ConvertTo-Json -Depth 4 | Write-Output
  exit 0
}

$errors = New-Object System.Collections.Generic.List[string]
foreach ($proc in $initial) {
  try {
    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
    Write-Info ("Force-CloseLabVIEW: terminated {0} (PID {1})." -f $proc.ProcessName, $proc.Id)
  } catch {
    $msg = ("Force-CloseLabVIEW: failed to terminate {0} (PID {1}): {2}" -f $proc.ProcessName, $proc.Id, $_.Exception.Message)
    $errors.Add($msg)
    Write-Warn $msg
  }
}

$deadline = (Get-Date).AddSeconds([Math]::Max(0,$WaitSeconds))
do {
  $remaining = @()
  if ($targetIds.Count -gt 0) {
    foreach ($id in $targetIds) {
      try {
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($proc -and (Test-MatchingProcessSurface -Process $proc -AllowedNames $names)) {
          $remaining += @($proc)
        }
      } catch {}
    }
  } else {
    foreach ($name in $names) {
      try {
        $remaining += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
      } catch {}
    }
  }
  if ($remaining.Count -eq 0) { break }
  Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $deadline)

$summary['errors'] = @($errors)
$summary['remaining'] = @(
  $remaining | Select-Object @{n='name';e={$_.ProcessName}}, @{n='pid';e={$_.Id}}
)

if ($remaining.Count -eq 0 -and $errors.Count -eq 0) {
  $summary['result'] = 'success'
  $summary | ConvertTo-Json -Depth 4 | Write-Output
  exit 0
}

if ($remaining.Count -gt 0) {
  $remainingDetails = (($remaining | ForEach-Object { "{0}(PID {1})" -f $_.ProcessName,$_.Id } | Sort-Object) -join ', ')
  Write-Warn ("Force-CloseLabVIEW: processes still running: {0}" -f $remainingDetails)
}

$summary['result'] = 'failed'
$summary | ConvertTo-Json -Depth 4 | Write-Output
exit 1
