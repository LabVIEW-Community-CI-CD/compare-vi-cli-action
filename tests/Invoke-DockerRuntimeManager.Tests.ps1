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

function Get-State {
  $statePath = Get-StatePath
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
      return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
    }
  }
  $initial = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INITIAL_CONTEXT')
  if ([string]::IsNullOrWhiteSpace($initial)) { $initial = 'desktop-windows' }
  $seed = [ordered]@{ activeContext = $initial }
  ($seed | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $statePath -Encoding utf8
  return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function Set-State([object]$State) {
  $statePath = Get-StatePath
  $parent = Split-Path -Parent $statePath
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  ($State | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $statePath -Encoding utf8
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
  if ([Environment]::GetEnvironmentVariable('DOCKER_STUB_FORCE_INFO_FAILURE') -eq '1') {
    [Console]::Error.WriteLine('docker info failed')
    exit 1
  }
  if ($active -match 'linux') { Write-Output 'linux'; exit 0 }
  Write-Output 'windows'
  exit 0
}

if ($Args[0] -eq 'manifest' -and $Args.Count -ge 3 -and $Args[1] -eq 'inspect') {
  $manifest = [ordered]@{
    schemaVersion = 2
    manifests = @(
      [ordered]@{
        digest = 'sha256:stubwindows'
        platform = [ordered]@{
          os = 'windows'
          architecture = 'amd64'
        }
      },
      [ordered]@{
        digest = 'sha256:stublinux'
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

exit 0
'@
      Set-Content -LiteralPath (Join-Path $binDir 'docker.ps1') -Value $dockerStub -Encoding utf8

      $dockerCmd = @"
@echo off
"$pwshPath" -NoLogo -NoProfile -File "%~dp0docker.ps1" %*
"@
      Set-Content -LiteralPath (Join-Path $binDir 'docker.cmd') -Value $dockerCmd -Encoding ascii

      $env:PATH = "{0};{1}" -f $binDir, $env:PATH
    }
  }

  BeforeEach {
    $script:SavedPath = $env:PATH
    $script:SavedEnv = @{
      DOCKER_STUB_STATE_PATH = $env:DOCKER_STUB_STATE_PATH
      DOCKER_STUB_INITIAL_CONTEXT = $env:DOCKER_STUB_INITIAL_CONTEXT
      DOCKER_STUB_FAIL_CONTEXT = $env:DOCKER_STUB_FAIL_CONTEXT
      DOCKER_STUB_FORCE_INFO_FAILURE = $env:DOCKER_STUB_FORCE_INFO_FAILURE
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

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 25
    $json.schema | Should -Be 'docker-runtime-manager@v1'
    $json.status | Should -Be 'success'
    $json.failureClass | Should -Be 'none'
    $json.lock.acquired | Should -BeTrue
    $json.probes.windows.status | Should -Be 'success'
    $json.probes.linux.status | Should -Be 'success'
    $json.probes.windows.digest | Should -Be 'sha256:stubwindows'
    $json.probes.linux.digest | Should -Be 'sha256:stublinux'
    $json.contexts.start | Should -Be 'desktop-linux'
    $json.contexts.final | Should -Be 'desktop-windows'

    $ghOutput = Get-Content -LiteralPath $outputPath -Raw
    $ghOutput | Should -Match 'manager_status=success'
    $ghOutput | Should -Match 'windows_image_digest=sha256:stubwindows'
    $ghOutput | Should -Match 'linux_image_digest=sha256:stublinux'

    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match '### Docker Runtime Manager'
    $summary | Should -Match 'status: `success`'
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

    $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 25
    $json.status | Should -Be 'failure'
    $json.failureClass | Should -Be 'runtime-determinism'
    $json.probes.windows.status | Should -Be 'success'
    $json.probes.linux.status | Should -Be 'failure'
    $json.probes.linux.error | Should -Match 'desktop-linux'

    $ghOutput = Get-Content -LiteralPath $outputPath -Raw
    $ghOutput | Should -Match 'manager_status=failure'
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

      $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -Depth 25
      $json.status | Should -Be 'failure'
      $json.failureClass | Should -Be 'runtime-determinism'
      $json.failureMessage | Should -Match 'Timed out waiting for Docker manager lock'
      $json.lock.acquired | Should -BeFalse
    } finally {
      $lockStream.Dispose()
    }
  }
}
