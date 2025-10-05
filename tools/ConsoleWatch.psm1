Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Variable -Name ConsoleWatchState -Scope Script -ErrorAction SilentlyContinue)) {
  $script:ConsoleWatchState = @{}
}

function Start-ConsoleWatch {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$OutDir,
    [string[]]$Targets = @('conhost','pwsh','powershell','cmd','wt')
  )
  if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { try { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null } catch {} }
  $id = 'ConsoleWatch_' + ([guid]::NewGuid().ToString('n'))
  $ndjson = Join-Path $OutDir 'console-spawns.ndjson'
  $targetsLower = @($Targets | ForEach-Object { $_.ToLowerInvariant().Trim() } | Where-Object { $_ })
  # Ensure the NDJSON file exists even if no events occur (helps consumers and artifacts)
  try {
    if (-not (Test-Path -LiteralPath $ndjson -PathType Leaf)) { '' | Out-File -FilePath $ndjson -Encoding utf8 -ErrorAction SilentlyContinue }
  } catch {}
  try {
    Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier $id -Action {
      param($e)
      try {
        $pid = $e.SourceEventArgs.NewEvent.ProcessID
        $name = [string]$e.SourceEventArgs.NewEvent.ProcessName
        if (-not $name) { return }
        if ($using:targetsLower -notcontains $name.ToLowerInvariant()) { return }
        $ppid = $e.SourceEventArgs.NewEvent.ParentProcessID
        $meta = $null
        try { $meta = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $pid) -ErrorAction SilentlyContinue } catch {}
        $cmd = $null; if ($meta) { $cmd = $meta.CommandLine }
        $parent = $null
        try { $parent = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ppid) -ErrorAction SilentlyContinue } catch {}
        $hasWindow = $false
        try { $hasWindow = ((Get-Process -Id $pid -ErrorAction SilentlyContinue).MainWindowHandle -ne 0) } catch { $hasWindow = $false }
        $rec = [pscustomobject]@{ ts=(Get-Date).ToString('o'); pid=[int]$pid; name=$name; ppid=[int]$ppid; parentName=if ($parent) { [string]$parent.Name } else { $null }; cmd=$cmd; hasWindow=$hasWindow }
        try { $rec | ConvertTo-Json -Compress | Add-Content -LiteralPath $using:ndjson -Encoding utf8 } catch {}
      } catch {}
    } | Out-Null
    $script:ConsoleWatchState[$id] = @{ Mode='event'; OutDir=$OutDir; Targets=$targetsLower; Path=$ndjson }
    return $id
  } catch {
    $pre = @()
    try { $pre = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName.ToLowerInvariant() -in $targetsLower } | Select-Object ProcessName,Id,StartTime) } catch { $pre = @() }
    $script:ConsoleWatchState[$id] = @{ Mode='snapshot'; OutDir=$OutDir; Targets=$targetsLower; Pre=$pre }
    return $id
  }
}

function Stop-ConsoleWatch {
  [CmdletBinding()]
  param(
      [Parameter(Mandatory)][string]$Id,
      [Parameter(Mandatory)][string]$OutDir,
      [string]$Phase
  )
  $state = $script:ConsoleWatchState[$Id]
  if ($state.Mode -eq 'event') { try { Unregister-Event -SourceIdentifier $Id -ErrorAction SilentlyContinue } catch {}; try { Remove-Event -SourceIdentifier $Id -ErrorAction SilentlyContinue } catch {} }
  $summary = [ordered]@{ schema='console-watch-summary/v1'; phase=$Phase; generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); counts=[ordered]@{}; last=@(); path=(Join-Path $OutDir 'console-spawns.ndjson') }
  try {
    $records = @()
    if ($state.Mode -eq 'event') {
      $nd = Join-Path $OutDir 'console-spawns.ndjson'
      if (Test-Path -LiteralPath $nd) {
        $lines = Get-Content -LiteralPath $nd -ErrorAction SilentlyContinue
        foreach ($ln in $lines) { try { $records += ($ln | ConvertFrom-Json) } catch {} }
      }
    } else {
      $pre = $state.Pre
      $post = @()
      try { $post = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName.ToLowerInvariant() -in $state.Targets } | Select-Object ProcessName,Id,StartTime) } catch { $post = @() }
      $preSet = @{}; foreach ($p in $pre) { $preSet[[string]$p.Id] = $true }
      foreach ($p in $post) { if (-not $preSet.ContainsKey([string]$p.Id)) { $records += [pscustomobject]@{ ts=(Get-Date).ToString('o'); pid=$p.Id; name=$p.ProcessName; ppid=$null; parentName=$null; cmd=$null; hasWindow=$null } } }
    }
    if ($records.Count -gt 0) {
      $byName = $records | Group-Object name | Sort-Object Name
      foreach ($g in $byName) { $summary.counts[$g.Name] = $g.Count }
      $summary.last = @($records | Select-Object -Last 3)
    }
  } catch {}
  try { $sumPath = Join-Path $OutDir 'console-watch-summary.json'; $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sumPath -Encoding utf8 } catch {}
  return $summary
}

Export-ModuleMember -Function Start-ConsoleWatch, Stop-ConsoleWatch
