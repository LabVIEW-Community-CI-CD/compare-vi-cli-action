#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$BaseRemote = 'upstream',
  [string]$HeadRemote = 'origin',
  [string]$Branch = 'develop',
  [string]$ParityReportPath,
  [switch]$KeepCurrentBranch,
  [ValidateRange(1, 20)]
  [int]$MaxAttempts = 3,
  [ValidateRange(1, 120)]
  [int]$RetryDelaySeconds = 4,
  [ValidateRange(5, 600)]
  [int]$LockWaitSeconds = 120,
  [ValidateRange(1, 30)]
  [int]$RemoteHeadPollAttempts = 8,
  [ValidateRange(1, 30)]
  [int]$RemoteHeadPollDelaySeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$IgnoreExitCode
  )

  $displayArguments = @($Arguments | ForEach-Object { Get-SafeRemoteLocation -Location ([string]$_) })
  Write-Host ("[sync] git {0}" -f ($displayArguments -join ' '))
  $raw = & git @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $lines = @($raw | ForEach-Object { [string]$_ })
  $text = ($lines -join "`n").Trim()
  if (-not $IgnoreExitCode -and $exitCode -ne 0) {
    if ($text) {
      throw ("git command failed (exit={0}): git {1}`n{2}" -f $exitCode, ($Arguments -join ' '), $text)
    }
    throw ("git command failed (exit={0}): git {1}" -f $exitCode, ($Arguments -join ' '))
  }
  return [pscustomobject]@{
    ExitCode = [int]$exitCode
    Lines = $lines
    Text = $text
  }
}

function Invoke-Node {
  param(
    [Parameter(Mandatory)][string[]]$Arguments
  )

  Write-Host ("[sync] node {0}" -f ($Arguments -join ' '))
  & node @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw ("node command failed (exit={0}): node {1}" -f $LASTEXITCODE, ($Arguments -join ' '))
  }
}

function Acquire-LockStream {
  param(
    [Parameter(Mandatory)][string]$LockPath,
    [ValidateRange(5, 600)][int]$WaitSeconds
  )

  $lockDir = Split-Path -Parent $LockPath
  if ($lockDir -and -not (Test-Path -LiteralPath $lockDir -PathType Container)) {
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
  }

  $deadline = (Get-Date).ToUniversalTime().AddSeconds($WaitSeconds)
  do {
    try {
      return [System.IO.File]::Open(
        $LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
      )
    } catch [System.IO.IOException] {
      Start-Sleep -Seconds 2
    }
  } while ((Get-Date).ToUniversalTime() -lt $deadline)

  throw ("Timed out waiting for sync lock: {0}" -f $LockPath)
}

function Get-GitValue {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $result = Invoke-Git -Arguments $Arguments
  if (-not $result.Text) { return '' }
  return ([string]$result.Lines[0]).Trim()
}

function Get-GitOptionalValue {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $result = Invoke-Git -Arguments $Arguments -IgnoreExitCode
  if ($result.ExitCode -ne 0 -or -not $result.Text) {
    return ''
  }
  return ([string]$result.Lines[0]).Trim()
}

function Resolve-GitAdminPath {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [Parameter(Mandatory)][string]$BasePath
  )

  $value = Get-GitValue -Arguments $Arguments
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw ("git {0} returned an empty path." -f ($Arguments -join ' '))
  }

  if ([System.IO.Path]::IsPathRooted($value)) {
    return [System.IO.Path]::GetFullPath($value)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $value))
}

function Get-RemoteHeadSha {
  param(
    [Parameter(Mandatory)][string]$Remote,
    [Parameter(Mandatory)][string]$BranchName
  )

  $result = Invoke-Git -Arguments @('ls-remote', '--heads', $Remote, $BranchName) -IgnoreExitCode
  if ($result.ExitCode -ne 0) {
    throw ("Failed to resolve {0}/{1} via ls-remote." -f $Remote, $BranchName)
  }

  $line = ($result.Lines | Select-Object -First 1)
  if (-not $line) { return '' }
  $parts = ([string]$line).Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)
  if ($parts.Count -lt 1) { return '' }
  return $parts[0].Trim()
}

function Wait-ForRemoteHead {
  param(
    [Parameter(Mandatory)][string]$Remote,
    [Parameter(Mandatory)][string]$BranchName,
    [Parameter(Mandatory)][string]$ExpectedSha,
    [ValidateRange(1, 60)][int]$Attempts,
    [ValidateRange(1, 60)][int]$DelaySeconds
  )

  for ($poll = 1; $poll -le $Attempts; $poll++) {
    $remoteHead = Get-RemoteHeadSha -Remote $Remote -BranchName $BranchName
    if ($remoteHead -eq $ExpectedSha) {
      return $true
    }
    if ($poll -lt $Attempts) {
      Start-Sleep -Seconds $DelaySeconds
    }
  }

  return $false
}

function Refresh-RemoteTrackingRef {
  param(
    [Parameter(Mandatory)][string]$Remote,
    [Parameter(Mandatory)][string]$BranchName,
    [Parameter(Mandatory)][string]$ExpectedSha
  )

  $trackingRef = 'refs/remotes/{0}/{1}' -f $Remote, $BranchName
  $refSpec = '+refs/heads/{0}:{1}' -f $BranchName, $trackingRef
  Invoke-Git -Arguments @('fetch', '--no-tags', $Remote, $refSpec) | Out-Null
  $resolvedSha = Get-GitValue -Arguments @('rev-parse', '--verify', $trackingRef)
  if ($resolvedSha -ne $ExpectedSha) {
    throw ("Remote tracking ref {0} resolved to {1} after refresh; expected {2}." -f $trackingRef, $resolvedSha, $ExpectedSha)
  }

  Write-Host ("[sync] Refreshed local tracking ref {0} -> {1}" -f $trackingRef, $ExpectedSha)
}

function Test-NonRetryableSyncFailure {
  param([Parameter(Mandatory)][string]$Message)

  if ($Message -match '(?i)not possible to fast-forward') { return $true }
  if ($Message -match '(?i)refusing to merge unrelated histories') { return $true }
  if ($Message -match '(?i)CONFLICT') { return $true }
  return $false
}

function Test-GitHubSshAuthFailure {
  param([Parameter(Mandatory)][string]$Message)

  if ($Message -match '(?i)Permission denied \(publickey\)') { return $true }
  if ($Message -match '(?i)Could not read from remote repository') { return $true }
  return $false
}

function Get-SafeRemoteLocation {
  param([string]$Location)

  if ([string]::IsNullOrWhiteSpace($Location)) {
    return $Location
  }

  return ($Location -replace '^(https?://)([^/@]+@)', '$1')
}

function Invoke-PushWithTransportFallback {
  param(
    [Parameter(Mandatory)][string]$Remote,
    [Parameter(Mandatory)][string]$BranchName
  )

  try {
    Invoke-Git -Arguments @('push', $Remote, $BranchName) | Out-Null
    return [ordered]@{
      target = $Remote
      usedFallback = $false
    }
  }
  catch {
    $message = $_.Exception.Message
    $fetchUrl = Get-GitOptionalValue -Arguments @('remote', 'get-url', $Remote)
    $pushUrl = Get-GitOptionalValue -Arguments @('remote', 'get-url', '--push', $Remote)
    $canFallback = (
      (Test-GitHubSshAuthFailure -Message $message) -and
      -not [string]::IsNullOrWhiteSpace($fetchUrl) -and
      $fetchUrl -ne $pushUrl
    )
    if (-not $canFallback) {
      throw
    }

    Write-Warning ("[sync] Push via remote '{0}' failed with SSH auth; retrying against fetch URL {1}" -f $Remote, (Get-SafeRemoteLocation -Location $fetchUrl))
    Invoke-Git -Arguments @(
      '-c', 'credential.interactive=never',
      '-c', 'core.askpass=',
      'push', $fetchUrl, ("{0}:{0}" -f $BranchName)
    ) | Out-Null
    return [ordered]@{
      target = Get-SafeRemoteLocation -Location $fetchUrl
      usedFallback = $true
      primaryRemote = $Remote
      primaryPushUrl = Get-SafeRemoteLocation -Location $pushUrl
    }
  }
}

$repoRoot = Get-GitValue -Arguments @('rev-parse', '--show-toplevel')
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
  throw 'Unable to resolve git repository root.'
}

$baseRef = '{0}/{1}' -f $BaseRemote, $Branch
$headRef = '{0}/{1}' -f $HeadRemote, $Branch
$parityReportPath = if ([string]::IsNullOrWhiteSpace($ParityReportPath)) {
  Join-Path $repoRoot ("tests/results/_agent/issue/{0}-upstream-parity.json" -f $HeadRemote)
} else {
  if ([System.IO.Path]::IsPathRooted($ParityReportPath)) {
    $ParityReportPath
  } else {
    Join-Path $repoRoot $ParityReportPath
  }
}
$lockName = ('priority-sync-{0}-{1}-{2}.lock' -f $BaseRemote, $HeadRemote, $Branch) -replace '[^A-Za-z0-9._-]', '_'
$lockPath = ''
$lockStream = $null
$restoreBranch = $false
$startingBranch = ''
$pushedLocation = $false
$gitDir = ''
$gitCommonDir = ''
$gitConfigPath = ''
$adminPaths = $null
$pushTransport = $null

Push-Location -LiteralPath $repoRoot
$pushedLocation = $true
try {
  $gitDir = Resolve-GitAdminPath -Arguments @('rev-parse', '--git-dir') -BasePath $repoRoot
  $gitCommonDir = Resolve-GitAdminPath -Arguments @('rev-parse', '--git-common-dir') -BasePath $repoRoot
  $gitConfigPath = Resolve-GitAdminPath -Arguments @('rev-parse', '--git-path', 'config') -BasePath $repoRoot
  $lockPath = Join-Path $gitCommonDir $lockName
  $adminPaths = [ordered]@{
    gitDir = $gitDir
    gitCommonDir = $gitCommonDir
    gitConfigPath = $gitConfigPath
    lockPath = $lockPath
  }

  $startingBranch = Get-GitValue -Arguments @('branch', '--show-current')
  $restoreBranch = (
    -not $KeepCurrentBranch -and
    -not [string]::IsNullOrWhiteSpace($startingBranch) -and
    $startingBranch -ne 'HEAD' -and
    $startingBranch -ne $Branch
  )

  $lockStream = Acquire-LockStream -LockPath $lockPath -WaitSeconds $LockWaitSeconds
  Write-Host ("[sync] Acquired lock: {0}" -f $lockPath)

  Invoke-Git -Arguments @('fetch', '--all', '--prune') | Out-Null
  if ($startingBranch -ne $Branch) {
    Invoke-Git -Arguments @('checkout', $Branch) | Out-Null
  }

  $syncSucceeded = $false
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      Write-Host ("[sync] Attempt {0}/{1}: pull+push {2}" -f $attempt, $MaxAttempts, $Branch)

      # Sequential by design: pull must complete before push starts.
      Invoke-Git -Arguments @('pull', '--ff-only', $BaseRemote, $Branch) | Out-Null
      $pushTransport = Invoke-PushWithTransportFallback -Remote $HeadRemote -BranchName $Branch

      $localHead = Get-GitValue -Arguments @('rev-parse', 'HEAD')
      if ([string]::IsNullOrWhiteSpace($localHead)) {
        throw 'Unable to resolve local HEAD after push.'
      }

      $converged = Wait-ForRemoteHead -Remote $HeadRemote -BranchName $Branch -ExpectedSha $localHead -Attempts $RemoteHeadPollAttempts -DelaySeconds $RemoteHeadPollDelaySeconds
      if (-not $converged) {
        throw ("Push completed but remote head did not converge to local HEAD ({0}) within {1} poll(s)." -f $localHead, $RemoteHeadPollAttempts)
      }
      Refresh-RemoteTrackingRef -Remote $HeadRemote -BranchName $Branch -ExpectedSha $localHead

      $syncSucceeded = $true
      break
    }
    catch {
      $message = $_.Exception.Message
      $nonRetryable = Test-NonRetryableSyncFailure -Message $message
      if ($nonRetryable -or $attempt -ge $MaxAttempts) {
        throw
      }

      Write-Warning ("[sync] Attempt {0}/{1} failed; retrying in {2}s. {3}" -f $attempt, $MaxAttempts, $RetryDelaySeconds, $message)
      Invoke-Git -Arguments @('fetch', '--all', '--prune') | Out-Null
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }

  if (-not $syncSucceeded) {
    throw ("Sync failed after {0} attempt(s)." -f $MaxAttempts)
  }

  Invoke-Node -Arguments @(
    'tools/priority/report-origin-upstream-parity.mjs',
    '--base-ref',
    $baseRef,
    '--head-ref',
    $headRef,
    '--output-path',
    $parityReportPath
  )

  if (-not (Test-Path -LiteralPath $parityReportPath -PathType Leaf)) {
    throw ("Parity report not found: {0}" -f $parityReportPath)
  }

  $parityReport = Get-Content -LiteralPath $parityReportPath -Raw | ConvertFrom-Json -AsHashtable
  $parityReport['adminPaths'] = $adminPaths
  if ($pushTransport) {
    $parityReport['pushTransport'] = $pushTransport
  }
  ($parityReport | ConvertTo-Json -Depth 20) + "`n" | Set-Content -LiteralPath $parityReportPath -Encoding utf8
  $tipDiffCount = [int]($parityReport['tipDiff']['fileCount'])
  if ($tipDiffCount -ne 0) {
    throw ("Origin/upstream parity failed: tipDiff.fileCount={0} (expected 0)." -f $tipDiffCount)
  }

  Write-Host ("[sync] Parity OK for {0} vs {1}" -f $baseRef, $headRef)
}
finally {
  if ($lockStream) {
    $lockStream.Dispose()
  }

  if ($restoreBranch) {
    Invoke-Git -Arguments @('checkout', $startingBranch) | Out-Null
  }

  if ($pushedLocation) {
    Pop-Location
  }
}
