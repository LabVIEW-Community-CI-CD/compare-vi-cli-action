#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Assert-DockerRuntimeDeterminism.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:GuardScript = Join-Path $script:RepoRoot 'tools' 'Assert-DockerRuntimeDeterminism.ps1'
    if (-not (Test-Path -LiteralPath $script:GuardScript -PathType Leaf)) {
      throw "Guard script not found: $script:GuardScript"
    }

    $script:CreateDockerWslStubs = {
      param([Parameter(Mandatory)][string]$WorkRoot)

      $binDir = Join-Path $WorkRoot 'bin'
      New-Item -ItemType Directory -Path $binDir -Force | Out-Null
      $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

      $dockerStub = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
if ($Args.Count -eq 0) { exit 0 }

$requestedContext = ''
if ($Args.Count -ge 3 -and $Args[0] -eq '--context') {
  $requestedContext = [string]$Args[1]
  $Args = @($Args | Select-Object -Skip 2)
}

$infoMode = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INFO_MODE')
if ([string]::IsNullOrWhiteSpace($infoMode)) { $infoMode = 'parsed-windows' }

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'show') {
  if ([Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT_SHOW_EMPTY') -eq '1') {
    exit 0
  }
  $ctx = [Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT')
  if ([string]::IsNullOrWhiteSpace($ctx)) { $ctx = 'desktop-windows' }
  Write-Output $ctx
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'ls') {
  $ctx = [Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT')
  if ([string]::IsNullOrWhiteSpace($ctx)) { $ctx = 'desktop-windows' }

  $rows = @(
    [ordered]@{
      Name = 'default'
      Current = 'false'
      Description = 'Current DOCKER_HOST based configuration'
      DockerEndpoint = 'npipe:////./pipe/docker_engine'
      Error = ''
    },
    [ordered]@{
      Name = 'desktop-linux'
      Current = if ($ctx -eq 'desktop-linux') { 'true' } else { 'false' }
      Description = 'Docker Desktop'
      DockerEndpoint = 'npipe:////./pipe/dockerDesktopLinuxEngine'
      Error = ''
    },
    [ordered]@{
      Name = 'desktop-windows'
      Current = if ($ctx -eq 'desktop-windows') { 'true' } else { 'false' }
      Description = 'Docker Desktop'
      DockerEndpoint = 'npipe:////./pipe/dockerDesktopWindowsEngine'
      Error = ''
    }
  )
  foreach ($row in $rows) {
    ($row | ConvertTo-Json -Compress) | Write-Output
  }
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 3 -and $Args[1] -eq 'use') {
  $failTarget = [Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT_USE_FAIL_TARGET')
  if (-not [string]::IsNullOrWhiteSpace($failTarget) -and $Args[2] -eq $failTarget) {
    [Console]::Error.WriteLine('context not found')
    exit 1
  }
  Write-Output $Args[2]
  exit 0
}

if ($Args[0] -eq 'ps') { exit 0 }

if ($Args[0] -eq 'info') {
  $infoJson = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INFO_JSON')
  if ($Args -contains '{{json .}}' -and -not [string]::IsNullOrWhiteSpace($infoJson)) {
    Write-Output $infoJson
    exit 0
  }
  $failInfoContext = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INFO_FAIL_CONTEXT')
  if (-not [string]::IsNullOrWhiteSpace($failInfoContext) -and $requestedContext -eq $failInfoContext) {
    Write-Output ("unable to resolve docker endpoint: context `"{0}`" not found" -f $requestedContext)
    exit 1
  }
  switch ($infoMode) {
    'parsed-windows' {
      Write-Output 'windows'
      exit 0
    }
    'parsed-linux' {
      Write-Output 'linux'
      exit 0
    }
    'daemon-unavailable' {
      Write-Output 'Error response from daemon: Docker Desktop is unable to start'
      Write-Output 'bootstrapping main distribution failed'
      $exitCode = 1
      $exitRaw = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INFO_EXIT_CODE')
      if (-not [string]::IsNullOrWhiteSpace($exitRaw)) {
        [void][int]::TryParse($exitRaw, [ref]$exitCode)
      }
      exit $exitCode
    }
    'unparseable-success' {
      Write-Output 'not-an-os-token'
      exit 0
    }
    default {
      Write-Output $infoMode
      exit 0
    }
  }
}

exit 0
'@
      Set-Content -LiteralPath (Join-Path $binDir 'docker.ps1') -Value $dockerStub -Encoding utf8

      $dockerCmd = @"
@echo off
"$pwshPath" -NoLogo -NoProfile -File "%~dp0docker.ps1" %*
"@
      Set-Content -LiteralPath (Join-Path $binDir 'docker.cmd') -Value $dockerCmd -Encoding ascii

      $wslStub = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
if ($Args.Count -ge 2 -and $Args[0] -eq '-l' -and $Args[1] -eq '-v') {
  Write-Output '  NAME              STATE           VERSION'
  Write-Output '* docker-desktop    Stopped         2'
  exit 0
}
if ($Args.Count -ge 1 -and $Args[0] -eq '--shutdown') {
  exit 0
}
exit 0
'@
      Set-Content -LiteralPath (Join-Path $binDir 'wsl.ps1') -Value $wslStub -Encoding utf8

      $wslCmd = @"
@echo off
"$pwshPath" -NoLogo -NoProfile -File "%~dp0wsl.ps1" %*
"@
      Set-Content -LiteralPath (Join-Path $binDir 'wsl.cmd') -Value $wslCmd -Encoding ascii

      $env:PATH = "{0};{1}" -f $binDir, $env:PATH
    }
  }

  BeforeEach {
    $script:SavedPath = $env:PATH
    $script:SavedEnv = @{
      DOCKER_STUB_INFO_MODE = $env:DOCKER_STUB_INFO_MODE
      DOCKER_STUB_INFO_EXIT_CODE = $env:DOCKER_STUB_INFO_EXIT_CODE
      DOCKER_STUB_INFO_FAIL_CONTEXT = $env:DOCKER_STUB_INFO_FAIL_CONTEXT
      DOCKER_STUB_INFO_JSON = $env:DOCKER_STUB_INFO_JSON
      DOCKER_STUB_CONTEXT = $env:DOCKER_STUB_CONTEXT
      DOCKER_STUB_CONTEXT_SHOW_EMPTY = $env:DOCKER_STUB_CONTEXT_SHOW_EMPTY
      DOCKER_STUB_CONTEXT_USE_FAIL_TARGET = $env:DOCKER_STUB_CONTEXT_USE_FAIL_TARGET
      DOCKER_HOST = $env:DOCKER_HOST
    }
  }

  AfterEach {
    $env:PATH = $script:SavedPath
    foreach ($name in $script:SavedEnv.Keys) {
      $value = $script:SavedEnv[$name]
      if ($null -eq $value -or $value -eq '') {
        Remove-Item ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
      } else {
        Set-Item ("Env:{0}" -f $name) $value
      }
    }
  }

  It 'fails fast when ExpectedContext is not provided explicitly' {
    $work = Join-Path $TestDrive 'missing-expected-context'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $snapshotPath = Join-Path $work 'runtime.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType windows `
      -AutoRepair:$false `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath '' 2>&1

    $LASTEXITCODE | Should -Not -Be 0
    ($output -join "`n") | Should -Match 'ExpectedContext'
  }

  It 'classifies daemon-unavailable probe when docker info cannot return OSType' {
    $work = Join-Path $TestDrive 'daemon-unavailable'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'daemon-unavailable'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'

    $snapshotPath = Join-Path $work 'runtime.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$false `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    $text = $output -join "`n"
    $text | Should -Match 'Runtime invariant mismatch'

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.result.status | Should -Be 'mismatch-failed'
    $snapshot.result.failureClass | Should -Be 'daemon-unavailable'
    $snapshot.observed.osType | Should -BeNullOrEmpty
    $snapshot.observed.dockerOsProbe.last.parseReason | Should -Match '^(daemon-unavailable|docker-info-command-failed)$'
    $snapshot.observed.PSObject.Properties.Name | Should -Contain 'dockerBackendProcesses'
    $snapshot.result.reason | Should -Match 'parseReason=(daemon-unavailable|docker-info-command-failed)'
    $snapshot.result.reason | Should -Match 'exitCode=1'
  }

  It 'classifies parse-defect when docker info output is non-empty but unparseable' {
    $work = Join-Path $TestDrive 'parse-defect-unparseable'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'unparseable-success'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'

    $snapshotPath = Join-Path $work 'runtime.json'
    $githubOutput = Join-Path $work 'github-output.txt'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$false `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath $githubOutput 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.result.status | Should -Be 'mismatch-failed'
    $snapshot.result.failureClass | Should -Be 'parse-defect'
    $snapshot.result.probeParseReason | Should -Be 'unparseable-output'

    $ghOut = Get-Content -LiteralPath $githubOutput -Raw
    $ghOut | Should -Match 'runtime-failure-class=parse-defect'
  }

  It 'hard-stops when observed OSType is empty even under auto-repair' {
    $work = Join-Path $TestDrive 'daemon-unavailable-autorepair'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'daemon-unavailable'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'

    $snapshotPath = Join-Path $work 'runtime.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$true `
      -ManageDockerEngine:$true `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.result.status | Should -Be 'mismatch-failed'
    $snapshot.observed.dockerOsProbe.last.parseReason | Should -Match '^(daemon-unavailable|docker-info-command-failed)$'
    @($snapshot.repairActions).Count | Should -Be 0
    $snapshot.result.reason | Should -Match 'observed Docker OSType is empty'
  }

  It 'skips host engine mutation actions when AllowHostEngineMutation is false' {
    $work = Join-Path $TestDrive 'os-mismatch-safe-autorepair'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'parsed-linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'

    $snapshotPath = Join-Path $work 'runtime.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$true `
      -ManageDockerEngine:$true `
      -AllowHostEngineMutation:$false `
      -EngineReadyTimeoutSeconds 5 `
      -EngineReadyPollSeconds 1 `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.result.status | Should -Be 'mismatch-failed'
    $snapshot.expected.allowHostEngineMutation | Should -BeFalse
    $snapshot.repairActions | Should -Contain 'host engine mutation skipped: AllowHostEngineMutation=false'
    (($snapshot.repairActions -join "`n") -match 'docker service recovery') | Should -BeFalse
    (($snapshot.repairActions -join "`n") -match 'docker engine switch') | Should -BeFalse
    (($snapshot.repairActions -join "`n") -match 'wsl --shutdown') | Should -BeFalse
    $snapshot.result.failureClass | Should -Be 'context-os-mismatch'
    $snapshot.result.reason | Should -Match 'Runtime invariant mismatch after repair'
  }

  It 'captures parsed probe details and emits parse-reason output on success' {
    $work = Join-Path $TestDrive 'probe-success'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'parsed-windows'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'

    $snapshotPath = Join-Path $work 'runtime.json'
    $githubOutput = Join-Path $work 'github-output.txt'

    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$true `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath $githubOutput 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.result.status | Should -Be 'ok'
    $snapshot.result.failureClass | Should -Be 'none'
    $snapshot.observed.osType | Should -Be 'windows'
    $snapshot.observed.context | Should -Be 'desktop-windows'
    $snapshot.observed.dockerOsProbe.initial.parseReason | Should -Be 'parsed'
    $snapshot.observed.dockerOsProbe.last.command | Should -Match '--context desktop-windows info --format'
    $snapshot.observed.PSObject.Properties.Name | Should -Contain 'dockerBackendProcesses'

    $ghOut = Get-Content -LiteralPath $githubOutput -Raw
    $ghOut | Should -Match 'runtime-status=ok'
    $ghOut | Should -Match 'runtime-failure-class=none'
    $ghOut | Should -Match 'docker-ostype-parse-reason=parsed'
  }

  It 'accepts default context alias when os probe matches expected lane' {
    $work = Join-Path $TestDrive 'default-context-alias'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'parsed-windows'
    Set-Item Env:DOCKER_STUB_CONTEXT 'default'

    $snapshotPath = Join-Path $work 'runtime.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$true `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.result.status | Should -Be 'ok'
    $snapshot.observed.osType | Should -Be 'windows'
    $snapshot.observed.context | Should -Be 'default'
    $snapshot.repairActions.Count | Should -Be 0
  }

  It 'passes when default context probe succeeds even if expected named context is unavailable' {
    $work = Join-Path $TestDrive 'default-context-named-missing'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'parsed-windows'
    Set-Item Env:DOCKER_STUB_CONTEXT 'default'
    Set-Item Env:DOCKER_STUB_INFO_FAIL_CONTEXT 'desktop-windows'

    $snapshotPath = Join-Path $work 'runtime.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$true `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.result.status | Should -Be 'ok'
    $snapshot.observed.osType | Should -Be 'windows'
    $snapshot.observed.context | Should -Be 'default'
  }

  It 'accepts native-wsl provider when the pinned DOCKER_HOST resolves to a distro-owned linux daemon' {
    $work = Join-Path $TestDrive 'native-wsl-ok'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'parsed-linux'
    Set-Item Env:DOCKER_STUB_INFO_JSON '{"OSType":"linux","OperatingSystem":"Ubuntu 24.04.1 LTS","Name":"ubuntu-native","Platform":{"Name":"Docker Engine - Community"},"Labels":["maintainer=comparevi"]}'
    Set-Item Env:DOCKER_HOST 'unix:///var/run/docker.sock'

    $snapshotPath = Join-Path $work 'runtime.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType linux `
      -RuntimeProvider native-wsl `
      -ExpectedDockerHost 'unix:///var/run/docker.sock' `
      -AutoRepair:$true `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.expected.provider | Should -Be 'native-wsl'
    $snapshot.expected.context | Should -Be ''
    $snapshot.expected.dockerHost | Should -Be 'unix:///var/run/docker.sock'
    $snapshot.result.status | Should -Be 'ok'
    $snapshot.result.failureClass | Should -Be 'none'
    $snapshot.observed.osType | Should -Be 'linux'
    $snapshot.observed.dockerHost | Should -Be 'unix:///var/run/docker.sock'
    $snapshot.observed.desktopBacked | Should -BeFalse
  }

  It 'rejects native-wsl provider when the pinned DOCKER_HOST still resolves to Docker Desktop' {
    $work = Join-Path $TestDrive 'native-wsl-desktop-backed'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerWslStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_INFO_MODE 'parsed-linux'
    Set-Item Env:DOCKER_STUB_INFO_JSON '{"OSType":"linux","OperatingSystem":"Docker Desktop","Name":"docker-desktop","Platform":{"Name":"Docker Desktop 4.41.0"},"Labels":["com.docker.desktop.address=npipe://"]}'
    Set-Item Env:DOCKER_HOST 'unix:///var/run/docker.sock'

    $snapshotPath = Join-Path $work 'runtime.json'
    $output = & pwsh -NoLogo -NoProfile -File $script:GuardScript `
      -ExpectedOsType linux `
      -RuntimeProvider native-wsl `
      -ExpectedDockerHost 'unix:///var/run/docker.sock' `
      -AutoRepair:$true `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath '' 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 12
    $snapshot.result.status | Should -Be 'mismatch-failed'
    $snapshot.result.failureClass | Should -Be 'provider-mismatch'
    $snapshot.observed.desktopBacked | Should -BeTrue
    (($snapshot.repairActions -join "`n") -match 'docker context use') | Should -BeFalse
    (($snapshot.repairActions -join "`n") -match 'docker engine switch') | Should -BeFalse
    $snapshot.result.reason | Should -Match 'provider=native-wsl'
  }
}
