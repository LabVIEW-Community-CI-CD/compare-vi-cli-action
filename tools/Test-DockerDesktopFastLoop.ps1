#Requires -Version 7.0
<#
.SYNOPSIS
  Local deterministic fast-loop for Docker Desktop Windows + Linux lanes.

.DESCRIPTION
  Executes runtime determinism preflight and probe checks for:
  1) NI Windows container compare lane
  2) NI Linux container compare lane
  3) Linux history/report plumbing probe (fixture -> renderer)
  Writes a machine-readable summary and fails if any lane fails.
#>
[CmdletBinding()]
param(
  [string]$WindowsImage = 'nationalinstruments/labview:2026q1-windows',
  [string]$LinuxImage = 'nationalinstruments/labview:2026q1-linux',
  [string]$WindowsLabVIEWPath = '',
  [string]$LinuxLabVIEWPath = '',
  [string]$ResultsRoot = 'tests/results/local-parity',
  [string]$StatusPath = '',
  [string]$ReadinessJsonPath = '',
  [string]$ReadinessMarkdownPath = '',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [ValidateSet('none', 'smoke', 'history-core')]
  [string]$HistoryScenarioSet = 'none',
  [ValidateSet('both', 'windows', 'linux')]
  [string]$LaneScope = 'both',
  [string]$HistoryHarnessPath = 'fixtures/vi-history/pr-harness.json',
  [string]$SequentialFixturePath = 'fixtures/vi-history/sequential.json',
  [ValidateRange(1, 86400)]
  [int]$StepTimeoutSeconds = 600,
  [bool]$ManageDockerEngine = $false,
  [ValidateSet('linux-first', 'windows-first')]
  [string]$LaneOrder = 'linux-first',
  [string]$VIHistorySourceBranch = 'develop',
  [ValidateRange(1, 100000)]
  [int]$VIHistorySourceBranchCommitLimit = 64,
  [switch]$SkipWindowsProbe,
  [switch]$SkipLinuxProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DockerFastLoopDiagnostics.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LabVIEW2026HostPlaneDiagnostics.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VendorTools.psm1') -Force

$classifierScriptPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Compare-ExitCodeClassifier.ps1'

function Resolve-DockerLaneLabVIEWPath {
  param(
    [string]$ExplicitPath,
    [string[]]$PreferredEnvNames = @(),
    [AllowEmptyString()][string]$FallbackPath = ''
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
    return $ExplicitPath.Trim()
  }

  foreach ($envName in @($PreferredEnvNames)) {
    if ([string]::IsNullOrWhiteSpace($envName)) {
      continue
    }
    $candidate = [Environment]::GetEnvironmentVariable($envName, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim()
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($FallbackPath)) {
    return $FallbackPath.Trim()
  }

  return ''
}

function Resolve-NativeHostPlanePath {
  param(
    [string[]]$PreferredEnvNames = @(),
    [AllowEmptyString()][string]$FallbackPath = '',
    [int]$Version = 2026,
    [ValidateSet(32,64)][int]$Bitness = 64
  )

  foreach ($envName in @($PreferredEnvNames)) {
    if ([string]::IsNullOrWhiteSpace($envName)) {
      continue
    }

    $candidate = [Environment]::GetEnvironmentVariable($envName, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim()
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($FallbackPath)) {
    return $FallbackPath.Trim()
  }

  $resolved = Find-LabVIEWVersionExePath -Version $Version -Bitness $Bitness
  if (-not [string]::IsNullOrWhiteSpace($resolved)) {
    return $resolved
  }

  return ''
}

function Resolve-NativeHostPlaneCliPath {
  param(
    [string[]]$PreferredEnvNames = @(),
    [AllowEmptyString()][string]$FallbackPath = '',
    [int]$Version = 2026,
    [ValidateSet(32,64)][int]$Bitness = 64
  )

  foreach ($envName in @($PreferredEnvNames)) {
    if ([string]::IsNullOrWhiteSpace($envName)) {
      continue
    }

    $candidate = [Environment]::GetEnvironmentVariable($envName, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim()
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($FallbackPath)) {
    return $FallbackPath.Trim()
  }

  $resolved = Resolve-LabVIEWCLIPath -Version $Version -Bitness $Bitness
  if (-not [string]::IsNullOrWhiteSpace($resolved)) {
    return $resolved
  }

  return ''
}

function Resolve-NativeComparePath {
  param(
    [string[]]$PreferredEnvNames = @()
  )

  foreach ($envName in @($PreferredEnvNames)) {
    if ([string]::IsNullOrWhiteSpace($envName)) {
      continue
    }

    $candidate = [Environment]::GetEnvironmentVariable($envName, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim()
    }
  }

  $resolved = Resolve-LVComparePath
  if (-not [string]::IsNullOrWhiteSpace($resolved)) {
    return $resolved
  }

  return ''
}

if (-not (Test-Path -LiteralPath $classifierScriptPath -PathType Leaf)) {
  throw ("Exit-code classifier script not found: {0}" -f $classifierScriptPath)
}
. $classifierScriptPath

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Get-RepoRootFromToolsScript {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Resolve-RepoRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PathValue,
    [Parameter(Mandatory)][string]$Description
  )

  $resolved = if ([System.IO.Path]::IsPathRooted($PathValue)) {
    [System.IO.Path]::GetFullPath($PathValue)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
  }
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw ("{0} not found: {1}" -f $Description, $resolved)
  }
  return $resolved
}

function Get-VIHistorySourceBranchGuard {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$BranchRef,
    [Parameter(Mandatory)][int]$MaxCommitCount
  )

  $result = [ordered]@{
    branchRef = $BranchRef
    baselineRef = $null
    maxCommitCount = [int]$MaxCommitCount
    commitCount = $null
    status = 'skipped'
    reason = 'branch-guard-not-evaluated'
  }

  if ([string]::IsNullOrWhiteSpace($BranchRef)) {
    $result.reason = 'branch-ref-empty'
    return [pscustomobject]$result
  }

  $normalizedBranchRef = $BranchRef.Trim()
  $result.branchRef = $normalizedBranchRef
  if ($normalizedBranchRef.StartsWith('-')) {
    $result.reason = 'branch-ref-invalid-format'
    return [pscustomobject]$result
  }

  if (-not (Get-Command -Name 'git' -ErrorAction SilentlyContinue)) {
    $result.reason = 'git-unavailable'
    return [pscustomobject]$result
  }

  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
    $result.reason = 'repo-not-git'
    return [pscustomobject]$result
  }

  Push-Location $RepoRoot
  try {
    $branchResolveSpec = '{0}^{{commit}}' -f $normalizedBranchRef
    $branchResolveOutput = & git rev-parse --verify --end-of-options $branchResolveSpec 2>$null
    if ($LASTEXITCODE -ne 0) {
      $result.reason = 'branch-not-found'
      return [pscustomobject]$result
    }
    $branchCommitRef = [string]($branchResolveOutput | Select-Object -Last 1)
    if ($null -ne $branchCommitRef) {
      $branchCommitRef = $branchCommitRef.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($branchCommitRef)) {
      $result.reason = 'branch-parse-failed'
      return [pscustomobject]$result
    }

    $range = $branchCommitRef
    $hasDevelopBaseline = $false
    $developResolveSpec = 'develop^{commit}'
    $developResolveOutput = & git rev-parse --verify --end-of-options $developResolveSpec 2>$null
    if ($LASTEXITCODE -eq 0) {
      $hasDevelopBaseline = $true
    }

    if ($hasDevelopBaseline) {
      $result.baselineRef = 'develop'
      $developCommitRef = [string]($developResolveOutput | Select-Object -Last 1)
      if ($null -ne $developCommitRef) {
        $developCommitRef = $developCommitRef.Trim()
      }
      if ([string]::Equals($branchCommitRef, $developCommitRef, [System.StringComparison]::OrdinalIgnoreCase)) {
        $range = ('{0}..{0}' -f $developCommitRef)
      } else {
        $range = ('{0}..{1}' -f $developCommitRef, $branchCommitRef)
      }
    }

    $countOutput = & git rev-list --count --first-parent $range
    $countText = [string]($countOutput | Select-Object -Last 1)
    $count = 0
    if (-not [int]::TryParse($countText, [ref]$count)) {
      $result.reason = 'commit-count-parse-failed'
      return [pscustomobject]$result
    }

    $result.commitCount = [int]$count
    if ($count -gt $MaxCommitCount) {
      $result.status = 'blocked'
      $result.reason = 'commit-limit-exceeded'
      throw ("VI history source branch '{0}' exceeds the commit safeguard ({1} > {2}). Narrow the branch or raise -VIHistorySourceBranchCommitLimit." -f $normalizedBranchRef, $count, $MaxCommitCount)
    }

    $result.status = 'ok'
    $result.reason = 'within-limit'
    return [pscustomobject]$result
  } finally {
    Pop-Location | Out-Null
  }
}

function Read-JsonFileOrNull {
  param([AllowNull()][AllowEmptyString()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 12)
  } catch {
    return $null
  }
}

function Test-ReadableTextFile {
  param([AllowNull()][AllowEmptyString()][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    [void](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
    return $true
  } catch {
    return $false
  }
}

function Write-GitHubOutputValue {
  param(
    [Parameter(Mandatory)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [AllowNull()][AllowEmptyString()][string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  Add-Content -LiteralPath $Path -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

function Get-HostPlaneSummaryAssessment {
  param(
    [AllowNull()]$Summary,
    [AllowNull()]$HostPlane,
    [AllowEmptyString()][string]$HostPlaneReportPath
  )

  $declaredPath = ''
  if ($Summary -and $Summary.PSObject.Properties['hostPlaneSummaryPath']) {
    $declaredPath = [string]$Summary.hostPlaneSummaryPath
  }
  if ([string]::IsNullOrWhiteSpace($declaredPath) -and $HostPlane -and $HostPlane.PSObject.Properties['summaryPath']) {
    $declaredPath = [string]$HostPlane.summaryPath
  }
  if (-not [string]::IsNullOrWhiteSpace($declaredPath)) {
    $declaredPath = Resolve-AbsolutePath -Path $declaredPath
  }

  $derivedPath = ''
  if (-not [string]::IsNullOrWhiteSpace($HostPlaneReportPath)) {
    $candidatePath = Join-Path (Split-Path -Parent $HostPlaneReportPath) 'labview-2026-host-plane-summary.md'
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
      $derivedPath = Resolve-AbsolutePath -Path $candidatePath
    }
  }

  $effectivePath = if (-not [string]::IsNullOrWhiteSpace($declaredPath)) { $declaredPath } else { $derivedPath }
  $declared = -not [string]::IsNullOrWhiteSpace($declaredPath)
  $status = 'not-present'
  $reason = ''
  $sha256 = ''
  $readable = $false

  if (-not [string]::IsNullOrWhiteSpace($effectivePath)) {
    $readable = Test-ReadableTextFile -Path $effectivePath
    if ($readable) {
      $status = 'ok'
      $sha256 = [string](Get-FileHash -LiteralPath $effectivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    } elseif ($declared) {
      $status = 'missing'
      $reason = 'declared-summary-unreadable'
    } else {
      $status = 'missing'
      $reason = 'derived-summary-missing'
    }
  }

  return [ordered]@{
    status = $status
    reason = $reason
    path = $effectivePath
    declared = $declared
    readable = $readable
    sha256 = $sha256
  }
}

function Get-RuntimeManagerLaneTelemetry {
  param(
    [Parameter(Mandatory)][ValidateSet('windows', 'linux')][string]$Lane,
    [Parameter(Mandatory)][string]$SnapshotPath
  )

  $snapshot = Read-JsonFileOrNull -Path $SnapshotPath
  $repairActions = @()
  if ($snapshot -and $snapshot.PSObject.Properties['repairActions'] -and $snapshot.repairActions) {
    $repairActions = @($snapshot.repairActions | ForEach-Object { [string]$_ })
  }

  $status = ''
  $failureClass = ''
  $probeParseReason = ''
  $observedOsType = ''
  $observedContext = ''
  if ($snapshot -and $snapshot.PSObject.Properties['result'] -and $snapshot.result) {
    if ($snapshot.result.PSObject.Properties['status']) { $status = [string]$snapshot.result.status }
    if ($snapshot.result.PSObject.Properties['failureClass']) { $failureClass = [string]$snapshot.result.failureClass }
    if ($snapshot.result.PSObject.Properties['probeParseReason']) { $probeParseReason = [string]$snapshot.result.probeParseReason }
  }
  if ($snapshot -and $snapshot.PSObject.Properties['observed'] -and $snapshot.observed) {
    if ($snapshot.observed.PSObject.Properties['osType']) { $observedOsType = [string]$snapshot.observed.osType }
    if ($snapshot.observed.PSObject.Properties['context']) { $observedContext = [string]$snapshot.observed.context }
  }
  if ([string]::IsNullOrWhiteSpace($probeParseReason) -and $snapshot -and $snapshot.PSObject.Properties['observed'] -and $snapshot.observed -and $snapshot.observed.PSObject.Properties['dockerOsProbe'] -and $snapshot.observed.dockerOsProbe -and $snapshot.observed.dockerOsProbe.PSObject.Properties['last'] -and $snapshot.observed.dockerOsProbe.last -and $snapshot.observed.dockerOsProbe.last.PSObject.Properties['parseReason']) {
    $probeParseReason = [string]$snapshot.observed.dockerOsProbe.last.parseReason
  }

  $contextSwitchCount = 0
  $engineSwitchCount = 0
  $serviceRecoveryCount = 0
  foreach ($action in @($repairActions)) {
    if ($action -match '(?i)^docker context use ') { $contextSwitchCount++ }
    if ($action -match '(?i)^docker engine switch to ') { $engineSwitchCount++ }
    if ($action -match '(?i)^docker service recovery:') { $serviceRecoveryCount++ }
  }

  return [ordered]@{
    lane = $Lane
    snapshotPath = $SnapshotPath
    snapshotPresent = ($null -ne $snapshot)
    status = $status
    failureClass = if ([string]::IsNullOrWhiteSpace($failureClass)) { 'none' } else { $failureClass }
    probeParseReason = $probeParseReason
    observedOsType = $observedOsType
    observedContext = $observedContext
    repairActionCount = @($repairActions).Count
    contextSwitchCount = [int]$contextSwitchCount
    engineSwitchCount = [int]$engineSwitchCount
    serviceRecoveryCount = [int]$serviceRecoveryCount
    daemonUnavailable = ([string]$failureClass -eq 'daemon-unavailable')
    parseDefect = ([string]$failureClass -eq 'parse-defect')
    repairActions = @($repairActions)
  }
}

function Get-RuntimeManagerTelemetry {
  param(
    [Parameter(Mandatory)][string]$WindowsSnapshotPath,
    [Parameter(Mandatory)][string]$LinuxSnapshotPath
  )

  $windows = Get-RuntimeManagerLaneTelemetry -Lane windows -SnapshotPath $WindowsSnapshotPath
  $linux = Get-RuntimeManagerLaneTelemetry -Lane linux -SnapshotPath $LinuxSnapshotPath
  return [ordered]@{
    schema = 'docker-fast-loop/runtime-manager@v1'
    lanes = [ordered]@{
      windows = $windows
      linux = $linux
    }
    transitionCount = [int]($windows.repairActionCount + $linux.repairActionCount)
    contextSwitchCount = [int]($windows.contextSwitchCount + $linux.contextSwitchCount)
    engineSwitchCount = [int]($windows.engineSwitchCount + $linux.engineSwitchCount)
    serviceRecoveryCount = [int]($windows.serviceRecoveryCount + $linux.serviceRecoveryCount)
    daemonUnavailableCount = [int](([int]$windows.daemonUnavailable) + ([int]$linux.daemonUnavailable))
    parseDefectCount = [int](([int]$windows.parseDefect) + ([int]$linux.parseDefect))
  }
}

function Get-HistoryScenarioIdsForSet {
  param(
    [Parameter(Mandatory)][string]$ScenarioSet,
    [Parameter(Mandatory)][object]$Harness
  )

  $diagnostics = New-Object System.Collections.Generic.List[string]
  $scenarioMap = @{}
  foreach ($scenario in @($Harness.scenarios)) {
    if (-not $scenario -or -not $scenario.PSObject.Properties['id']) { continue }
    $id = [string]$scenario.id
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $scenarioMap[$id] = $scenario
  }

  switch ($ScenarioSet) {
    'none' {
      return [pscustomobject]@{
        scenarioIds = @()
        diagnostics = @()
      }
    }
    'smoke' {
      $preferred = @('attribute', 'sequential')
      $resolved = New-Object System.Collections.Generic.List[string]
      foreach ($id in $preferred) {
        if (-not $scenarioMap.ContainsKey($id)) {
          $diagnostics.Add(("History smoke scenario '{0}' is not present in harness manifest." -f $id)) | Out-Null
          continue
        }
        $scenario = $scenarioMap[$id]
        $requireDiff = $false
        if ($scenario.PSObject.Properties['requireDiff']) {
          $requireDiff = [bool]$scenario.requireDiff
        }
        if ($requireDiff) {
          $resolved.Add($id) | Out-Null
        } else {
          $diagnostics.Add(("History smoke scenario '{0}' skipped because requireDiff=true is required." -f $id)) | Out-Null
        }
      }
      if ($resolved.Count -eq 0) {
        $details = if ($diagnostics.Count -gt 0) { [string]::Join(' ', @($diagnostics.ToArray())) } else { '' }
        throw ("History smoke scenario set resolved to empty after requireDiff=true filtering. {0}" -f $details)
      }
      return [pscustomobject]@{
        scenarioIds = @($resolved.ToArray())
        diagnostics = @($diagnostics.ToArray())
      }
    }
    'history-core' {
      if (-not $Harness.scenarios -or @($Harness.scenarios).Count -eq 0) {
        throw 'History core scenario set requires at least one scenario in the harness manifest.'
      }
      $resolved = New-Object System.Collections.Generic.List[string]
      foreach ($scenario in @($Harness.scenarios)) {
        if (-not $scenario -or -not $scenario.PSObject.Properties['id']) { continue }
        $id = [string]$scenario.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $requireDiff = $false
        if ($scenario.PSObject.Properties['requireDiff']) {
          $requireDiff = [bool]$scenario.requireDiff
        }
        if ($requireDiff) {
          $resolved.Add($id) | Out-Null
        } else {
          $diagnostics.Add(("History scenario '{0}' skipped because requireDiff=true is required for history-core." -f $id)) | Out-Null
        }
      }
      if ($resolved.Count -eq 0) {
        $details = if ($diagnostics.Count -gt 0) { [string]::Join(' ', @($diagnostics.ToArray())) } else { '' }
        throw ("History core scenario set resolved to empty after requireDiff=true filtering. {0}" -f $details)
      }
      return [pscustomobject]@{
        scenarioIds = @($resolved.ToArray())
        diagnostics = @($diagnostics.ToArray())
      }
    }
    default {
      throw ("Unsupported HistoryScenarioSet: {0}" -f $ScenarioSet)
    }
  }
}

function Invoke-GitInRepo {
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  Push-Location $RepoPath
  try {
    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
      $text = @($output | ForEach-Object { [string]$_ }) -join "`n"
      throw ("git {0} failed in {1}: {2}" -f ($Arguments -join ' '), $RepoPath, $text)
    }
    return @($output | ForEach-Object { [string]$_ })
  } finally {
    Pop-Location | Out-Null
  }
}

function Get-SequentialHistoryFixtureDefinition {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$FixturePath
  )

  $fixturePathResolved = Resolve-RepoRelativePath -RepoRoot $RepoRoot -PathValue $FixturePath -Description 'Sequential history fixture'
  $fixture = Get-Content -LiteralPath $fixturePathResolved -Raw | ConvertFrom-Json -Depth 8
  if (-not $fixture -or [string]$fixture.schema -ne 'vi-history-sequence@v1') {
    throw ("Unsupported sequential fixture schema in {0}" -f $fixturePathResolved)
  }
  if ([string]::IsNullOrWhiteSpace([string]$fixture.targetPath)) {
    throw ("Sequential fixture must declare targetPath: {0}" -f $fixturePathResolved)
  }
  if (-not $fixture.steps -or @($fixture.steps).Count -eq 0) {
    throw ("Sequential fixture contains no steps: {0}" -f $fixturePathResolved)
  }

  $steps = New-Object System.Collections.Generic.List[object]
  foreach ($step in @($fixture.steps)) {
    $requireDiff = $false
    if ($step.PSObject.Properties['requireDiff']) {
      $requireDiff = [bool]$step.requireDiff
    }
    if (-not $requireDiff) {
      continue
    }
    if (-not $step.PSObject.Properties['source'] -or [string]::IsNullOrWhiteSpace([string]$step.source)) {
      throw ("Sequential fixture step missing source path in {0}" -f $fixturePathResolved)
    }
    $resolvedSource = Resolve-RepoRelativePath -RepoRoot $RepoRoot -PathValue ([string]$step.source) -Description ("Sequential step source '{0}'" -f [string]$step.id)
    $steps.Add([pscustomobject]@{
      id = if ($step.PSObject.Properties['id']) { [string]$step.id } else { '' }
      title = if ($step.PSObject.Properties['title']) { [string]$step.title } else { '' }
      message = if ($step.PSObject.Properties['message']) { [string]$step.message } else { '' }
      source = [string]$step.source
      resolvedSource = $resolvedSource
    }) | Out-Null
  }

  if ($steps.Count -eq 0) {
    throw ("Sequential fixture resolved to empty after requireDiff=true filtering in {0}." -f $fixturePathResolved)
  }

  return [pscustomobject]@{
    path = $fixturePathResolved
    targetPath = [string]$fixture.targetPath
    baselineSourcePath = Resolve-RepoRelativePath -RepoRoot $RepoRoot -PathValue ([string]$fixture.targetPath) -Description 'Sequential history target baseline'
    maxPairs = if ($fixture.PSObject.Properties['maxPairs'] -and $null -ne $fixture.maxPairs) { [int]$fixture.maxPairs } else { $steps.Count }
    steps = @($steps.ToArray())
  }
}

function New-LinuxSequentialHistoryScenarioRepo {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$FixturePath,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$BranchRef
  )

  $fixture = Get-SequentialHistoryFixtureDefinition -RepoRoot $RepoRoot -FixturePath $FixturePath
  $scratchRepoRoot = Join-Path $OutputRoot 'repo'
  if (Test-Path -LiteralPath $scratchRepoRoot) {
    Remove-Item -LiteralPath $scratchRepoRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $scratchRepoRoot -Force | Out-Null

  Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('init', '--initial-branch=develop') | Out-Null
  Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('config', 'user.email', 'agent@example.com') | Out-Null
  Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('config', 'user.name', 'Agent Runner') | Out-Null

  $targetPath = Join-Path $scratchRepoRoot $fixture.targetPath
  $targetDir = Split-Path -Parent $targetPath
  if ($targetDir -and -not (Test-Path -LiteralPath $targetDir -PathType Container)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  }
  Copy-Item -LiteralPath $fixture.baselineSourcePath -Destination $targetPath -Force
  Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('add', '--', $fixture.targetPath) | Out-Null
  Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('commit', '-m', 'chore: linux sequential history baseline') | Out-Null

  $effectiveBranchRef = if ([string]::IsNullOrWhiteSpace($BranchRef)) { 'develop' } else { $BranchRef.Trim() }
  if (-not [string]::Equals($effectiveBranchRef, 'develop', [System.StringComparison]::OrdinalIgnoreCase)) {
    Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('switch', '-c', $effectiveBranchRef) | Out-Null
  }

  $appliedSteps = 0
  foreach ($step in @($fixture.steps)) {
    Copy-Item -LiteralPath $step.resolvedSource -Destination $targetPath -Force
    $status = @(Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('status', '--porcelain', '--', $fixture.targetPath))
    if ($status.Count -eq 0) {
      continue
    }
    Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('add', '--', $fixture.targetPath) | Out-Null
    $commitMessage = if ([string]::IsNullOrWhiteSpace($step.message)) {
      "chore: linux sequential history step $($appliedSteps + 1)"
    } else {
      [string]$step.message
    }
    Invoke-GitInRepo -RepoPath $scratchRepoRoot -Arguments @('commit', '-m', $commitMessage) | Out-Null
    $appliedSteps++
  }

  if ($appliedSteps -le 0) {
    throw ("Sequential fixture produced no materialized commits for linux fast-loop in {0}." -f $fixture.path)
  }

  return [pscustomobject]@{
    repoPath = $scratchRepoRoot
    branchRef = $effectiveBranchRef
    targetPath = $fixture.targetPath
    maxPairs = [Math]::Max(1, [int]$fixture.maxPairs)
    appliedSteps = [int]$appliedSteps
    fixturePath = $fixture.path
  }
}

function Invoke-WindowsHistoryCompare {
  param(
    [Parameter(Mandatory)][string]$BaseVi,
    [Parameter(Mandatory)][string]$HeadVi,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$LabVIEWPath,
    [Parameter(Mandatory)][string]$WindowsImage,
    [Parameter(Mandatory)][string]$RuntimeSnapshotPath,
    [Parameter(Mandatory)][bool]$RuntimeAutoRepair,
    [Parameter(Mandatory)][bool]$ManageDockerEngine,
    [Parameter(Mandatory)][int]$StepTimeoutSeconds
  )

  $reportDir = Split-Path -Parent $ReportPath
  if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
  }

  $runtimeGuardScript = Join-Path $PSScriptRoot 'Assert-DockerRuntimeDeterminism.ps1'
  if (-not (Test-Path -LiteralPath $runtimeGuardScript -PathType Leaf)) {
    throw ("Runtime guard script not found: {0}" -f $runtimeGuardScript)
  }
  & pwsh -NoLogo -NoProfile -File $runtimeGuardScript `
    -ExpectedOsType windows `
    -ExpectedContext desktop-windows `
    -AutoRepair:$RuntimeAutoRepair `
    -ManageDockerEngine:$ManageDockerEngine `
    -EngineReadyTimeoutSeconds $StepTimeoutSeconds `
    -EngineReadyPollSeconds 3 `
    -SnapshotPath $RuntimeSnapshotPath `
    -GitHubOutputPath '' | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw ("Windows runtime preflight failed before history compare. Snapshot: {0}" -f $RuntimeSnapshotPath)
  }

  $windowsCompareArgs = @(
    '-NoLogo', '-NoProfile',
    '-File', (Join-Path $PSScriptRoot 'Run-NIWindowsContainerCompare.ps1'),
    '-BaseVi', $BaseVi,
    '-HeadVi', $HeadVi,
    '-Image', $WindowsImage,
    '-ReportPath', $ReportPath,
    '-TimeoutSeconds', [string]$StepTimeoutSeconds,
    "-AutoRepairRuntime:$RuntimeAutoRepair",
    "-ManageDockerEngine:$ManageDockerEngine",
    '-RuntimeEngineReadyTimeoutSeconds', [string]$StepTimeoutSeconds,
    '-RuntimeEngineReadyPollSeconds', '3',
    '-RuntimeSnapshotPath', $RuntimeSnapshotPath
  )
  if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
    $windowsCompareArgs += @('-LabVIEWPath', $LabVIEWPath)
  }
  & pwsh @windowsCompareArgs | Out-Null

  $compareExit = $LASTEXITCODE

  $capturePath = Join-Path $reportDir 'ni-windows-container-capture.json'
  if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
    throw ("Windows history compare capture missing: {0}" -f $capturePath)
  }
  $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 8
  $captureMessage = if ($capture.PSObject.Properties['message']) { [string]$capture.message } else { '' }
  $runtimeStatus = if ($capture.PSObject.Properties['runtimeDeterminism'] -and $capture.runtimeDeterminism -and $capture.runtimeDeterminism.PSObject.Properties['status']) { [string]$capture.runtimeDeterminism.status } else { '' }
  $runtimeReason = if ($capture.PSObject.Properties['runtimeDeterminism'] -and $capture.runtimeDeterminism -and $capture.runtimeDeterminism.PSObject.Properties['reason']) { [string]$capture.runtimeDeterminism.reason } else { '' }
  $classification = if (
    $capture.PSObject.Properties['resultClass'] -and
    $capture.PSObject.Properties['isDiff'] -and
    $capture.PSObject.Properties['gateOutcome'] -and
    $capture.PSObject.Properties['failureClass']
  ) {
    [pscustomobject]@{
      resultClass = [string]$capture.resultClass
      isDiff = [bool]$capture.isDiff
      gateOutcome = [string]$capture.gateOutcome
      failureClass = [string]$capture.failureClass
    }
  } else {
    Get-CompareExitClassification `
      -ExitCode $compareExit `
      -CaptureStatus ([string]$capture.status) `
      -StdOut '' `
      -StdErr '' `
      -Message $captureMessage `
      -RuntimeDeterminismStatus $runtimeStatus `
      -RuntimeDeterminismReason $runtimeReason `
      -TimedOut:([bool]($capture.PSObject.Properties['timedOut'] -and [bool]$capture.timedOut))
  }

  if (
    [string]$classification.failureClass -eq 'preflight' -and
    (
      $captureMessage -match '(?i)runtime determinism' -or
      $captureMessage -match '(?i)runtime invariant mismatch' -or
      $captureMessage -match '(?i)expected os=' -or
      $captureMessage -match '(?i)docker desktop is unable to start' -or
      $captureMessage -match '(?i)dockerdesktop/wsl/execerror'
    )
  ) {
    $classification = [pscustomobject]@{
      resultClass = 'failure-runtime'
      isDiff = $false
      gateOutcome = 'fail'
      failureClass = 'runtime-determinism'
    }
  }

  $validationMessage = ''
  if ([string]$classification.gateOutcome -eq 'pass' -and -not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    $classification = [pscustomobject]@{
      resultClass = 'failure-tool'
      isDiff = [bool]$classification.isDiff
      gateOutcome = 'fail'
      failureClass = 'cli/tool'
    }
    $validationMessage = ("Windows history compare report missing: {0}" -f $ReportPath)
  }
  $effectiveMessage = $captureMessage
  if (-not [string]::IsNullOrWhiteSpace($validationMessage)) {
    if ([string]::IsNullOrWhiteSpace($effectiveMessage)) {
      $effectiveMessage = $validationMessage
    } else {
      $effectiveMessage = ("{0} | {1}" -f $effectiveMessage, $validationMessage)
    }
  }

  return [pscustomobject]@{
    ExitCode = [int]$compareExit
    CapturePath = $capturePath
    Capture = $capture
    Classification = $classification
    Message = $effectiveMessage
    ReportPath = $ReportPath
  }
}

function Invoke-LinuxContainerSmokeCompare {
  param(
    [string]$BaseVi = '',
    [string]$HeadVi = '',
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$LabVIEWPath,
    [Parameter(Mandatory)][string]$LinuxImage,
    [Parameter(Mandatory)][string]$RuntimeSnapshotPath,
    [Parameter(Mandatory)][bool]$RuntimeAutoRepair,
    [Parameter(Mandatory)][int]$StepTimeoutSeconds,
    [string]$BootstrapContractPath = '',
    [string]$ExpectedBootstrapMode = '',
    [string]$ExpectedBranchRef = '',
    [string]$ExpectedBootstrapMarkerPath = ''
  )

  $reportDir = Split-Path -Parent $ReportPath
  if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
  }

  $linuxCompareArgs = @(
    '-NoLogo', '-NoProfile',
    '-File', (Join-Path $PSScriptRoot 'Run-NILinuxContainerCompare.ps1'),
    '-Image', $LinuxImage,
    '-ReportPath', $ReportPath,
    '-TimeoutSeconds', [string]$StepTimeoutSeconds,
    "-AutoRepairRuntime:$RuntimeAutoRepair",
    '-RuntimeEngineReadyTimeoutSeconds', [string]$StepTimeoutSeconds,
    '-RuntimeEngineReadyPollSeconds', '3',
    '-RuntimeSnapshotPath', $RuntimeSnapshotPath,
    '-PassThru'
  )
  if (-not [string]::IsNullOrWhiteSpace($BaseVi)) {
    $linuxCompareArgs += @('-BaseVi', $BaseVi)
  }
  if (-not [string]::IsNullOrWhiteSpace($HeadVi)) {
    $linuxCompareArgs += @('-HeadVi', $HeadVi)
  }
  if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
    $linuxCompareArgs += @('-LabVIEWPath', $LabVIEWPath)
  }
  if (-not [string]::IsNullOrWhiteSpace($BootstrapContractPath)) {
    $linuxCompareArgs += @('-RuntimeBootstrapContractPath', $BootstrapContractPath)
  }

  $capture = & pwsh @linuxCompareArgs
  $compareExit = $LASTEXITCODE

  $capturePath = Join-Path $reportDir 'ni-linux-container-capture.json'
  if (-not $capture -or -not $capture.PSObject.Properties['status']) {
    if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
      throw ("Linux container compare capture missing: {0}" -f $capturePath)
    }
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 8
  }

  $captureMessage = if ($capture.PSObject.Properties['message']) { [string]$capture.message } else { '' }
  $runtimeStatus = if ($capture.PSObject.Properties['runtimeDeterminism'] -and $capture.runtimeDeterminism -and $capture.runtimeDeterminism.PSObject.Properties['status']) { [string]$capture.runtimeDeterminism.status } else { '' }
  $runtimeReason = if ($capture.PSObject.Properties['runtimeDeterminism'] -and $capture.runtimeDeterminism -and $capture.runtimeDeterminism.PSObject.Properties['reason']) { [string]$capture.runtimeDeterminism.reason } else { '' }
  $classification = if (
    $capture.PSObject.Properties['resultClass'] -and
    $capture.PSObject.Properties['isDiff'] -and
    $capture.PSObject.Properties['gateOutcome'] -and
    $capture.PSObject.Properties['failureClass']
  ) {
    [pscustomobject]@{
      resultClass = [string]$capture.resultClass
      isDiff = [bool]$capture.isDiff
      gateOutcome = [string]$capture.gateOutcome
      failureClass = [string]$capture.failureClass
    }
  } else {
    Get-CompareExitClassification `
      -ExitCode $compareExit `
      -CaptureStatus ([string]$capture.status) `
      -StdOut '' `
      -StdErr '' `
      -Message $captureMessage `
      -RuntimeDeterminismStatus $runtimeStatus `
      -RuntimeDeterminismReason $runtimeReason `
      -TimedOut:([bool]($capture.PSObject.Properties['timedOut'] -and [bool]$capture.timedOut))
  }

  $validationMessages = New-Object System.Collections.Generic.List[string]
  if ([string]$classification.gateOutcome -eq 'pass' -and -not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    $classification = [pscustomobject]@{
      resultClass = 'failure-tool'
      isDiff = [bool]$classification.isDiff
      gateOutcome = 'fail'
      failureClass = 'cli/tool'
    }
    $validationMessages.Add(("Linux container smoke report missing: {0}" -f $ReportPath)) | Out-Null
  }

  $runtimeInjection = if ($capture.PSObject.Properties['runtimeInjection']) { $capture.runtimeInjection } else { $null }
  if (-not [string]::IsNullOrWhiteSpace($BootstrapContractPath)) {
    $actualContractPath = if ($runtimeInjection -and $runtimeInjection.PSObject.Properties['contractPath']) { [string]$runtimeInjection.contractPath } else { '' }
    if (-not [string]::Equals($actualContractPath, $BootstrapContractPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      $classification = [pscustomobject]@{
        resultClass = 'failure-tool'
        isDiff = $false
        gateOutcome = 'fail'
        failureClass = 'cli/tool'
      }
      $validationMessages.Add(("Linux runtime bootstrap contract was not applied. expected={0} actual={1}" -f $BootstrapContractPath, $actualContractPath)) | Out-Null
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedBootstrapMode)) {
    $actualMode = if ($runtimeInjection -and $runtimeInjection.PSObject.Properties['contractMode']) { [string]$runtimeInjection.contractMode } else { '' }
    if (-not [string]::Equals($actualMode, $ExpectedBootstrapMode, [System.StringComparison]::OrdinalIgnoreCase)) {
      $classification = [pscustomobject]@{
        resultClass = 'failure-tool'
        isDiff = $false
        gateOutcome = 'fail'
        failureClass = 'cli/tool'
      }
      $validationMessages.Add(("Linux runtime bootstrap mode mismatch. expected={0} actual={1}" -f $ExpectedBootstrapMode, $actualMode)) | Out-Null
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedBranchRef)) {
    $actualBranchRef = if ($runtimeInjection -and $runtimeInjection.PSObject.Properties['branchRef']) { [string]$runtimeInjection.branchRef } else { '' }
    if (-not [string]::Equals($actualBranchRef, $ExpectedBranchRef, [System.StringComparison]::OrdinalIgnoreCase)) {
      $classification = [pscustomobject]@{
        resultClass = 'failure-tool'
        isDiff = $false
        gateOutcome = 'fail'
        failureClass = 'cli/tool'
      }
      $validationMessages.Add(("Linux runtime bootstrap branch mismatch. expected={0} actual={1}" -f $ExpectedBranchRef, $actualBranchRef)) | Out-Null
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedBootstrapMarkerPath) -and -not (Test-Path -LiteralPath $ExpectedBootstrapMarkerPath -PathType Leaf)) {
    $classification = [pscustomobject]@{
      resultClass = 'failure-tool'
      isDiff = $false
      gateOutcome = 'fail'
      failureClass = 'cli/tool'
    }
    $validationMessages.Add(("Linux bootstrap marker missing: {0}" -f $ExpectedBootstrapMarkerPath)) | Out-Null
  }

  $effectiveMessage = $captureMessage
  if ($validationMessages.Count -gt 0) {
    $validationMessage = [string]::Join(' | ', @($validationMessages))
    if ([string]::IsNullOrWhiteSpace($effectiveMessage)) {
      $effectiveMessage = $validationMessage
    } else {
      $effectiveMessage = ("{0} | {1}" -f $effectiveMessage, $validationMessage)
    }
  }

  return [pscustomobject]@{
    ExitCode = [int]$compareExit
    CapturePath = $capturePath
    Capture = $capture
    Classification = $classification
    Message = $effectiveMessage
    ReportPath = $ReportPath
    BootstrapMarkerPath = $ExpectedBootstrapMarkerPath
  }
}

function Get-StepLane {
  param([Parameter(Mandatory)][string]$StepName)
  if ($StepName -like 'windows-*') { return 'windows' }
  if ($StepName -like 'linux-*') { return 'linux' }
  return ''
}

function Get-MedianMs {
  param([Parameter(Mandatory)][int[]]$Values)
  if (-not $Values -or $Values.Count -eq 0) { return 0 }
  $sorted = @($Values | Sort-Object)
  $count = $sorted.Count
  $mid = [math]::Floor($count / 2)
  if (($count % 2) -eq 1) {
    return [int]$sorted[$mid]
  }
  return [int][math]::Round((([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0), 0)
}

function Get-HistoricalStepDurationMedians {
  param(
    [Parameter(Mandatory)][string]$ResultsDir,
    [int]$MaxRuns = 25
  )

  $durations = @{}
  $files = Get-ChildItem -LiteralPath $ResultsDir -Filter 'docker-runtime-fastloop-*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^docker-runtime-fastloop-\d{14}\.json$' } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First $MaxRuns

  foreach ($file in @($files)) {
    try {
      $summary = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 10
    } catch {
      continue
    }
    if (-not $summary -or -not $summary.steps) { continue }
    foreach ($step in @($summary.steps)) {
      if (-not $step -or -not $step.PSObject -or -not $step.PSObject.Properties['name']) { continue }
      $stepName = [string]$step.PSObject.Properties['name'].Value
      $duration = 0
      if ($step.PSObject.Properties['durationMs']) {
        $duration = [int]$step.PSObject.Properties['durationMs'].Value
      }
      if ($duration -le 0) { continue }
      if (-not $durations.ContainsKey($stepName)) {
        $durations[$stepName] = New-Object System.Collections.Generic.List[int]
      }
      $durations[$stepName].Add($duration) | Out-Null
    }
  }

  $medians = @{}
  foreach ($key in @($durations.Keys)) {
    $values = @($durations[$key].ToArray())
    if ($values.Count -eq 0) { continue }
    $medians[$key] = Get-MedianMs -Values $values
  }
  return $medians
}

function Get-LaneLifecycleFromPlan {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StepPlan,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ObservedSteps,
    [Parameter(Mandatory)][string]$Phase,
    [bool]$HardStopTriggered = $false,
    [AllowEmptyString()][string]$HardStopReason = ''
  )

  $laneNames = @('windows', 'linux')
  $lifecycle = [ordered]@{}
  foreach ($laneName in $laneNames) {
    $lifecycle[$laneName] = [ordered]@{
      totalPlannedSteps = 0
      executedSteps = 0
      started = $false
      completed = $false
      status = 'skipped'
      startStep = ''
      endStep = ''
      startedAt = ''
      endedAt = ''
      hardStopTriggered = $false
      stopClass = 'none'
      stopReason = ''
    }
  }

  foreach ($planStep in @($StepPlan)) {
    $laneName = Get-StepLane -StepName $planStep
    if ([string]::IsNullOrWhiteSpace($laneName) -or -not $lifecycle.Contains($laneName)) { continue }
    $lifecycle[$laneName].totalPlannedSteps = [int]$lifecycle[$laneName].totalPlannedSteps + 1
    if ([string]$lifecycle[$laneName].status -eq 'skipped') {
      $lifecycle[$laneName].status = 'pending'
    }
  }

  foreach ($step in @($ObservedSteps)) {
    if (-not $step -or -not $step.PSObject.Properties['name']) { continue }
    $stepName = [string]$step.name
    $laneName = Get-StepLane -StepName $stepName
    if ([string]::IsNullOrWhiteSpace($laneName) -or -not $lifecycle.Contains($laneName)) { continue }

    $lane = $lifecycle[$laneName]
    $lane.executedSteps = [int]$lane.executedSteps + 1
    $lane.started = $true
    if ([string]::IsNullOrWhiteSpace([string]$lane.startStep)) {
      $lane.startStep = $stepName
    }
    $lane.endStep = $stepName
    if ([string]::IsNullOrWhiteSpace([string]$lane.startedAt) -and $step.PSObject.Properties['startedAt']) {
      $lane.startedAt = [string]$step.startedAt
    }
    if ($step.PSObject.Properties['finishedAt']) {
      $lane.endedAt = [string]$step.finishedAt
    }

    $stepStatus = if ($step.PSObject.Properties['status']) { [string]$step.status } else { '' }
    if ($stepStatus -ne 'success') {
      $lane.status = 'failure'
      $lane.stopClass = 'failure'
      if ($step.PSObject.Properties['hardStopTriggered'] -and [bool]$step.hardStopTriggered) {
        $lane.hardStopTriggered = $true
        $lane.stopClass = 'hard-stop'
      }
      $failureClassText = if ($step.PSObject.Properties['failureClass']) { [string]$step.failureClass } else { '' }
      $messageText = if ($step.PSObject.Properties['message']) { [string]$step.message } else { '' }
      if (-not [string]::IsNullOrWhiteSpace($messageText)) {
        $lane.stopReason = $messageText
      } elseif (-not [string]::IsNullOrWhiteSpace($failureClassText)) {
        $lane.stopReason = ("failureClass={0}" -f $failureClassText)
      } else {
        $lane.stopReason = 'step-failure'
      }
      continue
    }

    if ([string]$lane.status -notin @('failure', 'success', 'incomplete')) {
      $lane.status = 'running'
    }
  }

  foreach ($laneName in $laneNames) {
    $lane = $lifecycle[$laneName]
    $planned = [int]$lane.totalPlannedSteps
    $executed = [int]$lane.executedSteps

    if ($planned -eq 0) {
      $lane.status = 'skipped'
      $lane.completed = $false
      $lane.stopClass = 'none'
      $lane.stopReason = ''
      continue
    }

    if ($executed -eq 0) {
      if ($HardStopTriggered) {
        $lane.status = 'blocked'
        $lane.stopClass = 'blocked'
        $lane.stopReason = if ([string]::IsNullOrWhiteSpace($HardStopReason)) { 'blocked-by-hard-stop' } else { $HardStopReason }
      } elseif ($Phase -eq 'completed') {
        $lane.status = 'blocked'
        $lane.stopClass = 'blocked'
        $lane.stopReason = 'lane-not-started'
      } else {
        $lane.status = 'pending'
        $lane.stopClass = 'none'
      }
      continue
    }

    if ([string]$lane.status -eq 'failure') {
      $lane.completed = ($executed -ge $planned)
      if ($lane.hardStopTriggered -and [string]::IsNullOrWhiteSpace([string]$lane.stopReason) -and -not [string]::IsNullOrWhiteSpace($HardStopReason)) {
        $lane.stopReason = $HardStopReason
      }
      continue
    }

    if ($executed -ge $planned) {
      $lane.status = 'success'
      $lane.completed = $true
      $lane.stopClass = 'completed'
      if ([string]::IsNullOrWhiteSpace([string]$lane.stopReason)) {
        $lane.stopReason = 'lane-complete'
      }
      continue
    }

    $lane.completed = $false
    if ($HardStopTriggered) {
      $lane.status = 'incomplete'
      $lane.stopClass = 'blocked'
      $lane.stopReason = if ([string]::IsNullOrWhiteSpace($HardStopReason)) { 'hard-stop-before-lane-complete' } else { $HardStopReason }
    } else {
      $lane.status = if ($Phase -eq 'completed') { 'incomplete' } else { 'running' }
      if ([string]$lane.stopClass -eq 'none') {
        $lane.stopReason = ''
      }
    }
  }

  return $lifecycle
}

function New-StatusTelemetry {
  param(
    [Parameter(Mandatory)][string]$RunStatus,
    [Parameter(Mandatory)][string]$Phase,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StepPlan,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ObservedSteps,
    [Parameter(Mandatory)][hashtable]$HistoricalMedians,
    [bool]$HardStopTriggered = $false,
    [AllowEmptyString()][string]$HardStopReason = ''
  )

  $completedDurationMs = 0
  $failedSteps = 0
  $completedNames = New-Object System.Collections.Generic.HashSet[string]
  $laneTotals = @{ windows = 0; linux = 0 }
  $laneCompleted = @{ windows = 0; linux = 0 }

  foreach ($planStep in @($StepPlan)) {
    $laneName = Get-StepLane -StepName $planStep
    if (-not [string]::IsNullOrWhiteSpace($laneName) -and $laneTotals.ContainsKey($laneName)) {
      $laneTotals[$laneName] = [int]$laneTotals[$laneName] + 1
    }
  }

  foreach ($step in @($ObservedSteps)) {
    if (-not $step -or -not $step.PSObject.Properties['name']) { continue }
    $name = [string]$step.name
    $completedNames.Add($name) | Out-Null
    $laneName = Get-StepLane -StepName $name
    if (-not [string]::IsNullOrWhiteSpace($laneName) -and $laneCompleted.ContainsKey($laneName)) {
      $laneCompleted[$laneName] = [int]$laneCompleted[$laneName] + 1
    }
    if ($step.PSObject.Properties['durationMs']) {
      $completedDurationMs += [int]$step.durationMs
    }
    if ($step.PSObject.Properties['status'] -and [string]$step.status -ne 'success') {
      $failedSteps++
    }
  }

  $remainingEstimateMs = 0
  foreach ($planned in @($StepPlan)) {
    if ($completedNames.Contains($planned)) { continue }
    if ($HistoricalMedians.ContainsKey($planned)) {
      $remainingEstimateMs += [int]$HistoricalMedians[$planned]
    } else {
      $remainingEstimateMs += 5000
    }
  }

  $etaSeconds = [math]::Round(($remainingEstimateMs / 1000.0), 1)
  $pushRecommendation = 'hold'
  $canPush = $false
  if ($Phase -eq 'completed' -and $RunStatus -eq 'success') {
    $pushRecommendation = 'push'
    $canPush = $true
  } elseif ($Phase -eq 'completed' -and $RunStatus -ne 'success') {
    $pushRecommendation = 'do-not-push'
  }
  $laneLifecycle = Get-LaneLifecycleFromPlan `
    -StepPlan $StepPlan `
    -ObservedSteps $ObservedSteps `
    -Phase $Phase `
    -HardStopTriggered:$HardStopTriggered `
    -HardStopReason $HardStopReason

  return [ordered]@{
    completedDurationMs = [int]$completedDurationMs
    remainingEstimateMs = [int]$remainingEstimateMs
    etaSeconds = $etaSeconds
    failedSteps = [int]$failedSteps
    laneProgress = [ordered]@{
      windows = [ordered]@{ completed = [int]$laneCompleted.windows; total = [int]$laneTotals.windows }
      linux = [ordered]@{ completed = [int]$laneCompleted.linux; total = [int]$laneTotals.linux }
    }
    laneLifecycle = $laneLifecycle
    pushRecommendation = $pushRecommendation
    canPush = [bool]$canPush
  }
}

function Write-SemiLiveStatus {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$StartedAt,
    [Parameter(Mandatory)][string]$RunStatus,
    [Parameter(Mandatory)][string]$Phase,
    [AllowEmptyString()][string]$CurrentStep,
    [Parameter(Mandatory)][int]$CompletedSteps,
    [Parameter(Mandatory)][int]$TotalSteps,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StepPlan,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps,
    [Parameter(Mandatory)][hashtable]$HistoricalStepMedians,
    [bool]$HardStopTriggered = $false,
    [AllowEmptyString()][string]$HardStopReason = '',
    [AllowEmptyString()][string]$LoopLabel = '',
    [AllowEmptyString()][string]$SummaryPath,
    [AllowEmptyString()][string]$HostPlaneReportPath = '',
    [AllowEmptyString()][string]$HostPlaneSummaryPath = '',
    [AllowEmptyString()][string]$HostPlaneSummaryStatus = '',
    [AllowEmptyString()][string]$HostPlaneSummarySha256 = '',
    [AllowEmptyString()][string]$HostPlaneSummaryReason = '',
    [AllowNull()]$RuntimeManagerTelemetry = $null
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }
  $statusDir = Split-Path -Parent $Path
  if ($statusDir -and -not (Test-Path -LiteralPath $statusDir -PathType Container)) {
    New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
  }
  $telemetry = New-StatusTelemetry `
    -RunStatus $RunStatus `
    -Phase $Phase `
    -StepPlan $StepPlan `
    -ObservedSteps $Steps `
    -HistoricalMedians $HistoricalStepMedians `
    -HardStopTriggered:$HardStopTriggered `
    -HardStopReason $HardStopReason

  $payload = [ordered]@{
    schema = 'docker-desktop-fast-loop-status@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    startedAt = $StartedAt
    loopLabel = if ([string]::IsNullOrWhiteSpace($LoopLabel)) { Get-DockerFastLoopLabel -ContextObject @{ laneScope = $LaneScope } } else { $LoopLabel }
    phase = $Phase
    status = $RunStatus
    currentStep = ($CurrentStep ?? '')
    completedSteps = [int]$CompletedSteps
    totalSteps = [int]$TotalSteps
    percentComplete = if ($TotalSteps -gt 0) { [math]::Round((100.0 * $CompletedSteps / $TotalSteps), 1) } else { 100.0 }
    windowsImage = $WindowsImage
    linuxImage = $LinuxImage
    historyScenarioSet = $HistoryScenarioSet
    laneScope = $LaneScope
    singleLaneMode = [bool]$singleLaneMode
    runtimeAutoRepair = [bool]$runtimeAutoRepairEnabled
    stepTimeoutSeconds = [int]$StepTimeoutSeconds
    manageDockerEngine = [bool]$effectiveManageDockerEngine
    hardStopTriggered = [bool]$HardStopTriggered
    hardStopReason = ($HardStopReason ?? '')
    laneLifecycle = $telemetry.laneLifecycle
    telemetry = $telemetry
    runtimeManager = $RuntimeManagerTelemetry
    steps = @($Steps)
    summaryPath = ($SummaryPath ?? '')
    hostPlaneReportPath = ($HostPlaneReportPath ?? '')
    hostPlaneSummaryPath = ($HostPlaneSummaryPath ?? '')
    hostPlaneSummaryStatus = ($HostPlaneSummaryStatus ?? '')
    hostPlaneSummarySha256 = ($HostPlaneSummarySha256 ?? '')
    hostPlaneSummaryReason = ($HostPlaneSummaryReason ?? '')
  }
  $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-StepActionWithTimeout {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [Parameter(Mandatory)][int]$TimeoutSeconds
  )

  $threadJobAvailable = $null -ne (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)
  if (-not $threadJobAvailable) {
    $global:LASTEXITCODE = 0
    try {
      $directOutput = & $Action
      $directExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
      return [pscustomobject]@{
        timedOut = $false
        succeeded = $true
        exitCode = [int]$directExit
        output = $directOutput
        errorMessage = ''
      }
    } catch {
      $directExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
      return [pscustomobject]@{
        timedOut = $false
        succeeded = $false
        exitCode = [int]$directExit
        output = $null
        errorMessage = [string]$_.Exception.Message
      }
    }
  }

  $job = $null
  try {
    $job = Start-ThreadJob -ScriptBlock {
      param([scriptblock]$InnerAction)
      Set-StrictMode -Version Latest
      $ErrorActionPreference = 'Stop'
      $global:LASTEXITCODE = 0
      try {
        $innerOutput = & $InnerAction
        $innerExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        [pscustomobject]@{
          timedOut = $false
          succeeded = $true
          exitCode = [int]$innerExit
          output = $innerOutput
          errorMessage = ''
        }
      } catch {
        $innerExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        [pscustomobject]@{
          timedOut = $false
          succeeded = $false
          exitCode = [int]$innerExit
          output = $null
          errorMessage = [string]$_.Exception.Message
        }
      }
    } -ArgumentList $Action

    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if ($null -eq $completed) {
      Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
      return [pscustomobject]@{
        timedOut = $true
        succeeded = $false
        exitCode = 124
        output = $null
        errorMessage = ("Step timed out after {0} second(s)." -f [int]$TimeoutSeconds)
      }
    }

    $jobResult = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) | Select-Object -Last 1
    if (-not $jobResult) {
      return [pscustomobject]@{
        timedOut = $false
        succeeded = $false
        exitCode = 1
        output = $null
        errorMessage = 'Step runner returned no output.'
      }
    }
    return $jobResult
  } finally {
    if ($job) {
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    }
  }
}

function Get-NormalizedStepExitCode {
  param(
    [Parameter(Mandatory)][int]$ExitCode,
    [AllowNull()][AllowEmptyString()][string]$ResultClass,
    [AllowNull()][AllowEmptyString()][string]$GateOutcome,
    [AllowNull()][AllowEmptyString()][string]$FailureClass
  )

  $normalizedExit = [int]$ExitCode
  $gate = if ([string]::IsNullOrWhiteSpace($GateOutcome)) { '' } else { $GateOutcome.Trim().ToLowerInvariant() }
  $result = if ([string]::IsNullOrWhiteSpace($ResultClass)) { '' } else { $ResultClass.Trim().ToLowerInvariant() }
  $failure = if ([string]::IsNullOrWhiteSpace($FailureClass)) { '' } else { $FailureClass.Trim().ToLowerInvariant() }

  if ($gate -ne 'fail' -or $normalizedExit -ne 0) {
    return $normalizedExit
  }

  switch ($failure) {
    'timeout' { return 124 }
    'runtime-determinism' { return 2 }
    'preflight' { return 2 }
    'startup-connectivity' { return 1 }
    'cli/tool' { return 1 }
  }

  switch ($result) {
    'failure-timeout' { return 124 }
    'failure-runtime' { return 2 }
    'failure-preflight' { return 2 }
    default { return 1 }
  }
}

function Invoke-Step {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Action,
    [int[]]$AllowedExitCodes = @(0),
    [bool]$HardStopOnRuntimeFailure = $false,
    [scriptblock]$CaptureValidator,
    [int]$TimeoutSeconds = 600
  )

  $stepStartUtc = (Get-Date).ToUniversalTime()
  $stepOutput = $null
  $stepExitCode = 0
  $stepStatus = 'failure'
  $stepMessage = ''
  $resultClass = 'failure-tool'
  $gateOutcome = 'fail'
  $failureClass = 'cli/tool'
  $isDiff = $false
  $diffEvidenceSource = ''
  $diffImageCount = 0
  $extractedReportPath = ''
  $containerExportStatus = ''

  try {
    $execution = Invoke-StepActionWithTimeout -Action $Action -TimeoutSeconds $TimeoutSeconds
    $stepOutput = $execution.output
    $stepExitCode = [int]$execution.exitCode

    if ([bool]$execution.timedOut) {
      $stepStatus = 'failure'
      $stepMessage = [string]$execution.errorMessage
      $resultClass = 'failure-timeout'
      $gateOutcome = 'fail'
      $failureClass = 'timeout'
    } else {
      if (-not [bool]$execution.succeeded) {
        throw ([System.Exception]::new([string]$execution.errorMessage))
      }

      $classification = $null
      if ($CaptureValidator) {
        $classification = & $CaptureValidator $stepOutput $stepExitCode
      }
      if (-not $classification) {
        $defaultStatus = if ($AllowedExitCodes -contains $stepExitCode) { 'ok' } else { 'error' }
        $classification = Get-CompareExitClassification `
          -ExitCode $stepExitCode `
          -CaptureStatus $defaultStatus `
          -StdOut '' `
          -StdErr '' `
          -Message ''
      }

      $resultClass = [string]$classification.resultClass
      $gateOutcome = [string]$classification.gateOutcome
      $failureClass = [string]$classification.failureClass
      $isDiff = [bool]$classification.isDiff
      if ($classification.PSObject.Properties['message']) {
        $stepMessage = [string]$classification.message
      }
      if ($classification.PSObject.Properties['diffEvidenceSource']) {
        $diffEvidenceSource = [string]$classification.diffEvidenceSource
      }
      if ($classification.PSObject.Properties['diffImageCount']) {
        $diffImageCount = [int]$classification.diffImageCount
      }
      if ($classification.PSObject.Properties['extractedReportPath']) {
        $extractedReportPath = [string]$classification.extractedReportPath
      }
      if ($classification.PSObject.Properties['containerExportStatus']) {
        $containerExportStatus = [string]$classification.containerExportStatus
      }
      $stepExitCode = Get-NormalizedStepExitCode `
        -ExitCode $stepExitCode `
        -ResultClass $resultClass `
        -GateOutcome $gateOutcome `
        -FailureClass $failureClass

      if (-not ($AllowedExitCodes -contains $stepExitCode) -and $gateOutcome -eq 'pass') {
        $gateOutcome = 'fail'
        $resultClass = 'failure-preflight'
        $failureClass = 'preflight'
        $stepMessage = ("Native command exited with disallowed code {0}." -f $stepExitCode)
      } elseif (-not ($AllowedExitCodes -contains $stepExitCode) -and [string]::IsNullOrWhiteSpace($stepMessage)) {
        $stepMessage = ("Native command exited with code {0}." -f $stepExitCode)
      }

      if ($gateOutcome -eq 'pass') {
        $stepStatus = 'success'
      } else {
        $stepStatus = 'failure'
        if ([string]::IsNullOrWhiteSpace($stepMessage)) {
          $stepMessage = ("Step failed with resultClass={0} failureClass={1} exit={2}." -f $resultClass, $failureClass, $stepExitCode)
        }
      }
    }
  } catch {
    $stepExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $stepMessage = $_.Exception.Message
    $fallback = Get-CompareExitClassification `
      -ExitCode $stepExitCode `
      -CaptureStatus 'error' `
      -StdOut '' `
      -StdErr '' `
      -Message $stepMessage
    $resultClass = [string]$fallback.resultClass
    $gateOutcome = [string]$fallback.gateOutcome
    $failureClass = [string]$fallback.failureClass
    $isDiff = [bool]$fallback.isDiff
    $stepStatus = 'failure'
  }

  $hardStopEligible = [bool]$HardStopOnRuntimeFailure -or ($failureClass -eq 'runtime-determinism')
  $hardStopTriggered = ($stepStatus -ne 'success' -and $hardStopEligible)
  $stepEndUtc = (Get-Date).ToUniversalTime()
  $durationMs = [math]::Round(($stepEndUtc - $stepStartUtc).TotalMilliseconds, 0)

  $capturePath = ''
  if ($stepOutput -and $stepOutput.PSObject -and $stepOutput.PSObject.Properties['CapturePath']) {
    $capturePath = [string]$stepOutput.CapturePath
  }
  if ($stepOutput -and $stepOutput.PSObject -and $stepOutput.PSObject.Properties['Capture'] -and $stepOutput.Capture) {
    $capture = $stepOutput.Capture
    if ([string]::IsNullOrWhiteSpace($diffEvidenceSource) -and $capture.PSObject.Properties['diffEvidenceSource']) {
      $diffEvidenceSource = [string]$capture.diffEvidenceSource
    }
    if ($diffImageCount -le 0 -and $capture.PSObject.Properties['reportAnalysis'] -and $capture.reportAnalysis -and $capture.reportAnalysis.PSObject.Properties['diffImageCount']) {
      $diffImageCount = [int]$capture.reportAnalysis.diffImageCount
    }
    if ([string]::IsNullOrWhiteSpace($extractedReportPath) -and $capture.PSObject.Properties['reportAnalysis'] -and $capture.reportAnalysis -and $capture.reportAnalysis.PSObject.Properties['reportPathExtracted']) {
      $extractedReportPath = [string]$capture.reportAnalysis.reportPathExtracted
    }
    if ([string]::IsNullOrWhiteSpace($containerExportStatus) -and $capture.PSObject.Properties['containerArtifacts'] -and $capture.containerArtifacts -and $capture.containerArtifacts.PSObject.Properties['copyStatus']) {
      $containerExportStatus = [string]$capture.containerArtifacts.copyStatus
    }
  }

  return [pscustomobject]@{
    name = $Name
    status = $stepStatus
    message = $stepMessage
    startedAt = $stepStartUtc.ToString('o')
    finishedAt = $stepEndUtc.ToString('o')
    durationMs = [int]$durationMs
    exitCode = [int]$stepExitCode
    resultClass = $resultClass
    gateOutcome = $gateOutcome
    failureClass = $failureClass
    isDiff = [bool]$isDiff
    diffEvidenceSource = $diffEvidenceSource
    diffImageCount = [int]$diffImageCount
    extractedReportPath = $extractedReportPath
    containerExportStatus = $containerExportStatus
    hardStopEligible = [bool]$hardStopEligible
    hardStopTriggered = [bool]$hardStopTriggered
    allowedExitCodes = @($AllowedExitCodes)
    capturePath = $capturePath
  }
}

$root = Resolve-AbsolutePath -Path $ResultsRoot
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
  New-Item -ItemType Directory -Path $root -Force | Out-Null
}

$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
$summaryPath = Join-Path $root ("docker-runtime-fastloop-{0}.json" -f $timestamp)
$statusResolved = if ([string]::IsNullOrWhiteSpace($StatusPath)) {
  Join-Path $root 'docker-runtime-fastloop-status.json'
} else {
  Resolve-AbsolutePath -Path $StatusPath
}
$readinessJsonResolved = if ([string]::IsNullOrWhiteSpace($ReadinessJsonPath)) {
  Join-Path $root 'docker-runtime-fastloop-readiness.json'
} else {
  Resolve-AbsolutePath -Path $ReadinessJsonPath
}
$readinessMarkdownResolved = if ([string]::IsNullOrWhiteSpace($ReadinessMarkdownPath)) {
  Join-Path $root 'docker-runtime-fastloop-readiness.md'
} else {
  Resolve-AbsolutePath -Path $ReadinessMarkdownPath
}
$hostPlaneReportPath = Join-Path $root 'labview-2026-host-plane-report.json'
$hostPlaneSummaryPath = Join-Path $root 'labview-2026-host-plane-summary.md'
$windowsSnapshot = Join-Path $root 'windows-runtime-determinism.json'
$linuxSnapshot = Join-Path $root 'linux-runtime-determinism.json'
$linuxSmokeRoot = Join-Path $root 'linux-smoke'
$historyScenariosRoot = Join-Path $root 'history-scenarios'
$repoRoot = Get-RepoRootFromToolsScript
$linuxSmokeBaseVi = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue 'fixtures/vi-attr/Base.vi' -Description 'Linux smoke base VI'
$linuxSmokeHeadVi = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue 'fixtures/vi-attr/Head.vi' -Description 'Linux smoke head VI'
$linuxSmokeBootstrapScript = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue 'tools/NILinux-VIHistorySuiteBootstrap.sh' -Description 'NI Linux VI history bootstrap script'
$historyScenarioSetNormalized = if ([string]::IsNullOrWhiteSpace($HistoryScenarioSet)) { 'none' } else { $HistoryScenarioSet.Trim().ToLowerInvariant() }
$laneScopeNormalized = if ([string]::IsNullOrWhiteSpace($LaneScope)) { 'both' } else { $LaneScope.Trim().ToLowerInvariant() }
$windowsLaneEnabled = $laneScopeNormalized -ne 'linux'
$linuxLaneEnabled = $laneScopeNormalized -ne 'windows'
$loopLabel = Get-DockerFastLoopLabel -ContextObject @{ laneScope = $laneScopeNormalized }
$loopPrefix = ('[{0}]' -f $loopLabel)
$singleLaneMode = $laneScopeNormalized -ne 'both'
if ($singleLaneMode -and $ManageDockerEngine) {
  throw ("LaneScope '{0}' does not allow -ManageDockerEngine`:$true. Use LaneScope 'both' for managed engine switching." -f $laneScopeNormalized)
}
$effectiveManageDockerEngine = if ($singleLaneMode) { $false } else { [bool]$ManageDockerEngine }
$runtimeAutoRepairEnabled = -not $singleLaneMode
$defaultWindowsDockerLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
$defaultLinuxDockerLabVIEWPath = '/usr/local/natinst/LabVIEW-2026-64/labview'
$effectiveWindowsLabVIEWPath = Resolve-DockerLaneLabVIEWPath `
  -ExplicitPath $WindowsLabVIEWPath `
  -PreferredEnvNames @('NI_WINDOWS_LABVIEW_PATH', 'COMPARE_WINDOWS_LABVIEW_PATH') `
  -FallbackPath $defaultWindowsDockerLabVIEWPath
$effectiveLinuxLabVIEWPath = Resolve-DockerLaneLabVIEWPath `
  -ExplicitPath $LinuxLabVIEWPath `
  -PreferredEnvNames @('NI_LINUX_LABVIEW_PATH', 'COMPARE_LINUX_LABVIEW_PATH') `
  -FallbackPath $defaultLinuxDockerLabVIEWPath
$nativeHostLabVIEW64Path = Resolve-NativeHostPlanePath `
  -PreferredEnvNames @('COMPAREVI_NATIVE_LABVIEW_2026_64_PATH', 'NI_HOST_LABVIEW_2026_64_PATH') `
  -FallbackPath $effectiveWindowsLabVIEWPath `
  -Version 2026 `
  -Bitness 64
$nativeHostLabVIEW32Path = Resolve-NativeHostPlanePath `
  -PreferredEnvNames @('COMPAREVI_NATIVE_LABVIEW_2026_32_PATH', 'NI_HOST_LABVIEW_2026_32_PATH') `
  -Version 2026 `
  -Bitness 32
$nativeHostCli64Path = Resolve-NativeHostPlaneCliPath `
  -PreferredEnvNames @('COMPAREVI_NATIVE_LABVIEWCLI_2026_64_PATH', 'NI_HOST_LABVIEWCLI_2026_64_PATH') `
  -Version 2026 `
  -Bitness 64
$nativeHostCli32Path = Resolve-NativeHostPlaneCliPath `
  -PreferredEnvNames @('COMPAREVI_NATIVE_LABVIEWCLI_2026_32_PATH', 'NI_HOST_LABVIEWCLI_2026_32_PATH') `
  -FallbackPath $nativeHostCli64Path `
  -Version 2026 `
  -Bitness 32
$nativeHostComparePath = Resolve-NativeComparePath `
  -PreferredEnvNames @('COMPAREVI_NATIVE_LVCOMPARE_PATH', 'NI_HOST_LVCOMPARE_PATH')
$hostPlaneReport = & (Join-Path $PSScriptRoot 'Write-LabVIEW2026HostPlaneDiagnostics.ps1') `
  -LabVIEW64Path $nativeHostLabVIEW64Path `
  -LabVIEW32Path $nativeHostLabVIEW32Path `
  -LabVIEWCli64Path $nativeHostCli64Path `
  -LabVIEWCli32Path $nativeHostCli32Path `
  -LVComparePath $nativeHostComparePath `
  -OutputPath $hostPlaneReportPath `
  -SummaryPath $hostPlaneSummaryPath `
  -GitHubOutputPath '' `
  -PassThru
$effectiveSkipWindowsProbe = [bool]$SkipWindowsProbe
$effectiveSkipLinuxProbe = [bool]$SkipLinuxProbe
switch ($laneScopeNormalized) {
  'windows' { $effectiveSkipLinuxProbe = $true }
  'linux' { $effectiveSkipWindowsProbe = $true }
  default { }
}
$viHistorySourceBranchGuard = [pscustomobject]@{
  branchRef = $VIHistorySourceBranch
  baselineRef = $null
  maxCommitCount = [int]$VIHistorySourceBranchCommitLimit
  commitCount = $null
  status = 'skipped'
  reason = if (-not $linuxLaneEnabled) { 'linux-lane-disabled' } elseif ($effectiveSkipLinuxProbe) { 'linux-probe-skipped' } else { 'branch-guard-not-evaluated' }
}
if ($linuxLaneEnabled -and -not $effectiveSkipLinuxProbe) {
  $viHistorySourceBranchGuard = Get-VIHistorySourceBranchGuard `
    -RepoRoot $repoRoot `
    -BranchRef $VIHistorySourceBranch `
    -MaxCommitCount $VIHistorySourceBranchCommitLimit
}
$historyScenarioCount = 0
$historyScenarioFilterDiagnostics = New-Object System.Collections.Generic.List[string]

$results = New-Object System.Collections.Generic.List[object]
$runStartedAt = (Get-Date).ToUniversalTime().ToString('o')
$stepDefinitions = New-Object System.Collections.Generic.List[object]
$hardStopTriggered = $false
$hardStopReason = ''

if (-not $effectiveSkipWindowsProbe) {
  $stepDefinitions.Add([pscustomobject]@{
    name = 'windows-runtime-preflight'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $true
    captureValidator = {
      param($stepOutput, $stepExitCode)
      $runtimeStatus = ''
      $runtimeReason = ''
      if (Test-Path -LiteralPath $windowsSnapshot -PathType Leaf) {
        try {
          $snapshot = Get-Content -LiteralPath $windowsSnapshot -Raw | ConvertFrom-Json -Depth 8
          if ($snapshot -and $snapshot.PSObject.Properties['result']) {
            if ($snapshot.result.PSObject.Properties['status']) { $runtimeStatus = [string]$snapshot.result.status }
            if ($snapshot.result.PSObject.Properties['reason']) { $runtimeReason = [string]$snapshot.result.reason }
          }
        } catch {}
      }
      $captureStatus = if ([int]$stepExitCode -eq 0) { 'ok' } else { 'preflight-error' }
      $classification = Get-CompareExitClassification `
        -ExitCode ([int]$stepExitCode) `
        -CaptureStatus $captureStatus `
        -StdOut '' `
        -StdErr '' `
        -Message $runtimeReason `
        -RuntimeDeterminismStatus $runtimeStatus `
        -RuntimeDeterminismReason $runtimeReason
      [pscustomobject]@{
        resultClass = [string]$classification.resultClass
        isDiff = [bool]$classification.isDiff
        gateOutcome = [string]$classification.gateOutcome
        failureClass = [string]$classification.failureClass
        message = $runtimeReason
      }
    }
    action = {
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Assert-DockerRuntimeDeterminism.ps1') `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$runtimeAutoRepairEnabled `
      -ManageDockerEngine:$effectiveManageDockerEngine `
      -EngineReadyTimeoutSeconds $StepTimeoutSeconds `
      -EngineReadyPollSeconds 3 `
      -SnapshotPath $windowsSnapshot `
      -GitHubOutputPath ''
    }
  }) | Out-Null

  $stepDefinitions.Add([pscustomobject]@{
    name = 'windows-container-probe'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $true
    action = {
    $windowsProbeArgs = @(
      '-NoLogo', '-NoProfile',
      '-File', (Join-Path $PSScriptRoot 'Run-NIWindowsContainerCompare.ps1'),
      '-Probe',
      '-Image', $WindowsImage,
      '-TimeoutSeconds', [string]$StepTimeoutSeconds,
      "-AutoRepairRuntime:$runtimeAutoRepairEnabled",
      "-ManageDockerEngine:$effectiveManageDockerEngine",
      '-RuntimeEngineReadyTimeoutSeconds', [string]$StepTimeoutSeconds,
      '-RuntimeEngineReadyPollSeconds', '3',
      '-RuntimeSnapshotPath', $windowsSnapshot
    )
    if (-not [string]::IsNullOrWhiteSpace($effectiveWindowsLabVIEWPath)) {
      $windowsProbeArgs += @('-LabVIEWPath', $effectiveWindowsLabVIEWPath)
    }
    pwsh @windowsProbeArgs | Out-Null
    }
  }) | Out-Null
}

if (-not $effectiveSkipLinuxProbe) {
  $stepDefinitions.Add([pscustomobject]@{
    name = 'linux-runtime-preflight'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $true
    captureValidator = {
      param($stepOutput, $stepExitCode)
      $runtimeStatus = ''
      $runtimeReason = ''
      if (Test-Path -LiteralPath $linuxSnapshot -PathType Leaf) {
        try {
          $snapshot = Get-Content -LiteralPath $linuxSnapshot -Raw | ConvertFrom-Json -Depth 8
          if ($snapshot -and $snapshot.PSObject.Properties['result']) {
            if ($snapshot.result.PSObject.Properties['status']) { $runtimeStatus = [string]$snapshot.result.status }
            if ($snapshot.result.PSObject.Properties['reason']) { $runtimeReason = [string]$snapshot.result.reason }
          }
        } catch {}
      }
      $captureStatus = if ([int]$stepExitCode -eq 0) { 'ok' } else { 'preflight-error' }
      $classification = Get-CompareExitClassification `
        -ExitCode ([int]$stepExitCode) `
        -CaptureStatus $captureStatus `
        -StdOut '' `
        -StdErr '' `
        -Message $runtimeReason `
        -RuntimeDeterminismStatus $runtimeStatus `
        -RuntimeDeterminismReason $runtimeReason
      [pscustomobject]@{
        resultClass = [string]$classification.resultClass
        isDiff = [bool]$classification.isDiff
        gateOutcome = [string]$classification.gateOutcome
        failureClass = [string]$classification.failureClass
        message = $runtimeReason
      }
    }
    action = {
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Assert-DockerRuntimeDeterminism.ps1') `
      -ExpectedOsType linux `
      -ExpectedContext desktop-linux `
      -AutoRepair:$runtimeAutoRepairEnabled `
      -ManageDockerEngine:$effectiveManageDockerEngine `
      -EngineReadyTimeoutSeconds $StepTimeoutSeconds `
      -EngineReadyPollSeconds 3 `
      -SnapshotPath $linuxSnapshot `
      -GitHubOutputPath ''
    }
  }) | Out-Null

    $stepDefinitions.Add([pscustomobject]@{
    name = 'linux-container-probe'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $true
    action = {
    $linuxProbeArgs = @(
      '-NoLogo', '-NoProfile',
      '-File', (Join-Path $PSScriptRoot 'Run-NILinuxContainerCompare.ps1'),
      '-Probe',
      '-Image', $LinuxImage,
      '-TimeoutSeconds', [string]$StepTimeoutSeconds,
      "-AutoRepairRuntime:$runtimeAutoRepairEnabled",
      '-RuntimeEngineReadyTimeoutSeconds', [string]$StepTimeoutSeconds,
      '-RuntimeEngineReadyPollSeconds', '3',
      '-RuntimeSnapshotPath', $linuxSnapshot
    )
    if (-not [string]::IsNullOrWhiteSpace($effectiveLinuxLabVIEWPath)) {
      $linuxProbeArgs += @('-LabVIEWPath', $effectiveLinuxLabVIEWPath)
    }
    pwsh @linuxProbeArgs | Out-Null
    }
  }) | Out-Null

  $stepDefinitions.Add([pscustomobject]@{
    name = 'linux-vi-history-suite-bootstrap-smoke'
    allowedExitCodes = @(0, 1)
    hardStopOnRuntimeFailure = $true
    captureValidator = {
      param($stepOutput, $stepExitCode)
      if (-not $stepOutput -or -not $stepOutput.PSObject.Properties['Classification']) {
        throw ("Missing compare classification for linux bootstrap smoke (exit={0})." -f $stepExitCode)
      }
      $classification = $stepOutput.Classification
      $validatorMessage = ''
      if ($stepOutput.PSObject.Properties['Message']) {
        $validatorMessage = [string]$stepOutput.Message
      }
      [pscustomobject]@{
        resultClass = [string]$classification.resultClass
        isDiff = [bool]$classification.isDiff
        gateOutcome = [string]$classification.gateOutcome
        failureClass = [string]$classification.failureClass
        message = $validatorMessage
        diffEvidenceSource = if ($stepOutput.Capture.PSObject.Properties['diffEvidenceSource']) { [string]$stepOutput.Capture.diffEvidenceSource } else { '' }
        diffImageCount = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['diffImageCount']) { [int]$stepOutput.Capture.reportAnalysis.diffImageCount } else { 0 }
        extractedReportPath = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['reportPathExtracted']) { [string]$stepOutput.Capture.reportAnalysis.reportPathExtracted } else { '' }
        containerExportStatus = if ($stepOutput.Capture.PSObject.Properties['containerArtifacts'] -and $stepOutput.Capture.containerArtifacts -and $stepOutput.Capture.containerArtifacts.PSObject.Properties['copyStatus']) { [string]$stepOutput.Capture.containerArtifacts.copyStatus } else { '' }
      }
    }
    action = {
    $suiteRoot = Join-Path $linuxSmokeRoot 'vi-history-suite'
    if (-not (Test-Path -LiteralPath $suiteRoot -PathType Container)) {
      New-Item -ItemType Directory -Path $suiteRoot -Force | Out-Null
    }

    $tmpOut = Join-Path $suiteRoot 'gh-output.txt'
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'New-VIHistorySmokeFixture.ps1') `
      -OutputRoot $suiteRoot `
      -GitHubOutputPath $tmpOut | Out-Null

    $outputs = @{}
    foreach ($line in Get-Content -LiteralPath $tmpOut) {
      if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '=') { continue }
      $parts = $line -split '=', 2
      $outputs[$parts[0]] = $parts[1]
    }
    $manifestPath = $outputs['suite-manifest-path']
    $contextPath = $outputs['history-context-path']
    $resultsDir = $outputs['results-dir']
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or [string]::IsNullOrWhiteSpace($contextPath) -or [string]::IsNullOrWhiteSpace($resultsDir)) {
      throw 'Fixture generator did not provide expected suite output paths for linux bootstrap smoke.'
    }

    $bootstrapMarker = Join-Path $resultsDir 'vi-history-bootstrap-ran.txt'
    $contractPath = Join-Path $suiteRoot 'runtime-bootstrap.json'
    $contract = [ordered]@{
      schema = 'ni-linux-runtime-bootstrap/v1'
      mode = 'vi-history-suite-smoke'
      branchRef = $VIHistorySourceBranch
      maxCommitCount = $VIHistorySourceBranchCommitLimit
      scriptPath = $linuxSmokeBootstrapScript
      viHistory = [ordered]@{
        repoPath = $repoRoot
        targetPath = 'fixtures/vi-attr/Head.vi'
        resultsPath = $resultsDir
        baselineRef = 'develop'
        maxPairs = 2
      }
    }
    $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $contractPath -Encoding utf8

    $reportPath = Join-Path $resultsDir 'linux-compare-report.html'
    Invoke-LinuxContainerSmokeCompare `
      -ReportPath $reportPath `
      -LabVIEWPath $effectiveLinuxLabVIEWPath `
      -LinuxImage $LinuxImage `
      -RuntimeSnapshotPath $linuxSnapshot `
      -RuntimeAutoRepair:$runtimeAutoRepairEnabled `
      -StepTimeoutSeconds $StepTimeoutSeconds `
      -BootstrapContractPath $contractPath `
      -ExpectedBootstrapMode 'vi-history-suite-smoke' `
      -ExpectedBranchRef $VIHistorySourceBranch `
      -ExpectedBootstrapMarkerPath $bootstrapMarker
    }
  }) | Out-Null

  $stepDefinitions.Add([pscustomobject]@{
    name = 'linux-renderer-smoke-probe'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $false
    action = {
    if (-not (Test-Path -LiteralPath $linuxSmokeRoot -PathType Container)) {
      New-Item -ItemType Directory -Path $linuxSmokeRoot -Force | Out-Null
    }
    $tmpOut = Join-Path $linuxSmokeRoot 'gh-output.txt'
    $tmpSummary = Join-Path $linuxSmokeRoot 'step-summary.md'
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'New-VIHistorySmokeFixture.ps1') `
      -OutputRoot $linuxSmokeRoot `
      -GitHubOutputPath $tmpOut | Out-Null

    $outputs = @{}
    foreach ($line in Get-Content -LiteralPath $tmpOut) {
      if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '=') { continue }
      $parts = $line -split '=', 2
      $outputs[$parts[0]] = $parts[1]
    }
    $manifestPath = $outputs['suite-manifest-path']
    $contextPath = $outputs['history-context-path']
    $resultsDir = $outputs['results-dir']
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or [string]::IsNullOrWhiteSpace($contextPath) -or [string]::IsNullOrWhiteSpace($resultsDir)) {
      throw 'Fixture generator did not provide expected output paths.'
    }

    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Render-VIHistoryReport.ps1') `
      -ManifestPath $manifestPath `
      -HistoryContextPath $contextPath `
      -OutputDir $resultsDir `
      -EmitHtml `
      -GitHubOutputPath $tmpOut `
      -StepSummaryPath $tmpSummary | Out-Null
    }
  }) | Out-Null
}

if ($historyScenarioSetNormalized -ne 'none') {
  $harnessPathResolved = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue $HistoryHarnessPath -Description 'History harness manifest'
  $harness = Get-Content -LiteralPath $harnessPathResolved -Raw | ConvertFrom-Json -Depth 8
  if (-not $harness -or [string]$harness.schema -ne 'vi-history-pr-harness@v1') {
    throw ("Unsupported history harness schema in {0}" -f $harnessPathResolved)
  }
  $scenarioSelection = Get-HistoryScenarioIdsForSet -ScenarioSet $historyScenarioSetNormalized -Harness $harness
  $scenarioIds = @($scenarioSelection.scenarioIds)
  foreach ($diagnostic in @($scenarioSelection.diagnostics)) {
    if ([string]::IsNullOrWhiteSpace([string]$diagnostic)) { continue }
    $historyScenarioFilterDiagnostics.Add([string]$diagnostic) | Out-Null
    Write-Host ("{0}[history-filter] {1}" -f $loopPrefix, [string]$diagnostic) -ForegroundColor DarkYellow
  }
  if ($scenarioIds.Count -gt 0 -and -not (Test-Path -LiteralPath $historyScenariosRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $historyScenariosRoot -Force | Out-Null
  }

  $baselineBase = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue 'fixtures/vi-attr/Base.vi' -Description 'History baseline base VI'
  $scenarioMap = @{}
  foreach ($scenario in @($harness.scenarios)) {
    if (-not $scenario -or -not $scenario.PSObject.Properties['id']) { continue }
    $scenarioMap[[string]$scenario.id] = $scenario
  }

  foreach ($scenarioId in $scenarioIds) {
    if (-not $scenarioMap.ContainsKey($scenarioId)) {
      throw ("History scenario '{0}' was not found in harness manifest {1}" -f $scenarioId, $harnessPathResolved)
    }
    $scenario = $scenarioMap[$scenarioId]
    $scenarioMode = if ($scenario.PSObject.Properties['mode']) { [string]$scenario.mode } else { 'attribute' }

    if ([string]::Equals($scenarioMode, 'sequential', [System.StringComparison]::OrdinalIgnoreCase)) {
      $sequentialPathResolved = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue $SequentialFixturePath -Description 'Sequential history fixture'
      $sequential = Get-Content -LiteralPath $sequentialPathResolved -Raw | ConvertFrom-Json -Depth 8
      if (-not $sequential -or [string]$sequential.schema -ne 'vi-history-sequence@v1') {
        throw ("Unsupported sequential fixture schema in {0}" -f $sequentialPathResolved)
      }
      if (-not $sequential.steps -or @($sequential.steps).Count -eq 0) {
        throw ("Sequential fixture contains no steps: {0}" -f $sequentialPathResolved)
      }

      if ($linuxLaneEnabled) {
        $linuxSequentialRoot = Join-Path $historyScenariosRoot (Join-Path 'sequential' 'linux-suite')
        $linuxHistoryAction = {
          if (-not (Test-Path -LiteralPath $linuxSequentialRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $linuxSequentialRoot -Force | Out-Null
          }

          $materialized = New-LinuxSequentialHistoryScenarioRepo `
            -RepoRoot $repoRoot `
            -FixturePath $SequentialFixturePath `
            -OutputRoot $linuxSequentialRoot `
            -BranchRef $VIHistorySourceBranch

          $resultsDir = Join-Path $linuxSequentialRoot 'results'
          if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) {
            New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
          }

          $bootstrapMarker = Join-Path $resultsDir 'vi-history-bootstrap-ran.txt'
          $contractPath = Join-Path $linuxSequentialRoot 'runtime-bootstrap.json'
          $contract = [ordered]@{
            schema = 'ni-linux-runtime-bootstrap/v1'
            mode = 'vi-history-sequential-smoke'
            branchRef = $materialized.branchRef
            maxCommitCount = $VIHistorySourceBranchCommitLimit
            scriptPath = $linuxSmokeBootstrapScript
            viHistory = [ordered]@{
              repoPath = $materialized.repoPath
              targetPath = $materialized.targetPath
              resultsPath = $resultsDir
              baselineRef = 'develop'
              maxPairs = $materialized.maxPairs
            }
          }
          $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $contractPath -Encoding utf8

          $reportPath = Join-Path $resultsDir 'linux-compare-report.html'
          Invoke-LinuxContainerSmokeCompare `
            -ReportPath $reportPath `
            -LabVIEWPath $effectiveLinuxLabVIEWPath `
            -LinuxImage $LinuxImage `
            -RuntimeSnapshotPath $linuxSnapshot `
            -RuntimeAutoRepair:$runtimeAutoRepairEnabled `
            -StepTimeoutSeconds $StepTimeoutSeconds `
            -BootstrapContractPath $contractPath `
            -ExpectedBootstrapMode 'vi-history-sequential-smoke' `
            -ExpectedBranchRef $materialized.branchRef `
            -ExpectedBootstrapMarkerPath $bootstrapMarker
        }.GetNewClosure()

        $stepDefinitions.Add([pscustomobject]@{
          name = 'linux-history-sequential'
          historyLane = 'linux'
          historySequence = 'sequential'
          historyMode = 'sequential'
          historyScenarioId = $scenarioId
          allowedExitCodes = @(0, 1)
          hardStopOnRuntimeFailure = $true
          captureValidator = {
            param($stepOutput, $stepExitCode)
            if (-not $stepOutput -or -not $stepOutput.PSObject.Properties['Classification']) {
              throw ("Missing compare classification for linux sequential history output (exit={0})." -f $stepExitCode)
            }
            $classification = $stepOutput.Classification
            $validatorMessage = ''
            if ($stepOutput.PSObject.Properties['Message']) {
              $validatorMessage = [string]$stepOutput.Message
            }
            [pscustomobject]@{
              resultClass = [string]$classification.resultClass
              isDiff = [bool]$classification.isDiff
              gateOutcome = [string]$classification.gateOutcome
              failureClass = [string]$classification.failureClass
              message = $validatorMessage
              diffEvidenceSource = if ($stepOutput.Capture.PSObject.Properties['diffEvidenceSource']) { [string]$stepOutput.Capture.diffEvidenceSource } else { '' }
              diffImageCount = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['diffImageCount']) { [int]$stepOutput.Capture.reportAnalysis.diffImageCount } else { 0 }
              extractedReportPath = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['reportPathExtracted']) { [string]$stepOutput.Capture.reportAnalysis.reportPathExtracted } else { '' }
              containerExportStatus = if ($stepOutput.Capture.PSObject.Properties['containerArtifacts'] -and $stepOutput.Capture.containerArtifacts -and $stepOutput.Capture.containerArtifacts.PSObject.Properties['copyStatus']) { [string]$stepOutput.Capture.containerArtifacts.copyStatus } else { '' }
            }
          }
          action = $linuxHistoryAction
        }) | Out-Null
        $historyScenarioCount++
      }

      $previousHead = $baselineBase
      $stepIndex = 0
      $addedSequentialSteps = 0
      if ($windowsLaneEnabled) {
        foreach ($sequenceStep in @($sequential.steps)) {
          $stepIndex++
          $seqIdRaw = if ($sequenceStep.PSObject.Properties['id']) { [string]$sequenceStep.id } else { ("step-{0:000}" -f $stepIndex) }
          $requireStepDiff = $false
          if ($sequenceStep.PSObject.Properties['requireDiff']) {
            $requireStepDiff = [bool]$sequenceStep.requireDiff
          }
          if (-not $requireStepDiff) {
            $skipMessage = ("Sequential step '{0}' skipped because requireDiff=true is required for diff-only history execution." -f $seqIdRaw)
            $historyScenarioFilterDiagnostics.Add($skipMessage) | Out-Null
            Write-Host ("{0}[history-filter] {1}" -f $loopPrefix, $skipMessage) -ForegroundColor DarkYellow
            continue
          }
          $safeSeqId = $seqIdRaw -replace '[^a-zA-Z0-9._-]', '-'
          $headPath = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue ([string]$sequenceStep.source) -Description ("Sequential step source '{0}'" -f $seqIdRaw)
          $reportPath = Join-Path $historyScenariosRoot (Join-Path 'sequential' (Join-Path $safeSeqId 'windows-compare-report.html'))
          $stepName = "windows-history-sequential-$safeSeqId"
          $baseForStep = $previousHead
          $headForStep = $headPath

          $historyAction = {
            Invoke-WindowsHistoryCompare `
              -BaseVi $baseForStep `
              -HeadVi $headForStep `
              -ReportPath $reportPath `
              -LabVIEWPath $effectiveWindowsLabVIEWPath `
              -WindowsImage $WindowsImage `
              -RuntimeSnapshotPath $windowsSnapshot `
              -RuntimeAutoRepair:$runtimeAutoRepairEnabled `
              -ManageDockerEngine:$effectiveManageDockerEngine `
              -StepTimeoutSeconds $StepTimeoutSeconds
          }.GetNewClosure()

          $stepDefinitions.Add([pscustomobject]@{
            name = $stepName
            historyLane = 'windows'
            historySequence = 'sequential'
            historyMode = $seqIdRaw
            historyScenarioId = $scenarioId
            allowedExitCodes = @(0, 1)
            hardStopOnRuntimeFailure = $true
            captureValidator = {
              param($stepOutput, $stepExitCode)
              if (-not $stepOutput -or -not $stepOutput.PSObject.Properties['Classification']) {
                throw ("Missing compare classification for step output (exit={0})." -f $stepExitCode)
              }
              $classification = $stepOutput.Classification
              $validatorMessage = ''
              if ($stepOutput.PSObject.Properties['Message']) {
                $validatorMessage = [string]$stepOutput.Message
              }
              [pscustomobject]@{
                resultClass = [string]$classification.resultClass
                isDiff = [bool]$classification.isDiff
                gateOutcome = [string]$classification.gateOutcome
                failureClass = [string]$classification.failureClass
                message = $validatorMessage
                diffEvidenceSource = if ($stepOutput.Capture.PSObject.Properties['diffEvidenceSource']) { [string]$stepOutput.Capture.diffEvidenceSource } else { '' }
                diffImageCount = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['diffImageCount']) { [int]$stepOutput.Capture.reportAnalysis.diffImageCount } else { 0 }
                extractedReportPath = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['reportPathExtracted']) { [string]$stepOutput.Capture.reportAnalysis.reportPathExtracted } else { '' }
                containerExportStatus = if ($stepOutput.Capture.PSObject.Properties['containerArtifacts'] -and $stepOutput.Capture.containerArtifacts -and $stepOutput.Capture.containerArtifacts.PSObject.Properties['copyStatus']) { [string]$stepOutput.Capture.containerArtifacts.copyStatus } else { '' }
              }
            }
            action = $historyAction
          }) | Out-Null

          $historyScenarioCount++
          $addedSequentialSteps++
          $previousHead = $headPath
        }
      }
      if ($windowsLaneEnabled -and $addedSequentialSteps -eq 0) {
        throw ("History sequential scenario '{0}' resolved to empty after requireDiff=true filtering in {1}." -f $scenarioId, $sequentialPathResolved)
      }
      continue
    }

    if (-not $scenario.PSObject.Properties['source'] -or [string]::IsNullOrWhiteSpace([string]$scenario.source)) {
      throw ("History scenario '{0}' requires a source path." -f $scenarioId)
    }
    if (-not $windowsLaneEnabled) {
      continue
    }
    $safeScenarioId = $scenarioId -replace '[^a-zA-Z0-9._-]', '-'
    $headPath = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue ([string]$scenario.source) -Description ("Scenario source '{0}'" -f $scenarioId)
    $reportPath = Join-Path $historyScenariosRoot (Join-Path $safeScenarioId 'windows-compare-report.html')
    $stepName = "windows-history-$safeScenarioId"

    $historyAction = {
      Invoke-WindowsHistoryCompare `
        -BaseVi $baselineBase `
        -HeadVi $headPath `
        -ReportPath $reportPath `
        -LabVIEWPath $effectiveWindowsLabVIEWPath `
        -WindowsImage $WindowsImage `
        -RuntimeSnapshotPath $windowsSnapshot `
        -RuntimeAutoRepair:$runtimeAutoRepairEnabled `
        -ManageDockerEngine:$effectiveManageDockerEngine `
        -StepTimeoutSeconds $StepTimeoutSeconds
    }.GetNewClosure()

    $stepDefinitions.Add([pscustomobject]@{
      name = $stepName
      historyLane = 'windows'
      historySequence = 'direct'
      historyMode = $scenarioMode
      historyScenarioId = $scenarioId
      allowedExitCodes = @(0, 1)
      hardStopOnRuntimeFailure = $true
      captureValidator = {
        param($stepOutput, $stepExitCode)
        if (-not $stepOutput -or -not $stepOutput.PSObject.Properties['Classification']) {
          throw ("Missing compare classification for step output (exit={0})." -f $stepExitCode)
        }
        $classification = $stepOutput.Classification
        $validatorMessage = ''
        if ($stepOutput.PSObject.Properties['Message']) {
          $validatorMessage = [string]$stepOutput.Message
        }
        [pscustomobject]@{
          resultClass = [string]$classification.resultClass
          isDiff = [bool]$classification.isDiff
          gateOutcome = [string]$classification.gateOutcome
          failureClass = [string]$classification.failureClass
          message = $validatorMessage
          diffEvidenceSource = if ($stepOutput.Capture.PSObject.Properties['diffEvidenceSource']) { [string]$stepOutput.Capture.diffEvidenceSource } else { '' }
          diffImageCount = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['diffImageCount']) { [int]$stepOutput.Capture.reportAnalysis.diffImageCount } else { 0 }
          extractedReportPath = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['reportPathExtracted']) { [string]$stepOutput.Capture.reportAnalysis.reportPathExtracted } else { '' }
          containerExportStatus = if ($stepOutput.Capture.PSObject.Properties['containerArtifacts'] -and $stepOutput.Capture.containerArtifacts -and $stepOutput.Capture.containerArtifacts.PSObject.Properties['copyStatus']) { [string]$stepOutput.Capture.containerArtifacts.copyStatus } else { '' }
        }
      }
      action = $historyAction
    }) | Out-Null
    $historyScenarioCount++
  }
}

function Get-StepLaneOrderRank {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$LanePreference
  )

  $linuxRank = 0
  $windowsRank = 1
  if ($LanePreference -eq 'windows-first') {
    $linuxRank = 1
    $windowsRank = 0
  }

  if ($Name -like 'linux-*') { return $linuxRank }
  if ($Name -like 'windows-*') { return $windowsRank }
  return 2
}

if ($stepDefinitions.Count -gt 1) {
  $indexed = for ($i = 0; $i -lt $stepDefinitions.Count; $i++) {
    [pscustomobject]@{
      index = $i
      def = $stepDefinitions[$i]
      rank = Get-StepLaneOrderRank -Name ([string]$stepDefinitions[$i].name) -LanePreference $LaneOrder
    }
  }
  $orderedDefs = @($indexed | Sort-Object -Property rank, index | ForEach-Object { $_.def })
  $stepDefinitions.Clear()
  foreach ($def in $orderedDefs) {
    $stepDefinitions.Add($def) | Out-Null
  }
}

$loopLabel = Get-DockerFastLoopLabel -ContextObject @{
  laneScope = $laneScopeNormalized
  steps = $stepDefinitions.ToArray()
}
$loopPrefix = ('[{0}]' -f $loopLabel)

$totalSteps = $stepDefinitions.Count
$stepPlan = @($stepDefinitions.ToArray() | ForEach-Object { [string]$_.name })
$historicalStepMedians = Get-HistoricalStepDurationMedians -ResultsDir $root
Write-SemiLiveStatus `
  -Path $statusResolved `
  -StartedAt $runStartedAt `
  -RunStatus 'running' `
  -Phase 'running' `
  -CurrentStep '' `
  -CompletedSteps 0 `
  -TotalSteps $totalSteps `
  -StepPlan $stepPlan `
  -Steps @() `
  -HistoricalStepMedians $historicalStepMedians `
  -HardStopTriggered:$hardStopTriggered `
  -HardStopReason $hardStopReason `
  -LoopLabel $loopLabel `
  -SummaryPath '' `
  -HostPlaneReportPath $hostPlaneReportPath `
  -HostPlaneSummaryPath $hostPlaneSummaryPath

foreach ($definition in $stepDefinitions.ToArray()) {
  $stepName = [string]$definition.name
  Write-Host ("{0} start: {1}" -f $loopPrefix, $stepName)
  Write-SemiLiveStatus `
    -Path $statusResolved `
    -StartedAt $runStartedAt `
    -RunStatus 'running' `
    -Phase 'running' `
    -CurrentStep $stepName `
    -CompletedSteps $results.Count `
    -TotalSteps $totalSteps `
    -StepPlan $stepPlan `
    -Steps $results.ToArray() `
    -HistoricalStepMedians $historicalStepMedians `
    -HardStopTriggered:$hardStopTriggered `
    -HardStopReason $hardStopReason `
    -LoopLabel $loopLabel `
    -SummaryPath '' `
    -HostPlaneReportPath $hostPlaneReportPath `
    -HostPlaneSummaryPath $hostPlaneSummaryPath

  $allowedExitCodes = @(0)
  if ($definition.PSObject.Properties['allowedExitCodes'] -and $definition.allowedExitCodes) {
    $allowedExitCodes = @($definition.allowedExitCodes | ForEach-Object { [int]$_ })
  }
  $hardStopOnRuntimeFailure = $false
  if ($definition.PSObject.Properties['hardStopOnRuntimeFailure']) {
    $hardStopOnRuntimeFailure = [bool]$definition.hardStopOnRuntimeFailure
  }
  $captureValidator = $null
  if ($definition.PSObject.Properties['captureValidator'] -and $definition.captureValidator) {
    $captureValidator = [scriptblock]$definition.captureValidator
  }
  $stepResult = Invoke-Step `
    -Name $stepName `
    -Action $definition.action `
    -AllowedExitCodes $allowedExitCodes `
    -HardStopOnRuntimeFailure:$hardStopOnRuntimeFailure `
    -CaptureValidator $captureValidator `
    -TimeoutSeconds $StepTimeoutSeconds
  foreach ($metadataName in @('historyLane', 'historySequence', 'historyMode', 'historyScenarioId')) {
    if ($definition.PSObject.Properties[$metadataName]) {
      $metadataValue = [string]$definition.PSObject.Properties[$metadataName].Value
      if (-not [string]::IsNullOrWhiteSpace($metadataValue)) {
        $stepResult | Add-Member -NotePropertyName $metadataName -NotePropertyValue $metadataValue -Force
      }
    }
  }
  $results.Add($stepResult) | Out-Null
  $durationText = if ($stepResult.PSObject.Properties['durationMs']) { [string]$stepResult.durationMs } else { '0' }
  $stepStatusText = [string]$stepResult.status
  $diffEvidenceText = ''
  if ($stepResult.PSObject.Properties['diffEvidenceSource'] -and -not [string]::IsNullOrWhiteSpace([string]$stepResult.diffEvidenceSource)) {
    $diffEvidenceText = (" evidence={0}" -f [string]$stepResult.diffEvidenceSource)
    if ($stepResult.PSObject.Properties['diffImageCount']) {
      $diffEvidenceText = ("{0} images={1}" -f $diffEvidenceText, [int]$stepResult.diffImageCount)
    }
  }
  if ($stepStatusText -eq 'success') {
    Write-Host ("{0} done: {1} ({2} ms) class={3} diff={4} exit={5}{6}" -f $loopPrefix, $stepName, $durationText, [string]$stepResult.resultClass, [bool]$stepResult.isDiff, [int]$stepResult.exitCode, $diffEvidenceText) -ForegroundColor Green
  } else {
    $failureMessage = [string]$stepResult.message
    Write-Host ("{0} failed: {1} ({2} ms) class={3} failureClass={4} exit={5}: {6}" -f $loopPrefix, $stepName, $durationText, [string]$stepResult.resultClass, [string]$stepResult.failureClass, [int]$stepResult.exitCode, $failureMessage) -ForegroundColor Red
    if ($stepResult.PSObject.Properties['hardStopTriggered'] -and [bool]$stepResult.hardStopTriggered) {
      $hardStopTriggered = $true
      $failureClassText = [string]$stepResult.failureClass
      $reasonPrefix = switch ($failureClassText) {
        'runtime-determinism' { 'Runtime determinism check failed' }
        'startup-connectivity' { 'Startup/connectivity failure detected' }
        'timeout' { 'Timeout failure detected' }
        'preflight' { 'Preflight failure detected' }
        default { 'Tool failure detected' }
      }
      $hardStopReason = ("{0} at step '{1}' (failureClass={2}, exit={3}): {4}" -f $reasonPrefix, $stepName, $failureClassText, [int]$stepResult.exitCode, $failureMessage)
      Write-Host ("{0} hard-stop: {1}" -f $loopPrefix, $hardStopReason) -ForegroundColor Red
    }
  }
  Write-SemiLiveStatus `
    -Path $statusResolved `
    -StartedAt $runStartedAt `
    -RunStatus 'running' `
    -Phase 'running' `
    -CurrentStep '' `
    -CompletedSteps $results.Count `
    -TotalSteps $totalSteps `
    -StepPlan $stepPlan `
    -Steps $results.ToArray() `
    -HistoricalStepMedians $historicalStepMedians `
    -HardStopTriggered:$hardStopTriggered `
    -HardStopReason $hardStopReason `
    -LoopLabel $loopLabel `
    -SummaryPath '' `
    -HostPlaneReportPath $hostPlaneReportPath `
    -HostPlaneSummaryPath $hostPlaneSummaryPath

  if ($hardStopTriggered) {
    break
  }
}

$failed = New-Object System.Collections.Generic.List[object]
foreach ($entry in $results.ToArray()) {
  $statusValue = $null
  if ($entry -is [System.Collections.IDictionary]) {
    $statusValue = [string]$entry['status']
  } elseif ($entry -and $entry.PSObject -and $entry.PSObject.Properties['status']) {
    $statusValue = [string]$entry.status
  }
  if ([string]::IsNullOrWhiteSpace($statusValue) -or $statusValue -ne 'success') {
    $failed.Add($entry) | Out-Null
  }
}
$diffStepCount = 0
$runtimeFailureCount = 0
$toolFailureCount = 0
$timeoutFailureCount = 0
$preflightFailureCount = 0
$diffEvidenceSteps = 0
$extractedReportCount = 0
$containerExportFailureCount = 0
$diffLaneSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($entry in $results.ToArray()) {
  $entryIsDiff = $false
  if ($entry.PSObject.Properties['isDiff']) {
    $entryIsDiff = [bool]$entry.isDiff
  }
  if ($entryIsDiff) {
    $diffStepCount++
    $laneName = if ($entry.PSObject.Properties['name']) { Get-StepLane -StepName ([string]$entry.name) } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($laneName)) {
      $diffLaneSet.Add($laneName) | Out-Null
    }
  }
  $failureClassValue = if ($entry.PSObject.Properties['failureClass']) { [string]$entry.failureClass } else { '' }
  switch ($failureClassValue) {
    'runtime-determinism' { $runtimeFailureCount++ }
    'startup-connectivity' { $toolFailureCount++ }
    'cli/tool' { $toolFailureCount++ }
    'timeout' { $timeoutFailureCount++ }
    'preflight' { $preflightFailureCount++ }
  }
  $diffEvidenceSourceValue = if ($entry.PSObject.Properties['diffEvidenceSource']) { [string]$entry.diffEvidenceSource } else { '' }
  if ([string]::Equals($diffEvidenceSourceValue, 'html', [System.StringComparison]::OrdinalIgnoreCase)) {
    $diffEvidenceSteps++
  }
  $extractedPathValue = if ($entry.PSObject.Properties['extractedReportPath']) { [string]$entry.extractedReportPath } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($extractedPathValue)) {
    $extractedReportCount++
  }
  $exportStatusValue = if ($entry.PSObject.Properties['containerExportStatus']) { [string]$entry.containerExportStatus } else { '' }
  if ($exportStatusValue -in @('failed', 'partial')) {
    $containerExportFailureCount++
  }
}

$summary = [ordered]@{
  schema = 'docker-desktop-fast-loop@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  loopLabel = $loopLabel
  windowsImage = $WindowsImage
  linuxImage = $LinuxImage
  labviewPaths = [ordered]@{
    windows = $effectiveWindowsLabVIEWPath
    linux = $effectiveLinuxLabVIEWPath
  }
  resultsRoot = $root
  snapshots = [ordered]@{
    windows = $windowsSnapshot
    linux = $linuxSnapshot
  }
  hostPlane = $hostPlaneReport
  hostPlaneReportPath = $hostPlaneReportPath
  hostPlaneSummaryPath = $hostPlaneSummaryPath
  hostPlaneSummaryStatus = ''
  hostPlaneSummarySha256 = ''
  hostPlaneSummaryReason = ''
  statusPath = $statusResolved
  readinessJsonPath = $readinessJsonResolved
  readinessMarkdownPath = $readinessMarkdownResolved
  historyScenarioSet = $historyScenarioSetNormalized
  laneScope = $laneScopeNormalized
  historyScenarioCount = [int]$historyScenarioCount
  diffStepCount = [int]$diffStepCount
  diffEvidenceSteps = [int]$diffEvidenceSteps
  diffLaneCount = [int]$diffLaneSet.Count
  extractedReportCount = [int]$extractedReportCount
  containerExportFailureCount = [int]$containerExportFailureCount
  runtimeFailureCount = [int]$runtimeFailureCount
  toolFailureCount = [int]$toolFailureCount
  timeoutFailureCount = [int]$timeoutFailureCount
  preflightFailureCount = [int]$preflightFailureCount
  hardStopTriggered = [bool]$hardStopTriggered
  hardStopReason = $hardStopReason
  skipWindowsProbe = [bool]$effectiveSkipWindowsProbe
  skipLinuxProbe = [bool]$effectiveSkipLinuxProbe
  historyScenarioFilterDiagnostics = @($historyScenarioFilterDiagnostics.ToArray())
  singleLaneMode = [bool]$singleLaneMode
  runtimeAutoRepair = [bool]$runtimeAutoRepairEnabled
  stepTimeoutSeconds = [int]$StepTimeoutSeconds
  manageDockerEngine = [bool]$effectiveManageDockerEngine
  laneOrder = $LaneOrder
  viHistorySourceBranch = [ordered]@{
    branchRef = $VIHistorySourceBranch
    maxCommitCount = [int]$VIHistorySourceBranchCommitLimit
    guard = $viHistorySourceBranchGuard
  }
  hostPlanes = $hostPlaneReport.native.planes
  hostExecutionPolicy = $hostPlaneReport.executionPolicy
  runtimeManager = (Get-RuntimeManagerTelemetry -WindowsSnapshotPath $windowsSnapshot -LinuxSnapshotPath $linuxSnapshot)
  laneLifecycle = (Get-LaneLifecycleFromPlan `
    -StepPlan $stepPlan `
    -ObservedSteps $results.ToArray() `
    -Phase 'completed' `
    -HardStopTriggered:$hardStopTriggered `
    -HardStopReason $hardStopReason)
  steps = $results.ToArray()
  status = if ($failed.Count -eq 0) { 'success' } else { 'failure' }
}
$hostPlaneSummary = Get-HostPlaneSummaryAssessment -Summary ([pscustomobject]$summary) -HostPlane $hostPlaneReport -HostPlaneReportPath $hostPlaneReportPath
$summary.hostPlaneSummaryPath = [string]$hostPlaneSummary.path
$summary.hostPlaneSummaryStatus = [string]$hostPlaneSummary.status
$summary.hostPlaneSummarySha256 = [string]$hostPlaneSummary.sha256
$summary.hostPlaneSummaryReason = [string]$hostPlaneSummary.reason
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
Write-Host ("{0} summary: {1}" -f $loopPrefix, $summaryPath)

Write-SemiLiveStatus `
  -Path $statusResolved `
  -StartedAt $runStartedAt `
  -RunStatus ([string]$summary.status) `
  -Phase 'completed' `
  -CurrentStep '' `
  -CompletedSteps $results.Count `
  -TotalSteps $totalSteps `
  -StepPlan $stepPlan `
  -Steps $results.ToArray() `
  -HistoricalStepMedians $historicalStepMedians `
  -HardStopTriggered:$hardStopTriggered `
  -HardStopReason $hardStopReason `
  -LoopLabel $loopLabel `
  -SummaryPath $summaryPath `
  -HostPlaneReportPath $hostPlaneReportPath `
  -HostPlaneSummaryPath ([string]$hostPlaneSummary.path) `
  -HostPlaneSummaryStatus ([string]$hostPlaneSummary.status) `
  -HostPlaneSummarySha256 ([string]$hostPlaneSummary.sha256) `
  -HostPlaneSummaryReason ([string]$hostPlaneSummary.reason) `
  -RuntimeManagerTelemetry $summary.runtimeManager

Write-GitHubOutputValue -Key 'docker-fast-loop-summary-path' -Value $summaryPath -Path $GitHubOutputPath
Write-GitHubOutputValue -Key 'docker-fast-loop-status-path' -Value $statusResolved -Path $GitHubOutputPath
Write-GitHubOutputValue -Key 'docker-fast-loop-host-plane-summary-path' -Value ([string]$hostPlaneSummary.path) -Path $GitHubOutputPath
Write-GitHubOutputValue -Key 'docker-fast-loop-host-plane-summary-status' -Value ([string]$hostPlaneSummary.status) -Path $GitHubOutputPath
Write-GitHubOutputValue -Key 'docker-fast-loop-host-plane-summary-sha256' -Value ([string]$hostPlaneSummary.sha256) -Path $GitHubOutputPath
Write-GitHubOutputValue -Key 'docker-fast-loop-host-plane-summary-reason' -Value ([string]$hostPlaneSummary.reason) -Path $GitHubOutputPath

if ($hostPlaneSummary.declared -and [string]$hostPlaneSummary.status -ne 'ok') {
  throw ("Declared host-plane summary artifact not readable: {0}" -f [string]$hostPlaneSummary.path)
}

pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Write-DockerFastLoopReadiness.ps1') `
  -ResultsRoot $root `
  -SummaryPath $summaryPath `
  -StatusPath $statusResolved `
  -OutputJsonPath $readinessJsonResolved `
  -OutputMarkdownPath $readinessMarkdownResolved `
  -PrintDifferentiatedDiagnostics:$false `
  -GitHubOutputPath '' `
  -StepSummaryPath '' | Out-Null

$readinessEnvelope = $null
if (Test-Path -LiteralPath $readinessJsonResolved -PathType Leaf) {
  try {
    $readinessEnvelope = Get-Content -LiteralPath $readinessJsonResolved -Raw | ConvertFrom-Json -Depth 16
  } catch {
    $readinessEnvelope = $null
  }
}
if ($readinessEnvelope) {
  Write-DockerFastLoopDifferentiatedDiagnostics -Readiness $readinessEnvelope -ResultsRoot $root | Out-Null
}

if ($failed.Count -gt 0) {
  foreach ($step in $failed.ToArray()) {
    $nameValue = if ($step -is [System.Collections.IDictionary]) { [string]$step['name'] } elseif ($step -and $step.PSObject.Properties['name']) { [string]$step.name } else { '<unknown-step>' }
    $messageValue = if ($step -is [System.Collections.IDictionary]) { [string]$step['message'] } elseif ($step -and $step.PSObject.Properties['message']) { [string]$step.message } else { 'no details' }
    Write-Host ("{0} failed: {1}: {2}" -f $loopPrefix, $nameValue, $messageValue) -ForegroundColor Red
  }
  if ($hardStopTriggered -and -not [string]::IsNullOrWhiteSpace($hardStopReason)) {
    throw ("Docker fast loop hard-stopped: {0}" -f $hardStopReason)
  }
  throw ("Docker fast loop failed with {0} step(s)." -f $failed.Count)
}

Write-Output $summaryPath
