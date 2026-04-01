#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$TestsPath = 'tests',
  [string]$ResultsPath = 'tests/results',
  [string]$ContextReceiptPath,
  [string]$ReadinessReceiptPath,
  [string]$SelectionReceiptPath,
  [ValidateSet('full', 'comparevi', 'dispatcher', 'workflow', 'fixtures', 'psummary', 'schema', 'loop')]
  [string]$ExecutionPack = 'full',
  [ValidateSet('auto', 'include', 'exclude')]
  [string]$IntegrationMode = 'exclude',
  [string[]]$IncludePatterns,
  [string]$BasePath,
  [string]$HeadPath,
  [switch]$EmitFailuresJsonAlways,
  [double]$TimeoutSeconds = 0,
  [switch]$DetectLeaks,
  [switch]$FailOnLeaks,
  [switch]$KillLeaks,
  [double]$LeakGraceSeconds = 3,
  [switch]$CleanLabVIEWBefore,
  [switch]$CleanAfter,
  [switch]$TrackArtifacts,
  [string]$SessionLockGroup = 'pester-selfhosted',
  [string]$SessionLockRoot,
  [int]$SessionLockQueueWaitSeconds = 15,
  [int]$SessionLockQueueMaxAttempts = 40,
  [int]$SessionLockStaleSeconds = 300,
  [int]$SessionHeartbeatSeconds = 15,
  [ValidateSet('auto', 'relocate', 'block', 'off')]
  [string]$PathHygieneMode = 'auto',
  [string]$PathHygieneSafeRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PortablePath {
  param([string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }
  return ($PathValue -replace '\\', '/')
}

function Resolve-RepoRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Resolve-OutputPath {
  param(
    [string]$RepoRoot,
    [string]$PathValue
  )
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$PathValue)
  if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
    throw "JSON file not found: $PathValue"
  }
  return (Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertTo-Bool {
  param($Value)
  if ($Value -is [bool]) {
    return $Value
  }
  if ($null -eq $Value) {
    return $false
  }
  $text = [string]$Value
  return $text.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on')
}

function ConvertTo-NullableDouble {
  param($Value)
  if ($null -eq $Value -or $Value -eq '') {
    return $null
  }
  $parsed = 0.0
  if ([double]::TryParse([string]$Value, [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function Resolve-RepositorySlug {
  param([string]$RepoRoot)
  try {
    $remoteUrl = git -C $RepoRoot remote get-url origin 2>$null
    if ($remoteUrl -match 'github\.com[:/](?<slug>[^/]+/[^/.]+)') {
      return $matches.slug
    }
  } catch {}
  return Split-Path -Leaf $RepoRoot
}

function Validate-ContextReceipt {
  param([string]$ReceiptPath)
  if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    return $null
  }
  $receipt = Read-JsonFile -PathValue $ReceiptPath
  if ($receipt.schema -ne 'pester-context-receipt@v1') {
    throw "Unexpected context receipt schema: $($receipt.schema)"
  }
  if ($receipt.status -ne 'ready') {
    throw "Context receipt status is not ready: $($receipt.status)"
  }
  return $receipt
}

function Validate-ReadinessReceipt {
  param([string]$ReceiptPath)
  if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    return $null
  }
  $receipt = Read-JsonFile -PathValue $ReceiptPath
  if ($receipt.schema -ne 'pester-selfhosted-readiness-receipt@v1') {
    throw "Unexpected readiness receipt schema: $($receipt.schema)"
  }
  if ($receipt.status -ne 'ready') {
    throw "Readiness receipt status is not ready: $($receipt.status)"
  }
  $freshnessWindowSeconds = 900
  if ($receipt.PSObject.Properties.Name -contains 'freshnessWindowSeconds') {
    $freshnessWindowSeconds = [int]$receipt.freshnessWindowSeconds
  }
  $generatedAtUtc = [DateTime]::Parse($receipt.generatedAtUtc).ToUniversalTime()
  $ageSeconds = [math]::Floor(([DateTime]::UtcNow - $generatedAtUtc).TotalSeconds)
  if ($ageSeconds -gt $freshnessWindowSeconds) {
    throw "Readiness receipt stale: age ${ageSeconds}s exceeds freshness window ${freshnessWindowSeconds}s"
  }
  return $receipt
}

function Validate-SelectionReceipt {
  param([string]$ReceiptPath)
  if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    return $null
  }
  $receipt = Read-JsonFile -PathValue $ReceiptPath
  if ($receipt.schema -ne 'pester-selection-receipt@v1') {
    throw "Unexpected selection receipt schema: $($receipt.schema)"
  }
  if ($receipt.status -ne 'ready') {
    throw "Selection receipt status is not ready: $($receipt.status)"
  }
  return $receipt
}

function Invoke-RunnerUnblockGuardLocal {
  param(
    [Parameter(Mandatory = $true)][string]$SnapshotPath,
    [bool]$Cleanup = $false,
    [string[]]$ProcessNames = @('LabVIEW', 'LVCompare')
  )
  $snapshotDir = Split-Path -Parent $SnapshotPath
  if ($snapshotDir -and -not (Test-Path -LiteralPath $snapshotDir -PathType Container)) {
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
  }
  $procs = @(
    Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessName -in $ProcessNames } |
      Select-Object ProcessName, Id, SessionId, StartTime
  )
  $jobs = @(Get-Job -ErrorAction SilentlyContinue | Select-Object Id, Name, State, HasMoreData)
  $snapshot = [ordered]@{
    processes = $procs
    jobs = $jobs
    cleanupPerformed = $false
  }
  if ($Cleanup) {
    $stopped = @()
    foreach ($name in $ProcessNames) {
      Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        $stopped += [ordered]@{
          name = $name
          id = $_.Id
        }
      }
    }
    $snapshot.cleanupPerformed = $true
    $snapshot.cleanup = $stopped
  }
  $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SnapshotPath -Encoding UTF8
}

function Invoke-PrepareFixturesLocal {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [string]$BaseSourcePath,
    [string]$HeadSourcePath
  )

  $resolvedBase = if ([string]::IsNullOrWhiteSpace($BaseSourcePath)) {
    if ($env:LV_BASE_VI) { $env:LV_BASE_VI } else { Join-Path $RepoRoot 'VI1.vi' }
  } else {
    $BaseSourcePath
  }
  $resolvedHead = if ([string]::IsNullOrWhiteSpace($HeadSourcePath)) {
    if ($env:LV_HEAD_VI) { $env:LV_HEAD_VI } else { Join-Path $RepoRoot 'VI2.vi' }
  } else {
    $HeadSourcePath
  }

  if (-not (Test-Path -LiteralPath $resolvedBase -PathType Leaf)) {
    throw "Base VI not found: $resolvedBase"
  }
  if (-not (Test-Path -LiteralPath $resolvedHead -PathType Leaf)) {
    throw "Head VI not found: $resolvedHead"
  }

  $tmpBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
  $tmpDir = Join-Path $tmpBase ("fixtures-" + [guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
  $baseCopy = Join-Path $tmpDir 'base.vi'
  $headCopy = Join-Path $tmpDir 'head.vi'
  Copy-Item -LiteralPath $resolvedBase -Destination $baseCopy -Force
  Copy-Item -LiteralPath $resolvedHead -Destination $headCopy -Force

  return [ordered]@{
    tempDir = $tmpDir
    base = $baseCopy
    head = $headCopy
    sourceBase = $resolvedBase
    sourceHead = $resolvedHead
  }
}

function Resolve-LVComparePath {
  if ($env:LVCOMPARE_PATH -and (Test-Path -LiteralPath $env:LVCOMPARE_PATH -PathType Leaf)) {
    return (Resolve-Path -LiteralPath $env:LVCOMPARE_PATH).Path
  }
  $canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  if (Test-Path -LiteralPath $canonical -PathType Leaf) {
    return $canonical
  }
  return $null
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)]$Payload
  )
  $dir = Split-Path -Parent $PathValue
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PathValue -Encoding UTF8
}

function Write-ExecutionReceiptFiles {
  param(
    [Parameter(Mandatory = $true)][string]$ReceiptRoot,
    [Parameter(Mandatory = $true)]$Receipt
  )

  $resolvedReceiptRoot = [System.IO.Path]::GetFullPath($ReceiptRoot)
  $receiptPath = Join-Path $resolvedReceiptRoot 'pester-run-receipt.json'
  $contractReceiptPath = Join-Path $resolvedReceiptRoot 'pester-execution-contract' 'pester-run-receipt.json'
  Write-JsonFile -PathValue $receiptPath -Payload $Receipt
  Write-JsonFile -PathValue $contractReceiptPath -Payload $Receipt
  return [pscustomobject]@{
    receiptPath = $receiptPath
    contractReceiptPath = $contractReceiptPath
  }
}

$repoRoot = Resolve-RepoRoot
$requestedResultsPath = Resolve-OutputPath -RepoRoot $repoRoot -PathValue $ResultsPath
$resolvedContextReceiptPath = Resolve-OutputPath -RepoRoot $repoRoot -PathValue $ContextReceiptPath
$resolvedReadinessReceiptPath = Resolve-OutputPath -RepoRoot $repoRoot -PathValue $ReadinessReceiptPath
$resolvedSelectionReceiptPath = Resolve-OutputPath -RepoRoot $repoRoot -PathValue $SelectionReceiptPath
$requestedSessionLockRoot = if ([string]::IsNullOrWhiteSpace($SessionLockRoot)) {
  Join-Path $requestedResultsPath '_session_lock'
} else {
  Resolve-OutputPath -RepoRoot $repoRoot -PathValue $SessionLockRoot
}
$resolvedResultsPath = $requestedResultsPath
$resolvedSessionLockRoot = $requestedSessionLockRoot

$contextReceipt = $null
$readinessReceipt = $null
$selectionReceipt = $null
$executionPackResolution = $null
$preparedFixtures = $null
$dispatcherExitCode = -1
$postprocessStatus = 'seam-defect'
$postprocessReportPath = $null
$resultsXmlStatus = $null
$executionStatus = 'seam-defect'
$executionJobResult = 'failure'
$heartbeatJob = $null
$lvComparePath = $null
$dotnetReady = $false
$sessionLockPath = $null
$sessionLockId = $null
$summaryPresent = $false
$receiptRoot = $resolvedResultsPath
$receiptPaths = $null
$pathHygienePlan = $null
$pathHygieneRecord = $null

Push-Location $repoRoot
try {
  . (Join-Path $repoRoot 'tools/PesterExecutionPacks.ps1')
  . (Join-Path $repoRoot 'tools/PesterPathHygiene.ps1')

  $pathHygienePlan = Resolve-PesterPathHygienePlan -ResultsPath $requestedResultsPath -SessionLockRoot $requestedSessionLockRoot -Mode $PathHygieneMode -SafeRoot $PathHygieneSafeRoot
  if ([string]::IsNullOrWhiteSpace([string]$pathHygienePlan.receiptRoot)) {
    $receiptRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("compare-vi-cli-action-path-hygiene-" + [Guid]::NewGuid().ToString('N'))
  } else {
    $receiptRoot = [System.IO.Path]::GetFullPath([string]$pathHygienePlan.receiptRoot)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$pathHygienePlan.effectiveResultsPath)) {
    $resolvedResultsPath = [System.IO.Path]::GetFullPath([string]$pathHygienePlan.effectiveResultsPath)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$pathHygienePlan.effectiveSessionLockRoot)) {
    $resolvedSessionLockRoot = [System.IO.Path]::GetFullPath([string]$pathHygienePlan.effectiveSessionLockRoot)
  }

  $pathHygieneRecord = [ordered]@{
    mode = [string]$pathHygienePlan.mode
    status = [string]$pathHygienePlan.status
    requestedResultsPath = ConvertTo-PortablePath $requestedResultsPath
    effectiveResultsPath = ConvertTo-PortablePath $resolvedResultsPath
    requestedSessionLockRoot = ConvertTo-PortablePath $requestedSessionLockRoot
    effectiveSessionLockRoot = ConvertTo-PortablePath $resolvedSessionLockRoot
    receiptRoot = ConvertTo-PortablePath $receiptRoot
    safeRoot = ConvertTo-PortablePath ([string]$pathHygienePlan.safeRoot)
    risks = @($pathHygienePlan.risks)
  }

  if ([string]$pathHygienePlan.status -eq 'path-hygiene-blocked') {
    $executionStatus = 'path-hygiene-blocked'
    $executionJobResult = 'skipped'
    $postprocessStatus = 'not-run'
    $repository = Resolve-RepositorySlug -RepoRoot $repoRoot
    $blockedReceipt = [ordered]@{
      schema = 'pester-execution-receipt@v1'
      generatedAtUtc = [DateTime]::UtcNow.ToString('o')
      source = 'local-harness'
      repository = $repository
      contextStatus = 'local-ready'
      contextReceiptPath = ConvertTo-PortablePath $resolvedContextReceiptPath
      contextReceiptPresent = $false
      standingPriorityIssue = $null
      readinessStatus = 'local-ready'
      readinessReceiptPath = ConvertTo-PortablePath $resolvedReadinessReceiptPath
      readinessReceiptPresent = $false
      selectionStatus = 'local-ready'
      selectionReceiptPath = ConvertTo-PortablePath $resolvedSelectionReceiptPath
      selectionReceiptPresent = $false
      dispatcherExitCode = $dispatcherExitCode
      postprocessStatus = $postprocessStatus
      resultsXmlStatus = $null
      executionJobResult = $executionJobResult
      summaryPresent = $summaryPresent
      status = $executionStatus
      pathHygieneStatus = [string]$pathHygienePlan.status
      rawArtifactName = 'pester-run-raw-local'
      localHarness = [ordered]@{
        dotnetReady = $false
        lvComparePath = $null
        fixtureBase = $null
        fixtureHead = $null
        timeoutSeconds = 0
        emitFailuresJsonAlways = $false
        detectLeaks = $false
        failOnLeaks = $false
        killLeaks = $false
        leakGraceSeconds = $LeakGraceSeconds
        cleanLabVIEWBefore = $false
        cleanAfter = $false
        trackArtifacts = $false
        sessionLockGroup = $SessionLockGroup
        sessionLockRoot = ConvertTo-PortablePath $resolvedSessionLockRoot
        sessionLockPath = $null
        postprocessReportPath = $null
        preSnapshotPath = $null
        dispatcherLogPath = $null
        pathHygiene = $pathHygieneRecord
      }
    }
    $receiptPaths = Write-ExecutionReceiptFiles -ReceiptRoot $receiptRoot -Receipt $blockedReceipt

    Write-Host '### Local Pester execution harness' -ForegroundColor Cyan
    Write-Host ("status      : {0}" -f $executionStatus)
    Write-Host ("requested   : {0}" -f $requestedResultsPath)
    Write-Host ("effective   : {0}" -f ($resolvedResultsPath ?? '<blocked>'))
    Write-Host ("receipt     : {0}" -f $receiptPaths.receiptPath)
    Write-Host ("contract    : {0}" -f $receiptPaths.contractReceiptPath)
    throw ("Local path hygiene blocked unsafe synchronized or externally managed roots. Receipt: {0}" -f $receiptPaths.receiptPath)
  }

  New-Item -ItemType Directory -Path $resolvedResultsPath -Force | Out-Null
  New-Item -ItemType Directory -Path $resolvedSessionLockRoot -Force | Out-Null

  $contextReceipt = Validate-ContextReceipt -ReceiptPath $resolvedContextReceiptPath
  $readinessReceipt = Validate-ReadinessReceipt -ReceiptPath $resolvedReadinessReceiptPath
  $selectionReceipt = Validate-SelectionReceipt -ReceiptPath $resolvedSelectionReceiptPath

  $repository = if ($contextReceipt) { [string]$contextReceipt.repository } else { Resolve-RepositorySlug -RepoRoot $repoRoot }
  $standingPriorityIssue = if ($contextReceipt) { $contextReceipt.standingPriority.issueNumber } else { $null }

  $effectiveExecutionPack = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('ExecutionPack')) {
    [string]$selectionReceipt.selection.executionPack
  } else {
    $ExecutionPack
  }

  $effectiveIntegrationMode = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('IntegrationMode')) {
    [string]$selectionReceipt.selection.integrationMode
  } else {
    $IntegrationMode
  }
  $effectiveIncludePatterns = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('IncludePatterns')) {
    if ($selectionReceipt.selection.PSObject.Properties.Name -contains 'refineIncludePatterns') {
      @($selectionReceipt.selection.refineIncludePatterns)
    } else {
      @($selectionReceipt.selection.includePatterns)
    }
  } else {
    @($IncludePatterns)
  }
  $executionPackResolution = Resolve-PesterExecutionPack -ExecutionPack $effectiveExecutionPack -RefineIncludePatterns $effectiveIncludePatterns
  $fixtureRequired = if ($selectionReceipt) {
    ConvertTo-Bool $selectionReceipt.selection.fixtureRequired
  } else {
    $false
  }
  if ($PSBoundParameters.ContainsKey('BasePath') -or $PSBoundParameters.ContainsKey('HeadPath') -or $env:LV_BASE_VI -or $env:LV_HEAD_VI) {
    $fixtureRequired = $true
  }

  $effectiveTimeoutSeconds = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('TimeoutSeconds')) {
    ConvertTo-NullableDouble $selectionReceipt.dispatcherProfile.timeoutSeconds
  } else {
    $TimeoutSeconds
  }
  if ($null -eq $effectiveTimeoutSeconds) {
    $effectiveTimeoutSeconds = 0
  }

  $effectiveEmitFailuresJsonAlways = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('EmitFailuresJsonAlways')) {
    ConvertTo-Bool $selectionReceipt.dispatcherProfile.emitFailuresJsonAlways
  } else {
    $EmitFailuresJsonAlways.IsPresent
  }
  $effectiveDetectLeaks = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('DetectLeaks')) {
    ConvertTo-Bool $selectionReceipt.dispatcherProfile.detectLeaks
  } else {
    $DetectLeaks.IsPresent
  }
  $effectiveFailOnLeaks = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('FailOnLeaks')) {
    ConvertTo-Bool $selectionReceipt.dispatcherProfile.failOnLeaks
  } else {
    $FailOnLeaks.IsPresent
  }
  $effectiveKillLeaks = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('KillLeaks')) {
    ConvertTo-Bool $selectionReceipt.dispatcherProfile.killLeaks
  } else {
    $KillLeaks.IsPresent
  }
  $effectiveLeakGraceSeconds = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('LeakGraceSeconds')) {
    ConvertTo-NullableDouble $selectionReceipt.dispatcherProfile.leakGraceSeconds
  } else {
    $LeakGraceSeconds
  }
  if ($null -eq $effectiveLeakGraceSeconds) {
    $effectiveLeakGraceSeconds = 3
  }
  $effectiveCleanBefore = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('CleanLabVIEWBefore')) {
    ConvertTo-Bool $selectionReceipt.dispatcherProfile.cleanLabVIEWBefore
  } else {
    $CleanLabVIEWBefore.IsPresent
  }
  $effectiveCleanAfter = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('CleanAfter')) {
    ConvertTo-Bool $selectionReceipt.dispatcherProfile.cleanAfter
  } else {
    $CleanAfter.IsPresent
  }
  $effectiveTrackArtifacts = if ($selectionReceipt -and -not $PSBoundParameters.ContainsKey('TrackArtifacts')) {
    ConvertTo-Bool $selectionReceipt.dispatcherProfile.trackArtifacts
  } else {
    $TrackArtifacts.IsPresent
  }

  if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw '.NET host toolchain is not available. Install dotnet before running the local execution harness.'
  }
  $dotnetReady = $true

  $lvComparePath = Resolve-LVComparePath
  $requiresLabVIEWRuntime = $fixtureRequired -or $effectiveIntegrationMode -eq 'include'
  if ($requiresLabVIEWRuntime -and -not $lvComparePath) {
    throw 'LVCompare is not available at LVCOMPARE_PATH or the canonical install path.'
  }
  if ($lvComparePath) {
    $env:LVCOMPARE_PATH = $lvComparePath
  }

  $preSnapshotPath = Join-Path $resolvedResultsPath 'runner-unblock-snapshot-pre.json'
  Invoke-RunnerUnblockGuardLocal -SnapshotPath $preSnapshotPath -Cleanup:$effectiveCleanBefore

  if ($fixtureRequired) {
    $preparedFixtures = Invoke-PrepareFixturesLocal -RepoRoot $repoRoot -BaseSourcePath $BasePath -HeadSourcePath $HeadPath
    $env:LV_BASE_VI = $preparedFixtures.base
    $env:LV_HEAD_VI = $preparedFixtures.head
  }

  $env:LOCAL_DISPATCHER = '1'
  $env:DISABLE_STEP_SUMMARY = '1'
  if ($effectiveCleanBefore) { $env:CLEAN_LABVIEW = '1' }
  if ($effectiveCleanAfter) { $env:CLEAN_AFTER = '1' }
  if ($effectiveTrackArtifacts) { $env:SCAN_ARTIFACTS = '1' }
  if ($effectiveDetectLeaks) { $env:DETECT_LEAKS = '1' }
  if ($effectiveFailOnLeaks) { $env:FAIL_ON_LEAKS = '1' }
  if ($effectiveKillLeaks) { $env:KILL_LEAKS = '1' }
  $env:LEAK_GRACE_SECONDS = [string]$effectiveLeakGraceSeconds

  $lockScript = Join-Path $repoRoot 'tools/Session-Lock.ps1'
  pwsh -NoLogo -NoProfile -File $lockScript -Action Acquire -Group $SessionLockGroup -LockRoot $resolvedSessionLockRoot -QueueWaitSeconds $SessionLockQueueWaitSeconds -QueueMaxAttempts $SessionLockQueueMaxAttempts -StaleSeconds $SessionLockStaleSeconds -HeartbeatSeconds $SessionHeartbeatSeconds | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to acquire session lock for group '$SessionLockGroup' under '$resolvedSessionLockRoot' (exit $LASTEXITCODE)."
  }
  $sessionLockPath = Join-Path (Join-Path $resolvedSessionLockRoot $SessionLockGroup) 'lock.json'
  if (-not (Test-Path -LiteralPath $sessionLockPath -PathType Leaf)) {
    throw "Session lock file not found after acquire: $sessionLockPath"
  }
  $sessionLockRecord = Read-JsonFile -PathValue $sessionLockPath
  if (-not $sessionLockRecord.lockId) {
    throw "Session lock record missing lockId: $sessionLockPath"
  }
  $sessionLockId = [string]$sessionLockRecord.lockId
  $env:SESSION_LOCK_ID = $sessionLockId
  $env:SESSION_LOCK_GROUP = $SessionLockGroup
  $env:SESSION_LOCK_PATH = $sessionLockPath
  $env:SESSION_LOCK_ROOT = $resolvedSessionLockRoot
  $env:SESSION_HEARTBEAT_SECONDS = [string]$SessionHeartbeatSeconds

  $heartbeatJob = Start-ThreadJob -ScriptBlock {
    param($ScriptPath, $Seconds, $LockGroup, $LockRootPath, $LockId)
    $env:SESSION_LOCK_ID = $LockId
    $env:SESSION_LOCK_GROUP = $LockGroup
    $env:SESSION_LOCK_ROOT = $LockRootPath
    while ($true) {
      pwsh -NoLogo -NoProfile -File $ScriptPath -Action Heartbeat -Group $LockGroup -LockRoot $LockRootPath | Out-Null
      Start-Sleep -Seconds $Seconds
    }
  } -ArgumentList $lockScript, $SessionHeartbeatSeconds, $SessionLockGroup, $resolvedSessionLockRoot, $sessionLockId

  $invokeParams = @{
    TestsPath = $TestsPath
    ResultsPath = $resolvedResultsPath
    ExecutionPack = $executionPackResolution.executionPack
    IntegrationMode = $effectiveIntegrationMode
  }
  $effectiveIncludePatternsList = @($executionPackResolution.refineIncludePatterns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($effectiveIncludePatternsList.Count -gt 0) {
    $invokeParams.IncludePatterns = $effectiveIncludePatternsList
  }
  if ($effectiveEmitFailuresJsonAlways) { $invokeParams.EmitFailuresJsonAlways = $true }
  if ($effectiveTimeoutSeconds -gt 0) { $invokeParams.TimeoutSeconds = $effectiveTimeoutSeconds }
  if ($effectiveDetectLeaks) { $invokeParams.DetectLeaks = $true }
  if ($effectiveFailOnLeaks) { $invokeParams.FailOnLeaks = $true }
  if ($effectiveKillLeaks) { $invokeParams.KillLeaks = $true }
  if ($effectiveLeakGraceSeconds -gt 0) { $invokeParams.LeakGraceSeconds = $effectiveLeakGraceSeconds }
  if ($effectiveCleanBefore) { $invokeParams.CleanLabVIEW = $true }
  if ($effectiveCleanAfter) { $invokeParams.CleanAfter = $true }
  if ($effectiveTrackArtifacts) { $invokeParams.TrackArtifacts = $true }

  $dispatcherPath = Join-Path $repoRoot 'Invoke-PesterTests.ps1'
  $logPath = Join-Path $resolvedResultsPath 'pester-dispatcher.log'
  $dispatcherOutputTrace = Join-Path $resolvedResultsPath 'dispatcher-github-output.txt'
  $originalGitHubOutput = $env:GITHUB_OUTPUT
  if (Test-Path -LiteralPath $logPath) {
    Remove-Item -LiteralPath $logPath -Force
  }
  if (Test-Path -LiteralPath $dispatcherOutputTrace) {
    Remove-Item -LiteralPath $dispatcherOutputTrace -Force
  }

  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $dispatcherPath @invokeParams 2>&1 | Tee-Object -FilePath $logPath
    $dispatcherExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  } catch {
    $_ | Out-String | Tee-Object -FilePath $logPath -Append | Write-Host
    $dispatcherExitCode = if ($null -ne $LASTEXITCODE -and [int]$LASTEXITCODE -ne 0) { [int]$LASTEXITCODE } else { 1 }
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($null -ne $originalGitHubOutput) {
      $env:GITHUB_OUTPUT = $originalGitHubOutput
    } else {
      Remove-Item -Path Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    }
    if ($heartbeatJob) {
      Stop-Job -Id $heartbeatJob.Id -ErrorAction SilentlyContinue | Out-Null
      Remove-Job -Id $heartbeatJob.Id -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if ($sessionLockId) {
      $env:SESSION_LOCK_ID = $sessionLockId
      $env:SESSION_LOCK_GROUP = $SessionLockGroup
      $env:SESSION_LOCK_ROOT = $resolvedSessionLockRoot
      pwsh -NoLogo -NoProfile -File $lockScript -Action Heartbeat -Group $SessionLockGroup -LockRoot $resolvedSessionLockRoot | Out-Null
      pwsh -NoLogo -NoProfile -File $lockScript -Action Release -Group $SessionLockGroup -LockRoot $resolvedSessionLockRoot | Out-Null
    }
  }

  "exit_code=$dispatcherExitCode" | Out-File -FilePath $dispatcherOutputTrace -Append -Encoding utf8

  $postprocessToolPath = Join-Path $repoRoot 'tools/Invoke-PesterExecutionPostprocess.ps1'
  if (-not (Test-Path -LiteralPath $postprocessToolPath -PathType Leaf)) {
    throw "Postprocess tool not found: $postprocessToolPath"
  }
  & $postprocessToolPath -ResultsDir $resolvedResultsPath | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Pester execution postprocess failed with exit code $LASTEXITCODE."
  }
  $postprocessReportPath = Join-Path $resolvedResultsPath 'pester-execution-postprocess.json'
  if (Test-Path -LiteralPath $postprocessReportPath -PathType Leaf) {
    $postprocessReport = Read-JsonFile -PathValue $postprocessReportPath
    $postprocessStatus = [string]$postprocessReport.status
    $resultsXmlStatus = [string]$postprocessReport.resultsXmlStatus
  }

  $telemetryToolPath = Join-Path $repoRoot 'tools/Invoke-PesterExecutionTelemetry.ps1'
  if (-not (Test-Path -LiteralPath $telemetryToolPath -PathType Leaf)) {
    throw "Telemetry tool not found: $telemetryToolPath"
  }
  & $telemetryToolPath -ResultsDir $resolvedResultsPath | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Pester execution telemetry failed with exit code $LASTEXITCODE."
  }
  $telemetryReportPath = Join-Path $resolvedResultsPath 'pester-execution-telemetry.json'
  $telemetryReport = if (Test-Path -LiteralPath $telemetryReportPath -PathType Leaf) {
    Read-JsonFile -PathValue $telemetryReportPath
  } else {
    $null
  }

  $summaryPath = Join-Path $resolvedResultsPath 'pester-summary.json'
  $summaryPresent = Test-Path -LiteralPath $summaryPath
  if ($postprocessStatus -in @('results-xml-truncated', 'invalid-results-xml', 'missing-results-xml', 'unsupported-schema')) {
    $executionStatus = $postprocessStatus
    $executionJobResult = 'failure'
  } elseif ($summaryPresent -and $dispatcherExitCode -eq 0) {
    $executionStatus = 'completed'
    $executionJobResult = 'success'
  } elseif ($summaryPresent) {
    $executionStatus = 'test-failures'
    $executionJobResult = 'failure'
  } elseif ($dispatcherExitCode -ne 0) {
    $executionStatus = 'seam-defect'
    $executionJobResult = 'failure'
  }

  $receipt = [ordered]@{
    schema = 'pester-execution-receipt@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    source = 'local-harness'
    repository = $repository
    contextStatus = if ($contextReceipt) { [string]$contextReceipt.status } else { 'local-ready' }
    contextReceiptPath = ConvertTo-PortablePath $resolvedContextReceiptPath
    contextReceiptPresent = [bool]$contextReceipt
    standingPriorityIssue = $standingPriorityIssue
    readinessStatus = if ($readinessReceipt) { [string]$readinessReceipt.status } else { 'local-ready' }
    readinessReceiptPath = ConvertTo-PortablePath $resolvedReadinessReceiptPath
    readinessReceiptPresent = [bool]$readinessReceipt
    selectionStatus = if ($selectionReceipt) { [string]$selectionReceipt.status } else { 'local-ready' }
    selectionReceiptPath = ConvertTo-PortablePath $resolvedSelectionReceiptPath
    selectionReceiptPresent = [bool]$selectionReceipt
    selectionExecutionPack = [string]$executionPackResolution.executionPack
    selectionExecutionPackSource = [string]$executionPackResolution.executionPackSource
    selectionIntegrationMode = $effectiveIntegrationMode
    selectionFixtureRequired = $fixtureRequired
    baseIncludePatterns = @($executionPackResolution.baseIncludePatterns)
    refineIncludePatterns = @($executionPackResolution.refineIncludePatterns)
    effectiveIncludePatterns = @($executionPackResolution.effectiveIncludePatterns)
    includePatterns = @($executionPackResolution.effectiveIncludePatterns)
    dispatcherExitCode = $dispatcherExitCode
    telemetryPresent = [bool]$telemetryReport
    telemetryStatus = if ($telemetryReport) { [string]$telemetryReport.telemetryStatus } else { '' }
    telemetryLastKnownPhase = if ($telemetryReport) { [string]$telemetryReport.lastKnownPhase } else { '' }
    telemetryEventCount = if ($telemetryReport) { [int]$telemetryReport.eventCount } else { 0 }
    postprocessStatus = $postprocessStatus
    resultsXmlStatus  = $resultsXmlStatus
    executionJobResult = $executionJobResult
    summaryPresent = $summaryPresent
    status = $executionStatus
    pathHygieneStatus = if ($pathHygienePlan) { [string]$pathHygienePlan.status } else { 'clean' }
    rawArtifactName = 'pester-run-raw-local'
    localHarness = [ordered]@{
      dotnetReady = $dotnetReady
      lvComparePath = ConvertTo-PortablePath $lvComparePath
      fixtureBase = if ($preparedFixtures) { ConvertTo-PortablePath $preparedFixtures.base } else { $null }
      fixtureHead = if ($preparedFixtures) { ConvertTo-PortablePath $preparedFixtures.head } else { $null }
      timeoutSeconds = $effectiveTimeoutSeconds
      emitFailuresJsonAlways = $effectiveEmitFailuresJsonAlways
      detectLeaks = $effectiveDetectLeaks
      failOnLeaks = $effectiveFailOnLeaks
      killLeaks = $effectiveKillLeaks
      leakGraceSeconds = $effectiveLeakGraceSeconds
      cleanLabVIEWBefore = $effectiveCleanBefore
      cleanAfter = $effectiveCleanAfter
      trackArtifacts = $effectiveTrackArtifacts
      sessionLockGroup = $SessionLockGroup
      sessionLockRoot = ConvertTo-PortablePath $resolvedSessionLockRoot
      sessionLockPath = ConvertTo-PortablePath $sessionLockPath
      postprocessReportPath = ConvertTo-PortablePath $postprocessReportPath
      telemetryReportPath = ConvertTo-PortablePath $telemetryReportPath
      preSnapshotPath = ConvertTo-PortablePath $preSnapshotPath
      dispatcherLogPath = ConvertTo-PortablePath $logPath
      pathHygiene = $pathHygieneRecord
    }
  }

  $receiptPaths = Write-ExecutionReceiptFiles -ReceiptRoot $receiptRoot -Receipt $receipt

  Write-Host '### Local Pester execution harness' -ForegroundColor Cyan
  Write-Host ("executionPack : {0}" -f $executionPackResolution.executionPack)
  Write-Host ("status      : {0}" -f $executionStatus)
  Write-Host ("exitCode    : {0}" -f $dispatcherExitCode)
  Write-Host ("summary     : {0}" -f $summaryPresent)
  $telemetryStatusDisplay = if ($telemetryReport) { [string]$telemetryReport.telemetryStatus } else { 'missing' }
  Write-Host ("telemetry   : {0}" -f $telemetryStatusDisplay)
  Write-Host ("receipt     : {0}" -f $receiptPaths.receiptPath)
  Write-Host ("contract    : {0}" -f $receiptPaths.contractReceiptPath)
}
finally {
  if ($preparedFixtures -and $preparedFixtures.tempDir -and (Test-Path -LiteralPath $preparedFixtures.tempDir -PathType Container)) {
    Remove-Item -LiteralPath $preparedFixtures.tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  foreach ($envName in @(
      'LOCAL_DISPATCHER',
      'DISABLE_STEP_SUMMARY',
      'CLEAN_LABVIEW',
      'CLEAN_AFTER',
      'SCAN_ARTIFACTS',
      'DETECT_LEAKS',
      'FAIL_ON_LEAKS',
      'KILL_LEAKS',
      'LEAK_GRACE_SECONDS',
      'LV_BASE_VI',
      'LV_HEAD_VI',
      'SESSION_LOCK_ID',
      'SESSION_LOCK_GROUP',
      'SESSION_LOCK_PATH',
      'SESSION_LOCK_ROOT',
      'SESSION_HEARTBEAT_SECONDS'
    )) {
    Remove-Item "Env:$envName" -ErrorAction SilentlyContinue
  }
  Pop-Location
}

if ($executionStatus -ne 'completed') {
  exit ([Math]::Max($dispatcherExitCode, 1))
}
exit 0
