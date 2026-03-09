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

  Write-Host ("[sync] git {0}" -f ($Arguments -join ' '))
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

function Test-NonRetryableSyncFailure {
  param([Parameter(Mandatory)][string]$Message)

  if ($Message -match '(?i)not possible to fast-forward') { return $true }
  if ($Message -match '(?i)refusing to merge unrelated histories') { return $true }
  if ($Message -match '(?i)CONFLICT') { return $true }
  return $false
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
$lockPath = Join-Path (Join-Path $repoRoot '.git') $lockName
$lockStream = $null
$restoreBranch = $false
$startingBranch = ''
$pushedLocation = $false

Push-Location -LiteralPath $repoRoot
$pushedLocation = $true
try {
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
      Invoke-Git -Arguments @('push', $HeadRemote, $Branch) | Out-Null

      $localHead = Get-GitValue -Arguments @('rev-parse', 'HEAD')
      if ([string]::IsNullOrWhiteSpace($localHead)) {
        throw 'Unable to resolve local HEAD after push.'
      }

      $converged = Wait-ForRemoteHead -Remote $HeadRemote -BranchName $Branch -ExpectedSha $localHead -Attempts $RemoteHeadPollAttempts -DelaySeconds $RemoteHeadPollDelaySeconds
      if (-not $converged) {
        throw ("Push completed but remote head did not converge to local HEAD ({0}) within {1} poll(s)." -f $localHead, $RemoteHeadPollAttempts)
      }

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

  Invoke-Node -Arguments @('tools/priority/report-origin-upstream-parity.mjs', '--base-ref', $baseRef, '--head-ref', $headRef)

  if (-not (Test-Path -LiteralPath $parityReportPath -PathType Leaf)) {
    throw ("Parity report not found: {0}" -f $parityReportPath)
  }

  $parityReport = Get-Content -LiteralPath $parityReportPath -Raw | ConvertFrom-Json
  $tipDiffCount = [int]($parityReport.tipDiff.fileCount)
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
