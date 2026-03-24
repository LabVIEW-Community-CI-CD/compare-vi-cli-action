<#
.SYNOPSIS
  Thin wrapper for TestStand: warmup LabVIEW runtime, run LVCompare, and optionally close.

.DESCRIPTION
  Sequentially invokes Warmup-LabVIEWRuntime.ps1 (to ensure LabVIEW readiness), then
  Invoke-LVCompare.ps1 to perform a deterministic compare, and finally optional close helpers.
  Writes a session-index.json with pointers to emitted crumbs and artifacts.

  Revision 2 adds an opt-in dual-plane native parity suite for LabVIEW 2026 x64/x32.
  The legacy single-plane session contract remains the default.
#>
[CmdletBinding()]
param(
[Parameter(Mandatory)][string]$BaseVi,
[Parameter(Mandatory)][string]$HeadVi,
[Alias('LabVIEWPath')]
[string]$LabVIEWExePath,
[ValidateSet('32','64')]
[string]$LabVIEWBitness = '64',
[Alias('LVCompareExePath')]
[string]$LVComparePath,
[string]$OutputRoot = 'tests/results/teststand-session',
[ValidateSet('detect','spawn','skip')]
[string]$Warmup = 'detect',
[string[]]$Flags,
[switch]$ReplaceFlags,
[ValidateSet('full','legacy')]
[string]$NoiseProfile = 'full',
[switch]$RenderReport,
[switch]$CloseLabVIEW,
[switch]$CloseLVCompare,
[int]$TimeoutSeconds = 600,
[switch]$DisableTimeout,
[string]$StagingRoot,
[switch]$SameNameHint,
[switch]$AllowSameLeaf,
[ValidateSet('single-compare','dual-plane-parity')]
[string]$SuiteClass = 'single-compare',
[string]$LabVIEW64ExePath,
[string]$LabVIEW32ExePath,
[switch]$InternalSinglePlane,
[ValidateSet('x64','x32')]
[string]$InternalPlaneKey,
[string]$AgentId = $env:CODEX_AGENT_ID,
[string]$AgentClass = $env:CODEX_AGENT_CLASS,
[string]$ExecutionCellLeasePath = $env:TESTSTAND_EXECUTION_CELL_LEASE_PATH,
[string]$ExecutionCellId = $env:TESTSTAND_EXECUTION_CELL_ID,
[string]$ExecutionCellLeaseId = $env:TESTSTAND_EXECUTION_CELL_LEASE_ID,
[string]$ExecutionCellSuiteClass = $env:TESTSTAND_EXECUTION_CELL_SUITE_CLASS,
[string]$HarnessInstanceLeasePath = $env:TESTSTAND_HARNESS_INSTANCE_LEASE_PATH,
[string]$HarnessInstanceId = $env:TESTSTAND_HARNESS_INSTANCE_ID,
[string]$ParentHarnessInstanceId = $env:TESTSTAND_PARENT_HARNESS_INSTANCE_ID
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { Import-Module ThreadJob -ErrorAction SilentlyContinue } catch {}

function New-Dir([string]$p){ if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Candidate
  )

  if ([System.IO.Path]::IsPathRooted($Candidate)) {
    return $Candidate
  }

  return (Join-Path $RepoRoot $Candidate)
}

function Resolve-LabVIEW2026Path {
  param([ValidateSet('32','64')][string]$Bitness)

  $root = if ($Bitness -eq '32') { ${env:ProgramFiles(x86)} } else { ${env:ProgramFiles} }
  if ([string]::IsNullOrWhiteSpace($root)) {
    return $null
  }
  return (Join-Path $root 'National Instruments\LabVIEW 2026\LabVIEW.exe')
}

function Convert-ToArchitectureLabel {
  param([ValidateSet('32','64')][string]$Bitness)
  if ($Bitness -eq '32') { return '32-bit' }
  return '64-bit'
}

function Invoke-WithTimeout {
  param(
    [scriptblock]$Block,
    [int]$TimeoutSeconds,
    [string]$Stage,
    [switch]$DisableTimeout,
    [object[]]$ArgumentList
  )

  if ($DisableTimeout -or $TimeoutSeconds -le 0) {
    if ($ArgumentList) {
      return & $Block @ArgumentList
    }
    return & $Block
  }

  $job = if ($ArgumentList) {
    Start-ThreadJob -ScriptBlock $Block -ArgumentList $ArgumentList
  } else {
    Start-ThreadJob -ScriptBlock $Block
  }
  try {
    if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
      try { Stop-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
      throw (New-Object System.TimeoutException("Harness stage '$Stage' exceeded ${TimeoutSeconds}s"))
    }
    return Receive-Job -Job $job
  } finally {
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function New-SessionOutcome {
  param([AllowNull()]$Capture)

  if ($null -eq $Capture) {
    return $null
  }

  return [ordered]@{
    exitCode = [int]$Capture.exitCode
    seconds  = [double]$Capture.seconds
    command  = $Capture.command
    diff     = [bool]($Capture.exitCode -eq 1)
  }
}

function Read-JsonFileIfPresent {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20
  } catch {
    return $null
  }
}

function Resolve-ExistingLiteralPath {
  param([AllowNull()][string]$LiteralPath)

  if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
    return $null
  }

  $resolved = Resolve-Path -LiteralPath $LiteralPath -ErrorAction SilentlyContinue
  if ($resolved) {
    return $resolved.Path
  }

  return $LiteralPath
}

function Get-FirstNonEmptyText {
  param([AllowNull()][object[]]$Values)

  foreach ($value in @($Values)) {
    if ($null -eq $value) {
      continue
    }
    $text = [string]$value
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      return $text
    }
  }

  return $null
}

function Resolve-TestStandExecutionCellContext {
  param(
    [AllowNull()][string]$ExecutionCellLeasePath,
    [AllowNull()][string]$ExecutionCellId,
    [AllowNull()][string]$ExecutionCellLeaseId,
    [AllowNull()][string]$ExecutionCellSuiteClass,
    [AllowNull()][string]$HarnessInstanceLeasePath,
    [AllowNull()][string]$HarnessInstanceId,
    [AllowNull()][string]$ParentHarnessInstanceId,
    [AllowNull()][string]$AgentId,
    [AllowNull()][string]$AgentClass,
    [AllowNull()][string]$SuiteClass,
    [AllowNull()][string]$PlaneName,
    [AllowNull()][string]$Role,
    [Parameter(Mandatory)][string]$OutputRoot
  )

  $resolvedLeasePath = Resolve-ExistingLiteralPath -LiteralPath $ExecutionCellLeasePath
  $lease = Read-JsonFileIfPresent -Path $resolvedLeasePath
  $leaseRequest = if ($lease -and $lease.PSObject.Properties['request']) { $lease.request } else { $null }
  $leaseGrant = if ($lease -and $lease.PSObject.Properties['grant']) { $lease.grant } else { $null }
  $leaseCommit = if ($lease -and $lease.PSObject.Properties['commit']) { $lease.commit } else { $null }
  $leaseHost = if ($lease -and $lease.PSObject.Properties['host']) { $lease.host } else { $null }
  $leaseCellId = if ($lease -and $lease.PSObject.Properties['cellId']) { $lease.cellId } else { $null }
  $leaseGrantLeaseId = if ($leaseGrant -and $leaseGrant.PSObject.Properties['leaseId']) { $leaseGrant.leaseId } else { $null }
  $leaseRequestAgentId = if ($leaseRequest -and $leaseRequest.PSObject.Properties['agentId']) { $leaseRequest.agentId } else { $null }
  $leaseRequestAgentClass = if ($leaseRequest -and $leaseRequest.PSObject.Properties['agentClass']) { $leaseRequest.agentClass } else { $null }
  $leaseRequestCellClass = if ($leaseRequest -and $leaseRequest.PSObject.Properties['cellClass']) { $leaseRequest.cellClass } else { $null }
  $leaseRequestSuiteClass = if ($leaseRequest -and $leaseRequest.PSObject.Properties['suiteClass']) { $leaseRequest.suiteClass } else { $null }
  $leaseRequestPlaneBinding = if ($leaseRequest -and $leaseRequest.PSObject.Properties['planeBinding']) { $leaseRequest.planeBinding } else { $null }
  $leaseRequestWorkingRoot = if ($leaseRequest -and $leaseRequest.PSObject.Properties['workingRoot']) { $leaseRequest.workingRoot } else { $null }
  $leaseRequestArtifactRoot = if ($leaseRequest -and $leaseRequest.PSObject.Properties['artifactRoot']) { $leaseRequest.artifactRoot } else { $null }
  $leaseRequestHarnessKind = if ($leaseRequest -and $leaseRequest.PSObject.Properties['harnessKind']) { $leaseRequest.harnessKind } else { $null }
  $leaseRequestOperatorAuthorizationRef = if ($leaseRequest -and $leaseRequest.PSObject.Properties['operatorAuthorizationRef']) { $leaseRequest.operatorAuthorizationRef } else { $null }
  $leaseCommitWorkingRoot = if ($leaseCommit -and $leaseCommit.PSObject.Properties['workingRoot']) { $leaseCommit.workingRoot } else { $null }
  $leaseCommitArtifactRoot = if ($leaseCommit -and $leaseCommit.PSObject.Properties['artifactRoot']) { $leaseCommit.artifactRoot } else { $null }
  $leaseHostIsolatedLaneGroupId = if ($leaseHost -and $leaseHost.PSObject.Properties['isolatedLaneGroupId']) { $leaseHost.isolatedLaneGroupId } else { $null }
  $leaseHostFingerprintSha256 = if ($leaseHost -and $leaseHost.PSObject.Properties['fingerprintSha256']) { $leaseHost.fingerprintSha256 } else { $null }
  $leaseGrantPremiumSaganMode = if ($leaseGrant -and $leaseGrant.PSObject.Properties['premiumSaganMode']) { $leaseGrant.premiumSaganMode } else { $null }

  $resolvedHarnessLeasePath = Resolve-ExistingLiteralPath -LiteralPath $HarnessInstanceLeasePath
  $harnessLease = Read-JsonFileIfPresent -Path $resolvedHarnessLeasePath
  $harnessLeaseRequest = if ($harnessLease -and $harnessLease.PSObject.Properties['request']) { $harnessLease.request } else { $null }
  $harnessLeaseGrant = if ($harnessLease -and $harnessLease.PSObject.Properties['grant']) { $harnessLease.grant } else { $null }
  $harnessLeaseCommit = if ($harnessLease -and $harnessLease.PSObject.Properties['commit']) { $harnessLease.commit } else { $null }
  $harnessLeaseInstanceId = if ($harnessLease -and $harnessLease.PSObject.Properties['instanceId']) { $harnessLease.instanceId } else { $null }
  $harnessLeaseGrantLeaseId = if ($harnessLeaseGrant -and $harnessLeaseGrant.PSObject.Properties['leaseId']) { $harnessLeaseGrant.leaseId } else { $null }
  $harnessLeaseRequestRole = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['role']) { $harnessLeaseRequest.role } else { $null }
  $harnessLeaseRequestPlaneKey = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['planeKey']) { $harnessLeaseRequest.planeKey } else { $null }
  $harnessLeaseRequestParentInstanceId = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['parentInstanceId']) { $harnessLeaseRequest.parentInstanceId } else { $null }
  $harnessLeaseRequestHarnessKind = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['harnessKind']) { $harnessLeaseRequest.harnessKind } else { $null }
  $harnessLeaseRequestRuntimeSurface = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['runtimeSurface']) { $harnessLeaseRequest.runtimeSurface } else { $null }
  $harnessLeaseRequestProcessModelClass = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['processModelClass']) { $harnessLeaseRequest.processModelClass } else { $null }
  $harnessLeaseRequestPlaneBinding = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['planeBinding']) { $harnessLeaseRequest.planeBinding } else { $null }
  $harnessLeaseRequestWorkingRoot = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['workingRoot']) { $harnessLeaseRequest.workingRoot } else { $null }
  $harnessLeaseRequestArtifactRoot = if ($harnessLeaseRequest -and $harnessLeaseRequest.PSObject.Properties['artifactRoot']) { $harnessLeaseRequest.artifactRoot } else { $null }
  $harnessLeaseCommitWorkingRoot = if ($harnessLeaseCommit -and $harnessLeaseCommit.PSObject.Properties['workingRoot']) { $harnessLeaseCommit.workingRoot } else { $null }
  $harnessLeaseCommitArtifactRoot = if ($harnessLeaseCommit -and $harnessLeaseCommit.PSObject.Properties['artifactRoot']) { $harnessLeaseCommit.artifactRoot } else { $null }

  $resolvedCellId = Get-FirstNonEmptyText @($ExecutionCellId, $leaseCellId)
  $resolvedLeaseId = Get-FirstNonEmptyText @($ExecutionCellLeaseId, $leaseGrantLeaseId)
  $resolvedAgentId = Get-FirstNonEmptyText @($AgentId, $leaseRequestAgentId)
  $resolvedAgentClass = (Get-FirstNonEmptyText @($AgentClass, $leaseRequestAgentClass))
  if ([string]::IsNullOrWhiteSpace($resolvedAgentClass)) {
    $resolvedAgentClass = 'subagent'
  }
  $resolvedSuiteClass = Get-FirstNonEmptyText @($ExecutionCellSuiteClass, $leaseRequestSuiteClass, $SuiteClass)
  $resolvedPlaneBinding = if ([string]::IsNullOrWhiteSpace($PlaneName)) {
    Get-FirstNonEmptyText @($harnessLeaseRequestPlaneBinding, $leaseRequestPlaneBinding, $(if ($resolvedSuiteClass -eq 'dual-plane-parity') { 'dual-plane-parity' } else { $null }))
  } else {
    $PlaneName
  }
  $resolvedWorkingRoot = Get-FirstNonEmptyText @($harnessLeaseCommitWorkingRoot, $harnessLeaseRequestWorkingRoot, $leaseCommitWorkingRoot, $leaseRequestWorkingRoot, $OutputRoot)
  $resolvedArtifactRoot = Get-FirstNonEmptyText @($harnessLeaseCommitArtifactRoot, $harnessLeaseRequestArtifactRoot, $leaseCommitArtifactRoot, $leaseRequestArtifactRoot, $OutputRoot)
  $resolvedHarnessKind = Get-FirstNonEmptyText @($harnessLeaseRequestHarnessKind, $leaseRequestHarnessKind, 'teststand-compare-harness')
  $resolvedParentHarnessInstanceId = Get-FirstNonEmptyText @($harnessLeaseRequestParentInstanceId, $ParentHarnessInstanceId)
  $resolvedRole = Get-FirstNonEmptyText @($harnessLeaseRequestRole, $Role, $(if (-not [string]::IsNullOrWhiteSpace($resolvedParentHarnessInstanceId)) { 'plane-child' } elseif ($resolvedSuiteClass -eq 'dual-plane-parity' -and [string]::IsNullOrWhiteSpace($PlaneName)) { 'coordinator' } else { 'single-plane' }))
  $resolvedProcessModelClass = Get-FirstNonEmptyText @($harnessLeaseRequestProcessModelClass, $(if ($resolvedSuiteClass -eq 'dual-plane-parity') {
    'parallel-process-model'
  } else {
    'sequential-process-model'
  }))
  $resolvedRuntimeSurface = Get-FirstNonEmptyText @($harnessLeaseRequestRuntimeSurface, 'windows-native-teststand')

  $planeSuffix = if ($PlaneName -match '2026-64$') {
    'x64'
  } elseif ($PlaneName -match '2026-32$') {
    'x32'
  } else {
    'plane'
  }
  $resolvedHarnessInstanceId = Get-FirstNonEmptyText @(
    $harnessLeaseInstanceId,
    $HarnessInstanceId,
    $(if (-not [string]::IsNullOrWhiteSpace($resolvedParentHarnessInstanceId)) { '{0}-{1}' -f $resolvedParentHarnessInstanceId, $planeSuffix } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($resolvedCellId)) { '{0}-{1}' -f $resolvedHarnessKind, $resolvedCellId } else { $null }),
    $(if (-not [string]::IsNullOrWhiteSpace($PlaneName)) { '{0}-{1}' -f $resolvedHarnessKind, $planeSuffix } else { $resolvedHarnessKind })
  )

  $executionCell = $null
  if (-not [string]::IsNullOrWhiteSpace($resolvedCellId) -or -not [string]::IsNullOrWhiteSpace($resolvedLeaseId) -or -not [string]::IsNullOrWhiteSpace($resolvedAgentId) -or -not [string]::IsNullOrWhiteSpace($resolvedLeasePath)) {
    $executionCell = [ordered]@{
      cellId = $resolvedCellId
      leaseId = $resolvedLeaseId
      leasePath = $resolvedLeasePath
      agentId = $resolvedAgentId
      agentClass = $resolvedAgentClass
      cellClass = Get-FirstNonEmptyText @($leaseRequestCellClass)
      suiteClass = $resolvedSuiteClass
      planeBinding = $resolvedPlaneBinding
      runtimeSurface = $resolvedRuntimeSurface
      premiumSaganMode = if ($null -eq $leaseGrantPremiumSaganMode) { $false } else { [bool]$leaseGrantPremiumSaganMode }
      operatorAuthorizationRef = Get-FirstNonEmptyText @($leaseRequestOperatorAuthorizationRef)
      workingRoot = $resolvedWorkingRoot
      artifactRoot = $resolvedArtifactRoot
      isolatedLaneGroupId = Get-FirstNonEmptyText @($leaseHostIsolatedLaneGroupId)
      hostOsFingerprintSha256 = Get-FirstNonEmptyText @($leaseHostFingerprintSha256)
    }
  }

  $harnessInstance = [ordered]@{
    harnessKind = $resolvedHarnessKind
    instanceId = $resolvedHarnessInstanceId
    leaseId = Get-FirstNonEmptyText @($harnessLeaseGrantLeaseId)
    leasePath = $resolvedHarnessLeasePath
    role = $resolvedRole
    processModelClass = $resolvedProcessModelClass
    planeBinding = $resolvedPlaneBinding
    parentInstanceId = $resolvedParentHarnessInstanceId
  }

  $processModel = [ordered]@{
    runtimeSurface = $resolvedRuntimeSurface
    processModelClass = $resolvedProcessModelClass
    windowsOnly = $true
    rootHarnessInstanceId = Get-FirstNonEmptyText @($resolvedParentHarnessInstanceId, $resolvedHarnessInstanceId)
    planeCount = if ($resolvedSuiteClass -eq 'dual-plane-parity') { 2 } else { 1 }
  }

  return [pscustomobject]@{
    executionCell = $executionCell
    harnessInstance = $harnessInstance
    processModel = $processModel
  }
}

function Invoke-TestStandSinglePlaneSession {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$BaseVi,
    [Parameter(Mandatory)][string]$HeadVi,
    [AllowNull()][string]$LabVIEWExePath,
    [ValidateSet('32','64')][string]$LabVIEWBitness = '64',
    [AllowNull()][string]$LVComparePath,
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateSet('detect','spawn','skip')][string]$Warmup,
    [AllowNull()][string]$SuiteClass,
    [AllowNull()][string[]]$Flags,
    [bool]$ReplaceFlags,
    [ValidateSet('full','legacy')][string]$NoiseProfile,
    [bool]$RenderReport,
    [bool]$CloseLabVIEW,
    [bool]$CloseLVCompare,
    [int]$TimeoutSeconds,
    [bool]$DisableTimeout,
    [AllowNull()][string]$StagingRoot,
    [bool]$SameNameHint,
    [bool]$AllowSameLeaf,
    [AllowNull()][string]$PlaneName,
    [AllowNull()][string]$AgentId,
    [AllowNull()][string]$AgentClass,
    [AllowNull()][string]$ExecutionCellLeasePath,
    [AllowNull()][string]$ExecutionCellId,
    [AllowNull()][string]$ExecutionCellLeaseId,
    [AllowNull()][string]$ExecutionCellSuiteClass,
    [AllowNull()][string]$HarnessInstanceLeasePath,
    [AllowNull()][string]$HarnessInstanceId,
    [AllowNull()][string]$ParentHarnessInstanceId,
    [AllowNull()][string]$HarnessRole
  )

  $resolvedOutputRoot = Resolve-AbsolutePath -RepoRoot $RepoRoot -Candidate $OutputRoot
  $cellLeaseContext = Resolve-TestStandExecutionCellContext -ExecutionCellLeasePath $ExecutionCellLeasePath -ExecutionCellId $ExecutionCellId -ExecutionCellLeaseId $ExecutionCellLeaseId -ExecutionCellSuiteClass $ExecutionCellSuiteClass -HarnessInstanceLeasePath $HarnessInstanceLeasePath -HarnessInstanceId $HarnessInstanceId -ParentHarnessInstanceId $ParentHarnessInstanceId -AgentId $AgentId -AgentClass $AgentClass -SuiteClass $SuiteClass -PlaneName $PlaneName -Role $HarnessRole -OutputRoot $resolvedOutputRoot
  $paths = [ordered]@{
    warmupDir = Join-Path $resolvedOutputRoot '_warmup'
    compareDir = Join-Path $resolvedOutputRoot 'compare'
  }
  New-Dir $paths.warmupDir
  New-Dir $paths.compareDir

  $baseLeaf = Split-Path -Path $BaseVi -Leaf
  $headLeaf = Split-Path -Path $HeadVi -Leaf
  $sameName = [string]::Equals($baseLeaf, $headLeaf, [System.StringComparison]::OrdinalIgnoreCase)
  $baseResolved = (Resolve-Path -LiteralPath $BaseVi -ErrorAction Stop).Path
  $headResolved = (Resolve-Path -LiteralPath $HeadVi -ErrorAction Stop).Path
  if ($baseResolved -ne $headResolved) {
    $baseResolvedLeaf = Split-Path -Path $baseResolved -Leaf
    $headResolvedLeaf = Split-Path -Path $headResolved -Leaf
    if ([string]::Equals($baseResolvedLeaf, $headResolvedLeaf, [System.StringComparison]::OrdinalIgnoreCase) -and -not $AllowSameLeaf) {
      throw ("LVCompare limitation: staged inputs must have distinct filenames. Received '{0}' and '{1}'." -f $BaseVi, $HeadVi)
    }
  }
  if ($SameNameHint) {
    $sameName = $true
  }

  $rawPolicy = $env:LVCI_COMPARE_POLICY
  $policy = if ([string]::IsNullOrWhiteSpace($rawPolicy)) { 'cli-only' } else { $rawPolicy }
  $rawMode = $env:LVCI_COMPARE_MODE
  $mode = if ([string]::IsNullOrWhiteSpace($rawMode)) { 'labview-cli' } else { $rawMode }
  $autoCli = $false
  $effectiveWarmup = $Warmup
  if ($sameName -and $policy -ne 'lv-only') {
    $autoCli = $true
    if ($effectiveWarmup -ne 'skip') {
      Write-Host "Harness: skipping warmup for same-name VIs (CLI path auto-selected)." -ForegroundColor Gray
      $effectiveWarmup = 'skip'
    }
  }
  if ($policy -eq 'cli-only') {
    if ($effectiveWarmup -ne 'skip') {
      Write-Host "Harness: skipping warmup (headless CLI default policy)." -ForegroundColor Gray
      $effectiveWarmup = 'skip'
    }
  }
  if ([string]::IsNullOrWhiteSpace($rawPolicy)) {
    try { [System.Environment]::SetEnvironmentVariable('LVCI_COMPARE_POLICY', $policy, 'Process') } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($rawMode)) {
    try { [System.Environment]::SetEnvironmentVariable('LVCI_COMPARE_MODE', $mode, 'Process') } catch {}
  }

  $warmupLog = Join-Path $paths.warmupDir 'labview-runtime.ndjson'
  $compareLog = Join-Path $paths.compareDir 'compare-events.ndjson'
  $capPath = Join-Path $paths.compareDir 'lvcompare-capture.json'
  $reportPath = Join-Path $paths.compareDir 'compare-report.html'
  $cap = $null
  $warmupRan = $false
  $err = $null
  $closeLVCompareScript = Join-Path $RepoRoot 'tools' 'Close-LVCompare.ps1'
  $closeLabVIEWScript = Join-Path $RepoRoot 'tools' 'Close-LabVIEW.ps1'
  $effectiveTimeout = if ($DisableTimeout) { 0 } else { [Math]::Max(0, [int]$TimeoutSeconds) }

  try {
    if ($effectiveWarmup -ne 'skip') {
      $warmupScript = Join-Path $RepoRoot 'tools' 'Warmup-LabVIEWRuntime.ps1'
      if (-not (Test-Path -LiteralPath $warmupScript)) { throw "Warmup-LabVIEWRuntime.ps1 not found at $warmupScript" }
      $warmParams = @{ JsonLogPath = $warmupLog; SupportedBitness = $LabVIEWBitness }
      if ($LabVIEWExePath) { $warmParams.LabVIEWPath = $LabVIEWExePath }
      $warmupRunner = {
        param($warmupScriptPath, $warmupParameters)
        & $warmupScriptPath @warmupParameters | Out-Null
      }
      try {
        Invoke-WithTimeout -Block $warmupRunner -TimeoutSeconds $effectiveTimeout -Stage 'warmup' -DisableTimeout:$DisableTimeout -ArgumentList @($warmupScript, $warmParams) | Out-Null
        $warmupRan = $true
      } catch {
        $err = $_.Exception.Message
        throw
      }
    }

    $invoke = Join-Path $RepoRoot 'tools' 'Invoke-LVCompare.ps1'
    if (-not (Test-Path -LiteralPath $invoke)) { throw "Invoke-LVCompare.ps1 not found at $invoke" }
    $invokeParams = @{
      BaseVi = $BaseVi
      HeadVi = $HeadVi
      OutputDir = $paths.compareDir
      JsonLogPath = $compareLog
      RenderReport = $RenderReport
      NoiseProfile = $NoiseProfile
      LabVIEWBitness = $LabVIEWBitness
    }
    if ($LabVIEWExePath) { $invokeParams.LabVIEWExePath = $LabVIEWExePath }
    if ($LVComparePath) { $invokeParams.LVComparePath = $LVComparePath }
    if ($Flags) { $invokeParams.Flags = $Flags }
    if ($ReplaceFlags) { $invokeParams.ReplaceFlags = $true }
    if ($AllowSameLeaf) { $invokeParams.AllowSameLeaf = $true }
    $compareRunner = {
      param($invokePath, $invokeParameters)
      & $invokePath @invokeParameters | Out-Null
    }
    Invoke-WithTimeout -Block $compareRunner -TimeoutSeconds $effectiveTimeout -Stage 'compare' -DisableTimeout:$DisableTimeout -ArgumentList @($invoke, $invokeParams) | Out-Null
    if (Test-Path -LiteralPath $capPath) { $cap = Get-Content -LiteralPath $capPath -Raw | ConvertFrom-Json }
  } catch {
    $err = $_.Exception.Message
  } finally {
    if ($CloseLVCompare -and (Test-Path -LiteralPath $closeLVCompareScript)) {
      try { & $closeLVCompareScript | Out-Null } catch {}
    }
    if ($CloseLabVIEW -and (Test-Path -LiteralPath $closeLabVIEWScript)) {
      try {
        $closeParams = @{ SupportedBitness = $LabVIEWBitness }
        if ($LabVIEWExePath) { $closeParams.LabVIEWExePath = $LabVIEWExePath }
        & $closeLabVIEWScript @closeParams | Out-Null
      } catch {}
    }
  }

  $reportExists = Test-Path -LiteralPath $reportPath -PathType Leaf
  $warmupNode = [ordered]@{
    mode   = $effectiveWarmup
    events = if ($warmupRan) { $warmupLog } else { $null }
  }
  $compareNode = [ordered]@{
    events  = $compareLog
    capture = $capPath
    report  = $reportExists
  }
  $compareNode.staging = [ordered]@{
    enabled = [bool]([string]::IsNullOrWhiteSpace($StagingRoot) -eq $false)
    root    = if ([string]::IsNullOrWhiteSpace($StagingRoot)) { $null } else { $StagingRoot }
  }
  $compareNode.allowSameLeaf = $AllowSameLeaf
  if ($cap) {
    if ($cap.PSObject.Properties['command']) { $compareNode.command = $cap.command }
    if ($cap.PSObject.Properties['cliPath']) { $compareNode.cliPath = $cap.cliPath }
    if ($cap.PSObject.Properties['environment']) {
      $envNode = $cap.environment
      if ($envNode -and $envNode.PSObject.Properties['cli']) {
        $compareNode.cli = $envNode.cli
      }
    }
  }
  $compareNode.autoCli = $autoCli
  $compareNode.sameName = $sameName
  $compareNode.timeoutSeconds = $effectiveTimeout
  if ($env:LVCI_COMPARE_POLICY) { $compareNode.policy = $env:LVCI_COMPARE_POLICY }
  if ($env:LVCI_COMPARE_MODE) { $compareNode.mode = $env:LVCI_COMPARE_MODE }

  $planeRecord = [ordered]@{
    plane = if ([string]::IsNullOrWhiteSpace($PlaneName)) { $null } else { $PlaneName }
    architecture = Convert-ToArchitectureLabel -Bitness $LabVIEWBitness
    labviewExePath = if ([string]::IsNullOrWhiteSpace($LabVIEWExePath)) { $null } else { $LabVIEWExePath }
    outputRoot = $resolvedOutputRoot
    warmup = $warmupNode
    compare = $compareNode
    outcome = New-SessionOutcome -Capture $cap
    error = $err
    exitCode = if ($cap) { [int]$cap.exitCode } else { 1 }
    executionCell = $cellLeaseContext.executionCell
    harnessInstance = $cellLeaseContext.harnessInstance
    processModel = $cellLeaseContext.processModel
  }

  return [pscustomobject]$planeRecord
}

function Write-TestStandV1SessionIndex {
  param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][object]$PlaneSession
  )

  $index = [ordered]@{
    schema  = 'teststand-compare-session/v1'
    at      = (Get-Date).ToString('o')
    warmup  = $PlaneSession.warmup
    compare = $PlaneSession.compare
    outcome = $PlaneSession.outcome
    error   = $PlaneSession.error
    executionCell = $PlaneSession.executionCell
    harnessInstance = $PlaneSession.harnessInstance
    processModel = $PlaneSession.processModel
  }

  $indexPath = Join-Path $OutputRoot 'session-index.json'
  New-Dir $OutputRoot
  $index | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $indexPath -Encoding utf8
}

function Convert-ToParityComparableValue {
  param($Value)
  if ($null -eq $Value) { return $null }
  return $Value
}

function New-DualPlaneParitySummary {
  param(
    [Parameter(Mandatory)][object]$X64Session,
    [Parameter(Mandatory)][object]$X32Session
  )

  $mismatches = New-Object System.Collections.Generic.List[object]
  $comparedFields = @('outcome.exitCode', 'outcome.diff', 'compare.report', 'compare.mode', 'compare.policy')

  foreach ($field in $comparedFields) {
    $x64Value = switch ($field) {
      'outcome.exitCode' { Convert-ToParityComparableValue $X64Session.outcome.exitCode }
      'outcome.diff' { Convert-ToParityComparableValue $X64Session.outcome.diff }
      'compare.report' { Convert-ToParityComparableValue $X64Session.compare.report }
      'compare.mode' { Convert-ToParityComparableValue $X64Session.compare.mode }
      'compare.policy' { Convert-ToParityComparableValue $X64Session.compare.policy }
      default { $null }
    }
    $x32Value = switch ($field) {
      'outcome.exitCode' { Convert-ToParityComparableValue $X32Session.outcome.exitCode }
      'outcome.diff' { Convert-ToParityComparableValue $X32Session.outcome.diff }
      'compare.report' { Convert-ToParityComparableValue $X32Session.compare.report }
      'compare.mode' { Convert-ToParityComparableValue $X32Session.compare.mode }
      'compare.policy' { Convert-ToParityComparableValue $X32Session.compare.policy }
      default { $null }
    }

    if ($x64Value -ne $x32Value) {
      $mismatches.Add([ordered]@{ field = $field; x64 = $x64Value; x32 = $x32Value }) | Out-Null
    }
  }

  $incomplete = (
    ($null -eq $X64Session.outcome) -or
    ($null -eq $X32Session.outcome) -or
    (-not [string]::IsNullOrWhiteSpace([string]$X64Session.error)) -or
    (-not [string]::IsNullOrWhiteSpace([string]$X32Session.error))
  )

  $status = if ($incomplete) {
    'incomplete'
  } elseif ($mismatches.Count -gt 0) {
    'mismatch'
  } else {
    'match'
  }

  return [ordered]@{
    status = $status
    comparedFields = $comparedFields
    exitCodeParity = if ($null -eq $X64Session.outcome -or $null -eq $X32Session.outcome) { $null } else { [bool]($X64Session.outcome.exitCode -eq $X32Session.outcome.exitCode) }
    diffParity = if ($null -eq $X64Session.outcome -or $null -eq $X32Session.outcome) { $null } else { [bool]($X64Session.outcome.diff -eq $X32Session.outcome.diff) }
    mismatchCount = $mismatches.Count
    mismatches = @($mismatches.ToArray())
  }
}

function Wait-ForChildProcesses {
  param(
    [Parameter(Mandatory)][System.Diagnostics.Process[]]$Processes,
    [int]$TimeoutSeconds = 0
  )

  $deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { $null }
  while ($true) {
    $active = @($Processes | Where-Object { -not $_.HasExited })
    if ($active.Count -eq 0) {
      break
    }
    if ($deadline -and (Get-Date) -gt $deadline) {
      foreach ($proc in $active) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
      }
      throw (New-Object System.TimeoutException("Dual-plane parity suite exceeded ${TimeoutSeconds}s"))
    }
    Start-Sleep -Milliseconds 250
    foreach ($proc in $Processes) {
      try { $null = $proc.Refresh() } catch {}
    }
  }
}

function Start-DualPlaneChildProcess {
  param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$PlaneKey,
    [Parameter(Mandatory)][string]$BaseVi,
    [Parameter(Mandatory)][string]$HeadVi,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$LabVIEWExePath,
    [Parameter(Mandatory)][ValidateSet('32','64')][string]$LabVIEWBitness,
    [AllowNull()][string]$LVComparePath,
    [ValidateSet('detect','spawn','skip')][string]$Warmup,
    [AllowNull()][string[]]$Flags,
    [bool]$ReplaceFlags,
    [ValidateSet('full','legacy')][string]$NoiseProfile,
    [bool]$RenderReport,
    [bool]$CloseLabVIEW,
    [bool]$CloseLVCompare,
    [int]$TimeoutSeconds,
    [bool]$DisableTimeout,
    [AllowNull()][string]$StagingRoot,
    [bool]$SameNameHint,
    [bool]$AllowSameLeaf,
    [AllowNull()][string]$AgentId,
    [AllowNull()][string]$AgentClass,
    [AllowNull()][string]$ExecutionCellLeasePath,
    [AllowNull()][string]$ExecutionCellId,
    [AllowNull()][string]$ExecutionCellLeaseId,
    [AllowNull()][string]$ExecutionCellSuiteClass,
    [AllowNull()][string]$HarnessInstanceLeasePath,
    [AllowNull()][string]$ParentHarnessInstanceId
  )

  $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
  $args = New-Object System.Collections.Generic.List[string]
  $args.Add('-NoLogo') | Out-Null
  $args.Add('-NoProfile') | Out-Null
  $args.Add('-File') | Out-Null
  $args.Add($ScriptPath) | Out-Null
  $args.Add('-BaseVi') | Out-Null
  $args.Add($BaseVi) | Out-Null
  $args.Add('-HeadVi') | Out-Null
  $args.Add($HeadVi) | Out-Null
  $args.Add('-OutputRoot') | Out-Null
  $args.Add($OutputRoot) | Out-Null
  $args.Add('-LabVIEWExePath') | Out-Null
  $args.Add($LabVIEWExePath) | Out-Null
  $args.Add('-LabVIEWBitness') | Out-Null
  $args.Add($LabVIEWBitness) | Out-Null
  $args.Add('-Warmup') | Out-Null
  $args.Add($Warmup) | Out-Null
  $args.Add('-NoiseProfile') | Out-Null
  $args.Add($NoiseProfile) | Out-Null
  $args.Add('-SuiteClass') | Out-Null
  $args.Add('single-compare') | Out-Null
  $args.Add('-InternalSinglePlane') | Out-Null
  $args.Add('-InternalPlaneKey') | Out-Null
  $args.Add($PlaneKey) | Out-Null

  if ($LVComparePath) {
    $args.Add('-LVComparePath') | Out-Null
    $args.Add($LVComparePath) | Out-Null
  }
  if ($Flags) {
    foreach ($flag in $Flags) {
      $args.Add('-Flags') | Out-Null
      $args.Add($flag) | Out-Null
    }
  }
  if ($ReplaceFlags) { $args.Add('-ReplaceFlags') | Out-Null }
  if ($RenderReport) { $args.Add('-RenderReport') | Out-Null }
  if ($CloseLabVIEW) { $args.Add('-CloseLabVIEW') | Out-Null }
  if ($CloseLVCompare) { $args.Add('-CloseLVCompare') | Out-Null }
  if ($DisableTimeout) { $args.Add('-DisableTimeout') | Out-Null } else {
    $args.Add('-TimeoutSeconds') | Out-Null
    $args.Add([string]$TimeoutSeconds) | Out-Null
  }
  if ($StagingRoot) {
    $args.Add('-StagingRoot') | Out-Null
    $args.Add($StagingRoot) | Out-Null
  }
  if ($AgentId) {
    $args.Add('-AgentId') | Out-Null
    $args.Add($AgentId) | Out-Null
  }
  if ($AgentClass) {
    $args.Add('-AgentClass') | Out-Null
    $args.Add($AgentClass) | Out-Null
  }
  if ($ExecutionCellLeasePath) {
    $args.Add('-ExecutionCellLeasePath') | Out-Null
    $args.Add($ExecutionCellLeasePath) | Out-Null
  }
  if ($ExecutionCellId) {
    $args.Add('-ExecutionCellId') | Out-Null
    $args.Add($ExecutionCellId) | Out-Null
  }
  if ($ExecutionCellLeaseId) {
    $args.Add('-ExecutionCellLeaseId') | Out-Null
    $args.Add($ExecutionCellLeaseId) | Out-Null
  }
  if ($ExecutionCellSuiteClass) {
    $args.Add('-ExecutionCellSuiteClass') | Out-Null
    $args.Add($ExecutionCellSuiteClass) | Out-Null
  }
  if ($HarnessInstanceLeasePath) {
    $args.Add('-HarnessInstanceLeasePath') | Out-Null
    $args.Add($HarnessInstanceLeasePath) | Out-Null
  }
  if ($ParentHarnessInstanceId) {
    $args.Add('-ParentHarnessInstanceId') | Out-Null
    $args.Add($ParentHarnessInstanceId) | Out-Null
  }
  if ($SameNameHint) { $args.Add('-SameNameHint') | Out-Null }
  if ($AllowSameLeaf) { $args.Add('-AllowSameLeaf') | Out-Null }

  return Start-Process -FilePath $pwsh -ArgumentList @($args.ToArray()) -PassThru -WindowStyle Hidden
}

function Invoke-DualPlaneParitySuite {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$BaseVi,
    [Parameter(Mandatory)][string]$HeadVi,
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowNull()][string]$DefaultLabVIEWExePath,
    [AllowNull()][string]$LabVIEW64ExePath,
    [AllowNull()][string]$LabVIEW32ExePath,
    [AllowNull()][string]$LVComparePath,
    [ValidateSet('detect','spawn','skip')][string]$Warmup,
    [AllowNull()][string[]]$Flags,
    [bool]$ReplaceFlags,
    [ValidateSet('full','legacy')][string]$NoiseProfile,
    [bool]$RenderReport,
    [bool]$CloseLabVIEW,
    [bool]$CloseLVCompare,
    [int]$TimeoutSeconds,
    [bool]$DisableTimeout,
    [AllowNull()][string]$StagingRoot,
    [bool]$SameNameHint,
    [bool]$AllowSameLeaf,
    [AllowNull()][string]$AgentId,
    [AllowNull()][string]$AgentClass,
    [AllowNull()][string]$ExecutionCellLeasePath,
    [AllowNull()][string]$ExecutionCellId,
    [AllowNull()][string]$ExecutionCellLeaseId,
    [AllowNull()][string]$HarnessInstanceLeasePath,
    [AllowNull()][string]$HarnessInstanceId
  )

  $resolvedOutputRoot = Resolve-AbsolutePath -RepoRoot $RepoRoot -Candidate $OutputRoot
  New-Dir $resolvedOutputRoot
  $dualPlaneContext = Resolve-TestStandExecutionCellContext -ExecutionCellLeasePath $ExecutionCellLeasePath -ExecutionCellId $ExecutionCellId -ExecutionCellLeaseId $ExecutionCellLeaseId -ExecutionCellSuiteClass 'dual-plane-parity' -HarnessInstanceLeasePath $HarnessInstanceLeasePath -HarnessInstanceId $HarnessInstanceId -AgentId $AgentId -AgentClass $AgentClass -SuiteClass 'dual-plane-parity' -PlaneName $null -Role 'coordinator' -OutputRoot $resolvedOutputRoot

  $x64LabVIEW = if ([string]::IsNullOrWhiteSpace($LabVIEW64ExePath)) {
    if ([string]::IsNullOrWhiteSpace($DefaultLabVIEWExePath)) { Resolve-LabVIEW2026Path -Bitness '64' } else { $DefaultLabVIEWExePath }
  } else {
    $LabVIEW64ExePath
  }
  $x32LabVIEW = if ([string]::IsNullOrWhiteSpace($LabVIEW32ExePath)) { Resolve-LabVIEW2026Path -Bitness '32' } else { $LabVIEW32ExePath }

  $planesRoot = Join-Path $resolvedOutputRoot 'planes'
  $x64Root = Join-Path $planesRoot 'x64'
  $x32Root = Join-Path $planesRoot 'x32'
  New-Dir $x64Root
  New-Dir $x32Root

  $suiteTimeout = if ($DisableTimeout -or $TimeoutSeconds -le 0) { 0 } else { [Math]::Max(30, $TimeoutSeconds + 30) }

  $x64Process = Start-DualPlaneChildProcess -ScriptPath $ScriptPath -PlaneKey 'x64' -BaseVi $BaseVi -HeadVi $HeadVi -OutputRoot $x64Root -LabVIEWExePath $x64LabVIEW -LabVIEWBitness '64' -LVComparePath $LVComparePath -Warmup $Warmup -Flags $Flags -ReplaceFlags:$ReplaceFlags -NoiseProfile $NoiseProfile -RenderReport:$RenderReport -CloseLabVIEW:$CloseLabVIEW -CloseLVCompare:$CloseLVCompare -TimeoutSeconds $TimeoutSeconds -DisableTimeout:$DisableTimeout -StagingRoot $StagingRoot -SameNameHint:$SameNameHint -AllowSameLeaf:$AllowSameLeaf -AgentId $AgentId -AgentClass $AgentClass -ExecutionCellLeasePath $ExecutionCellLeasePath -ExecutionCellId $ExecutionCellId -ExecutionCellLeaseId $ExecutionCellLeaseId -ExecutionCellSuiteClass 'dual-plane-parity' -ParentHarnessInstanceId $dualPlaneContext.harnessInstance.instanceId
  $x32Process = Start-DualPlaneChildProcess -ScriptPath $ScriptPath -PlaneKey 'x32' -BaseVi $BaseVi -HeadVi $HeadVi -OutputRoot $x32Root -LabVIEWExePath $x32LabVIEW -LabVIEWBitness '32' -LVComparePath $LVComparePath -Warmup $Warmup -Flags $Flags -ReplaceFlags:$ReplaceFlags -NoiseProfile $NoiseProfile -RenderReport:$RenderReport -CloseLabVIEW:$CloseLabVIEW -CloseLVCompare:$CloseLVCompare -TimeoutSeconds $TimeoutSeconds -DisableTimeout:$DisableTimeout -StagingRoot $StagingRoot -SameNameHint:$SameNameHint -AllowSameLeaf:$AllowSameLeaf -AgentId $AgentId -AgentClass $AgentClass -ExecutionCellLeasePath $ExecutionCellLeasePath -ExecutionCellId $ExecutionCellId -ExecutionCellLeaseId $ExecutionCellLeaseId -ExecutionCellSuiteClass 'dual-plane-parity' -ParentHarnessInstanceId $dualPlaneContext.harnessInstance.instanceId

  Wait-ForChildProcesses -Processes @($x64Process, $x32Process) -TimeoutSeconds $suiteTimeout

  $x64IndexPath = Join-Path $x64Root 'session-index.json'
  $x32IndexPath = Join-Path $x32Root 'session-index.json'
  if (-not (Test-Path -LiteralPath $x64IndexPath -PathType Leaf)) {
    throw "Dual-plane parity suite missing x64 session index at $x64IndexPath"
  }
  if (-not (Test-Path -LiteralPath $x32IndexPath -PathType Leaf)) {
    throw "Dual-plane parity suite missing x32 session index at $x32IndexPath"
  }

  $x64Index = Get-Content -LiteralPath $x64IndexPath -Raw | ConvertFrom-Json -Depth 12
  $x32Index = Get-Content -LiteralPath $x32IndexPath -Raw | ConvertFrom-Json -Depth 12

  $x64Session = [pscustomobject][ordered]@{
    plane = 'native-labview-2026-64'
    architecture = '64-bit'
    labviewExePath = $x64LabVIEW
    outputRoot = $x64Root
    warmup = $x64Index.warmup
    compare = $x64Index.compare
    outcome = $x64Index.outcome
    error = $x64Index.error
    exitCode = if ($null -ne $x64Index.outcome) { [int]$x64Index.outcome.exitCode } else { if ($x64Process.ExitCode -is [int]) { [int]$x64Process.ExitCode } else { 1 } }
    executionCell = $x64Index.executionCell
    harnessInstance = $x64Index.harnessInstance
    processModel = $x64Index.processModel
  }
  $x32Session = [pscustomobject][ordered]@{
    plane = 'native-labview-2026-32'
    architecture = '32-bit'
    labviewExePath = $x32LabVIEW
    outputRoot = $x32Root
    warmup = $x32Index.warmup
    compare = $x32Index.compare
    outcome = $x32Index.outcome
    error = $x32Index.error
    exitCode = if ($null -ne $x32Index.outcome) { [int]$x32Index.outcome.exitCode } else { if ($x32Process.ExitCode -is [int]) { [int]$x32Process.ExitCode } else { 1 } }
    executionCell = $x32Index.executionCell
    harnessInstance = $x32Index.harnessInstance
    processModel = $x32Index.processModel
  }

  $parity = New-DualPlaneParitySummary -X64Session $x64Session -X32Session $x32Session

  $topError = if ($parity.status -eq 'incomplete') {
    @($x64Session.error, $x32Session.error | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join '; '
  } else {
    $null
  }

  $topIndex = [ordered]@{
    schema = 'teststand-compare-session/v2'
    at = (Get-Date).ToString('o')
    suiteClass = 'dual-plane-parity'
    primaryPlane = 'native-labview-2026-64'
    requestedSimultaneous = $true
    warmup = $x64Session.warmup
    compare = $x64Session.compare
    outcome = $x64Session.outcome
    error = $topError
    executionCell = $dualPlaneContext.executionCell
    harnessInstance = $dualPlaneContext.harnessInstance
    processModel = $dualPlaneContext.processModel
    planes = [ordered]@{
      x64 = $x64Session
      x32 = $x32Session
    }
    parity = $parity
  }

  $indexPath = Join-Path $resolvedOutputRoot 'session-index.json'
  $topIndex | ConvertTo-Json -Depth 12 | Out-File -LiteralPath $indexPath -Encoding utf8

  $exitCode = switch ($parity.status) {
    'match' { if ($null -ne $x64Session.outcome) { [int]$x64Session.outcome.exitCode } else { 1 } }
    'mismatch' { 2 }
    default { 1 }
  }

  Write-Host ("TestStand Dual-Plane Parity result: status={0} x64={1} x32={2} index={3}" -f $parity.status, $x64Session.exitCode, $x32Session.exitCode, $indexPath) -ForegroundColor Yellow
  exit $exitCode
}

$repo = (Resolve-Path '.').Path

if ($InternalSinglePlane -and [string]::IsNullOrWhiteSpace($InternalPlaneKey) -eq $false) {
  if ($InternalPlaneKey -eq 'x32' -and -not $PSBoundParameters.ContainsKey('LabVIEWBitness')) {
    $LabVIEWBitness = '32'
  }
  if ($InternalPlaneKey -eq 'x64' -and -not $PSBoundParameters.ContainsKey('LabVIEWBitness')) {
    $LabVIEWBitness = '64'
  }
}

if (-not [System.IO.Path]::IsPathRooted($OutputRoot)) {
  $OutputRoot = Join-Path $repo $OutputRoot
}

if ($SuiteClass -eq 'dual-plane-parity' -and -not $InternalSinglePlane) {
  Invoke-DualPlaneParitySuite -RepoRoot $repo -ScriptPath $PSCommandPath -BaseVi $BaseVi -HeadVi $HeadVi -OutputRoot $OutputRoot -DefaultLabVIEWExePath $LabVIEWExePath -LabVIEW64ExePath $LabVIEW64ExePath -LabVIEW32ExePath $LabVIEW32ExePath -LVComparePath $LVComparePath -Warmup $Warmup -Flags $Flags -ReplaceFlags:$ReplaceFlags -NoiseProfile $NoiseProfile -RenderReport:$RenderReport -CloseLabVIEW:$CloseLabVIEW -CloseLVCompare:$CloseLVCompare -TimeoutSeconds $TimeoutSeconds -DisableTimeout:$DisableTimeout -StagingRoot $StagingRoot -SameNameHint:$SameNameHint -AllowSameLeaf:$AllowSameLeaf -AgentId $AgentId -AgentClass $AgentClass -ExecutionCellLeasePath $ExecutionCellLeasePath -ExecutionCellId $ExecutionCellId -ExecutionCellLeaseId $ExecutionCellLeaseId -HarnessInstanceLeasePath $HarnessInstanceLeasePath -HarnessInstanceId $HarnessInstanceId
  return
}

$planeName = switch ($InternalPlaneKey) {
  'x64' { 'native-labview-2026-64' }
  'x32' { 'native-labview-2026-32' }
  default { $null }
}
$harnessRole = if ($InternalSinglePlane -and -not [string]::IsNullOrWhiteSpace($InternalPlaneKey)) { 'plane-child' } else { 'single-plane' }

$singlePlaneSession = Invoke-TestStandSinglePlaneSession -RepoRoot $repo -BaseVi $BaseVi -HeadVi $HeadVi -LabVIEWExePath $LabVIEWExePath -LabVIEWBitness $LabVIEWBitness -LVComparePath $LVComparePath -OutputRoot $OutputRoot -Warmup $Warmup -Flags $Flags -ReplaceFlags:$ReplaceFlags -NoiseProfile $NoiseProfile -RenderReport:$RenderReport -CloseLabVIEW:$CloseLabVIEW -CloseLVCompare:$CloseLVCompare -TimeoutSeconds $TimeoutSeconds -DisableTimeout:$DisableTimeout -StagingRoot $StagingRoot -SameNameHint:$SameNameHint -AllowSameLeaf:$AllowSameLeaf -PlaneName $planeName -AgentId $AgentId -AgentClass $AgentClass -ExecutionCellLeasePath $ExecutionCellLeasePath -ExecutionCellId $ExecutionCellId -ExecutionCellLeaseId $ExecutionCellLeaseId -ExecutionCellSuiteClass $ExecutionCellSuiteClass -HarnessInstanceLeasePath $HarnessInstanceLeasePath -HarnessInstanceId $HarnessInstanceId -ParentHarnessInstanceId $ParentHarnessInstanceId -HarnessRole $harnessRole -SuiteClass $SuiteClass

Write-TestStandV1SessionIndex -OutputRoot $OutputRoot -PlaneSession $singlePlaneSession

$capPath = if ($singlePlaneSession.compare) { $singlePlaneSession.compare.capture } else { $null }
$diffDisplay = if ($singlePlaneSession.outcome) { $singlePlaneSession.outcome.diff } else { 'unknown' }
$exitDisplay = if ($singlePlaneSession.outcome) { $singlePlaneSession.outcome.exitCode } else { 'n/a' }
Write-Host ("TestStand Compare Harness result: exit={0} diff={1} capture={2}" -f $exitDisplay, $diffDisplay, $capPath) -ForegroundColor Yellow

exit $singlePlaneSession.exitCode
