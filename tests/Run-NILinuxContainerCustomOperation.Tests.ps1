#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Run-NILinuxContainerCustomOperation.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunnerScript = Join-Path $script:RepoRoot 'tools' 'Run-NILinuxContainerCustomOperation.ps1'
    if (-not (Test-Path -LiteralPath $script:RunnerScript -PathType Leaf)) {
      throw "Run-NILinuxContainerCustomOperation.ps1 not found at $script:RunnerScript"
    }

    $script:NewDockerStub = {
      param([Parameter(Mandatory)][string]$WorkRoot)

      $stubPath = Join-Path $WorkRoot 'docker-stub.ps1'
      @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$logPath = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  $record = [ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    args = @($Args)
  }
  ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $logPath -Encoding utf8
}

function Get-EnvValue {
  param([Parameter(Mandatory)][string]$Name)
  return [System.Environment]::GetEnvironmentVariable($Name)
}

function Resolve-HostPathFromContainerPath {
  param(
    [Parameter(Mandatory)][string]$ContainerPath,
    [Parameter(Mandatory)][object[]]$VolumeMap
  )

  $normalizedContainerPath = $ContainerPath.Replace('\', '/')
  foreach ($mapping in $VolumeMap) {
    $containerRoot = [string]$mapping.container
    $normalizedRoot = $containerRoot.Replace('\', '/').TrimEnd('/')
    if ($normalizedContainerPath -eq $normalizedRoot) {
      return [string]$mapping.host
    }
    $prefix = '{0}/' -f $normalizedRoot
    if ($normalizedContainerPath.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
      $relative = $normalizedContainerPath.Substring($prefix.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
      return (Join-Path ([string]$mapping.host) $relative)
    }
  }
  return $ContainerPath
}

if ($Args.Count -eq 0) { exit 0 }

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'show') {
  Write-Output 'desktop-linux'
  exit 0
}

if ($Args[0] -eq 'info') {
  Write-Output 'linux'
  exit 0
}

if ($Args[0] -eq 'image' -and $Args.Count -ge 2 -and $Args[1] -eq 'inspect') {
  if ([string]::Equals((Get-EnvValue -Name 'DOCKER_STUB_IMAGE_EXISTS'), '1', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Output '[]'
    exit 0
  }
  [Console]::Error.WriteLine('Error: No such image')
  exit 1
}

  if ($Args[0] -eq 'run') {
    $stubEnv = @{}
    $volumeMap = @()
  for ($i = 0; $i -lt $Args.Count; $i++) {
    if ($Args[$i] -eq '--env' -and ($i + 1) -lt $Args.Count) {
      $pair = [string]$Args[$i + 1]
      if ($pair -match '^(?<k>[^=]+)=(?<v>.*)$') {
        $stubEnv[$Matches['k']] = $Matches['v']
      }
      $i++
      continue
    }
    if ($Args[$i] -eq '-v' -and ($i + 1) -lt $Args.Count) {
      $spec = [string]$Args[$i + 1]
      $separator = $spec.LastIndexOf(':/')
      if ($separator -gt 0) {
        $volumeMap += [pscustomobject]@{
          host = $spec.Substring(0, $separator)
          container = $spec.Substring($separator + 1)
        }
      }
      $i++
      }
    }

  $captureRoot = Get-EnvValue -Name 'DOCKER_STUB_CAPTURE_ROOT'
  if ([string]::IsNullOrWhiteSpace($captureRoot)) {
    $captureMapping = @($volumeMap | Where-Object { [string]$_.container -eq '/capture' } | Select-Object -First 1)
    if ($captureMapping.Count -eq 0) {
      throw 'Missing /capture volume mapping.'
    }
    $captureRoot = [string]$captureMapping[0].host
  }
  if (-not (Test-Path -LiteralPath $captureRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
  }
  $argsFile = Join-Path $captureRoot 'custom-operation-args.txt'
  $cliArgs = if (Test-Path -LiteralPath $argsFile -PathType Leaf) { Get-Content -LiteralPath $argsFile } else { @() }
  $expectedOutputPath = [string]$stubEnv['CUSTOM_OP_EXPECT_OUTPUT_PATH']
  $hostOutputPath = Join-Path $captureRoot 'print-output.html'
  '<html><body>printed</body></html>' | Set-Content -LiteralPath $hostOutputPath -Encoding utf8

  [ordered]@{
    schema = 'ni-linux-container-custom-operation-scenario@v1'
    status = 'succeeded'
    timedOut = $false
    exitCode = 0
    cliPath = 'LabVIEWCLI'
    stdoutPath = '/capture/labview-cli-stdout.txt'
    stderrPath = '/capture/labview-cli-stderr.txt'
    prelaunchAttempted = $true
    iniPath = '/etc/natinst/LabVIEWCLI/LabVIEWCLI.ini'
    expectedOutputPath = $expectedOutputPath
    outputExists = $true
    args = @($cliArgs)
    finishedAt = '2026-03-21T00:00:00Z'
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $captureRoot 'scenario-result.json') -Encoding utf8

  'stdout' | Set-Content -LiteralPath (Join-Path $captureRoot 'labview-cli-stdout.txt') -Encoding utf8
  'stderr' | Set-Content -LiteralPath (Join-Path $captureRoot 'labview-cli-stderr.txt') -Encoding utf8
  Write-Output 'stub run ok'
  exit 0
}

exit 0
'@ | Set-Content -LiteralPath $stubPath -Encoding utf8
      return $stubPath
    }
  }

  It 'writes a probe-ok capture from the Linux shell contract' {
    $resultsRoot = Join-Path $TestDrive 'results-probe'
    $logPath = Join-Path $TestDrive 'docker-probe.log'
    $stubPath = & $script:NewDockerStub -WorkRoot $TestDrive

    $previousOverride = $env:DOCKER_COMMAND_OVERRIDE
    $previousLog = $env:DOCKER_STUB_LOG
    $previousImageExists = $env:DOCKER_STUB_IMAGE_EXISTS
    $previousCaptureRoot = $env:DOCKER_STUB_CAPTURE_ROOT
    try {
      $env:DOCKER_COMMAND_OVERRIDE = $stubPath
      $env:DOCKER_STUB_LOG = $logPath
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $env:DOCKER_STUB_CAPTURE_ROOT = $resultsRoot

      $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
        -Probe `
        -ResultsRoot $resultsRoot *>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      $capturePath = Join-Path $resultsRoot 'ni-linux-custom-operation-capture.json'
      $capturePath | Should -Exist
      $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 12
      $capture.schema | Should -Be 'ni-linux-container-custom-operation/v1'
      $capture.status | Should -Be 'probe-ok'
      $capture.image | Should -Be 'nationalinstruments/labview:2026q1-linux'
      $capture.dockerServerOs | Should -Be 'linux'
      $capture.dockerContext | Should -Be 'desktop-linux'
      $capture.shellContract.executable | Should -Be 'bash'
      $capture.shellContract.pwshRequired | Should -BeFalse
    } finally {
      $env:DOCKER_COMMAND_OVERRIDE = $previousOverride
      $env:DOCKER_STUB_LOG = $previousLog
      $env:DOCKER_STUB_IMAGE_EXISTS = $previousImageExists
      $env:DOCKER_STUB_CAPTURE_ROOT = $previousCaptureRoot
    }
  }

  It 'uses bash and preserves additional mounts during execution' {
    $resultsRoot = Join-Path $TestDrive 'results-run'
    $operationRoot = Join-Path $TestDrive 'operation'
    $targetRepo = Join-Path $TestDrive 'target-repo'
    $logPath = Join-Path $TestDrive 'docker-run.log'
    $stubPath = & $script:NewDockerStub -WorkRoot $TestDrive
    New-Item -ItemType Directory -Path $operationRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $targetRepo -Force | Out-Null
    'placeholder' | Set-Content -LiteralPath (Join-Path $targetRepo 'Sample.vi') -Encoding utf8

    $previousOverride = $env:DOCKER_COMMAND_OVERRIDE
    $previousLog = $env:DOCKER_STUB_LOG
    $previousImageExists = $env:DOCKER_STUB_IMAGE_EXISTS
    $previousCaptureRoot = $env:DOCKER_STUB_CAPTURE_ROOT
    try {
      $env:DOCKER_COMMAND_OVERRIDE = $stubPath
      $env:DOCKER_STUB_LOG = $logPath
      $env:DOCKER_STUB_IMAGE_EXISTS = '1'
      $env:DOCKER_STUB_CAPTURE_ROOT = $resultsRoot

      $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
        -OperationName 'PrintToSingleFileHtml' `
        -AdditionalOperationDirectory $operationRoot `
        -ResultsRoot $resultsRoot `
        -AdditionalMount ('{0}::/target-repo' -f $targetRepo) `
        -ArgumentsJson '["-VI","/target-repo/Sample.vi","-OutputPath","/capture/print-output.html"]' `
        -ExpectedOutputPath '/capture/print-output.html' `
        -Headless `
        -LogToConsole *>&1
      $capturePath = Join-Path $resultsRoot 'ni-linux-custom-operation-capture.json'
      $captureDebug = if (Test-Path -LiteralPath $capturePath -PathType Leaf) { Get-Content -LiteralPath $capturePath -Raw } else { '<missing capture>' }
      $LASTEXITCODE | Should -Be 0 -Because ((($output -join "`n") + "`n" + $captureDebug))

      $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 12
      $capture.status | Should -Be 'ok'
      $capture.preview.args | Should -Contain '-VI'
      $capture.preview.args | Should -Contain '/target-repo/Sample.vi'
      $capture.scenarioResult.status | Should -Be 'succeeded'
      (Join-Path $resultsRoot 'print-output.html') | Should -Exist

      $logRecords = Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 8 }
      $runRecord = @($logRecords | Where-Object { @($_.args)[0] -eq 'run' } | Select-Object -Last 1)
      $runRecord.Count | Should -Be 1
      $runArgs = @($runRecord[0].args)
      $runArgs | Should -Contain 'bash'
      $runArgs | Should -Contain '/capture/custom-operation-runner.sh'
      (($runArgs -join ' ')) | Should -Match '/target-repo'
    } finally {
      $env:DOCKER_COMMAND_OVERRIDE = $previousOverride
      $env:DOCKER_STUB_LOG = $previousLog
      $env:DOCKER_STUB_IMAGE_EXISTS = $previousImageExists
      $env:DOCKER_STUB_CAPTURE_ROOT = $previousCaptureRoot
    }
  }
}
