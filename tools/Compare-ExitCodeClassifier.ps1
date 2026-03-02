#Requires -Version 7.0
<#
.SYNOPSIS
  Classifies NI compare helper outcomes into deterministic gate semantics.

.DESCRIPTION
  Normalizes raw process exit behavior and optional capture metadata into
  additive result fields used by local gates and workflow evidence:
  - resultClass
  - isDiff
  - gateOutcome
  - failureClass

  Policy contract:
  - exit 0 => success-no-diff
  - exit 1 => success-diff unless positive failure heuristics/classification
  - runtime determinism failures are always blocking
#>

Set-StrictMode -Version Latest

function Test-CompareToolFailureSignature {
  [CmdletBinding()]
  param(
    [AllowNull()][AllowEmptyString()][string]$StdOut,
    [AllowNull()][AllowEmptyString()][string]$StdErr,
    [AllowNull()][AllowEmptyString()][string]$Message
  )

  $combined = @($StdErr, $StdOut, $Message) -join "`n"
  if ([string]::IsNullOrWhiteSpace($combined)) {
    return $false
  }

  return (
    $combined -match 'Error code\s*:' -or
    $combined -match 'An error occurred while running the LabVIEW CLI' -or
    $combined -match 'Report path already exists' -or
    $combined -match 'overwrite existing report' -or
    $combined -match 'CreateComparisonReport operation failed' -or
    $combined -match '(?i)\bexception\b' -or
    $combined -match '(?i)\bfatal\b'
  )
}

function Test-CompareStartupConnectivitySignature {
  [CmdletBinding()]
  param(
    [AllowNull()][AllowEmptyString()][string]$StdOut,
    [AllowNull()][AllowEmptyString()][string]$StdErr,
    [AllowNull()][AllowEmptyString()][string]$Message
  )

  $combined = @($StdErr, $StdOut, $Message) -join "`n"
  if ([string]::IsNullOrWhiteSpace($combined)) {
    return $false
  }

  return (
    $combined -match '-350000' -or
    $combined -match '(?i)openappreference' -or
    $combined -match '(?i)afterlaunchopenappreference' -or
    $combined -match '(?i)vi server' -or
    $combined -match '(?i)connect(ion|ivity)'
  )
}

function Test-CompareRuntimeDeterminismFailureSignature {
  [CmdletBinding()]
  param(
    [AllowNull()][AllowEmptyString()][string]$Message,
    [AllowNull()][AllowEmptyString()][string]$RuntimeDeterminismStatus,
    [AllowNull()][AllowEmptyString()][string]$RuntimeDeterminismReason
  )

  $status = if ([string]::IsNullOrWhiteSpace($RuntimeDeterminismStatus)) {
    ''
  } else {
    $RuntimeDeterminismStatus.Trim().ToLowerInvariant()
  }
  if ($status -eq 'mismatch-failed') {
    return $true
  }

  $combined = @($Message, $RuntimeDeterminismReason) -join "`n"
  if ([string]::IsNullOrWhiteSpace($combined)) {
    return $false
  }

  return (
    $combined -match '(?i)runtime determinism' -or
    $combined -match '(?i)runtime invariant mismatch' -or
    $combined -match '(?i)expected os='
  )
}

function Get-CompareExitClassification {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][int]$ExitCode,
    [AllowNull()][AllowEmptyString()][string]$CaptureStatus,
    [AllowNull()][AllowEmptyString()][string]$StdOut,
    [AllowNull()][AllowEmptyString()][string]$StdErr,
    [AllowNull()][AllowEmptyString()][string]$Message,
    [AllowNull()][AllowEmptyString()][string]$RuntimeDeterminismStatus,
    [AllowNull()][AllowEmptyString()][string]$RuntimeDeterminismReason,
    [switch]$TimedOut
  )

  $status = if ([string]::IsNullOrWhiteSpace($CaptureStatus)) {
    ''
  } else {
    $CaptureStatus.Trim().ToLowerInvariant()
  }

  $isRuntimeFailure = Test-CompareRuntimeDeterminismFailureSignature `
    -Message $Message `
    -RuntimeDeterminismStatus $RuntimeDeterminismStatus `
    -RuntimeDeterminismReason $RuntimeDeterminismReason
  $isToolFailure = Test-CompareToolFailureSignature -StdOut $StdOut -StdErr $StdErr -Message $Message
  $isStartupConnectivityFailure = Test-CompareStartupConnectivitySignature -StdOut $StdOut -StdErr $StdErr -Message $Message
  $isTimeout = $TimedOut.IsPresent -or $status -eq 'timeout' -or $ExitCode -eq 124
  $isPreflight = $status -eq 'preflight-error' -or $ExitCode -eq 2
  $isDiff = $status -eq 'diff'

  if (-not $isDiff -and $ExitCode -eq 1 -and -not $isRuntimeFailure -and -not $isTimeout -and -not $isPreflight -and -not $isToolFailure -and -not $isStartupConnectivityFailure) {
    $isDiff = $true
  }

  $resultClass = 'failure-tool'
  $failureClass = 'cli/tool'
  $gateOutcome = 'fail'

  if ($isRuntimeFailure) {
    $resultClass = 'failure-runtime'
    $failureClass = 'runtime-determinism'
  } elseif ($isTimeout) {
    $resultClass = 'failure-timeout'
    $failureClass = 'timeout'
  } elseif ($isPreflight) {
    $resultClass = 'failure-preflight'
    $failureClass = 'preflight'
  } elseif ($isDiff) {
    $resultClass = 'success-diff'
    $failureClass = 'none'
    $gateOutcome = 'pass'
  } elseif ($ExitCode -eq 0 -or $status -eq 'ok' -or $status -eq 'probe-ok') {
    $resultClass = 'success-no-diff'
    $failureClass = 'none'
    $gateOutcome = 'pass'
  } else {
    $resultClass = 'failure-tool'
    $failureClass = if ($isStartupConnectivityFailure) { 'startup-connectivity' } else { 'cli/tool' }
  }

  [pscustomobject]@{
    resultClass = $resultClass
    isDiff = [bool]$isDiff
    gateOutcome = $gateOutcome
    failureClass = $failureClass
  }
}

function Get-CompareCaptureClassification {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][psobject]$Capture
  )

  $runtimeStatus = ''
  $runtimeReason = ''
  if ($Capture.PSObject.Properties['runtimeDeterminism'] -and $Capture.runtimeDeterminism) {
    if ($Capture.runtimeDeterminism.PSObject.Properties['status']) {
      $runtimeStatus = [string]$Capture.runtimeDeterminism.status
    }
    if ($Capture.runtimeDeterminism.PSObject.Properties['reason']) {
      $runtimeReason = [string]$Capture.runtimeDeterminism.reason
    }
  }

  $timedOut = $false
  if ($Capture.PSObject.Properties['timedOut']) {
    $timedOut = [bool]$Capture.timedOut
  }
  $exitCode = 0
  if ($Capture.PSObject.Properties['exitCode'] -and $null -ne $Capture.exitCode) {
    $exitCode = [int]$Capture.exitCode
  }
  $status = if ($Capture.PSObject.Properties['status']) { [string]$Capture.status } else { '' }
  $stdout = if ($Capture.PSObject.Properties['stdout']) { [string]$Capture.stdout } else { '' }
  $stderr = if ($Capture.PSObject.Properties['stderr']) { [string]$Capture.stderr } else { '' }
  $message = if ($Capture.PSObject.Properties['message']) { [string]$Capture.message } else { '' }

  return Get-CompareExitClassification `
    -ExitCode $exitCode `
    -CaptureStatus $status `
    -StdOut $stdout `
    -StdErr $stderr `
    -Message $message `
    -RuntimeDeterminismStatus $runtimeStatus `
    -RuntimeDeterminismReason $runtimeReason `
    -TimedOut:$timedOut
}
