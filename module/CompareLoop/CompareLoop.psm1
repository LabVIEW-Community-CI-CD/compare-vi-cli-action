# CompareLoop PowerShell module
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CanonicalLVCompare = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'

# Import shared tokenization pattern - navigate up to repo root then to scripts
$moduleDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $moduleDir | Split-Path -Parent
Import-Module (Join-Path $repoRoot 'scripts' 'ArgTokenization.psm1') -Force
Import-Module (Join-Path $repoRoot 'scripts' 'CompareVI.psm1') -Force

function Test-CanonicalCli {
  if (-not (Test-Path -LiteralPath $script:CanonicalLVCompare -PathType Leaf)) {
    throw "LVCompare.exe not found at canonical path: $script:CanonicalLVCompare"
  }
  $script:CanonicalLVCompare
}

function Format-LoopDuration([double]$Seconds) {
  if ($Seconds -lt 1) { return ('{0} ms' -f [math]::Round($Seconds*1000,1)) }
  '{0:N3} s' -f $Seconds
}

# Local quoting helper (aligns with scripts/CompareVI.ps1 behavior)
function Quote($s) {
  if ($null -eq $s) { return '""' }
  if ($s -match '\s|"') { return '"' + ($s -replace '"','\"') + '"' } else { return $s }
}

# Streaming Quantile Approximation (Ring Buffer Reservoir)
# Rationale: Simpler, stable implementation; approximates distribution with bounded memory. Capacity configurable via -StreamCapacity.


function Invoke-IntegrationCompareLoop {
  <#
  .SYNOPSIS
    Run a repeating diff loop (programmatic entry point for testing/automation).
  .DESCRIPTION
  $cleanStreak = 0
  $rebaselinePerformed = $false
  $rebaselineCandidate = $null
    Core loop logic extracted for reuse. Supports dependency injection via -CompareExecutor.
  .PARAMETER Base
    Path to base VI (required unless -SkipValidation & -PassThroughPaths used for unit tests).
  .PARAMETER Head
    Path to head VI (required unless test bypass flags used).
  .PARAMETER CompareExecutor
    ScriptBlock invoked instead of LVCompare: receives -CliPath -Base -Head -Args and returns exit code.
  .PARAMETER BypassCliValidation
    Skips canonical CLI existence check (leave for non-prod scenarios).
  .PARAMETER SkipValidation
    Bypass file presence checks (unit tests with placeholder paths).
  .PARAMETER PassThroughPaths
    Do not resolve paths via Resolve-Path (unit tests / synthetic paths).
  .OUTPUTS
    PSCustomObject with: Succeeded, Iterations, DiffCount, ErrorCount, AverageSeconds, TotalSeconds, Records (array)
  #>
  [CmdletBinding()] param(
    [string]$Base,
    [string]$Head,
  [double]$IntervalSeconds = 5,
    [int]$MaxIterations = 0,
    [switch]$SkipIfUnchanged,
    [string]$JsonLog,
    [string]$LvCompareArgs = '-nobdcosm -nofppos -noattr',
    [switch]$FailOnDiff,
    [switch]$Quiet,
    [switch]$PreviewArgs,
    [scriptblock]$CompareExecutor,
    [switch]$BypassCliValidation,
    [switch]$SkipValidation,
    [switch]$PassThroughPaths,
    [switch]$UseEventDriven,
    [int]$DebounceMilliseconds = 250,
    [ValidateSet('None','Text','Markdown','Html')][string]$DiffSummaryFormat = 'None',
    [string]$DiffSummaryPath,
    [switch]$AdaptiveInterval,
    [double]$MinIntervalSeconds = 1,
    [double]$MaxIntervalSeconds = 30,
    [double]$BackoffFactor = 2.0,
    [int]$RebaselineAfterCleanCount,
    [switch]$ApplyRebaseline,
    [int]$HistogramBins = 5,
    [int]$MetricsSnapshotEvery,
  [string]$MetricsSnapshotPath,
    [switch]$IncludeSnapshotHistogram,
  [ValidateSet('Exact','StreamingP2','StreamingReservoir','Hybrid')][string]$QuantileStrategy = 'Exact',
  [int]$HybridExactThreshold = 500,
  [int]$StreamCapacity = 500,
  [int]$ReconcileEvery = 0
  , [string]$CustomPercentiles
  , [string]$RunSummaryJsonPath
  )

  if (-not $SkipValidation) {
    try {
      if (-not (Test-Path -LiteralPath $Base -PathType Leaf)) { throw "Base VI not found: $Base" }
      if (-not (Test-Path -LiteralPath $Head -PathType Leaf)) { throw "Head VI not found: $Head" }
    } catch { if (-not $Quiet) { Write-Error $_ }; return [pscustomobject]@{ Succeeded=$false; Reason='ValidationFailed'; Error=$_.Exception.Message } }
  }

  if ($PassThroughPaths) {
    $baseAbs = $Base
    $headAbs = $Head
  } else {
    if ($Base) { try { $baseAbs = (Resolve-Path -LiteralPath $Base -ErrorAction Stop).Path } catch { $baseAbs = $Base } } else { $baseAbs = $Base }
    if ($Head) { try { $headAbs = (Resolve-Path -LiteralPath $Head -ErrorAction Stop).Path } catch { $headAbs = $Head } } else { $headAbs = $Head }
  }

  $cli = if ($BypassCliValidation) { $script:CanonicalLVCompare } else { Test-CanonicalCli }

  # Preflight: disallow comparing two VIs with identical filenames in different directories (LVCompare may raise IDE dialog)
  try {
    $baseLeaf = Split-Path -Leaf $baseAbs
    $headLeaf = Split-Path -Leaf $headAbs
    if ($baseLeaf -ieq $headLeaf -and $baseAbs -ne $headAbs) {
      $msg = "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$baseAbs Head=$headAbs"
      if (-not $Quiet) { Write-Error $msg }
      return [pscustomobject]@{ Succeeded=$false; Reason='InvalidInput'; Error=$msg }
    }
  } catch {}

  if ($SkipValidation -and $PassThroughPaths) {
    $prevBaseTime = (Get-Date).ToUniversalTime()
    $prevHeadTime = $prevBaseTime
  } else {
    $prevBaseTime = (Get-Item -LiteralPath $baseAbs).LastWriteTimeUtc
    $prevHeadTime = (Get-Item -LiteralPath $headAbs).LastWriteTimeUtc
  }

  # Build a one-time tokenized args list and command preview (matching per-iteration logic)
  $previewArgsList = @()
  if ($LvCompareArgs) {
    $pattern = Get-LVCompareArgTokenPattern
    $tokens = [regex]::Matches($LvCompareArgs, $pattern) | ForEach-Object { $_.Value }
    foreach ($t in $tokens) {
      $tok = $t.Trim()
      if ($tok.StartsWith('"') -and $tok.EndsWith('"')) { $tok = $tok.Substring(1, $tok.Length-2) }
      elseif ($tok.StartsWith("'") -and $tok.EndsWith("'")) { $tok = $tok.Substring(1, $tok.Length-2) }
      if ($tok) { $previewArgsList += $tok }
    }
    # Normalize combined flag/value tokens and -flag=value
    function Normalize-PathToken([string]$s) {
      if ($null -eq $s) { return $s }
      if ($s -match '^[A-Za-z]:/') { return ($s -replace '/', '\') }
      if ($s -match '^//') { return ($s -replace '/', '\') }
      return $s
    }
    $norm = @(); foreach ($t in $previewArgsList) {
      $tok = $t
      if ($tok.StartsWith('-') -and $tok.Contains('=')) {
        $eq = $tok.IndexOf('=')
        if ($eq -gt 0) {
          $f = $tok.Substring(0, $eq)
          $v = $tok.Substring($eq + 1)
          if ($v.StartsWith('"') -and $v.EndsWith('"')) {
            $v = $v.Substring(1, $v.Length - 2)
          } elseif ($v.StartsWith("'") -and $v.EndsWith("'")) {
            $v = $v.Substring(1, $v.Length - 2)
          }
          if ($f) { $norm += $f }
          if ($v) { $norm += (Normalize-PathToken $v) }
          continue
        }
      }
      if ($tok.StartsWith('-') -and $tok -match '\s+') {
        $sp = $tok.IndexOf(' ')
        if ($sp -gt 0) {
          $f = $tok.Substring(0, $sp)
          $v = $tok.Substring($sp + 1)
          if ($f) { $norm += $f }
          if ($v) { $norm += (Normalize-PathToken $v) }
          continue
        }
      }
      if (-not $tok.StartsWith('-')) { $tok = Normalize-PathToken $tok }
      $norm += $tok
    }
    $previewArgsList = $norm
  }
  $previewCmd = (@(Quote $cli; Quote $baseAbs; Quote $headAbs) + ($previewArgsList | ForEach-Object { Quote $_ })) -join ' '

  if ($PreviewArgs -or $env:LV_PREVIEW -eq '1') {
    if (-not $Quiet) {
      Write-Host 'Preview (no loop execution):' -ForegroundColor Cyan
      Write-Host "  CLI:     $cli" -ForegroundColor Gray
      Write-Host "  Base:    $baseAbs" -ForegroundColor Gray
      Write-Host "  Head:    $headAbs" -ForegroundColor Gray
      Write-Host ("  Tokens:  {0}" -f (($previewArgsList) -join ' | ')) -ForegroundColor Gray
      Write-Host ("  Command: {0}" -f $previewCmd) -ForegroundColor Gray
    }
    $result = [pscustomobject]@{
      Succeeded = $true
      Iterations = 0
      DiffCount = 0
      ErrorCount = 0
      AverageSeconds = 0
      TotalSeconds = 0
      Records = @()
      BasePath = $baseAbs
      HeadPath = $headAbs
      Args = $LvCompareArgs
      Mode = if ($UseEventDriven) { 'Event' } else { 'Polling' }
      Percentiles = [pscustomobject]@{ p50=0; p90=0; p99=0 }
      Histogram = $null
      DiffSummary = $null
      QuantileStrategy = $QuantileStrategy
      StreamingWindowCount = 0
      CliPath = $cli
      Command = $previewCmd
      PreviewArgs = $true
    }
    return $result
  }

  $iteration = 0; $diffCount = 0; $errorCount = 0; $totalSeconds = 0.0
  # Pre-parse custom percentiles so snapshot emission can reference $customList / helper
  $percentiles = $null
  $customList = @()
  if ($CustomPercentiles) {
    try {
      $raw = $CustomPercentiles -split '[, ]+' | Where-Object { $_ -and $_.Trim() -ne '' }
      $vals = @()
      foreach ($token in $raw) {
        $num = $null
        if (-not [double]::TryParse($token, [ref]$num)) { throw "Invalid percentile value '$token'" }
        if ($num -le 0 -or $num -ge 100) { throw "Percentile out of range (0-100 exclusive): $num" }
        $vals += [double]::Parse($token, [Globalization.CultureInfo]::InvariantCulture)
      }
      $customList = $vals | Sort-Object -Unique
      if ($customList.Count -gt 50) { throw "Too many percentile values ($($customList.Count)); max 50" }
    } catch { throw "Failed to parse CustomPercentiles: $_" }
  }
  function New-PercentileObject {
    param([double[]]$SortedSamples,[double[]]$Requested)
    if (-not $SortedSamples -or $SortedSamples.Count -eq 0) { return $null }
    if (-not $Requested -or $Requested.Count -eq 0) { $Requested = @(50,90,99) }
    $o = [ordered]@{}
    function _pctDyn($arr,[double]$p){ $a=@($arr); if($a.Count -eq 0){return 0}; $rank=($p/100.0)*($a.Count-1); $lo=[math]::Floor($rank); $hi=[math]::Ceiling($rank); if($lo -eq $hi){return [math]::Round($a[$lo],3)}; $w=$rank-$lo; [math]::Round(($a[$lo]*(1-$w)+$a[$hi]*$w),3) }
    foreach ($p in $Requested) {
      $label = ('p{0}' -f ($p.ToString('0.###',[Globalization.CultureInfo]::InvariantCulture) -replace '\.','_'))
      if (-not $o.Contains($label)) { $o[$label] = _pctDyn $SortedSamples $p }
    }
    [pscustomobject]$o
  }
  $swOverall = [System.Diagnostics.Stopwatch]::StartNew()
  $records = @()
  # --- Quantile Strategy State ---
  if ($QuantileStrategy -eq 'StreamingP2') {
    if (-not $Quiet) { Write-Warning '[DEPRECATED] QuantileStrategy "StreamingP2" has been renamed to "StreamingReservoir"; it now uses a bounded reservoir approximation.' }
    $QuantileStrategy = 'StreamingReservoir'
  }
  $useStreaming = $QuantileStrategy -eq 'StreamingReservoir'
  $hybridMode = $QuantileStrategy -eq 'Hybrid'
  $streamingActive = $useStreaming

  if ($StreamCapacity -lt 10) { $StreamCapacity = 10 }
  $streamCapacity = $StreamCapacity
  $streamSamples = New-Object System.Collections.Generic.List[double]
  $streamIndex = 0
  function Add-StreamSample([double]$x) {
    if ($streamSamples.Count -lt $streamCapacity) { $null = $streamSamples.Add($x) }
    else { $streamSamples[$streamIndex] = $x; $streamIndex = ($streamIndex + 1) % $streamCapacity }
  }
  function Get-StreamPercentiles {
    if ($streamSamples.Count -eq 0) { return [pscustomobject]@{ p50=0; p90=0; p99=0 } }
    $arr = @($streamSamples.ToArray() | Sort-Object)
    function _pct($a,[double]$p){ if($a.Count -eq 0){return 0}; $rank=($p/100.0)*($a.Count-1); $lo=[math]::Floor($rank); $hi=[math]::Ceiling($rank); if($lo -eq $hi){return [math]::Round($a[$lo],3)}; $w=$rank-$lo; [math]::Round(($a[$lo]*(1-$w)+$a[$hi]*$w),3) }
    [pscustomobject]@{ p50 = (_pct $arr 50); p90 = (_pct $arr 90); p99 = (_pct $arr 99) }
  }
  function Invoke-Reconciliation {
    param([double[]]$all)
    if (-not $all -or $all.Count -eq 0) { return }
    # Rebuild reservoir: uniform subsample up to capacity preserving breadth of distribution
  $streamSamples.Clear(); $script:__tmp=0 # streamIndex reset implicit by reservoir rebuild pattern
    $take = [math]::Min($all.Count, $streamCapacity)
    if ($all.Count -le $streamCapacity) {
      foreach ($v in $all) { $null = $streamSamples.Add([double]$v) }
      return
    }
    $step = $all.Count / $take
    for ($i=0; $i -lt $take; $i++) {
      $idx = [int]([math]::Floor($i * $step))
      if ($idx -ge $all.Count) { $idx = $all.Count - 1 }
      $null = $streamSamples.Add([double]$all[$idx])
    }
  }
  $hybridExactSamples = @()
  # Re-baseline state tracking
  $cleanStreak = 0
  $rebaselinePerformed = $false
  $rebaselineCandidate = $null

  $watchers = @()
  $eventSourceId = "CompareLoopChanged_$([guid]::NewGuid().ToString('N'))"
  if ($UseEventDriven) {
    if ($SkipValidation -or $PassThroughPaths) {
      if (-not $Quiet) { Write-Warning 'UseEventDriven ignored because validation is skipped or paths are synthetic.' }
      $UseEventDriven = $false
    } else {
      try {
        $baseDir = Split-Path -LiteralPath $baseAbs -Parent
        $headDir = Split-Path -LiteralPath $headAbs -Parent
        $dirs = @($baseDir, $headDir | Sort-Object -Unique)
        foreach ($d in ($dirs | Sort-Object -Unique)) {
          $fsw = [System.IO.FileSystemWatcher]::new($d)
          $fsw.IncludeSubdirectories = $false
          $fsw.EnableRaisingEvents = $true
          Register-ObjectEvent -InputObject $fsw -EventName Changed -SourceIdentifier $eventSourceId | Out-Null
          Register-ObjectEvent -InputObject $fsw -EventName Created -SourceIdentifier $eventSourceId | Out-Null
          Register-ObjectEvent -InputObject $fsw -EventName Renamed -SourceIdentifier $eventSourceId | Out-Null
          $watchers += $fsw
        }
        if (-not $Quiet) { Write-Verbose "Event-driven mode enabled. Watching: $($watchers.Count) directory(ies)." }
      } catch {
        if (-not $Quiet) { Write-Warning "Failed to initialize FileSystemWatcher; reverting to polling. $_" }
        $UseEventDriven = $false
      }
    }
  }

  $currentInterval = [double]$IntervalSeconds
  if ($AdaptiveInterval) {
    if ($currentInterval -lt $MinIntervalSeconds) { $currentInterval = $MinIntervalSeconds }
  }

  try {
    while ($true) {
    if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) { break }
    $iteration++
    $skipReason = $null

    if ($SkipValidation -and $PassThroughPaths) {
      $now = (Get-Date).ToUniversalTime()
      $baseInfo = [pscustomobject]@{ LastWriteTimeUtc = $now }
      $headInfo = [pscustomobject]@{ LastWriteTimeUtc = $now }
      $baseChanged = $true; $headChanged = $true
    } else {
      $baseInfo = Get-Item -LiteralPath $baseAbs
      $headInfo = Get-Item -LiteralPath $headAbs
      $baseChanged = $baseInfo.LastWriteTimeUtc -ne $prevBaseTime
      $headChanged = $headInfo.LastWriteTimeUtc -ne $prevHeadTime
    }

    if ($UseEventDriven) {
      # Drain events and determine if relevant file changed
      $relevant = $false
      $received = @()
      $timer = [System.Diagnostics.Stopwatch]::StartNew()
      # First wait (blocking) only if no immediate changed detection from timestamps (we still rely on event)
      $initialEvent = Wait-Event -SourceIdentifier $eventSourceId -Timeout 0.01 -ErrorAction SilentlyContinue
      if (-not $initialEvent) {
        # Short wait equal to IntervalSeconds for event; treat absence as skip
        $initialEvent = Wait-Event -SourceIdentifier $eventSourceId -Timeout $IntervalSeconds -ErrorAction SilentlyContinue
      }
      if ($initialEvent) { $received += $initialEvent }
      # Debounce window: gather additional events
      while ($timer.ElapsedMilliseconds -lt $DebounceMilliseconds) {
        $more = Wait-Event -SourceIdentifier $eventSourceId -Timeout 0.01 -ErrorAction SilentlyContinue
        if ($more) { $received += $more } else { Start-Sleep -Milliseconds 5 }
      }
      foreach ($ev in $received) { Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue }
      if ($received.Count -gt 0) {
        # We cannot rely on event args easily without casting; re-check timestamps below
        $relevant = $true
      }
      if (-not $relevant) { $skipReason = 'no-change-event' }
    }

    if (-not $UseEventDriven) {
      if ($SkipIfUnchanged -and -not ($baseChanged -or $headChanged)) { $skipReason = 'unchanged' }
    }


    $diff = $false; $exitCode = $null; $durationSeconds = 0.0; $status = 'SKIPPED'
    if (-not $skipReason) {
      $status = 'OK'
      $iterationSw = [System.Diagnostics.Stopwatch]::StartNew()
      $argsList = @()
      if ($LvCompareArgs) {
        $pattern = Get-LVCompareArgTokenPattern
        $tokens = [regex]::Matches($LvCompareArgs, $pattern) | ForEach-Object { $_.Value }
        foreach ($t in $tokens) {
          $tok = $t.Trim()
          if ($tok.StartsWith('"') -and $tok.EndsWith('"')) { $tok = $tok.Substring(1, $tok.Length-2) }
          elseif ($tok.StartsWith("'") -and $tok.EndsWith("'")) { $tok = $tok.Substring(1, $tok.Length-2) }
          if ($tok) { $argsList += $tok }
        }
        # Normalize combined flag/value tokens and -flag=value
        function Normalize-PathToken([string]$s) {
          if ($null -eq $s) { return $s }
          if ($s -match '^[A-Za-z]:/') { return ($s -replace '/', '\') }
          if ($s -match '^//') { return ($s -replace '/', '\') }
          return $s
        }
        $norm = @(); foreach ($t in $argsList) {
          $tok = $t
          if ($tok.StartsWith('-') -and $tok.Contains('=')) { $eq=$tok.IndexOf('='); if ($eq -gt 0){ $f=$tok.Substring(0,$eq); $v=$tok.Substring($eq+1); if ($v.StartsWith('"') -and $v.EndsWith('"')){ $v=$v.Substring(1,$v.Length-2)} elseif ($v.StartsWith("'") -and $v.EndsWith("'")){ $v=$v.Substring(1,$v.Length-2)}; if($f){$norm+=$f}; if($v){$norm+=(Normalize-PathToken $v)}; continue } }
          if ($tok.StartsWith('-') -and $tok -match '\s+') { $sp=$tok.IndexOf(' '); if ($sp -gt 0){ $f=$tok.Substring(0,$sp); $v=$tok.Substring($sp+1); if($f){$norm+=$f}; if($v){$norm+=(Normalize-PathToken $v)}; continue } }
          if (-not $tok.StartsWith('-')) { $tok = Normalize-PathToken $tok }
          $norm += $tok
        }
        $argsList = $norm
      }
      $resultDiff = $null
      $compareResult = $null
      if ($CompareExecutor) {
        # Invoke executor positionally to avoid parameter name coupling.
        $exitCode = & $CompareExecutor $cli $baseAbs $headAbs $argsList
      } else {
        try {
          $compareParams = @{
            Base = $baseAbs
            Head = $headAbs
            FailOnDiff = $false
          }
          if ($LvCompareArgs) { $compareParams.LvCompareArgs = $LvCompareArgs }
          $compareResult = Invoke-CompareVI @compareParams
          $exitCode = [int]$compareResult.ExitCode
          $resultDiff = [bool]$compareResult.Diff
        } catch {
          if (-not $Quiet) { Write-Verbose ("Invoke-CompareVI failed: {0}" -f $_) }
          $exitCode = -999
          try {
            $msg = $_.Exception.Message
            if ($msg -match 'exit code\s+(-?\d+)') { $exitCode = [int]$Matches[1] }
          } catch {}
          $status = 'ERROR'
        }
      }
      $iterationSw.Stop()
      if ($compareResult -and $compareResult.CompareDurationSeconds -gt 0) {
        $durationSeconds = [math]::Round([double]$compareResult.CompareDurationSeconds,3)
      } else {
        $durationSeconds = [math]::Round($iterationSw.Elapsed.TotalSeconds,3)
      }
      $totalSeconds += $durationSeconds
      switch ($exitCode) {
        0 { $diff = $false }
        1 {
          $diff = if ($null -ne $resultDiff) { $resultDiff } else { $true }
          if ($diff) { $diffCount++ }
          else {
            $status = 'ERROR'
            $errorCount++
          }
        }
        default { $status = 'ERROR'; $errorCount++ }
      }
      if ($durationSeconds -gt 0) {
        if ($hybridMode -and -not $streamingActive) {
          $hybridExactSamples += $durationSeconds
          if ($iteration -ge $HybridExactThreshold) { foreach ($s in $hybridExactSamples) { Add-StreamSample -x $s }; $hybridExactSamples=@(); $streamingActive=$true }
        } elseif ($streamingActive) { Add-StreamSample -x $durationSeconds }
      }
    }

    $record = [pscustomobject]@{
      iteration = $iteration
      diff = $diff
      exitCode = $exitCode
      status = $status
      durationSeconds = $durationSeconds
      skipped = [bool]$skipReason
      skipReason = $skipReason
      baseChanged = $baseChanged
      headChanged = $headChanged
    }
    $records += $record
    $prevBaseTime = $baseInfo.LastWriteTimeUtc
    $prevHeadTime = $headInfo.LastWriteTimeUtc

    if (-not $UseEventDriven) {
      if ($AdaptiveInterval) {
        if ($diff -or $status -eq 'ERROR' -or -not $skipReason) {
          # Reset interval to baseline on activity
          $currentInterval = [math]::Max($MinIntervalSeconds, $IntervalSeconds)
        } else {
          # Backoff on quiet iteration
            $currentInterval = [math]::Min($MaxIntervalSeconds, [math]::Ceiling($currentInterval * $BackoffFactor * 1000.0)/1000.0)
        }
        if ($currentInterval -ge 1) {
          Start-Sleep -Seconds ([int][math]::Floor($currentInterval))
          $remainder = $currentInterval - [math]::Floor($currentInterval)
          if ($remainder -gt 0) { Start-Sleep -Milliseconds ([int]([math]::Round($remainder*1000))) }
        } elseif ($currentInterval -gt 0) {
          Start-Sleep -Milliseconds ([int]([math]::Round($currentInterval*1000)))
        }
      } else {
        if ($IntervalSeconds -gt 0) {
          if ($IntervalSeconds -ge 1) {
            Start-Sleep -Seconds ([int][math]::Floor($IntervalSeconds))
            $rem = $IntervalSeconds - [math]::Floor($IntervalSeconds)
            if ($rem -gt 0) { Start-Sleep -Milliseconds ([int]([math]::Round($rem*1000))) }
          } else {
            Start-Sleep -Milliseconds ([int]([math]::Round($IntervalSeconds*1000)))
          }
        }
      }
    }
    if (-not $diff -and $status -ne 'ERROR' -and -not $skipReason) {
      $cleanStreak++
    } elseif ($diff) {
      $cleanStreak = 0
    }

    if (-not $rebaselinePerformed -and $RebaselineAfterCleanCount -gt 0) {
      if ($cleanStreak -ge $RebaselineAfterCleanCount) {
        $rebaselineCandidate = [pscustomobject]@{ TriggerIteration=$iteration; CleanStreak=$cleanStreak }
        if ($ApplyRebaseline) {
          $prevBaseTime = $headInfo.LastWriteTimeUtc
          $rebaselinePerformed = $true
        }
      }
    }
    if ($FailOnDiff -and $diff) { break }
    if ($ReconcileEvery -gt 0 -and $streamingActive -and ($iteration % $ReconcileEvery -eq 0)) {
      try {
        $durAll = @($records | Where-Object { $_.durationSeconds -gt 0 } | Select-Object -ExpandProperty durationSeconds)
        Invoke-Reconciliation -all $durAll
      } catch { if (-not $Quiet) { Write-Verbose "Reconciliation failed: $_" } }
    }
    # Metrics snapshot emission (JSON lines) if configured (per iteration)
    if ($MetricsSnapshotEvery -gt 0 -and $MetricsSnapshotPath) {
      if ($iteration % $MetricsSnapshotEvery -eq 0) {
        try {
          $avgSoFar = if ($iteration -gt 0) { [math]::Round($totalSeconds / $iteration,3) } else { 0 }
          $snap = [pscustomobject]@{
            iteration      = $iteration
            diffCount      = $diffCount
            errorCount     = $errorCount
            totalSeconds   = [math]::Round($swOverall.Elapsed.TotalSeconds,3)
            averageSeconds = $avgSoFar
            p50 = $null; p90 = $null; p99 = $null
            timestamp      = (Get-Date).ToString('o')
            schema         = 'metrics-snapshot-v2'
            quantileStrategy = $QuantileStrategy
            requestedPercentiles = $null
            percentiles = $null
            histogram = $null
          }
          # Build current duration sample set for snapshot-specific percentile/histogram generation
          $durSamplesIter = @($records | Where-Object { $_.durationSeconds -gt 0 } | Select-Object -ExpandProperty durationSeconds)
          $sortedIter = @()
          if ($durSamplesIter.Count -gt 0) { $sortedIter = @($durSamplesIter | Sort-Object) }
          if ($sortedIter.Count -gt 0) {
            # Legacy fixed percentiles
            function _pctSnap($a,[double]$p){ if($a.Count -eq 0){return 0}; $rank=($p/100.0)*($a.Count-1); $lo=[math]::Floor($rank); $hi=[math]::Ceiling($rank); if($lo -eq $hi){return [math]::Round($a[$lo],3)}; $w=$rank-$lo; [math]::Round(($a[$lo]*(1-$w)+$a[$hi]*$w),3) }
            $snap.p50 = _pctSnap $sortedIter 50
            $snap.p90 = _pctSnap $sortedIter 90
            $snap.p99 = _pctSnap $sortedIter 99
            # Dynamic percentile object
            $dyn = New-PercentileObject -SortedSamples $sortedIter -Requested $customList
            if ($dyn) {
              $snap.percentiles = $dyn
              if ($customList -and $customList.Count -gt 0) { $snap.requestedPercentiles = @($customList) } else { $snap.requestedPercentiles = @(50,90,99) }
            }
            if ($IncludeSnapshotHistogram -and $HistogramBins -gt 0) {
              try {
                $min=[math]::Floor(($sortedIter | Measure-Object -Minimum).Minimum)
                $max=[math]::Ceiling(($sortedIter | Measure-Object -Maximum).Maximum)
                if ($max -le $min) { $max = $min + 1 }
                $bins = [math]::Max(1,$HistogramBins)
                $width = ($max - $min)/$bins; if ($width -le 0) { $width = 1 }
                $ranges = for ($i=0;$i -lt $bins;$i++){ [pscustomobject]@{ index=$i; start=[math]::Round($min+$i*$width,3); end=[math]::Round($min+($i+1)*$width,3); count=0 } }
                foreach ($v in $sortedIter) {
                  $idx = [math]::Floor(([double]($v-$min)) / $width); if ($idx -ge $bins) { $idx = $bins-1 }
                  $ranges[$idx].count++
                }
                $snap.histogram = $ranges
              } catch {}
            }
          }
          $dir = Split-Path -Parent $MetricsSnapshotPath
          if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
          # Emit NDJSON (one compact JSON object per line)
          $json = $snap | ConvertTo-Json -Depth 3 -Compress
          if (-not $json) { $json = ($snap | ConvertTo-Json -Depth 3) -replace "`r?`n","" }
          Add-Content -Path $MetricsSnapshotPath -Value $json -Encoding utf8
        } catch { if (-not $Quiet) { Write-Warning "Failed to write metrics snapshot: $_" } }
      }
    }
  }
  } finally {
    foreach ($w in $watchers) { try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch {} }
    Unregister-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue | Out-Null
    Get-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
  }

  $swOverall.Stop()
  $avg = if ($iteration -gt 0) { [math]::Round($totalSeconds / $iteration,3) } else { 0 }

  # Derive samples for metrics (exclude zero-duration iterations so skip records don't skew stats)
  $durSamples = @($records | Where-Object { $_.durationSeconds -gt 0 } | Select-Object -ExpandProperty durationSeconds)

  if ($streamingActive -and ($useStreaming -or $hybridMode)) {
    # Build sorted array from reservoir for percentile computation
    if ($streamSamples.Count -gt 0) {
      $arrStream = @($streamSamples.ToArray() | Sort-Object)
      $percentiles = New-PercentileObject -SortedSamples $arrStream -Requested $customList
    }
  } elseif ($durSamples.Count -gt 0) {
      $sorted = @($durSamples | Sort-Object)
      $percentiles = New-PercentileObject -SortedSamples $sorted -Requested $customList
  }
  if (-not $percentiles) {
    # Ensure a stable object shape so downstream output handling does not break when no samples >0
    $percentiles = [pscustomobject]@{ p50 = 0; p90 = 0; p99 = 0 }
  }

  $histogram = $null
  if ($durSamples.Count -gt 0 -and $HistogramBins -gt 0) {
    $min=[math]::Floor(($durSamples | Measure-Object -Minimum).Minimum)
    $max=[math]::Ceiling(($durSamples | Measure-Object -Maximum).Maximum)
    if ($max -le $min) { $max = $min + 1 }
    $bins = [math]::Max(1,$HistogramBins)
    $width = ($max - $min)/$bins
    if ($width -le 0) { $width = 1 }
    $ranges = for ($i=0;$i -lt $bins;$i++){ [pscustomobject]@{ Index=$i; Start=[math]::Round($min+$i*$width,3); End=[math]::Round($min+($i+1)*$width,3); Count=0 } }
    foreach ($v in $durSamples) {
      $idx = [math]::Floor(([double]($v-$min)) / $width)
      if ($idx -ge $bins) { $idx = $bins-1 }
      $ranges[$idx].Count++
    }
    $histogram = $ranges
  }

  $result = [pscustomobject]@{
    Succeeded = ($errorCount -eq 0)
    Iterations = $iteration
    DiffCount = $diffCount
    ErrorCount = $errorCount
    AverageSeconds = $avg
    TotalSeconds = [math]::Round($swOverall.Elapsed.TotalSeconds,3)
    Records = $records
    BasePath = $baseAbs
    HeadPath = $headAbs
    Args = $LvCompareArgs
    Mode = if ($UseEventDriven) { 'Event' } else { 'Polling' }
  Percentiles = $percentiles
    Histogram = $histogram
    DiffSummary = $null
    QuantileStrategy = $QuantileStrategy
    StreamingWindowCount = if ($streamingActive) { $streamSamples.Count } else { 0 }
  }
  if ($result.DiffCount -gt 0 -and $DiffSummaryFormat -ne 'None') {
    $summary = switch ($DiffSummaryFormat) {
      'Text' { "Diffs detected: $($result.DiffCount) between `nBase: $($result.BasePath)`nHead: $($result.HeadPath)" }
      'Markdown' { "### VI Compare Diff Summary\n\n*Base:* `$($result.BasePath)`  \n*Head:* `$($result.HeadPath)`  \n**Diff Iterations:** $($result.DiffCount)  \n**Total Iterations:** $($result.Iterations)" }
      'Html' { "<h3>VI Compare Diff Summary</h3><ul><li><b>Base:</b> $([System.Web.HttpUtility]::HtmlEncode($result.BasePath))</li><li><b>Head:</b> $([System.Web.HttpUtility]::HtmlEncode($result.HeadPath))</li><li><b>Diff Iterations:</b> $($result.DiffCount)</li><li><b>Total Iterations:</b> $($result.Iterations)</li></ul>" }
    }
    $result.DiffSummary = $summary
    if ($DiffSummaryPath) {
      try {
        $targetPath = (Resolve-Path -LiteralPath $DiffSummaryPath -ErrorAction SilentlyContinue)
        if (-not $targetPath) { $targetPath = $DiffSummaryPath }
        [IO.File]::WriteAllText($targetPath, $summary)
      } catch { if (-not $Quiet) { Write-Warning "Failed to write diff summary: $_" } }
    }
  }
  # Attach rebaseline metadata then output once
  Add-Member -InputObject $result -NotePropertyName RebaselineCandidate -NotePropertyValue $rebaselineCandidate -Force
  Add-Member -InputObject $result -NotePropertyName RebaselineApplied -NotePropertyValue $rebaselinePerformed -Force

  # Optional final run summary JSON emission (schema: compare-loop-run-summary-v1)
  if ($RunSummaryJsonPath) {
    try {
      $dir = Split-Path -Parent $RunSummaryJsonPath
      if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      $reqPct = @()
      if ($CustomPercentiles) { $reqPct = @($customList) } else { $reqPct = @(50,90,99) }
      $summary = [pscustomobject]@{
        schema = 'compare-loop-run-summary-v1'
        timestamp = (Get-Date).ToString('o')
        iterations = $result.Iterations
        diffCount = $result.DiffCount
        errorCount = $result.ErrorCount
        averageSeconds = $result.AverageSeconds
        totalSeconds = $result.TotalSeconds
        quantileStrategy = $result.QuantileStrategy
        requestedPercentiles = $reqPct
        percentiles = $result.Percentiles
        histogram = $histogram
        mode = $result.Mode
        basePath = $result.BasePath
        headPath = $result.HeadPath
        rebaselineApplied = $result.RebaselineApplied
        rebaselineCandidate = $result.RebaselineCandidate
      }
      $json = $summary | ConvertTo-Json -Depth 6
      [IO.File]::WriteAllText($RunSummaryJsonPath, $json, [Text.Encoding]::UTF8)
    } catch {
      if (-not $Quiet) { Write-Warning "Failed to write run summary JSON: $_" }
    }
  }

  $result
}

Export-ModuleMember -Function Invoke-IntegrationCompareLoop, Test-CanonicalCli, Format-LoopDuration
