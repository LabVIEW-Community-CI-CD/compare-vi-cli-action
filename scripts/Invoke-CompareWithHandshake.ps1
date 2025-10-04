param(
  [Parameter(Mandatory)][string]$Base,
  [Parameter(Mandatory)][string]$Head,
  [string]$LvCompareArgs = '',
  [int]$PreWaitMs = 150,
  [int]$PostWaitMs = 500,
  [int]$SettlePolls = 4,
  [int]$SettleIntervalMs = 250,
  [int]$StartTimeoutMs = 15000,
  [int]$ExitTimeoutMs = 15000,
  [int]$QuiescentTimeoutMs = 5000,
  [switch]$CanonicalOnly,
  [string]$MutexName,
  [int]$BufferMax = 64,
  [switch]$ForceCleanup,
  [switch]$CleanupOnError,
  [string]$OutputJson,
  [string]$GitHubOutputPath,
  [switch]$Simulate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProcCount([string]$name) { try { (Get-Process -Name $name -ErrorAction SilentlyContinue | Measure-Object).Count } catch { 0 } }

function Get-LVCompareCount {
  param([switch]$CanonicalOnly)
  try {
    $procs = Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue
    if (-not $procs) { return 0 }
    if (-not $CanonicalOnly) { return (@($procs).Count) }
    $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
    return (@($procs | Where-Object { $_.Path -eq $canonical }).Count)
  } catch { 0 }
}

function Get-StringHashHex([string]$s) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  try {
    $hash = $sha1.ComputeHash($bytes)
  } finally { $sha1.Dispose() }
  -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function New-MutexName([string]$base,[string]$head) {
  $b = (Resolve-Path $base -ErrorAction Stop).Path
  $h = (Resolve-Path $head -ErrorAction Stop).Path
  $key = "$b:::$h"
  $hex = Get-StringHashHex $key
  return "Global/CompareVI-LV-$($hex.Substring(0,16))"
}

# 4-wire handshake signals (conceptual):
# - pre-run wait (wire 1)
# - LVCompare start observed (wire 2)
# - LVCompare exit observed (wire 3)
# - quiescent LabVIEW observed (wire 4)

try {
Add-Type -TypeDefinition @"
using System;
using System.Threading;
public static class NamedMutexGate {
  public static IDisposable Enter(string name, int timeoutMs) {
    bool created;
    var m = new Mutex(false, name, out created);
    if (!m.WaitOne(timeoutMs)) throw new TimeoutException($"Failed to acquire mutex: {name}");
    return m;
  }
}
"@
} catch { }

[IDisposable]$gate = $null
$acquireMs = 0
$phase = 'init'
$startSeenTimeout = $false
$exitSeenTimeout = $false
$quiescentTimeout = $false
$cleanup = @{ attempted=$false; stoppedLVCompare=0; stoppedLabVIEW=0 }
$compareJob = $null
$compareOutput = $null
$compareError = $null
try {
  if (-not $MutexName -or [string]::IsNullOrWhiteSpace($MutexName)) { $MutexName = New-MutexName -base $Base -head $Head }
  $tAcquire = [System.Diagnostics.Stopwatch]::StartNew()
  $gate = [NamedMutexGate]::Enter($MutexName, 10000)
  $tAcquire.Stop(); $acquireMs = [int]$tAcquire.ElapsedMilliseconds
  Start-Sleep -Milliseconds ([Math]::Max(0,$PreWaitMs))
  $lvBefore = Get-ProcCount 'LabVIEW'
  $lvcBefore = Get-LVCompareCount -CanonicalOnly:$CanonicalOnly.IsPresent

  $compare = Join-Path $PSScriptRoot 'CompareVI.ps1'
  if (-not (Test-Path -LiteralPath $compare)) { $compare = (Resolve-Path (Join-Path $PSScriptRoot 'CompareVI.ps1')).Path }

  # Run compare and track LVCompare transient
  $lvcompareSeen = $false
  $lvcompareGone = $false

  $phase = 'spawn'
  # Support simulation mode (no real CLI), controlled by env LOOP_SIMULATE
  if ($Simulate -or $env:LOOP_SIMULATE -eq '1') {
    # Simulate minimal outputs; prefer configured GitHubOutputPath if provided
    $code = 0
    [void][int]::TryParse($env:LOOP_SIMULATE_EXIT_CODE, [ref]$code)
    if ($GitHubOutputPath) {
      try { @(
        "exitCode=$code",
        "cliPath=C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe",
        "command=$Base $Head $LvCompareArgs",
        "diff=" + ($(if ($code -eq 1) { 'true' } else { 'false' }))
      ) | Set-Content -Path $GitHubOutputPath -Encoding utf8 } catch {}
    }
    # Still build observation buffer with a couple of synthetic samples
    $bufMax = [Math]::Max(4,[Math]::Min([int]::MaxValue,[int]$BufferMax))
    $obs = New-Object System.Collections.Generic.Queue[object]
    function Add-Obs([int]$ms,[int]$lv,[int]$lvc) {
      $obj = [pscustomobject]@{ tms=$ms; labview=$lv; lvcompare=$lvc }
      $obs.Enqueue($obj)
      while ($obs.Count -gt $bufMax) { [void]$obs.Dequeue() }
    }
    Add-Obs 0 (Get-ProcCount 'LabVIEW') 0; Add-Obs 50 (Get-ProcCount 'LabVIEW') 0
    $compareOutput = "[simulated] exitCode=$code"

    # Emit a minimal, consistent result and return early
    $result = [pscustomobject]@{
      schema = 'compare-handshake-v1'
      base = (Resolve-Path $Base).Path
      head = (Resolve-Path $Head).Path
      lvCompareArgs = $LvCompareArgs
      pre = @{ LabVIEW=(Get-ProcCount 'LabVIEW'); LVCompare=0 }
      observed = @{ lvcompareSeen=$false; lvcompareGone=$true }
      post = @{ LabVIEW=(Get-ProcCount 'LabVIEW'); LVCompare=0 }
      quiescent = $true
      mutex = $MutexName
      timings = @{ preWaitMs=$PreWaitMs; postWaitMs=$PostWaitMs; settlePolls=$SettlePolls; settleIntervalMs=$SettleIntervalMs; startTimeoutMs=$StartTimeoutMs; exitTimeoutMs=$ExitTimeoutMs; quiescentTimeoutMs=$QuiescentTimeoutMs; acquireMs=$acquireMs }
      timeouts = @{ start=$false; exit=$false; quiescent=$false }
      phase = 'simulate'
      compare = @{ output=$compareOutput; error=$null }
      buffer = @($obs)
    }
    if ($OutputJson) {
      try { ($result | ConvertTo-Json -Depth 6) | Set-Content -Path $OutputJson -Encoding utf8 } catch {}
    }
    return $result
  }
  else {
    $compareJob = Start-Job -ScriptBlock {
      param($compare,$Base,$Head,$LvCompareArgs,$GitHubOutputPath)
      try {
        $env:COMPARE_BYPASS_HANDSHAKE = '1'
        pwsh -NoLogo -NoProfile -File $compare -Base $Base -Head $Head -LvCompareArgs $LvCompareArgs -FailOnDiff:$false -GitHubOutputPath $GitHubOutputPath | Out-String
      } catch {
        "[compare-job-error] $($_.Exception.Message)"
      }
    } -ArgumentList $compare,$Base,$Head,$LvCompareArgs,$GitHubOutputPath
  }

  # Bounded observation buffer for debounce and post-mortem
  $bufMax = [Math]::Max(4,[Math]::Min([int]::MaxValue,[int]$BufferMax))
  $obs = New-Object System.Collections.Generic.Queue[object]
  function Add-Obs([int]$ms,[int]$lv,[int]$lvc) {
    $obj = [pscustomobject]@{ tms=$ms; labview=$lv; lvcompare=$lvc }
    $obs.Enqueue($obj)
    while ($obs.Count -gt $bufMax) { [void]$obs.Dequeue() }
  }

  $t0 = [DateTime]::UtcNow

  # Observe LVCompare start within timeout (debounced: require two consecutive positives)
  $startDeadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(500,$StartTimeoutMs))
  $startConsec = 0
  $phase = 'start-detect'
  while ([DateTime]::UtcNow -lt $startDeadline) {
    $lvCnt = Get-ProcCount 'LabVIEW'
    $lvcCnt = Get-LVCompareCount -CanonicalOnly:$CanonicalOnly.IsPresent
    Add-Obs (([DateTime]::UtcNow - $t0).TotalMilliseconds) [int]$lvCnt [int]$lvcCnt
    if ($lvcCnt -gt 0) { $startConsec++ } else { $startConsec = 0 }
    if ($startConsec -ge 2) { $lvcompareSeen = $true; break }
    $js = (Get-Job $compareJob).State
    if ($js -eq 'Failed' -or $js -eq 'Completed') { break }
    Start-Sleep -Milliseconds (50 + (Get-Random -Minimum 0 -Maximum 15))
  }
  if (-not $lvcompareSeen) { $startSeenTimeout = $true }

  # Observe LVCompare exit within timeout (debounced: require two consecutive zeros)
  $exitDeadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(500,$ExitTimeoutMs))
  $exitConsecZero = 0
  $phase = 'exit-detect'
  while ([DateTime]::UtcNow -lt $exitDeadline) {
    $lvCnt = Get-ProcCount 'LabVIEW'
    $lvcCnt = Get-LVCompareCount -CanonicalOnly:$CanonicalOnly.IsPresent
    Add-Obs (([DateTime]::UtcNow - $t0).TotalMilliseconds) [int]$lvCnt [int]$lvcCnt
    if ($lvcCnt -eq 0) { $exitConsecZero++ } else { $exitConsecZero = 0 }
    if ($lvcompareSeen -and $exitConsecZero -ge 2) { $lvcompareGone = $true; break }
    if ((Get-Job $compareJob).State -in 'Completed','Failed') { }
    Start-Sleep -Milliseconds (50 + (Get-Random -Minimum 0 -Maximum 15))
  }
  if (-not $lvcompareGone) { $exitSeenTimeout = $true }

  $phase = 'receive'
  if ($compareJob) {
    try { $compareOutput = Receive-Job -Job $compareJob -Wait -ErrorAction SilentlyContinue } catch { $compareError = $_.Exception.Message }
    finally { try { Remove-Job -Job $compareJob -Force -ErrorAction SilentlyContinue } catch {} }
  }

  Start-Sleep -Milliseconds ([Math]::Max(0,$PostWaitMs))

  # Quiescent check: N stable polls within an overall timeout (debounced using the same buffer)
  $stable = $true
  $prev = Get-ProcCount 'LabVIEW'
  $qDeadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max($SettlePolls*$SettleIntervalMs, $QuiescentTimeoutMs))
  $polls = 0
  $phase = 'quiescent'
  while ($polls -lt $SettlePolls -and [DateTime]::UtcNow -lt $qDeadline) {
    Start-Sleep -Milliseconds $SettleIntervalMs
    $cur = Get-ProcCount 'LabVIEW'
    Add-Obs (([DateTime]::UtcNow - $t0).TotalMilliseconds) [int]$cur (Get-LVCompareCount -CanonicalOnly:$CanonicalOnly.IsPresent)
    if ($cur -ne $prev) { $stable = $false; $prev = $cur; $polls = 0 } else { $polls++ }
  }
  if ($polls -lt $SettlePolls) { $quiescentTimeout = $true }

  $result = [pscustomobject]@{
    schema = 'compare-handshake-v1'
    base = (Resolve-Path $Base).Path
    head = (Resolve-Path $Head).Path
    lvCompareArgs = $LvCompareArgs
    pre = @{ LabVIEW=$lvBefore; LVCompare=$lvcBefore }
    observed = @{ lvcompareSeen=$lvcompareSeen; lvcompareGone=$lvcompareGone }
    post = @{ LabVIEW=(Get-ProcCount 'LabVIEW'); LVCompare=(Get-LVCompareCount -CanonicalOnly:$CanonicalOnly.IsPresent) }
    quiescent = $stable
    mutex = $MutexName
    timings = @{ preWaitMs=$PreWaitMs; postWaitMs=$PostWaitMs; settlePolls=$SettlePolls; settleIntervalMs=$SettleIntervalMs; startTimeoutMs=$StartTimeoutMs; exitTimeoutMs=$ExitTimeoutMs; quiescentTimeoutMs=$QuiescentTimeoutMs; acquireMs=$acquireMs }
    timeouts = @{ start=$startSeenTimeout; exit=$exitSeenTimeout; quiescent=$quiescentTimeout }
    phase = $phase
    compare = @{ output=$compareOutput; error=$compareError }
    buffer = @($obs)
  }

  if ($OutputJson) {
    try { ($result | ConvertTo-Json -Depth 6) | Set-Content -Path $OutputJson -Encoding utf8 } catch {}
  }

  $result
}
finally {
  $shouldCleanup = $false
  if ($ForceCleanup) { $shouldCleanup = $true }
  elseif ($CleanupOnError) {
    # Trigger cleanup only when handshake observed problematic conditions
    if ($startSeenTimeout -or $exitSeenTimeout -or $quiescentTimeout) { $shouldCleanup = $true }
    # Also cleanup if compare job reported an error string
    if (-not $shouldCleanup -and ($compareError -and -not [string]::IsNullOrWhiteSpace($compareError))) { $shouldCleanup = $true }
  }
  if ($shouldCleanup) {
    $cleanup.attempted = $true
    # Try to dot-source cleanup helpers
    try {
      $clean = Join-Path $PSScriptRoot 'Ensure-LVCompareClean.ps1'
      if (Test-Path -LiteralPath $clean) { . $clean }
    } catch {}
    try { if (Get-Command Stop-LVCompareProcesses -ErrorAction SilentlyContinue) { $cleanup.stoppedLVCompare = Stop-LVCompareProcesses -Quiet } } catch {}
    try { if (Get-Command Stop-LabVIEWProcesses -ErrorAction SilentlyContinue) { $cleanup.stoppedLabVIEW = Stop-LabVIEWProcesses -Quiet } } catch {}
  }
  if ($null -ne $gate) { try { $gate.Dispose() } catch {} }
}