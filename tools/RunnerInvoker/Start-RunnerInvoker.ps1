param(
  [string]$PipeName,
  [string]$SentinelPath,
  [string]$ResultsDir = 'tests/results/_invoker',
  [string]$ReadyFile,
  [string]$StoppedFile,
  [string]$PidFile
)

$ErrorActionPreference = 'Stop'

function New-ParentDir {
  param([string]$Path)
  $dir = Split-Path -Parent -LiteralPath $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

if (-not $PipeName) { $PipeName = "lvci.invoker.$([Environment]::GetEnvironmentVariable('GITHUB_RUN_ID')).$([Environment]::GetEnvironmentVariable('GITHUB_JOB')).$([Environment]::GetEnvironmentVariable('GITHUB_RUN_ATTEMPT'))" }
if (-not $ReadyFile)   { $ReadyFile   = Join-Path $ResultsDir "_invoker/ready.json" }
if (-not $StoppedFile) { $StoppedFile = Join-Path $ResultsDir "_invoker/stopped.json" }
if (-not $PidFile)     { $PidFile     = Join-Path $ResultsDir "_invoker/pid.txt" }

New-Item -ItemType Directory -Path (Join-Path $ResultsDir '_invoker') -Force | Out-Null
if ($SentinelPath) { New-ParentDir -Path $SentinelPath; if (-not (Test-Path -LiteralPath $SentinelPath)) { New-Item -ItemType File -Path $SentinelPath -Force | Out-Null } }

# Touch console-spawns.ndjson (artifact presence guarantee)
$spawns = Join-Path $ResultsDir '_invoker/console-spawns.ndjson'
if (-not (Test-Path -LiteralPath $spawns)) { New-Item -ItemType File -Path $spawns -Force | Out-Null }

# Write PID file
$pidContent = [string]$PID
Set-Content -LiteralPath $PidFile -Value $pidContent -Encoding ASCII

# Write ready marker
$now = (Get-Date).ToUniversalTime().ToString('o')
$readyObj = [pscustomobject]@{ schema='invoker-ready/v1'; pipe=$PipeName; pid=$PID; at=$now }
$readyObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReadyFile -Encoding UTF8

# Load server module and run loop until sentinel removed
Import-Module (Join-Path $PSScriptRoot 'RunnerInvoker.psm1') -Force
$hb = Join-Path $ResultsDir '_invoker/heartbeat.ndjson'
try {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = 0
  $job = Start-Job -ScriptBlock {
    param($pn,$sp,$rd)
    Import-Module (Join-Path $using:PSScriptRoot 'RunnerInvoker.psm1') -Force
    Start-InvokerLoop -PipeName $pn -SentinelPath $sp -ResultsDir $rd -PollIntervalMs 200
  } -ArgumentList @($PipeName,$SentinelPath,$ResultsDir)
  while ($true) {
    if ($SentinelPath -and -not (Test-Path -LiteralPath $SentinelPath)) { break }
    if (($sw.ElapsedMilliseconds - $last) -ge 1000) {
      $beat = [pscustomobject]@{ at=(Get-Date).ToUniversalTime().ToString('o'); pid=$PID }
      ($beat | ConvertTo-Json -Compress) | Add-Content -LiteralPath $hb -Encoding UTF8
      $last = $sw.ElapsedMilliseconds
    }
    Start-Sleep -Milliseconds 200
  }
}
finally {
  try { Receive-Job * | Out-Null; Remove-Job * -Force -ErrorAction SilentlyContinue } catch {}
  $stopObj = [pscustomobject]@{ schema='invoker-stopped/v1'; pid=$PID; at=(Get-Date).ToUniversalTime().ToString('o') }
  $stopObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StoppedFile -Encoding UTF8
}
