#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-DockerRuntimeManager.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ManagerScript = Join-Path $script:RepoRoot 'tools' 'Invoke-DockerRuntimeManager.ps1'
    if (-not (Test-Path -LiteralPath $script:ManagerScript -PathType Leaf)) {
      throw "Manager script not found: $script:ManagerScript"
    }

    $script:CreateDockerStub = {
      param([Parameter(Mandatory)][string]$WorkRoot)

      $binDir = Join-Path $WorkRoot 'bin'
      New-Item -ItemType Directory -Path $binDir -Force | Out-Null
      $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

      $dockerStub = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)

function Get-StatePath {
  $path = [Environment]::GetEnvironmentVariable('DOCKER_STUB_STATE_PATH')
  if ([string]::IsNullOrWhiteSpace($path)) {
    $tmp = [System.IO.Path]::GetTempPath()
    return (Join-Path $tmp 'docker-stub-state.json')
  }
  return $path
}

function New-SeedState {
  $initial = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INITIAL_CONTEXT')
  if ([string]::IsNullOrWhiteSpace($initial)) { $initial = 'desktop-windows' }
  return [ordered]@{
    activeContext = $initial
    pulledWindows = $false
    pulledLinux = $false
  }
}

function Get-State {
  $statePath = Get-StatePath
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
      return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
    }
  }
  $seed = New-SeedState
  ($seed | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $statePath -Encoding utf8
  return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function Set-State([object]$State) {
  $statePath = Get-StatePath
  $parent = Split-Path -Parent $statePath
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  ($State | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Is-WindowsImage([string]$Image) {
  return ($Image -match '(?i)windows')
}

function Is-LinuxImage([string]$Image) {
  return ($Image -match '(?i)linux')
}

if ($Args.Count -eq 0) { exit 0 }

$state = Get-State
$active = [string]$state.activeContext
if ([string]::IsNullOrWhiteSpace($active)) { $active = 'desktop-windows' }

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'show') {
  Write-Output $active
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 3 -and $Args[1] -eq 'use') {
  $target = [string]$Args[2]
  $failTarget = [Environment]::GetEnvironmentVariable('DOCKER_STUB_FAIL_CONTEXT')
  if (-not [string]::IsNullOrWhiteSpace($failTarget) -and $target -eq $failTarget) {
    [Console]::Error.WriteLine(("context use blocked for {0}" -f $target))
    exit 1
  }
  $state.activeContext = $target
  Set-State -State $state
  Write-Output $target
  exit 0
}

if ($Args[0] -eq 'info') {
  $infoSleep = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INFO_SLEEP_SECONDS')
  if (-not [string]::IsNullOrWhiteSpace($infoSleep)) {
    Start-Sleep -Seconds ([int]$infoSleep)
  }
  if ([Environment]::GetEnvironmentVariable('DOCKER_STUB_FORCE_INFO_FAILURE') -eq '1') {
    [Console]::Error.WriteLine('docker info failed')
    exit 1
  }
  if ($active -match 'linux') { Write-Output 'linux'; exit 0 }
  Write-Output 'windows'
  exit 0
}

if ($Args[0] -eq 'manifest' -and $Args.Count -ge 3 -and $Args[1] -eq 'inspect') {
  $paddingBytes = [Environment]::GetEnvironmentVariable('DOCKER_STUB_MANIFEST_PADDING_BYTES')
  $padding = ''
  if (-not [string]::IsNullOrWhiteSpace($paddingBytes)) {
    $padding = ('x' * [int]$paddingBytes)
  }
  $manifest = [ordered]@{
    schemaVersion = 2
    annotations = [ordered]@{
      padding = $padding
    }
    manifests = @(
      [ordered]@{
        digest = 'sha256:1111111111111111111111111111111111111111111111111111111111111111'
        platform = [ordered]@{
          os = 'windows'
          architecture = 'amd64'
        }
      },
      [ordered]@{
        digest = 'sha256:2222222222222222222222222222222222222222222222222222222222222222'
        platform = [ordered]@{
          os = 'linux'
          architecture = 'amd64'
        }
      }
    )
  }
  ($manifest | ConvertTo-Json -Depth 10) | Write-Output
  exit 0
}

if ($Args[0] -eq 'image' -and $Args.Count -ge 3 -and $Args[1] -eq 'inspect') {
  $inspectSleep = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INSPECT_SLEEP_SECONDS')
  if (-not [string]::IsNullOrWhiteSpace($inspectSleep)) {
    Start-Sleep -Seconds ([int]$inspectSleep)
  }
  $image = [string]$Args[2]
  $requirePullWindows = ([Environment]::GetEnvironmentVariable('DOCKER_STUB_REQUIRE_PULL_WINDOWS') -eq '1')
  $requirePullLinux = ([Environment]::GetEnvironmentVariable('DOCKER_STUB_REQUIRE_PULL_LINUX') -eq '1')

  $needsPull = $false
  if ($requirePullWindows -and (Is-WindowsImage -Image $image) -and -not [bool]$state.pulledWindows) { $needsPull = $true }
  if ($requirePullLinux -and (Is-LinuxImage -Image $image) -and -not [bool]$state.pulledLinux) { $needsPull = $true }

  if ($needsPull) {
    [Console]::Error.WriteLine(("Error: No such image: {0}" -f $image))
    exit 1
  }

  $digest = if (Is-WindowsImage -Image $image) { 'sha256:3333333333333333333333333333333333333333333333333333333333333333' } else { 'sha256:4444444444444444444444444444444444444444444444444444444444444444' }
  $id = if (Is-WindowsImage -Image $image) { 'sha256:stub-image-id-windows' } else { 'sha256:stub-image-id-linux' }
  $payload = [ordered]@{
    Id = $id
    RepoDigests = @("$image@$digest")
  }
  ($payload | ConvertTo-Json -Depth 10 -Compress) | Write-Output
  exit 0
}

if ($Args[0] -eq 'pull' -and $Args.Count -ge 2) {
  $image = [string]$Args[1]
  $pullSleepVar = if (Is-WindowsImage -Image $image) { 'DOCKER_STUB_PULL_SLEEP_WINDOWS' } else { 'DOCKER_STUB_PULL_SLEEP_LINUX' }
  $pullSleep = [Environment]::GetEnvironmentVariable($pullSleepVar)
  if (-not [string]::IsNullOrWhiteSpace($pullSleep)) {
    Start-Sleep -Seconds ([int]$pullSleep)
  }
  if (([Environment]::GetEnvironmentVariable('DOCKER_STUB_PULL_FAIL_WINDOWS') -eq '1') -and (Is-WindowsImage -Image $image)) {
    [Console]::Error.WriteLine(("pull denied for {0}" -f $image))
    exit 1
  }
  if (([Environment]::GetEnvironmentVariable('DOCKER_STUB_PULL_FAIL_LINUX') -eq '1') -and (Is-LinuxImage -Image $image)) {
    [Console]::Error.WriteLine(("pull denied for {0}" -f $image))
    exit 1
  }

  if (Is-WindowsImage -Image $image) { $state.pulledWindows = $true }
  if (Is-LinuxImage -Image $image) { $state.pulledLinux = $true }
  Set-State -State $state
  $digest = if (Is-WindowsImage -Image $image) { 'sha256:3333333333333333333333333333333333333333333333333333333333333333' } else { 'sha256:4444444444444444444444444444444444444444444444444444444444444444' }
  Write-Output ("Digest: {0}" -f $digest)
  exit 0
}

if ($Args[0] -eq 'run') {
  $joined = ($Args -join ' ')
  if ($joined -match '(?i)windows') {
    $runSleep = [Environment]::GetEnvironmentVariable('DOCKER_STUB_RUN_SLEEP_WINDOWS')
    if (-not [string]::IsNullOrWhiteSpace($runSleep)) {
      Start-Sleep -Seconds ([int]$runSleep)
    }
  }
  if ($joined -match '(?i)linux') {
    $runSleep = [Environment]::GetEnvironmentVariable('DOCKER_STUB_RUN_SLEEP_LINUX')
    if (-not [string]::IsNullOrWhiteSpace($runSleep)) {
      Start-Sleep -Seconds ([int]$runSleep)
    }
  }
  $runFailWindows = ([Environment]::GetEnvironmentVariable('DOCKER_STUB_RUN_FAIL_WINDOWS') -eq '1')
  $runFailLinux = ([Environment]::GetEnvironmentVariable('DOCKER_STUB_RUN_FAIL_LINUX') -eq '1')
  if ($runFailWindows -and $joined -match '(?i)windows') {
    [Console]::Error.WriteLine('runtime probe failed (windows)')
    exit 5
  }
  if ($runFailLinux -and $joined -match '(?i)linux') {
    [Console]::Error.WriteLine('runtime probe failed (linux)')
    exit 6
  }
  Write-Output 'ni-runtime-probe-ok'
  exit 0
}

exit 0
'@
      Set-Content -LiteralPath (Join-Path $binDir 'docker.ps1') -Value $dockerStub -Encoding utf8

      $dockerCmd = @"
@echo off
"$pwshPath" -NoLogo -NoProfile -File "%~dp0docker.ps1" %*
"@
      Set-Content -LiteralPath (Join-Path $binDir 'docker.cmd') -Value $dockerCmd -Encoding ascii

      $env:PATH = "{0};{1}" -f $binDir, $env:PATH
      $env:DOCKER_COMMAND_OVERRIDE = (Join-Path $binDir 'docker.ps1')
    }
  }

  BeforeEach {
    $script:SavedPath = $env:PATH
    $script:SavedEnv = @{
      DOCKER_STUB_STATE_PATH = $env:DOCKER_STUB_STATE_PATH
      DOCKER_STUB_INITIAL_CONTEXT = $env:DOCKER_STUB_INITIAL_CONTEXT
      DOCKER_STUB_FAIL_CONTEXT = $env:DOCKER_STUB_FAIL_CONTEXT
      DOCKER_STUB_FORCE_INFO_FAILURE = $env:DOCKER_STUB_FORCE_INFO_FAILURE
      DOCKER_STUB_REQUIRE_PULL_WINDOWS = $env:DOCKER_STUB_REQUIRE_PULL_WINDOWS
      DOCKER_STUB_REQUIRE_PULL_LINUX = $env:DOCKER_STUB_REQUIRE_PULL_LINUX
      DOCKER_STUB_PULL_FAIL_WINDOWS = $env:DOCKER_STUB_PULL_FAIL_WINDOWS
      DOCKER_STUB_PULL_FAIL_LINUX = $env:DOCKER_STUB_PULL_FAIL_LINUX
      DOCKER_STUB_RUN_FAIL_WINDOWS = $env:DOCKER_STUB_RUN_FAIL_WINDOWS
      DOCKER_STUB_RUN_FAIL_LINUX = $env:DOCKER_STUB_RUN_FAIL_LINUX
      DOCKER_STUB_INFO_SLEEP_SECONDS = $env:DOCKER_STUB_INFO_SLEEP_SECONDS
      DOCKER_STUB_INSPECT_SLEEP_SECONDS = $env:DOCKER_STUB_INSPECT_SLEEP_SECONDS
      DOCKER_STUB_MANIFEST_PADDING_BYTES = $env:DOCKER_STUB_MANIFEST_PADDING_BYTES
      DOCKER_STUB_PULL_SLEEP_WINDOWS = $env:DOCKER_STUB_PULL_SLEEP_WINDOWS
      DOCKER_STUB_PULL_SLEEP_LINUX = $env:DOCKER_STUB_PULL_SLEEP_LINUX
      DOCKER_STUB_RUN_SLEEP_WINDOWS = $env:DOCKER_STUB_RUN_SLEEP_WINDOWS
      DOCKER_STUB_RUN_SLEEP_LINUX = $env:DOCKER_STUB_RUN_SLEEP_LINUX
      DOCKER_COMMAND_OVERRIDE = $env:DOCKER_COMMAND_OVERRIDE
      RUNNER_TEMP = $env:RUNNER_TEMP
    }
  }

  AfterEach {
    $env:PATH = $script:SavedPath
    foreach ($key in $script:SavedEnv.Keys) {
      $value = $script:SavedEnv[$key]
      if ($null -eq $value -or $value -eq '') {
        Remove-Item ("Env:{0}" -f $key) -ErrorAction SilentlyContinue
      } else {
        Set-Item ("Env:{0}" -f $key) $value
      }
    }
  }

  It 'emits docker-runtime-manager@v1 outputs on successful windows/linux probe cycle' {
    $work = Join-Path $TestDrive 'success'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerStub -WorkRoot $work

    Set-Item Env:DOCKER_STUB_STATE_PATH (Join-Path $work 'docker-state.json')
    Set-Item Env:DOCKER_STUB_INITIAL_CONTEXT 'desktop-linux'
    Set-Item Env:RUNNER_TEMP (Join-Path $work 'runner-temp')

    $jsonPath = Join-Path $work 'docker-runtime-manager.json'
    $outputPath = Join-Path $work 'github-output.txt'
    $summaryPath = Join-Path $work 'step-summary.md'

    $output = & pwsh -NoLogo -NoProfile -File $script:ManagerScript `
      -OutputJsonPath $jsonPath `
      -GitHubOutputPath $outputPath `
      -StepSummaryPath $summaryPath `
      -SwitchRetryCount 1 `
      -SwitchTimeoutSeconds 30 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
    $json.schema | Should -Be 'docker-runtime-manager@v1'
    $json.status | Should -Be 'success'
    $json.failureClass | Should -Be 'none'
    $json.lock.acquired | Should -BeTrue
    $json.probes.windows.status | Should -Be 'success'
    $json.probes.linux.status | Should -Be 'success'
    $json.probes.windows.digest | Should -Be 'sha256:1111111111111111111111111111111111111111111111111111111111111111'
    $json.probes.linux.digest | Should -Be 'sha256:2222222222222222222222222222222222222222222222222222222222222222'
    $json.probes.windows.bootstrap.imagePresent | Should -BeTrue
    $json.probes.linux.bootstrap.imagePresent | Should -BeTrue
    $json.probes.windows.bootstrap.localDigest | Should -Be 'sha256:3333333333333333333333333333333333333333333333333333333333333333'
    $json.probes.linux.bootstrap.localDigest | Should -Be 'sha256:4444444444444444444444444444444444444444444444444444444444444444'
    $json.probes.windows.probe.status | Should -Be 'success'
    $json.probes.linux.probe.status | Should -Be 'success'
    $json.contexts.start | Should -Be 'desktop-linux'
    $json.contexts.final | Should -Be 'desktop-windows'

    $ghOutput = Get-Content -LiteralPath $outputPath -Raw
    $ghOutput | Should -Match 'manager_status=success'
    $ghOutput | Should -Match 'windows_image_digest=sha256:3333333333333333333333333333333333333333333333333333333333333333'
    $ghOutput | Should -Match 'linux_image_digest=sha256:4444444444444444444444444444444444444444444444444444444444444444'
    $ghOutput | Should -Match 'windows_probe_status=success'
    $ghOutput | Should -Match 'linux_probe_status=success'

    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match '### Docker Runtime Manager'
    $summary | Should -Match 'status: `success`'
    $summary | Should -Match 'probe=`success`'
  }

  It 'bootstraps missing windows image when windows-only probe scope is selected' {
    $work = Join-Path $TestDrive 'bootstrap-windows'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerStub -WorkRoot $work

    Set-Item Env:DOCKER_STUB_STATE_PATH (Join-Path $work 'docker-state.json')
    Set-Item Env:DOCKER_STUB_INITIAL_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_REQUIRE_PULL_WINDOWS '1'
    Set-Item Env:RUNNER_TEMP (Join-Path $work 'runner-temp')

    $jsonPath = Join-Path $work 'docker-runtime-manager.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:ManagerScript `
      -ProbeScope windows `
      -OutputJsonPath $jsonPath `
      -SwitchRetryCount 1 `
      -SwitchTimeoutSeconds 30 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
    $json.status | Should -Be 'success'
    $json.probes.windows.bootstrap.pulled | Should -BeTrue
    $json.probes.windows.bootstrap.imagePresent | Should -BeTrue
    $json.probes.windows.probe.status | Should -Be 'success'
    $json.probes.linux.status | Should -Be 'skipped'
  }

  It 'classifies context switch failure as runtime-determinism failure' {
    $work = Join-Path $TestDrive 'runtime-failure'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerStub -WorkRoot $work

    Set-Item Env:DOCKER_STUB_STATE_PATH (Join-Path $work 'docker-state.json')
    Set-Item Env:DOCKER_STUB_INITIAL_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_FAIL_CONTEXT 'desktop-linux'
    Set-Item Env:RUNNER_TEMP (Join-Path $work 'runner-temp')

    $jsonPath = Join-Path $work 'docker-runtime-manager.json'
    $outputPath = Join-Path $work 'github-output.txt'
    $output = & pwsh -NoLogo -NoProfile -File $script:ManagerScript `
      -OutputJsonPath $jsonPath `
      -GitHubOutputPath $outputPath `
      -SwitchRetryCount 1 `
      -SwitchTimeoutSeconds 30 2>&1

    $LASTEXITCODE | Should -Not -Be 0
    $text = $output -join "`n"
    $text | Should -Match 'Failed to switch Docker context to'

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
    $json.status | Should -Be 'failure'
    $json.failureClass | Should -Be 'runtime-determinism'
    $json.probes.windows.status | Should -Be 'success'
    $json.probes.linux.status | Should -Be 'failure'
    $json.probes.linux.error | Should -Match 'desktop-linux'

    $ghOutput = Get-Content -LiteralPath $outputPath -Raw
    $ghOutput | Should -Match 'manager_status=failure'
  }

  It 'fails with image-bootstrap classification when windows image is missing and bootstrap is disabled' {
    $work = Join-Path $TestDrive 'bootstrap-disabled'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerStub -WorkRoot $work

    Set-Item Env:DOCKER_STUB_STATE_PATH (Join-Path $work 'docker-state.json')
    Set-Item Env:DOCKER_STUB_INITIAL_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_REQUIRE_PULL_WINDOWS '1'
    Set-Item Env:RUNNER_TEMP (Join-Path $work 'runner-temp')

    $jsonPath = Join-Path $work 'docker-runtime-manager.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:ManagerScript `
      -ProbeScope windows `
      -BootstrapWindowsImage:$false `
      -OutputJsonPath $jsonPath `
      -SwitchRetryCount 1 `
      -SwitchTimeoutSeconds 30 2>&1

    $LASTEXITCODE | Should -Not -Be 0
    ($output -join "`n") | Should -Match 'Local image inspect failed'

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
    $json.status | Should -Be 'failure'
    $json.failureClass | Should -Be 'image-bootstrap'
    $json.probes.windows.status | Should -Be 'success'
  }

  It 'fails closed with image-bootstrap-timeout when a windows image pull exceeds the allowed bound' {
    $work = Join-Path $TestDrive 'pull-timeout'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerStub -WorkRoot $work

    Set-Item Env:DOCKER_STUB_STATE_PATH (Join-Path $work 'docker-state.json')
    Set-Item Env:DOCKER_STUB_INITIAL_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_REQUIRE_PULL_WINDOWS '1'
    Set-Item Env:DOCKER_STUB_PULL_SLEEP_WINDOWS '6'
    Set-Item Env:RUNNER_TEMP (Join-Path $work 'runner-temp')

    $jsonPath = Join-Path $work 'docker-runtime-manager.json'
    $output = @(& pwsh -NoLogo -NoProfile -File $script:ManagerScript `
      -ProbeScope windows `
      -OutputJsonPath $jsonPath `
      -BootstrapPullTimeoutSeconds 5 `
      -SwitchRetryCount 1 `
      -SwitchTimeoutSeconds 30 2>&1)

    $LASTEXITCODE | Should -Not -Be 0
    ($output -join "`n") | Should -Match 'docker pull timed out'

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
    $json.status | Should -Be 'failure'
    $json.failureClass | Should -Be 'image-bootstrap-timeout'
    $json.probes.windows.bootstrap.pullError | Should -Match 'docker pull timed out'
  }

  It 'fails closed with runtime-probe-timeout when a windows runtime probe exceeds the allowed bound' {
    $work = Join-Path $TestDrive 'runtime-probe-timeout'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerStub -WorkRoot $work

    Set-Item Env:DOCKER_STUB_STATE_PATH (Join-Path $work 'docker-state.json')
    Set-Item Env:DOCKER_STUB_INITIAL_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_SLEEP_WINDOWS '6'
    Set-Item Env:RUNNER_TEMP (Join-Path $work 'runner-temp')

    $jsonPath = Join-Path $work 'docker-runtime-manager.json'
    $output = @(& pwsh -NoLogo -NoProfile -File $script:ManagerScript `
      -ProbeScope windows `
      -OutputJsonPath $jsonPath `
      -ProbeTimeoutSeconds 5 `
      -SwitchRetryCount 1 `
      -SwitchTimeoutSeconds 30 2>&1)

    $LASTEXITCODE | Should -Not -Be 0
    ($output -join "`n") | Should -Match 'Runtime probe failed'

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
    $json.status | Should -Be 'failure'
    $json.failureClass | Should -Be 'runtime-probe-timeout'
    $json.probes.windows.probe.status | Should -Be 'timeout'
  }

  It 'handles large manifest output without deadlocking the timeout helper' {
    $work = Join-Path $TestDrive 'large-manifest-output'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerStub -WorkRoot $work

    Set-Item Env:DOCKER_STUB_STATE_PATH (Join-Path $work 'docker-state.json')
    Set-Item Env:DOCKER_STUB_INITIAL_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_MANIFEST_PADDING_BYTES '20000'
    Set-Item Env:RUNNER_TEMP (Join-Path $work 'runner-temp')

    $jsonPath = Join-Path $work 'docker-runtime-manager.json'
    $output = @(& pwsh -NoLogo -NoProfile -File $script:ManagerScript `
      -ProbeScope windows `
      -OutputJsonPath $jsonPath `
      -CommandTimeoutSeconds 15 `
      -SwitchRetryCount 1 `
      -SwitchTimeoutSeconds 30 2>&1)

    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
    $json.status | Should -Be 'success'
    $json.probes.windows.status | Should -Be 'success'
    $json.probes.windows.digest | Should -Be 'sha256:1111111111111111111111111111111111111111111111111111111111111111'
  }

  It 'fails with lock timeout when the runtime manager lock is held by another process' {
    $work = Join-Path $TestDrive 'lock-timeout'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerStub -WorkRoot $work

    Set-Item Env:DOCKER_STUB_STATE_PATH (Join-Path $work 'docker-state.json')
    Set-Item Env:DOCKER_STUB_INITIAL_CONTEXT 'desktop-windows'
    $runnerTemp = Join-Path $work 'runner-temp'
    Set-Item Env:RUNNER_TEMP $runnerTemp

    $lockPath = Join-Path $runnerTemp 'docker-runtime-manager\engine-switch.lock'
    $lockDir = Split-Path -Parent $lockPath
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
      $jsonPath = Join-Path $work 'docker-runtime-manager.json'
      $output = & pwsh -NoLogo -NoProfile -File $script:ManagerScript `
        -OutputJsonPath $jsonPath `
        -LockWaitSeconds 5 `
        -SwitchRetryCount 1 `
        -SwitchTimeoutSeconds 30 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      ($output -join "`n") | Should -Match 'Timed out waiting for Docker manager lock'

      $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 30
      $json.status | Should -Be 'failure'
      $json.failureClass | Should -Be 'runtime-determinism'
      $json.failureMessage | Should -Match 'Timed out waiting for Docker manager lock'
      $json.lock.acquired | Should -BeFalse
    } finally {
      $lockStream.Dispose()
    }
  }
}
