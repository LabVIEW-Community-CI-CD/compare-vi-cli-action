Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'VI history local acceleration surfaces' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RepoRoot = $repoRoot
    $script:BuildScript = Join-Path $repoRoot 'tools' 'Build-VIHistoryDevImage.ps1'
    $script:ManagerScript = Join-Path $repoRoot 'tools' 'Manage-VIHistoryRuntimeInDocker.ps1'
    $script:WrapperScript = Join-Path $repoRoot 'tools' 'Invoke-VIHistoryLocalRefinement.ps1'

    function New-DockerStub {
      param([Parameter(Mandatory)][string]$Root)

      $binDir = Join-Path $Root 'bin'
      New-Item -ItemType Directory -Path $binDir -Force | Out-Null
      $stubPath = Join-Path $binDir 'docker.ps1'
      $cmdPath = Join-Path $binDir 'docker.cmd'

      @'
$scriptArgs = @($args)

$logPath = [Environment]::GetEnvironmentVariable('DOCKER_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  $record = [ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    args = @($scriptArgs)
  }
  ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $logPath -Encoding utf8
}

$stateRoot = [Environment]::GetEnvironmentVariable('DOCKER_STUB_STATE_ROOT')
if ([string]::IsNullOrWhiteSpace($stateRoot)) {
  $stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'docker-stub-state'
}
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$containersDir = Join-Path $stateRoot 'containers'
New-Item -ItemType Directory -Path $containersDir -Force | Out-Null

function Get-ContainerFile {
  param([string]$Name)
  return (Join-Path $containersDir ("{0}.json" -f $Name))
}

function Resolve-HostPathFromContainerPath {
  param(
    [Parameter(Mandatory)][string]$ContainerPath,
    [Parameter(Mandatory)][System.Collections.Generic.List[object]]$VolumeMap
  )

  $normalizedContainerPath = $ContainerPath.Replace('\', '/')
  foreach ($mapping in $VolumeMap) {
    $root = ([string]$mapping.container).TrimEnd('/')
    if ([string]::Equals($normalizedContainerPath, $root, [System.StringComparison]::Ordinal)) {
      return [string]$mapping.host
    }
    $prefix = "$root/"
    if ($normalizedContainerPath.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
      $relative = $normalizedContainerPath.Substring($prefix.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
      return (Join-Path ([string]$mapping.host) $relative)
    }
  }

  $repoHost = [Environment]::GetEnvironmentVariable('COMPARE_REUSE_REPO_HOST_PATH')
  $repoContainer = [Environment]::GetEnvironmentVariable('COMPARE_REUSE_REPO_CONTAINER_PATH')
  if (-not [string]::IsNullOrWhiteSpace($repoHost) -and -not [string]::IsNullOrWhiteSpace($repoContainer)) {
    $repoRoot = $repoContainer.TrimEnd('/').Replace('\', '/')
    if ($normalizedContainerPath.StartsWith("$repoRoot/", [System.StringComparison]::Ordinal)) {
      $relative = $normalizedContainerPath.Substring($repoRoot.Length + 1).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
      return (Join-Path $repoHost $relative)
    }
  }

  $resultsHost = [Environment]::GetEnvironmentVariable('COMPARE_REUSE_RESULTS_HOST_PATH')
  $resultsContainer = [Environment]::GetEnvironmentVariable('COMPARE_REUSE_RESULTS_CONTAINER_PATH')
  if (-not [string]::IsNullOrWhiteSpace($resultsHost) -and -not [string]::IsNullOrWhiteSpace($resultsContainer)) {
    $resultsRoot = $resultsContainer.TrimEnd('/').Replace('\', '/')
    if ([string]::Equals($normalizedContainerPath, $resultsRoot, [System.StringComparison]::Ordinal)) {
      return $resultsHost
    }
    if ($normalizedContainerPath.StartsWith("$resultsRoot/", [System.StringComparison]::Ordinal)) {
      $relative = $normalizedContainerPath.Substring($resultsRoot.Length + 1).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
      return (Join-Path $resultsHost $relative)
    }
  }

  return $null
}

function Save-ContainerState {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][object]$State
  )

  $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Get-ContainerFile -Name $Name) -Encoding utf8
}

function Load-ContainerState {
  param([Parameter(Mandatory)][string]$Name)
  $path = Get-ContainerFile -Name $Name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return $null
  }
  return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 20)
}

if ($scriptArgs.Count -eq 0) { exit 0 }

if ($scriptArgs[0] -eq 'image' -and $scriptArgs.Count -ge 3 -and $scriptArgs[1] -eq 'inspect') {
  if ([string]::Equals([Environment]::GetEnvironmentVariable('DOCKER_STUB_IMAGE_EXISTS'), '1', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Output '[]'
    exit 0
  }
  exit 1
}

if ($scriptArgs[0] -eq 'build') {
  exit 0
}

if ($scriptArgs[0] -eq 'inspect' -and $scriptArgs.Count -ge 2) {
  $name = $scriptArgs[1]
  $state = Load-ContainerState -Name $name
  if ($null -eq $state) {
    exit 1
  }
  Write-Output ($state | ConvertTo-Json -Depth 20)
  exit 0
}

if ($scriptArgs[0] -eq 'run') {
  $volumeMap = [System.Collections.Generic.List[object]]::new()
  $containerName = ''
  $image = ''
  $envPairs = @{}
  for ($i = 0; $i -lt $scriptArgs.Count; $i++) {
    switch ($scriptArgs[$i]) {
      '--name' {
        $containerName = [string]$scriptArgs[$i + 1]
        $i++
        continue
      }
      '-v' {
        $spec = [string]$scriptArgs[$i + 1]
        if ($spec -match '^(?<host>.+):(?<container>/.*)$') {
          $volumeMap.Add([pscustomobject]@{
            host = [string]$Matches['host']
            container = [string]$Matches['container']
          }) | Out-Null
        }
        $i++
        continue
      }
      '-e' {
        $pair = [string]$scriptArgs[$i + 1]
        if ($pair -match '^(?<k>[^=]+)=(?<v>.*)$') {
          $envPairs[$Matches['k']] = $Matches['v']
        }
        $i++
        continue
      }
    }
  }
  $bashIndex = [Array]::IndexOf($scriptArgs, 'bash')
  if ($bashIndex -gt 0) {
    $image = [string]$scriptArgs[$bashIndex - 1]
  } else {
    $image = [string]$scriptArgs[$scriptArgs.Count - 3]
  }
  $heartbeatContainerPath = [string]$envPairs['COMPAREVI_HEARTBEAT_PATH']
  if (-not [string]::IsNullOrWhiteSpace($heartbeatContainerPath)) {
    $heartbeatHostPath = Resolve-HostPathFromContainerPath -ContainerPath $heartbeatContainerPath -VolumeMap $volumeMap
    if (-not [string]::IsNullOrWhiteSpace($heartbeatHostPath)) {
      $heartbeatDir = Split-Path -Parent $heartbeatHostPath
      if (-not (Test-Path -LiteralPath $heartbeatDir -PathType Container)) {
        New-Item -ItemType Directory -Path $heartbeatDir -Force | Out-Null
      }
      [ordered]@{
        schema = 'comparevi/local-runtime-heartbeat@v1'
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        status = 'running'
      } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $heartbeatHostPath -Encoding utf8
    }
  }
  $state = @(
    [ordered]@{
      Id = 'stub-container'
      Config = [ordered]@{ Image = $image }
      State = [ordered]@{
        Running = $true
        Status = 'running'
        StartedAt = (Get-Date).ToUniversalTime().ToString('o')
        FinishedAt = ''
      }
    }
  )
  Save-ContainerState -Name $containerName -State $state
  Write-Output 'stub-container'
  exit 0
}

if ($scriptArgs[0] -eq 'logs') {
  Write-Output 'warm runtime log'
  exit 0
}

if ($scriptArgs[0] -eq 'rm' -or $scriptArgs[0] -eq 'stop') {
  $name = [string]$scriptArgs[-1]
  $path = Get-ContainerFile -Name $name
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    Remove-Item -LiteralPath $path -Force
  }
  exit 0
}

exit 0
'@ | Set-Content -LiteralPath $stubPath -Encoding utf8

      "@echo off`r`nsetlocal`r`npwsh -NoLogo -NoProfile -File `"%~dp0docker.ps1`" %*`r`n" | Set-Content -LiteralPath $cmdPath -Encoding ascii

      return [pscustomobject]@{
        CommandPath = $cmdPath
        ScriptPath = $stubPath
      }
    }

    function New-ReviewSuiteStub {
      param([Parameter(Mandatory)][string]$Path)

      @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$RepoRoot,
  [string]$ResultsRoot,
  [string]$Image,
  [string]$LabVIEWPath,
  [string]$HistoryTargetPath,
  [string]$HistoryBranchRef,
  [string]$HistoryBaselineRef,
  [int]$HistoryMaxPairs,
  [int]$HistoryMaxCommitCount,
  [int]$FlagScenarioParallelism = 0,
  [string]$ReuseContainerName = '',
  [string]$ReuseRepoHostPath = '',
  [string]$ReuseRepoContainerPath = '',
  [string]$ReuseResultsHostPath = '',
  [string]$ReuseResultsContainerPath = '',
  [string[]]$RuntimeInjectionMount = @()
)
$logPath = [Environment]::GetEnvironmentVariable('LOCAL_REVIEW_SUITE_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  [ordered]@{
    baseVi = $BaseVi
    headVi = $HeadVi
    repoRoot = $RepoRoot
    historyTargetPath = $HistoryTargetPath
    historyBranchRef = $HistoryBranchRef
    historyBaselineRef = $HistoryBaselineRef
    flagScenarioParallelism = $FlagScenarioParallelism
    image = $Image
    reuseContainerName = $ReuseContainerName
    reuseRepoHostPath = $ReuseRepoHostPath
    reuseRepoContainerPath = $ReuseRepoContainerPath
    reuseResultsHostPath = $ReuseResultsHostPath
    reuseResultsContainerPath = $ReuseResultsContainerPath
    runtimeInjectionMounts = @($RuntimeInjectionMount)
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $logPath -Encoding utf8
}
New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
[ordered]@{
  schema = 'ni-linux-review-suite@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  image = $Image
  scenarios = @(
    [ordered]@{
      kind = 'vi-history-report'
      name = 'vi-history-report'
    }
  )
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResultsRoot 'review-suite-summary.json') -Encoding utf8
[ordered]@{
  schema = 'ni-linux-review-suite-review-loop@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResultsRoot 'vi-history-review-loop-receipt.json') -Encoding utf8
exit 0
'@ | Set-Content -LiteralPath $Path -Encoding utf8
    }

    function New-BuildStub {
      param([Parameter(Mandatory)][string]$Path)

      @'
param([string]$Tag)
$logPath = [Environment]::GetEnvironmentVariable('LOCAL_BUILD_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  Set-Content -LiteralPath $logPath -Value $Tag -Encoding utf8
}
exit 0
'@ | Set-Content -LiteralPath $Path -Encoding utf8
    }

    function New-WarmManagerStub {
      param([Parameter(Mandatory)][string]$Path)

      @'
param(
  [string]$Action = 'start',
  [string]$RepoRoot,
  [string]$ResultsRoot,
  [string]$RuntimeDir,
  [string]$Image,
  [int]$HeavyExecutionParallelism = 0,
  [string]$HostRamBudgetPath = '',
  [string]$HostRamBudgetTargetProfile = 'heavy',
  [Nullable[long]]$HostRamBudgetTotalBytes = $null,
  [Nullable[long]]$HostRamBudgetFreeBytes = $null,
  [Nullable[int]]$HostRamBudgetCpuParallelism = $null
)
$logPath = [Environment]::GetEnvironmentVariable('LOCAL_WARM_MANAGER_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  [ordered]@{
    action = $Action
    repoRoot = $RepoRoot
    resultsRoot = $ResultsRoot
    runtimeDir = $RuntimeDir
    image = $Image
    heavyExecutionParallelism = $HeavyExecutionParallelism
    hostRamBudgetPath = $HostRamBudgetPath
    hostRamBudgetTargetProfile = $HostRamBudgetTargetProfile
    hostRamBudgetTotalBytes = $HostRamBudgetTotalBytes
    hostRamBudgetFreeBytes = $HostRamBudgetFreeBytes
    hostRamBudgetCpuParallelism = $HostRamBudgetCpuParallelism
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $logPath -Encoding utf8
}
$outcome = [Environment]::GetEnvironmentVariable('LOCAL_WARM_MANAGER_OUTCOME')
if ([string]::IsNullOrWhiteSpace($outcome)) {
  $outcome = 'reused'
}
$payload = [ordered]@{
  schema = 'comparevi/local-runtime-state@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  action = $Action
  outcome = $outcome
  container = [ordered]@{
    name = 'warm-stub'
    image = $Image
  }
  mounts = [ordered]@{
    repoHostPath = $RepoRoot
    repoContainerPath = '/opt/comparevi/source'
    resultsHostPath = $ResultsRoot
    resultsContainerPath = '/opt/comparevi/vi-history/results'
  }
  hostRamBudget = [ordered]@{
    path = if ([string]::IsNullOrWhiteSpace($HostRamBudgetPath)) { (Join-Path $RuntimeDir 'host-ram-budget.json') } else { $HostRamBudgetPath }
    targetProfile = $HostRamBudgetTargetProfile
    requestedParallelism = [int]$HeavyExecutionParallelism
    recommendedParallelism = if ($HeavyExecutionParallelism -gt 0) { [int]$HeavyExecutionParallelism } else { 2 }
    actualParallelism = 1
    decisionSource = if ($HeavyExecutionParallelism -gt 0) { 'explicit-override' } else { 'host-ram-budget' }
    reason = if ($HeavyExecutionParallelism -gt 0) { 'warm-runtime-single-container' } else { 'warm-runtime-single-container' }
    executionMode = 'serial'
    parallelExecutionSupported = $false
    report = [ordered]@{
      schema = 'priority/host-ram-budget@v1'
      selectedProfile = [ordered]@{
        id = $HostRamBudgetTargetProfile
        recommendedParallelism = if ($HeavyExecutionParallelism -gt 0) { [int]$HeavyExecutionParallelism } else { 2 }
        reasons = @('balanced')
      }
    }
  }
}
$payload | ConvertTo-Json -Depth 10
'@ | Set-Content -LiteralPath $Path -Encoding utf8
    }

    function New-WindowsPreflightStub {
      param([Parameter(Mandatory)][string]$Path)

      @'
param(
  [string]$Image = '',
  [string]$ResultsDir = '',
  [string]$OutputJsonPath = ''
)
$logPath = [Environment]::GetEnvironmentVariable('LOCAL_WINDOWS_PREFLIGHT_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  [ordered]@{
    image = $Image
    resultsDir = $ResultsDir
    outputJsonPath = $OutputJsonPath
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $logPath -Encoding utf8
}
if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $OutputJsonPath) -Force | Out-Null
  [ordered]@{
    schema = 'comparevi/windows-host-preflight@v1'
    image = $Image
    status = 'ready'
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputJsonPath -Encoding utf8
}
Write-Output $OutputJsonPath
exit 0
'@ | Set-Content -LiteralPath $Path -Encoding utf8
    }

    function New-WindowsCompareStub {
      param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$EmitNoise
      )

      $emitNoiseLiteral = if ($EmitNoise) { '$true' } else { '$false' }
      $stub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$Image = '',
  [string]$ReportPath = '',
  [string]$LabVIEWPath = '',
  [string]$RuntimeSnapshotPath = '',
  [switch]$PassThru
)
$emitNoise = __EMIT_NOISE__
$logPath = [Environment]::GetEnvironmentVariable('LOCAL_WINDOWS_COMPARE_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  [ordered]@{
    baseVi = $BaseVi
    headVi = $HeadVi
    image = $Image
    reportPath = $ReportPath
    labviewPath = $LabVIEWPath
    runtimeSnapshotPath = $RuntimeSnapshotPath
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $logPath -Encoding utf8
}
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $ReportPath) -Force | Out-Null
  '<html><body>windows mirror report</body></html>' | Set-Content -LiteralPath $ReportPath -Encoding utf8
  $capturePath = Join-Path (Split-Path -Parent $ReportPath) 'ni-windows-container-capture.json'
  [ordered]@{
    status = 'diff'
    classification = 'diff'
    resultClass = 'diff'
    gateOutcome = 'pass'
    failureClass = 'none'
    reportPath = $ReportPath
    capturePath = $capturePath
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $capturePath -Encoding utf8
}
if (-not [string]::IsNullOrWhiteSpace($RuntimeSnapshotPath)) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $RuntimeSnapshotPath) -Force | Out-Null
  [ordered]@{
    schema = 'comparevi/runtime-determinism@v1'
    status = 'ready'
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $RuntimeSnapshotPath -Encoding utf8
}
if ($emitNoise) {
  Write-Output 'windows-compare-noise'
}
$result = [pscustomobject]@{
  schema = 'ni-windows-container-compare/v1'
  status = 'diff'
  classification = 'diff'
  resultClass = 'diff'
  gateOutcome = 'pass'
  failureClass = 'none'
}
if ($PassThru) {
  $result
}
exit 0
'@
      $stub = $stub.Replace('__EMIT_NOISE__', $emitNoiseLiteral)
      $stub | Set-Content -LiteralPath $Path -Encoding utf8
    }
  }

  It 'Build-VIHistoryDevImage uses the dedicated Dockerfile' {
    $work = Join-Path $TestDrive 'build'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $dockerStub = New-DockerStub -Root $work
    $logPath = Join-Path $work 'docker-log.jsonl'

    $originalPath = $env:PATH
    try {
      $env:DOCKER_STUB_LOG = $logPath
      $env:DOCKER_STUB_STATE_ROOT = (Join-Path $work 'state')
      $env:PATH = ("{0}{1}{2}" -f (Split-Path -Parent $dockerStub.CommandPath), [System.IO.Path]::PathSeparator, $originalPath)

      & $script:BuildScript -Tag 'comparevi-vi-history-dev:test'
      $LASTEXITCODE | Should -Be 0
    } finally {
      $env:PATH = $originalPath
      Remove-Item Env:DOCKER_STUB_LOG -ErrorAction SilentlyContinue
      Remove-Item Env:DOCKER_STUB_STATE_ROOT -ErrorAction SilentlyContinue
    }

    $records = Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json }
    $buildRecord = @($records | Where-Object { $_.args[0] -eq 'build' } | Select-Object -Last 1)
    $buildRecord.Count | Should -Be 1
    ($buildRecord[0].args -join ' ') | Should -Match 'Dockerfile\.vi-history-dev'
    ($buildRecord[0].args -join ' ') | Should -Match 'comparevi-vi-history-dev:test'
    ($buildRecord[0].args -join ' ') | Should -Match 'BASE_IMAGE=nationalinstruments/labview:2026q1-linux'
  }

  It 'Manage-VIHistoryRuntimeInDocker writes deterministic lease, state, and health receipts' {
    $work = Join-Path $TestDrive 'runtime-manager'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $repoRoot = Join-Path $work 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests/results/local-vi-history/warm-dev'
    $runtimeDir = Join-Path $repoRoot 'tests/results/local-vi-history/runtime/warm-dev'
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    $dockerStub = New-DockerStub -Root $work

    try {
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $startJson = & $script:ManagerScript `
        -Action start `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -RuntimeDir $runtimeDir `
        -Image 'comparevi-vi-history-dev:local' `
        -HeavyExecutionParallelism 3 `
        -HostRamBudgetTotalBytes 34359738368 `
        -HostRamBudgetFreeBytes 25769803776 `
        -HostRamBudgetCpuParallelism 8 `
        -DockerCommand $dockerStub.CommandPath
      $LASTEXITCODE | Should -Be 0
      $startState = ($startJson -join "`n") | ConvertFrom-Json -Depth 20
      $startState.schema | Should -Be 'comparevi/local-runtime-state@v1'
      $startState.outcome | Should -Be 'started'
      $startState.lease.schema | Should -Be 'comparevi/local-runtime-lease@v1'
      $startState.hostRamBudget.targetProfile | Should -Be 'heavy'
      $startState.hostRamBudget.decisionSource | Should -Be 'explicit-override'
      $startState.hostRamBudget.requestedParallelism | Should -Be 3
      $startState.hostRamBudget.recommendedParallelism | Should -Be 3
      $startState.hostRamBudget.actualParallelism | Should -Be 1
      $startState.hostRamBudget.reason | Should -Be 'warm-runtime-single-container'

      $healthJson = & $script:ManagerScript `
        -Action status `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -RuntimeDir $runtimeDir `
        -Image 'comparevi-vi-history-dev:local' `
        -HeavyExecutionParallelism 3 `
        -HostRamBudgetTotalBytes 34359738368 `
        -HostRamBudgetFreeBytes 25769803776 `
        -HostRamBudgetCpuParallelism 8 `
        -DockerCommand $dockerStub.CommandPath
      $LASTEXITCODE | Should -Be 0
      $health = ($healthJson -join "`n") | ConvertFrom-Json -Depth 20
      $health.schema | Should -Be 'comparevi/local-runtime-health@v1'
      $health.status | Should -Be 'healthy'
      $health.hostRamBudget.decisionSource | Should -Be 'explicit-override'
      $health.hostRamBudget.reason | Should -Be 'warm-runtime-single-container'
    } finally {
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
    }

    $statePath = Join-Path $runtimeDir 'local-runtime-state.json'
    $leasePath = Join-Path $runtimeDir 'local-runtime-lease.json'
    $healthPath = Join-Path $runtimeDir 'local-runtime-health.json'
    $hostRamBudgetPath = Join-Path $runtimeDir 'host-ram-budget.json'
    (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -BeTrue
    (Test-Path -LiteralPath $leasePath -PathType Leaf) | Should -BeTrue
    (Test-Path -LiteralPath $healthPath -PathType Leaf) | Should -BeTrue
    (Test-Path -LiteralPath $hostRamBudgetPath -PathType Leaf) | Should -BeTrue
  }

  It 'Manage-VIHistoryRuntimeInDocker records deterministic-floor RAM budgets under pressure' {
    $work = Join-Path $TestDrive 'runtime-manager-floor'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $repoRoot = Join-Path $work 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests/results/local-vi-history/warm-dev'
    $runtimeDir = Join-Path $repoRoot 'tests/results/local-vi-history/runtime/warm-dev'
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    $dockerStub = New-DockerStub -Root $work

    try {
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $startJson = & $script:ManagerScript `
        -Action start `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -RuntimeDir $runtimeDir `
        -Image 'comparevi-vi-history-dev:local' `
        -HostRamBudgetTotalBytes 8589934592 `
        -HostRamBudgetFreeBytes 2147483648 `
        -HostRamBudgetCpuParallelism 8 `
        -DockerCommand $dockerStub.CommandPath
      $LASTEXITCODE | Should -Be 0
    } finally {
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
    }

    $startState = ($startJson -join "`n") | ConvertFrom-Json -Depth 20
    $startState.hostRamBudget.decisionSource | Should -Be 'host-ram-budget'
    $startState.hostRamBudget.recommendedParallelism | Should -Be 1
    $startState.hostRamBudget.actualParallelism | Should -Be 1
    $startState.hostRamBudget.reason | Should -Match 'deterministic-floor'
  }

  It 'Manage-VIHistoryRuntimeInDocker reconciles stale heartbeat runtimes by replacing the container' {
    $work = Join-Path $TestDrive 'runtime-manager-stale'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $repoRoot = Join-Path $work 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests/results/local-vi-history/warm-dev'
    $runtimeDir = Join-Path $repoRoot 'tests/results/local-vi-history/runtime/warm-dev'
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.git') -Force | Out-Null
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    $dockerStub = New-DockerStub -Root $work
    $dockerLog = Join-Path $work 'docker-log.jsonl'

    try {
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $env:DOCKER_STUB_LOG = $dockerLog
      & $script:ManagerScript `
        -Action start `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -RuntimeDir $runtimeDir `
        -Image 'comparevi-vi-history-dev:local' `
        -DockerCommand $dockerStub.CommandPath | Out-Null
      $LASTEXITCODE | Should -Be 0

      $heartbeatPath = Join-Path $runtimeDir 'local-runtime-heartbeat.json'
      $staleHeartbeat = [ordered]@{
        schema = 'comparevi/local-runtime-heartbeat@v1'
        generatedAt = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
        status = 'running'
      }
      $staleHeartbeat | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $heartbeatPath -Encoding utf8

      $reconcileJson = & $script:ManagerScript `
        -Action reconcile `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -RuntimeDir $runtimeDir `
        -Image 'comparevi-vi-history-dev:local' `
        -DockerCommand $dockerStub.CommandPath
      $LASTEXITCODE | Should -Be 0
    } finally {
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
      Remove-Item Env:DOCKER_STUB_LOG -ErrorAction SilentlyContinue
    }

    $reconcileState = ($reconcileJson -join "`n") | ConvertFrom-Json -Depth 20
    $reconcileState.outcome | Should -Be 'recovered-stale-runtime'
    $reconcileState.recovery.attempted | Should -BeTrue
    $reconcileState.recovery.previousHealth.reason | Should -Be 'heartbeat-stale'
    $reconcileState.health.status | Should -Be 'healthy'

    $records = Get-Content -LiteralPath $dockerLog | ForEach-Object { $_ | ConvertFrom-Json }
    @($records | Where-Object { $_.args[0] -eq 'run' }).Count | Should -Be 2
    @($records | Where-Object { $_.args[0] -eq 'rm' -and $_.args[1] -eq '-f' }).Count | Should -BeGreaterThan 0
  }

  It 'Invoke-VIHistoryLocalRefinement writes a dev-fast receipt and benchmark' {
    $work = Join-Path $TestDrive 'local-refinement-dev-fast'
    $repoRoot = Join-Path $work 'repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8
    $dockerStub = New-DockerStub -Root $work
    $buildStub = Join-Path $work 'build-stub.ps1'
    $reviewStub = Join-Path $work 'review-stub.ps1'
    New-BuildStub -Path $buildStub
    New-ReviewSuiteStub -Path $reviewStub
    $buildLog = Join-Path $work 'build.log'

    $originalPath = $env:PATH
    try {
      $env:DOCKER_STUB_IMAGE_EXISTS = '0'
      $env:LOCAL_BUILD_STUB_LOG = $buildLog
      $env:PATH = ("{0}{1}{2}" -f (Split-Path -Parent $dockerStub.CommandPath), [System.IO.Path]::PathSeparator, $originalPath)

      & $script:WrapperScript `
        -Profile 'dev-fast' `
        -RepoRoot $repoRoot `
        -BuildImageScriptPath $buildStub `
        -ReviewSuiteScriptPath $reviewStub `
        -HostRamBudgetTotalBytes 34359738368 `
        -HostRamBudgetFreeBytes 25769803776 `
        -HostRamBudgetCpuParallelism 8
      $LASTEXITCODE | Should -Be 0
    } finally {
      $env:PATH = $originalPath
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
      Remove-Item Env:LOCAL_BUILD_STUB_LOG -ErrorAction SilentlyContinue
    }

    (Get-Content -LiteralPath $buildLog -Raw).Trim() | Should -Be 'comparevi-vi-history-dev:local'
    $receiptPath = Join-Path $repoRoot 'tests/results/local-vi-history/dev-fast/local-refinement.json'
    $benchmarkPath = Join-Path $repoRoot 'tests/results/local-vi-history/dev-fast/local-refinement-benchmark.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 20
    $receipt.schema | Should -Be 'comparevi/local-refinement@v1'
    $receipt.runtimeProfile | Should -Be 'dev-fast'
    $receipt.cacheReuseState | Should -Be 'built-local-image'
    $receipt.benchmarkSampleKind | Should -Be 'dev-fast-cold'
    $receipt.hostRamBudget.decisionSource | Should -Be 'host-ram-budget'
    $receipt.hostRamBudget.targetProfile | Should -Be 'heavy'
    $receipt.hostRamBudget.recommendedParallelism | Should -Be 3
    $receipt.hostRamBudget.actualParallelism | Should -Be 1
    $receipt.hostRamBudget.reason | Should -Be 'single-review-execution'
    $receipt.finalStatus | Should -Be 'succeeded'
    $benchmark = Get-Content -LiteralPath $benchmarkPath -Raw | ConvertFrom-Json -Depth 20
    $benchmark.schema | Should -Be 'comparevi/local-refinement-benchmark@v1'
    Test-Path -LiteralPath (Join-Path $repoRoot 'tests/results/local-vi-history/dev-fast/host-ram-budget.json') | Should -BeTrue
  }

  It 'Invoke-VIHistoryLocalRefinement preserves deterministic-floor RAM budgets for proof' {
    $work = Join-Path $TestDrive 'local-refinement-proof-floor'
    $repoRoot = Join-Path $work 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests/results/local-vi-history/proof'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8
    $reviewStub = Join-Path $work 'review-stub.ps1'
    New-ReviewSuiteStub -Path $reviewStub

    & $script:WrapperScript `
      -Profile 'proof' `
      -RepoRoot $repoRoot `
      -ResultsRoot $resultsRoot `
      -ReviewSuiteScriptPath $reviewStub `
      -HostRamBudgetTotalBytes 8589934592 `
      -HostRamBudgetFreeBytes 2147483648 `
      -HostRamBudgetCpuParallelism 8
    $LASTEXITCODE | Should -Be 0

    $receipt = Get-Content -LiteralPath (Join-Path $resultsRoot 'local-refinement.json') -Raw | ConvertFrom-Json -Depth 20
    $receipt.hostRamBudget.decisionSource | Should -Be 'host-ram-budget'
    $receipt.hostRamBudget.recommendedParallelism | Should -Be 1
    $receipt.hostRamBudget.actualParallelism | Should -Be 1
    $receipt.hostRamBudget.reason | Should -Match 'deterministic-floor'
  }

  It 'Invoke-VIHistoryLocalRefinement writes a windows-mirror-proof receipt and host artifacts' {
    $work = Join-Path $TestDrive 'windows-mirror-proof'
    $repoRoot = Join-Path $work 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests/results/local-vi-history/windows-mirror-proof'
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8

    $preflightStub = Join-Path $work 'Test-WindowsNI2026q1HostPreflight.stub.ps1'
    $compareStub = Join-Path $work 'Run-NIWindowsContainerCompare.stub.ps1'
    New-WindowsPreflightStub -Path $preflightStub
    New-WindowsCompareStub -Path $compareStub

    $preflightLog = Join-Path $work 'windows-preflight.json'
    $compareLog = Join-Path $work 'windows-compare.json'

    try {
      $env:LOCAL_WINDOWS_PREFLIGHT_STUB_LOG = $preflightLog
      $env:LOCAL_WINDOWS_COMPARE_STUB_LOG = $compareLog

      $receipt = & $script:WrapperScript `
        -Profile 'windows-mirror-proof' `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -WindowsMirrorLabVIEWPath 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe' `
        -WindowsHostPreflightScriptPath $preflightStub `
        -WindowsCompareScriptPath $compareStub `
        -PassThru

      $receipt.schema | Should -Be 'comparevi/local-refinement@v1'
      $receipt.runtimeProfile | Should -Be 'windows-mirror-proof'
    $receipt.runtimePlane | Should -Be 'windows-mirror'
    $receipt.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
      $receipt.toolSource | Should -Be 'windows-mirror-proof-image'
      $receipt.cacheReuseState | Should -Be 'canonical-windows-proof-image'
      $receipt.coldWarmClass | Should -Be 'cold'
      $receipt.benchmarkSampleKind | Should -Be 'windows-mirror-proof-cold'
      $receipt.reviewSuite | Should -Be $null
      $receipt.reviewLoop | Should -Be $null
      $receipt.windowsMirror.hostPreflight.path | Should -Be (Join-Path $resultsRoot 'windows-ni-2026q1-host-preflight.json')
      $receipt.windowsMirror.compare.reportPath | Should -Be (Join-Path $resultsRoot 'windows-mirror-report.html')
      $receipt.windowsMirror.compare.capturePath | Should -Be (Join-Path $resultsRoot 'ni-windows-container-capture.json')
    $receipt.windowsMirror.compare.runtimeSnapshotPath | Should -Be (Join-Path $resultsRoot 'windows-mirror-runtime-snapshot.json')
    $receipt.hostRamBudget.targetProfile | Should -Be 'windows-mirror-heavy'
    $receipt.hostRamBudget.actualParallelism | Should -Be 1
    $receipt.windowsMirror.headlessContract.required | Should -BeTrue
      $receipt.windowsMirror.headlessContract.labviewCliMode | Should -Be 'headless'
      $receipt.finalStatus | Should -Be 'succeeded'

      Test-Path -LiteralPath (Join-Path $resultsRoot 'windows-ni-2026q1-host-preflight.json') | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $resultsRoot 'windows-mirror-report.html') | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $resultsRoot 'ni-windows-container-capture.json') | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $resultsRoot 'windows-mirror-runtime-snapshot.json') | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $resultsRoot 'local-refinement-benchmark.json') | Should -BeTrue

      $preflightCapture = Get-Content -LiteralPath $preflightLog -Raw | ConvertFrom-Json -Depth 10
      $preflightCapture.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
      $preflightCapture.outputJsonPath | Should -Be (Join-Path $resultsRoot 'windows-ni-2026q1-host-preflight.json')

      $compareCapture = Get-Content -LiteralPath $compareLog -Raw | ConvertFrom-Json -Depth 10
      $compareCapture.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
      $compareCapture.labviewPath | Should -Be 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
      $compareCapture.runtimeSnapshotPath | Should -Be (Join-Path $resultsRoot 'windows-mirror-runtime-snapshot.json')
    } finally {
      Remove-Item Env:LOCAL_WINDOWS_PREFLIGHT_STUB_LOG -ErrorAction SilentlyContinue
      Remove-Item Env:LOCAL_WINDOWS_COMPARE_STUB_LOG -ErrorAction SilentlyContinue
    }
  }

  It 'rejects non-canonical images for windows-mirror-proof' {
    $work = Join-Path $TestDrive 'local-refinement-windows-mirror-image-guard'
    $repoRoot = Join-Path $work 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests/results/local-vi-history/windows-mirror-proof'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8

    $preflightStub = Join-Path $work 'Test-WindowsNI2026q1HostPreflight.stub.ps1'
    $compareStub = Join-Path $work 'Run-NIWindowsContainerCompare.stub.ps1'
    New-WindowsPreflightStub -Path $preflightStub
    New-WindowsCompareStub -Path $compareStub

    {
      & $script:WrapperScript `
        -Profile 'windows-mirror-proof' `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -WindowsMirrorImage 'nationalinstruments/labview:2026q1-windows-beta' `
        -WindowsHostPreflightScriptPath $preflightStub `
        -WindowsCompareScriptPath $compareStub `
        -PassThru
    } | Should -Throw "*windows-mirror-proof is pinned to canonical image 'nationalinstruments/labview:2026q1-windows'*"
  }

  It 'projects windows mirror compare fields even when the compare helper emits pipeline noise' {
    $work = Join-Path $TestDrive 'windows-mirror-proof-pass-thru-noise'
    $repoRoot = Join-Path $work 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests/results/local-vi-history/windows-mirror-proof'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8

    $preflightStub = Join-Path $work 'Test-WindowsNI2026q1HostPreflight.stub.ps1'
    $compareStub = Join-Path $work 'Run-NIWindowsContainerCompare.noisy.stub.ps1'
    New-WindowsPreflightStub -Path $preflightStub
    New-WindowsCompareStub -Path $compareStub -EmitNoise

    $receipt = & $script:WrapperScript `
      -Profile 'windows-mirror-proof' `
      -RepoRoot $repoRoot `
      -ResultsRoot $resultsRoot `
      -WindowsHostPreflightScriptPath $preflightStub `
      -WindowsCompareScriptPath $compareStub `
      -PassThru

    $receipt.windowsMirror.compare.status | Should -Be 'diff'
    $receipt.windowsMirror.compare.classification | Should -Be 'diff'
    $receipt.windowsMirror.compare.resultClass | Should -Be 'diff'
    $receipt.windowsMirror.compare.gateOutcome | Should -Be 'pass'
    $receipt.windowsMirror.compare.failureClass | Should -Be 'none'
  }

  It 'Invoke-VIHistoryLocalRefinement PassThru returns only the canonical receipt when the review suite writes pipeline output' {
    $work = Join-Path $TestDrive 'local-refinement-pass-thru-noise'
    $repoRoot = Join-Path $work 'repo'
    $resultsRoot = Join-Path $repoRoot 'tests/results/local-vi-history/dev-fast'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8
    $dockerStub = New-DockerStub -Root $work
    $buildStub = Join-Path $work 'build-stub.ps1'
    $reviewStub = Join-Path $work 'review-noise-stub.ps1'
    New-BuildStub -Path $buildStub

    @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$RepoRoot,
  [string]$ResultsRoot,
  [string]$Image,
  [string]$LabVIEWPath,
  [string]$HistoryTargetPath,
  [string]$HistoryBranchRef,
  [string]$HistoryBaselineRef,
  [int]$HistoryMaxPairs,
  [int]$HistoryMaxCommitCount,
  [string]$ReuseContainerName = '',
  [string]$ReuseRepoHostPath = '',
  [string]$ReuseRepoContainerPath = '',
  [string]$ReuseResultsHostPath = '',
  [string]$ReuseResultsContainerPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
'runtime-noise'
[ordered]@{
  kind = 'intermediate'
  image = $Image
}
[ordered]@{
  schema = 'ni-linux-review-suite@v1'
  image = $Image
  scenarios = @()
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResultsRoot 'review-suite-summary.json') -Encoding utf8
[ordered]@{
  schema = 'ni-linux-review-suite-review-loop@v1'
  finalStatus = 'succeeded'
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResultsRoot 'vi-history-review-loop-receipt.json') -Encoding utf8
'@ | Set-Content -LiteralPath $reviewStub -Encoding utf8

    $originalPath = $env:PATH
    try {
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $env:PATH = ("{0}{1}{2}" -f (Split-Path -Parent $dockerStub.CommandPath), [System.IO.Path]::PathSeparator, $originalPath)

      $result = & $script:WrapperScript `
        -Profile 'dev-fast' `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -BuildImageScriptPath $buildStub `
        -ReviewSuiteScriptPath $reviewStub `
        -PassThru
      $LASTEXITCODE | Should -Be 0
    } finally {
      $env:PATH = $originalPath
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
    }

    $result.GetType().FullName | Should -Be 'System.Management.Automation.PSCustomObject'
    $result.schema | Should -Be 'comparevi/local-refinement@v1'
    $result.runtimeProfile | Should -Be 'dev-fast'
    $result.resultsRoot | Should -Be $resultsRoot
  }

  It 'Invoke-VIHistoryLocalRefinement resolves helper scripts and default fixtures from ToolingRoot for cross-repo consumers' {
    $work = Join-Path $TestDrive 'local-refinement-cross-repo-tooling'
    $consumerRepoRoot = Join-Path $work 'consumer-repo'
    $toolingRoot = Join-Path $work 'tooling-root'
    $resultsRoot = Join-Path $consumerRepoRoot 'tests/results/local-vi-history/proof'
    New-Item -ItemType Directory -Path (Join-Path $consumerRepoRoot 'Tooling/deployment') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $toolingRoot 'fixtures/vi-attr') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $toolingRoot 'tools') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $consumerRepoRoot 'Tooling/deployment/Test.vi') -Value 'consumer-target' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $toolingRoot 'fixtures/vi-attr/Base.vi') -Value 'tooling-base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $toolingRoot 'fixtures/vi-attr/Head.vi') -Value 'tooling-head' -Encoding utf8

    $reviewLog = Join-Path $work 'review.log'
    $reviewStub = Join-Path $toolingRoot 'tools' 'Invoke-NILinuxReviewSuite.ps1'
    New-ReviewSuiteStub -Path $reviewStub

    try {
      $env:LOCAL_REVIEW_SUITE_STUB_LOG = $reviewLog
      & $script:WrapperScript `
        -Profile 'proof' `
        -RepoRoot $consumerRepoRoot `
        -ToolingRoot $toolingRoot `
        -ResultsRoot $resultsRoot `
        -HistoryTargetPath 'Tooling/deployment/Test.vi'
      $LASTEXITCODE | Should -Be 0
    } finally {
      Remove-Item Env:LOCAL_REVIEW_SUITE_STUB_LOG -ErrorAction SilentlyContinue
    }

    $receiptPath = Join-Path $resultsRoot 'local-refinement.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 20
    $receipt.schema | Should -Be 'comparevi/local-refinement@v1'
    $receipt.runtimeProfile | Should -Be 'proof'
    $receipt.repoRoot | Should -Be $consumerRepoRoot
    $receipt.resultsRoot | Should -Be $resultsRoot

    $reviewLogObject = Get-Content -LiteralPath $reviewLog -Raw | ConvertFrom-Json -Depth 10
    $reviewLogObject.repoRoot | Should -Be $consumerRepoRoot
    $reviewLogObject.baseVi | Should -Be (Join-Path $toolingRoot 'fixtures/vi-attr/Base.vi')
    $reviewLogObject.headVi | Should -Be (Join-Path $toolingRoot 'fixtures/vi-attr/Head.vi')
    $reviewLogObject.historyTargetPath | Should -Be (Join-Path $consumerRepoRoot 'Tooling/deployment/Test.vi')
  }

  It 'Invoke-VIHistoryLocalRefinement supports warm-dev cross-repo consumers with a separate tooling root' {
    $work = Join-Path $TestDrive 'local-refinement-cross-repo-tooling-warm'
    $consumerRepoRoot = Join-Path $work 'consumer-repo'
    $toolingRoot = Join-Path $work 'tooling-root'
    $resultsRoot = Join-Path $consumerRepoRoot 'tests/results/local-vi-history/warm-dev'
    New-Item -ItemType Directory -Path (Join-Path $consumerRepoRoot 'Tooling/deployment') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $toolingRoot 'fixtures/vi-attr') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $toolingRoot 'tools') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $consumerRepoRoot 'Tooling/deployment/Test.vi') -Value 'consumer-target' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $toolingRoot 'fixtures/vi-attr/Base.vi') -Value 'tooling-base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $toolingRoot 'fixtures/vi-attr/Head.vi') -Value 'tooling-head' -Encoding utf8

    $dockerStub = New-DockerStub -Root $work
    $buildStub = Join-Path $work 'build-stub.ps1'
    $warmManagerStub = Join-Path $work 'warm-manager-stub.ps1'
    $reviewLog = Join-Path $work 'review.log'
    $reviewStub = Join-Path $toolingRoot 'tools' 'Invoke-NILinuxReviewSuite.ps1'
    New-BuildStub -Path $buildStub
    New-ReviewSuiteStub -Path $reviewStub
    New-WarmManagerStub -Path $warmManagerStub

    $originalPath = $env:PATH
    try {
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $env:LOCAL_REVIEW_SUITE_STUB_LOG = $reviewLog
      $env:PATH = ("{0}{1}{2}" -f (Split-Path -Parent $dockerStub.CommandPath), [System.IO.Path]::PathSeparator, $originalPath)

      & $script:WrapperScript `
        -Profile 'warm-dev' `
        -RepoRoot $consumerRepoRoot `
        -ToolingRoot $toolingRoot `
        -ResultsRoot $resultsRoot `
        -BuildImageScriptPath $buildStub `
        -ReviewSuiteScriptPath $reviewStub `
        -WarmRuntimeManagerScriptPath $warmManagerStub `
        -HistoryTargetPath 'Tooling/deployment/Test.vi'
      $LASTEXITCODE | Should -Be 0
    } finally {
      $env:PATH = $originalPath
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
      Remove-Item Env:LOCAL_REVIEW_SUITE_STUB_LOG -ErrorAction SilentlyContinue
    }

    $reviewLogObject = Get-Content -LiteralPath $reviewLog -Raw | ConvertFrom-Json -Depth 10
    $reviewLogObject.reuseContainerName | Should -Be 'warm-stub'
    $reviewLogObject.historyTargetPath | Should -Be (Join-Path $consumerRepoRoot 'Tooling/deployment/Test.vi')
    $reviewLogObject.baseVi | Should -Be (Join-Path $toolingRoot 'fixtures/vi-attr/Base.vi')
    $reviewLogObject.headVi | Should -Be (Join-Path $toolingRoot 'fixtures/vi-attr/Head.vi')
  }

  It 'Invoke-VIHistoryLocalRefinement records warm runtime reuse' {
    $work = Join-Path $TestDrive 'local-refinement-warm'
    $repoRoot = Join-Path $work 'repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8
    $dockerStub = New-DockerStub -Root $work
    $buildStub = Join-Path $work 'build-stub.ps1'
    $reviewStub = Join-Path $work 'review-stub.ps1'
    $warmManagerStub = Join-Path $work 'warm-manager-stub.ps1'
    $warmManagerLog = Join-Path $work 'warm-manager.log'
    New-BuildStub -Path $buildStub
    New-ReviewSuiteStub -Path $reviewStub
    New-WarmManagerStub -Path $warmManagerStub
    $reviewLog = Join-Path $work 'review.log'

    $originalPath = $env:PATH
    try {
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $env:LOCAL_REVIEW_SUITE_STUB_LOG = $reviewLog
      $env:LOCAL_WARM_MANAGER_STUB_LOG = $warmManagerLog
      $env:PATH = ("{0}{1}{2}" -f (Split-Path -Parent $dockerStub.CommandPath), [System.IO.Path]::PathSeparator, $originalPath)

      & $script:WrapperScript `
        -Profile 'warm-dev' `
        -RepoRoot $repoRoot `
        -BuildImageScriptPath $buildStub `
        -ReviewSuiteScriptPath $reviewStub `
        -WarmRuntimeManagerScriptPath $warmManagerStub
      $LASTEXITCODE | Should -Be 0
    } finally {
      $env:PATH = $originalPath
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
      Remove-Item Env:LOCAL_REVIEW_SUITE_STUB_LOG -ErrorAction SilentlyContinue
      Remove-Item Env:LOCAL_WARM_MANAGER_STUB_LOG -ErrorAction SilentlyContinue
    }

    $receiptPath = Join-Path $repoRoot 'tests/results/local-vi-history/warm-dev/local-refinement.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 20
    $receipt.schema | Should -Be 'comparevi/local-refinement@v1'
    $receipt.runtimeProfile | Should -Be 'warm-dev'
    $receipt.cacheReuseState | Should -Be 'warm-runtime-reused'
    $receipt.coldWarmClass | Should -Be 'warm'
    $receipt.benchmarkSampleKind | Should -Be 'warm-dev-repeat'
    $receipt.hostRamBudget.targetProfile | Should -Be 'heavy'
    $receipt.hostRamBudget.reason | Should -Be 'warm-runtime-single-container'

    $reviewLogObject = Get-Content -LiteralPath $reviewLog -Raw | ConvertFrom-Json -Depth 10
    $reviewLogObject.reuseContainerName | Should -Be 'warm-stub'
    $reviewLogObject.reuseRepoContainerPath | Should -Be '/opt/comparevi/source'
    $reviewLogObject.flagScenarioParallelism | Should -Be 1

    $warmManagerLogObject = Get-Content -LiteralPath $warmManagerLog -Raw | ConvertFrom-Json -Depth 10
    $warmManagerLogObject.action | Should -Be 'reconcile'
    $warmManagerLogObject.hostRamBudgetTargetProfile | Should -Be 'heavy'
  }

  It 'Invoke-VIHistoryLocalRefinement benchmarks proof cold, dev-fast cold, and warm-dev repeat samples' {
    $work = Join-Path $TestDrive 'local-refinement-benchmark-samples'
    $repoRoot = Join-Path $work 'repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8
    $dockerStub = New-DockerStub -Root $work
    $buildStub = Join-Path $work 'build-stub.ps1'
    $reviewStub = Join-Path $work 'review-stub.ps1'
    $warmManagerStub = Join-Path $work 'warm-manager-stub.ps1'
    New-BuildStub -Path $buildStub
    New-ReviewSuiteStub -Path $reviewStub
    New-WarmManagerStub -Path $warmManagerStub

    $originalPath = $env:PATH
    try {
      $env:PATH = ("{0}{1}{2}" -f (Split-Path -Parent $dockerStub.CommandPath), [System.IO.Path]::PathSeparator, $originalPath)

      & $script:WrapperScript `
        -Profile 'proof' `
        -RepoRoot $repoRoot `
        -ReviewSuiteScriptPath $reviewStub
      $LASTEXITCODE | Should -Be 0

      $env:DOCKER_STUB_IMAGE_EXISTS = '0'
      & $script:WrapperScript `
        -Profile 'dev-fast' `
        -RepoRoot $repoRoot `
        -BuildImageScriptPath $buildStub `
        -ReviewSuiteScriptPath $reviewStub
      $LASTEXITCODE | Should -Be 0

      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $env:LOCAL_WARM_MANAGER_OUTCOME = 'reused'
      & $script:WrapperScript `
        -Profile 'warm-dev' `
        -RepoRoot $repoRoot `
        -BuildImageScriptPath $buildStub `
        -ReviewSuiteScriptPath $reviewStub `
        -WarmRuntimeManagerScriptPath $warmManagerStub
      $LASTEXITCODE | Should -Be 0
    } finally {
      $env:PATH = $originalPath
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
      Remove-Item Env:LOCAL_WARM_MANAGER_OUTCOME -ErrorAction SilentlyContinue
    }

    $benchmarkPath = Join-Path $repoRoot 'tests/results/local-vi-history/warm-dev/local-refinement-benchmark.json'
    $benchmark = Get-Content -LiteralPath $benchmarkPath -Raw | ConvertFrom-Json -Depth 20
    $benchmark.selectedSamples.proofCold.benchmarkSampleKind | Should -Be 'proof-cold'
    $benchmark.selectedSamples.devFastCold.benchmarkSampleKind | Should -Be 'dev-fast-cold'
    $benchmark.selectedSamples.warmDevRepeat.benchmarkSampleKind | Should -Be 'warm-dev-repeat'
    $benchmark.comparisons.devFastVsProof.left | Should -Be 'proof-cold'
    $benchmark.comparisons.devFastVsProof.right | Should -Be 'dev-fast-cold'
    $benchmark.comparisons.warmDevVsDevFast.left | Should -Be 'dev-fast-cold'
    $benchmark.comparisons.warmDevVsDevFast.right | Should -Be 'warm-dev-repeat'
  }

  It 'Invoke-VIHistoryLocalRefinement derives the warm runtime directory from ResultsRoot' {
    $work = Join-Path $TestDrive 'local-refinement-warm-custom-results'
    $repoRoot = Join-Path $work 'repo'
    $customResultsRoot = Join-Path $repoRoot 'out/warm-live'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8
    $dockerStub = New-DockerStub -Root $work
    $buildStub = Join-Path $work 'build-stub.ps1'
    $reviewStub = Join-Path $work 'review-stub.ps1'
    $warmManagerStub = Join-Path $work 'warm-manager-stub.ps1'
    $warmManagerLog = Join-Path $work 'warm-manager.log'
    New-BuildStub -Path $buildStub
    New-ReviewSuiteStub -Path $reviewStub
    New-WarmManagerStub -Path $warmManagerStub

    $originalPath = $env:PATH
    try {
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $env:LOCAL_WARM_MANAGER_STUB_LOG = $warmManagerLog
      $env:PATH = ("{0}{1}{2}" -f (Split-Path -Parent $dockerStub.CommandPath), [System.IO.Path]::PathSeparator, $originalPath)

      & $script:WrapperScript `
        -Profile 'warm-dev' `
        -RepoRoot $repoRoot `
        -ResultsRoot $customResultsRoot `
        -BuildImageScriptPath $buildStub `
        -ReviewSuiteScriptPath $reviewStub `
        -WarmRuntimeManagerScriptPath $warmManagerStub
      $LASTEXITCODE | Should -Be 0
    } finally {
      $env:PATH = $originalPath
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
      Remove-Item Env:LOCAL_WARM_MANAGER_STUB_LOG -ErrorAction SilentlyContinue
    }

    $warmManagerLogObject = Get-Content -LiteralPath $warmManagerLog -Raw | ConvertFrom-Json -Depth 10
    $warmManagerLogObject.resultsRoot | Should -Be $customResultsRoot
    $warmManagerLogObject.runtimeDir | Should -Be (Join-Path (Join-Path (Split-Path -Parent $customResultsRoot) 'runtime') (Split-Path -Leaf $customResultsRoot))
  }
}
