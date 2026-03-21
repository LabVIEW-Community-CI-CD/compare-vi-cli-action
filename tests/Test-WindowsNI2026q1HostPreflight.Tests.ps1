#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Test-WindowsNI2026q1HostPreflight.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ToolPath = Join-Path $script:RepoRoot 'tools' 'Test-WindowsNI2026q1HostPreflight.ps1'
    if (-not (Test-Path -LiteralPath $script:ToolPath -PathType Leaf)) {
      throw "Test-WindowsNI2026q1HostPreflight.ps1 not found: $script:ToolPath"
    }

    $script:CreateDockerHostedStubs = {
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

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'show') {
  $ctx = [Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT')
  if ([string]::IsNullOrWhiteSpace($ctx)) { $ctx = 'default' }
  Write-Output $ctx
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'ls') {
  $ctx = [Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT')
  if ([string]::IsNullOrWhiteSpace($ctx)) { $ctx = 'default' }
  $rows = @(
    [ordered]@{
      Name = 'default'
      Current = if ($ctx -eq 'default') { 'true' } else { 'false' }
      Description = 'Current DOCKER_HOST based configuration'
      DockerEndpoint = 'npipe:////./pipe/docker_engine'
      Error = ''
    }
  )
  foreach ($row in $rows) {
    ($row | ConvertTo-Json -Compress) | Write-Output
  }
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 3 -and $Args[1] -eq 'use') {
  [System.Environment]::SetEnvironmentVariable('DOCKER_STUB_CONTEXT', $Args[2], 'Process')
  Write-Output $Args[2]
  exit 0
}

if ($Args[0] -eq 'info') {
  $infoJson = [Environment]::GetEnvironmentVariable('DOCKER_STUB_INFO_JSON')
  if ($Args -contains '{{json .}}' -and -not [string]::IsNullOrWhiteSpace($infoJson)) {
    Write-Output $infoJson
    exit 0
  }
  $osType = [Environment]::GetEnvironmentVariable('DOCKER_STUB_OSTYPE')
  if ([string]::IsNullOrWhiteSpace($osType)) { $osType = 'windows' }
  Write-Output $osType
  exit 0
}

if ($Args[0] -eq 'image' -and $Args.Count -ge 2 -and $Args[1] -eq 'inspect') {
  $exists = [Environment]::GetEnvironmentVariable('DOCKER_STUB_IMAGE_EXISTS')
  if ($exists -eq '1') {
    Write-Output '{"Id":"sha256:synthetic","RepoDigests":["nationalinstruments/labview:2026q1-windows@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"]}'
    exit 0
  }
  [Console]::Error.WriteLine('Error: No such image')
  exit 1
}

if ($Args[0] -eq 'pull') {
  Write-Output 'pulled'
  exit 0
}

if ($Args[0] -eq 'run') {
  Write-Output 'ni-runtime-probe-ok'
  exit 0
}

if ($Args[0] -eq 'ps') {
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
      DOCKER_STUB_CONTEXT = $env:DOCKER_STUB_CONTEXT
      DOCKER_STUB_OSTYPE = $env:DOCKER_STUB_OSTYPE
      DOCKER_STUB_IMAGE_EXISTS = $env:DOCKER_STUB_IMAGE_EXISTS
      DOCKER_STUB_INFO_JSON = $env:DOCKER_STUB_INFO_JSON
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

  It 'writes a hosted Windows preflight receipt without Docker Desktop mutation' {
    $work = Join-Path $TestDrive 'hosted-preflight'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    & $script:CreateDockerHostedStubs -WorkRoot $work

    Set-Item Env:DOCKER_STUB_CONTEXT 'default'
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_INFO_JSON '{"OSType":"windows","OperatingSystem":"Windows Server 2022","Name":"github-hosted","Platform":{"Name":"Docker Engine - Community"}}'
    Set-Item Env:DOCKER_HOST 'npipe:////./pipe/docker_engine'

    $resultsRoot = Join-Path $work 'results'
    $outputJsonPath = Join-Path $resultsRoot 'windows-ni-2026q1-host-preflight.json'

    $output = & pwsh -NoLogo -NoProfile -File $script:ToolPath `
      -Image 'nationalinstruments/labview:2026q1-windows' `
      -ResultsDir $resultsRoot `
      -ExecutionSurface 'github-hosted-windows' `
      -OutputJsonPath $outputJsonPath `
      -GitHubOutputPath '' `
      -StepSummaryPath '' 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $json = Get-Content -LiteralPath $outputJsonPath -Raw | ConvertFrom-Json -Depth 20
    $json.schema | Should -Be 'comparevi/windows-host-preflight@v1'
    $json.executionSurface | Should -Be 'github-hosted-windows'
    $json.status | Should -Be 'ready'
    $json.runtimeProvider | Should -Be 'github-hosted-windows'
    $json.dockerHost | Should -Be 'npipe:////./pipe/docker_engine'
    $json.contexts.final | Should -Be 'default'
    $json.contexts.finalOsType | Should -Be 'windows'
    $json.bootstrap.imagePresent | Should -BeTrue
    $json.probe.status | Should -Be 'success'
    $json.hostedContract.hostEngineMutationAllowed | Should -BeFalse
  }
}
