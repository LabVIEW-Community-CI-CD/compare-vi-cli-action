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
  [string]$ReuseContainerName = '',
  [string]$ReuseRepoHostPath = '',
  [string]$ReuseRepoContainerPath = '',
  [string]$ReuseResultsHostPath = '',
  [string]$ReuseResultsContainerPath = ''
)
$logPath = [Environment]::GetEnvironmentVariable('LOCAL_REVIEW_SUITE_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  [ordered]@{
    image = $Image
    reuseContainerName = $ReuseContainerName
    reuseRepoHostPath = $ReuseRepoHostPath
    reuseRepoContainerPath = $ReuseRepoContainerPath
    reuseResultsHostPath = $ReuseResultsHostPath
    reuseResultsContainerPath = $ReuseResultsContainerPath
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
  [string]$Image
)
$logPath = [Environment]::GetEnvironmentVariable('LOCAL_WARM_MANAGER_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  [ordered]@{
    action = $Action
    repoRoot = $RepoRoot
    resultsRoot = $ResultsRoot
    runtimeDir = $RuntimeDir
    image = $Image
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
}
$payload | ConvertTo-Json -Depth 10
'@ | Set-Content -LiteralPath $Path -Encoding utf8
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
        -DockerCommand $dockerStub.CommandPath
      $LASTEXITCODE | Should -Be 0
      $startState = ($startJson -join "`n") | ConvertFrom-Json -Depth 20
      $startState.schema | Should -Be 'comparevi/local-runtime-state@v1'
      $startState.outcome | Should -Be 'started'
      $startState.lease.schema | Should -Be 'comparevi/local-runtime-lease@v1'

      $healthJson = & $script:ManagerScript `
        -Action status `
        -RepoRoot $repoRoot `
        -ResultsRoot $resultsRoot `
        -RuntimeDir $runtimeDir `
        -Image 'comparevi-vi-history-dev:local' `
        -DockerCommand $dockerStub.CommandPath
      $LASTEXITCODE | Should -Be 0
      $health = ($healthJson -join "`n") | ConvertFrom-Json -Depth 20
      $health.schema | Should -Be 'comparevi/local-runtime-health@v1'
      $health.status | Should -Be 'healthy'
    } finally {
      Remove-Item Env:DOCKER_STUB_IMAGE_EXISTS -ErrorAction SilentlyContinue
    }

    $statePath = Join-Path $runtimeDir 'local-runtime-state.json'
    $leasePath = Join-Path $runtimeDir 'local-runtime-lease.json'
    $healthPath = Join-Path $runtimeDir 'local-runtime-health.json'
    (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -BeTrue
    (Test-Path -LiteralPath $leasePath -PathType Leaf) | Should -BeTrue
    (Test-Path -LiteralPath $healthPath -PathType Leaf) | Should -BeTrue
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
        -ReviewSuiteScriptPath $reviewStub
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
    $receipt.finalStatus | Should -Be 'succeeded'
    $benchmark = Get-Content -LiteralPath $benchmarkPath -Raw | ConvertFrom-Json -Depth 20
    $benchmark.schema | Should -Be 'comparevi/local-refinement-benchmark@v1'
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

    $reviewLogObject = Get-Content -LiteralPath $reviewLog -Raw | ConvertFrom-Json -Depth 10
    $reviewLogObject.reuseContainerName | Should -Be 'warm-stub'
    $reviewLogObject.reuseRepoContainerPath | Should -Be '/opt/comparevi/source'

    $warmManagerLogObject = Get-Content -LiteralPath $warmManagerLog -Raw | ConvertFrom-Json -Depth 10
    $warmManagerLogObject.action | Should -Be 'reconcile'
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
