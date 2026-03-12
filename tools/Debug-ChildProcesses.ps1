<#
.SYNOPSIS
  Capture a snapshot of child processes (pwsh, conhost, LabVIEW, LVCompare, LabVIEWCLI, g-cli) with memory usage.

.DESCRIPTION
  Writes a JSON snapshot to tests/results/_agent/child-procs.json and optionally appends
  a brief summary to the GitHub Step Summary when available.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string[]]$Names = @('pwsh','conhost','LabVIEW','LVCompare','LabVIEWCLI','g-cli'),
  [switch]$AppendStepSummary
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CommandLine([int]$ProcId){
  try {
    $ci = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcId) -ErrorAction SilentlyContinue
    if (-not $ci) { return $null }
    $value = $ci.CommandLine
    if ($null -eq $value) { return $null }
    if ($value -is [System.Array]) { $value = ($value -join ' ') }
    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
  } catch { return $null }
}

$repoRoot = (Resolve-Path '.').Path
# Always write snapshot under repo tests/results/_agent to keep location stable
$agentDir = Join-Path (Join-Path $repoRoot 'tests/results') '_agent'
if (-not (Test-Path -LiteralPath $agentDir)) { New-Item -ItemType Directory -Path $agentDir -Force | Out-Null }
$outPath = Join-Path $agentDir 'child-procs.json'

$snapshot = [ordered]@{
  schema = 'child-procs-snapshot/v1'
  at     = (Get-Date).ToUniversalTime().ToString('o')
  groups = @{}
}

$summaryLines = @('### Child Processes Snapshot','')
foreach ($name in $Names) {
  $procs = @()
  try {
    if ($name -ieq 'g-cli') {
      $procs = @(Get-CimInstance Win32_Process -Filter "Name='g-cli.exe'" -ErrorAction SilentlyContinue)
    } elseif ($name -ieq 'LabVIEWCLI') {
      $procs = @(Get-Process -Name 'LabVIEWCLI' -ErrorAction SilentlyContinue)
      if (-not $procs -or $procs.Count -eq 0) {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='LabVIEWCLI.exe'" -ErrorAction SilentlyContinue)
      }
    } else {
      $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }
  } catch { $procs = @() }
  $items = @()
  $totalWs = 0L; $totalPm = 0L
  foreach ($p in $procs) {
    $title = $null
    try { $title = $p.MainWindowTitle } catch {}
    $procId = try { [int]$p.Id } catch { try { [int]$p.ProcessId } catch { $null } }
    $cmd = $null
    if ($procId) {
      $cmd = Get-CommandLine -ProcId $procId
      if ($cmd -and $cmd.Length -gt 2048) {
        $cmd = $cmd.Substring(0, 2048) + ' ...'
      }
    }
    $ws = 0L; $pm = 0L
    try { $ws = [int64]$p.WorkingSet64 } catch {}
    try { $pm = [int64]$p.PagedMemorySize64 } catch {}
    $totalWs += $ws; $totalPm += $pm
    $items += [pscustomobject]@{
      pid   = $procId
      ws    = $ws
      pm    = $pm
      title = $title
      cmd   = $cmd
    }
  }
  $snapshot.groups[$name] = [pscustomobject]@{
    count  = $procs.Count
    memory = @{ ws = $totalWs; pm = $totalPm }
    items  = $items
  }
  $summaryLines += ('- {0}: count={1}, wsMB={2:N1}, pmMB={3:N1}' -f $name, $procs.Count, ($totalWs/1MB), ($totalPm/1MB))
}

$snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $outPath -Encoding utf8

if ($AppendStepSummary -and $env:GITHUB_STEP_SUMMARY) {
  try { ($summaryLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 } catch {}
}

Write-Host ("Child process snapshot written: {0}" -f $outPath) -ForegroundColor DarkGray
$snapshot
