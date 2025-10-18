# Function-only module for testing (no parameter block or auto-run)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared tokenization pattern
Import-Module (Join-Path $PSScriptRoot 'ArgTokenization.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CompareVI.psm1') -Force

$canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
function Test-CanonicalCli {
  param(
    [ValidateSet('Auto','x64','x86')] [string]$PreferredBitness = 'Auto'
  )
  return Resolve-Cli -PreferredBitness $PreferredBitness
}
function Format-Duration([double]$seconds) { if ($seconds -lt 1) { return ('{0} ms' -f [math]::Round($seconds*1000,1)) }; return ('{0:N3} s' -f $seconds) }
function Invoke-IntegrationCompareLoop {
  [CmdletBinding()]param(
    [string]$Base,
    [string]$Head,
    [int]$IntervalSeconds = 5,
    [int]$MaxIterations = 0,
    [switch]$SkipIfUnchanged,
    [string]$JsonLog,
    [string]$LvCompareArgs = '-nobdcosm -nofppos -noattr',
    [ValidateSet('Auto','x64','x86')][string]$LvCompareBitness = 'Auto',
    [switch]$FailOnDiff,
    [switch]$Quiet,
    [scriptblock]$CompareExecutor,
    [switch]$BypassCliValidation,
    [switch]$SkipValidation,
    [switch]$PassThroughPaths
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
  $cli = if ($BypassCliValidation) { $canonical } else { Test-CanonicalCli -PreferredBitness $LvCompareBitness }
  if ($SkipValidation -and $PassThroughPaths) {
    $prevBaseTime = (Get-Date).ToUniversalTime()
    $prevHeadTime = $prevBaseTime
  } else {
    $prevBaseTime = (Get-Item -LiteralPath $baseAbs).LastWriteTimeUtc
    $prevHeadTime = (Get-Item -LiteralPath $headAbs).LastWriteTimeUtc
  }
  $iteration = 0; $diffCount = 0; $errorCount = 0; $totalSeconds = 0.0; $swOverall = [System.Diagnostics.Stopwatch]::StartNew(); $records = @()
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
      $baseInfo = Get-Item -LiteralPath $baseAbs; $headInfo = Get-Item -LiteralPath $headAbs
      $baseChanged = $baseInfo.LastWriteTimeUtc -ne $prevBaseTime
      $headChanged = $headInfo.LastWriteTimeUtc -ne $prevHeadTime
    }
    if ($SkipIfUnchanged -and -not ($baseChanged -or $headChanged)) { $skipReason = 'unchanged' }
  $diff=$false; $exitCode=$null; $durationSeconds=0.0; $status='SKIPPED'
    if (-not $skipReason) {
  $status='OK'; $iterationSw=[System.Diagnostics.Stopwatch]::StartNew(); $argsList=@(); if ($LvCompareArgs) { $pattern=Get-LVCompareArgTokenPattern; $tokens=[regex]::Matches($LvCompareArgs,$pattern)|ForEach-Object{$_.Value}; foreach($t in $tokens){$argsList+=$t.Trim('"')}}; if ($CompareExecutor){$exitCode=& $CompareExecutor -CliPath $cli -Base $baseAbs -Head $headAbs -Args $argsList}else{ & $cli $baseAbs $headAbs @argsList; $exitCode=$LASTEXITCODE }; $iterationSw.Stop(); $durationSeconds=[math]::Round($iterationSw.Elapsed.TotalSeconds,3); $totalSeconds+=$durationSeconds; if ($exitCode -eq 0){} elseif ($exitCode -eq 1){$diff=$true; $diffCount++} else {$status='ERROR'; $errorCount++}
    }
  $record=[pscustomobject]@{ iteration=$iteration; diff=$diff; exitCode=$exitCode; status=$status; durationSeconds=$durationSeconds; skipped=[bool]$skipReason; skipReason=$skipReason; baseChanged=$baseChanged; headChanged=$headChanged }
    $records+=$record
    $prevBaseTime=$baseInfo.LastWriteTimeUtc; $prevHeadTime=$headInfo.LastWriteTimeUtc
  if ($FailOnDiff -and $diff) { break }
    if ($MaxIterations -gt 0 -and $iteration -ge $MaxIterations) { break }
  }
  $swOverall.Stop(); $avg= if ($iteration -gt 0){[math]::Round($totalSeconds/$iteration,3)} else {0}
  [pscustomobject]@{ Succeeded=($errorCount -eq 0); Iterations=$iteration; DiffCount=$diffCount; ErrorCount=$errorCount; AverageSeconds=$avg; TotalSeconds=[math]::Round($swOverall.Elapsed.TotalSeconds,3); Records=$records }
}
Export-ModuleMember -Function Invoke-IntegrationCompareLoop
