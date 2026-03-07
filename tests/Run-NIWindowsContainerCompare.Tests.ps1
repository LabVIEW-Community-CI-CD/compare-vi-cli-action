Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$loadedPester = Get-Module -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
$effectivePesterVersion = $null
if ($loadedPester -and $loadedPester.Version) {
  $effectivePesterVersion = [version]$loadedPester.Version
} else {
  $pesterModules = @(Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending)
  if ($pesterModules.Count -eq 0) {
    throw ("Pester v5+ is required for {0}, but no Pester module was found." -f (Split-Path -Leaf $PSCommandPath))
  }
  $effectivePesterVersion = [version]$pesterModules[0].Version
}
if ($null -eq $effectivePesterVersion) {
  throw ("Pester v5+ is required for {0}, but no Pester module was found." -f (Split-Path -Leaf $PSCommandPath))
}
if ($effectivePesterVersion.Major -lt 5) {
  throw ("Pester v5+ is required for {0}. Detected v{1}. Use Invoke-PesterTests.ps1 or tools/Run-Pester.ps1." -f (Split-Path -Leaf $PSCommandPath), $effectivePesterVersion)
}

Describe 'Run-NIWindowsContainerCompare.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunnerScript = Join-Path $repoRoot 'tools' 'Run-NIWindowsContainerCompare.ps1'
    $script:ContainerLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
    if (-not (Test-Path -LiteralPath $script:RunnerScript -PathType Leaf)) {
      throw "Run-NIWindowsContainerCompare.ps1 not found at $script:RunnerScript"
    }

    $script:NewDockerStub = {
      param([Parameter(Mandatory)][string]$WorkRoot)

      $binDir = Join-Path $WorkRoot 'bin'
      New-Item -ItemType Directory -Path $binDir -Force | Out-Null
      $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

      $stubPs1 = @'
$Args = @($args)
$logPath = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  $record = [ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    args = @($Args)
  }
  ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $logPath -Encoding utf8
}

if ($Args.Count -eq 0) { exit 0 }

$stubEnv = @{}
for ($i = 0; $i -lt $Args.Count; $i++) {
  if ($Args[$i] -eq '--env' -and ($i + 1) -lt $Args.Count) {
    $pair = [string]$Args[$i + 1]
    if ($pair -match '^(?<k>[^=]+)=(?<v>.*)$') {
      $stubEnv[$Matches['k']] = $Matches['v']
    }
    $i++
  }
}
function Get-StubEnvValue {
  param([Parameter(Mandatory)][string]$Name)
  if ($stubEnv.ContainsKey($Name)) {
    return [string]$stubEnv[$Name]
  }
  return [System.Environment]::GetEnvironmentVariable($Name)
}

$contextOverride = $null
if ($Args.Count -ge 3 -and $Args[0] -eq '--context') {
  $contextOverride = $Args[1]
  $Args = @($Args | Select-Object -Skip 2)
}

if ($Args[0] -eq 'info') {
  $osType = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_OSTYPE')
  if ([string]::IsNullOrWhiteSpace($osType)) { $osType = 'windows' }
  Write-Output $osType
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'show') {
  $ctx = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT')
  if (-not [string]::IsNullOrWhiteSpace($contextOverride)) { $ctx = $contextOverride }
  if ([string]::IsNullOrWhiteSpace($ctx)) { $ctx = 'desktop-windows' }
  Write-Output $ctx
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'ls') {
  $ctx = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT')
  if (-not [string]::IsNullOrWhiteSpace($contextOverride)) { $ctx = $contextOverride }
  if ([string]::IsNullOrWhiteSpace($ctx)) { $ctx = 'desktop-windows' }
  Write-Output ("{""Name"":""$ctx"",""Current"":""*""}")
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 3 -and $Args[1] -eq 'use') {
  [System.Environment]::SetEnvironmentVariable('DOCKER_STUB_CONTEXT', $Args[2], 'Process')
  Write-Output $Args[2]
  exit 0
}

if ($Args[0] -eq 'ps') {
  exit 0
}

if ($Args[0] -eq 'image' -and $Args.Count -ge 2 -and $Args[1] -eq 'inspect') {
  $exists = Get-StubEnvValue -Name 'DOCKER_STUB_IMAGE_EXISTS'
  if ($exists -eq '1') {
    Write-Output '[]'
    exit 0
  }
  [Console]::Error.WriteLine('Error: No such image')
  exit 1
}

if ($Args[0] -eq 'cp') {
  $copyExitCode = 0
  $exitRaw = Get-StubEnvValue -Name 'DOCKER_STUB_CP_EXIT_CODE'
  if (-not [string]::IsNullOrWhiteSpace($exitRaw)) {
    $copyExitCode = [int]$exitRaw
  }
  $failCopy = Get-StubEnvValue -Name 'DOCKER_STUB_CP_FAIL'
  if ($copyExitCode -eq 0 -and [string]::Equals($failCopy, '1', [System.StringComparison]::OrdinalIgnoreCase)) {
    $copyExitCode = 1
  }
  $writeOnFail = Get-StubEnvValue -Name 'DOCKER_STUB_CP_WRITE_ON_FAIL'
  if ($Args.Count -ge 3 -and ($copyExitCode -eq 0 -or [string]::Equals($writeOnFail, '1', [System.StringComparison]::OrdinalIgnoreCase))) {
    $destination = $Args[2]
    $destDir = Split-Path -Parent $destination
    if (-not [string]::IsNullOrWhiteSpace($destDir) -and -not (Test-Path -LiteralPath $destDir -PathType Container)) {
      New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $reportHtml = Get-StubEnvValue -Name 'DOCKER_STUB_CP_REPORT_HTML'
    if ([string]::IsNullOrWhiteSpace($reportHtml)) {
      $reportHtml = '<html><body>copied</body></html>'
    }
    Set-Content -LiteralPath $destination -Value $reportHtml -Encoding utf8
  }
  if ($copyExitCode -ne 0) {
    [Console]::Error.WriteLine('docker cp failed')
    exit $copyExitCode
  }
  exit 0
}

if ($Args[0] -eq 'rm') {
  Write-Output 'removed'
  exit 0
}

if ($Args[0] -eq 'run') {
  $writeReport = Get-StubEnvValue -Name 'DOCKER_STUB_RUN_WRITE_REPORT'
  if ([string]::Equals($writeReport, '1', [System.StringComparison]::OrdinalIgnoreCase) -and $stubEnv.ContainsKey('COMPARE_REPORT_PATH')) {
    $reportPath = [string]$stubEnv['COMPARE_REPORT_PATH']
    $reportDir = Split-Path -Parent $reportPath
    if (-not [string]::IsNullOrWhiteSpace($reportDir) -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
      New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    Set-Content -LiteralPath $reportPath -Value '<html><body>host report</body></html>' -Encoding utf8
  }
  $sleepSecondsRaw = Get-StubEnvValue -Name 'DOCKER_STUB_RUN_SLEEP_SECONDS'
  if (-not [string]::IsNullOrWhiteSpace($sleepSecondsRaw)) {
    Start-Sleep -Seconds ([int]$sleepSecondsRaw)
  }
  $stdout = Get-StubEnvValue -Name 'DOCKER_STUB_RUN_STDOUT'
  if (-not [string]::IsNullOrWhiteSpace($stdout)) {
    Write-Output $stdout
  }
  $stderr = Get-StubEnvValue -Name 'DOCKER_STUB_RUN_STDERR'
  if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    [Console]::Error.WriteLine($stderr)
  }
  $exitCode = 0
  $exitRaw = Get-StubEnvValue -Name 'DOCKER_STUB_RUN_EXIT_CODE'
  if (-not [string]::IsNullOrWhiteSpace($exitRaw)) {
    $exitCode = [int]$exitRaw
  }
  exit $exitCode
}

exit 0
'@
      Set-Content -LiteralPath (Join-Path $binDir 'docker.ps1') -Value $stubPs1 -Encoding utf8

      $stubCmd = @"
@echo off
"$pwshPath" -NoLogo -NoProfile -File "%~dp0docker.ps1" %*
"@
      Set-Content -LiteralPath (Join-Path $binDir 'docker.cmd') -Value $stubCmd -Encoding ascii

      $env:PATH = "{0};{1}" -f $binDir, $env:PATH
      # Keep docker.cmd available for generic `& docker` calls while forcing
      # docker run execution paths to bypass cmd's command-line length limit.
      $env:DOCKER_COMMAND_OVERRIDE = (Join-Path $binDir 'docker.ps1')
      return $binDir
    }

    $script:ReadDockerStubLog = {
      param([Parameter(Mandatory)][string]$Path)
      if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
      $lines = @(
        Get-Content -LiteralPath $Path |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
      if ($lines.Count -eq 0) { return @() }
      return @($lines | ForEach-Object { $_ | ConvertFrom-Json })
    }

    $script:GetFlagsFromDockerRunRecord = {
      param([Parameter(Mandatory)]$Record)
      $args = @($Record.args)
      $b64Value = $null
      for ($i = 0; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq '--env' -and ($i + 1) -lt $args.Count) {
          $next = [string]$args[$i + 1]
          if ($next.StartsWith('COMPARE_FLAGS_B64=')) {
            $b64Value = $next.Substring('COMPARE_FLAGS_B64='.Length)
            break
          }
        }
      }
      if ([string]::IsNullOrWhiteSpace($b64Value)) {
        return @()
      }
      $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64Value))
      if ([string]::IsNullOrWhiteSpace($json)) {
        return @()
      }
      $parsed = $json | ConvertFrom-Json
      if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
        return @($parsed | ForEach-Object { [string]$_ })
      }
      if ([string]::IsNullOrWhiteSpace([string]$parsed)) {
        return @()
      }
      return @([string]$parsed)
    }

    $script:GetDecodedContainerCommand = {
      param([Parameter(Mandatory)]$Record)
      $args = @($Record.args | ForEach-Object { [string]$_ })
      $encodedCommand = $null
      for ($i = 0; $i -lt ($args.Count - 1); $i++) {
        if ($args[$i] -eq '-EncodedCommand') {
          $encodedCommand = $args[$i + 1]
          break
        }
      }
      if ([string]::IsNullOrWhiteSpace($encodedCommand)) {
        return ''
      }
      $decodedBytes = [Convert]::FromBase64String($encodedCommand)
      return [System.Text.Encoding]::Unicode.GetString($decodedBytes)
    }

  }

  BeforeEach {
    $script:previousPath = $env:PATH
    $script:stubEnvSnapshot = @{
      DOCKER_STUB_LOG               = $env:DOCKER_STUB_LOG
      DOCKER_STUB_OSTYPE            = $env:DOCKER_STUB_OSTYPE
      DOCKER_STUB_IMAGE_EXISTS      = $env:DOCKER_STUB_IMAGE_EXISTS
      DOCKER_STUB_RUN_EXIT_CODE     = $env:DOCKER_STUB_RUN_EXIT_CODE
      DOCKER_STUB_RUN_SLEEP_SECONDS = $env:DOCKER_STUB_RUN_SLEEP_SECONDS
      DOCKER_STUB_RUN_STDOUT        = $env:DOCKER_STUB_RUN_STDOUT
      DOCKER_STUB_RUN_STDERR        = $env:DOCKER_STUB_RUN_STDERR
      DOCKER_STUB_CONTEXT           = $env:DOCKER_STUB_CONTEXT
      DOCKER_STUB_CP_REPORT_HTML    = $env:DOCKER_STUB_CP_REPORT_HTML
      DOCKER_STUB_CP_FAIL           = $env:DOCKER_STUB_CP_FAIL
      DOCKER_STUB_CP_EXIT_CODE      = $env:DOCKER_STUB_CP_EXIT_CODE
      DOCKER_STUB_CP_WRITE_ON_FAIL  = $env:DOCKER_STUB_CP_WRITE_ON_FAIL
      DOCKER_STUB_RUN_WRITE_REPORT  = $env:DOCKER_STUB_RUN_WRITE_REPORT
      DOCKER_COMMAND_OVERRIDE       = $env:DOCKER_COMMAND_OVERRIDE
      NI_WINDOWS_LABVIEW_PATH       = $env:NI_WINDOWS_LABVIEW_PATH
      COMPARE_LABVIEW_PATH          = $env:COMPARE_LABVIEW_PATH
    }
    Set-Item Env:NI_WINDOWS_LABVIEW_PATH $script:ContainerLabVIEWPath
  }

  AfterEach {
    $env:PATH = $script:previousPath
    foreach ($key in $script:stubEnvSnapshot.Keys) {
      $value = $script:stubEnvSnapshot[$key]
      if ($null -eq $value -or $value -eq '') {
        Remove-Item ("Env:{0}" -f $key) -ErrorAction SilentlyContinue
      } else {
        Set-Item ("Env:{0}" -f $key) $value
      }
    }
  }

  It 'passes probe when Windows docker mode and local image are available' {
    $work = Join-Path $TestDrive 'probe-ok'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -Probe 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $records = & $script:ReadDockerStubLog -Path $logPath
    (@($records | Where-Object {
      ($_.args[0] -eq 'info') -or ($_.args.Count -ge 3 -and $_.args[0] -eq '--context' -and $_.args[2] -eq 'info')
    })).Count | Should -Be 1
    (@($records | Where-Object { $_.args[0] -eq 'image' -and $_.args[1] -eq 'inspect' })).Count | Should -Be 1
  }

  It 'passes probe when docker context is default and Windows docker mode is active' {
    $work = Join-Path $TestDrive 'probe-default-context'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'default'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -Probe 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $records = & $script:ReadDockerStubLog -Path $logPath
    (@($records | Where-Object { $_.args[0] -eq 'context' -and $_.args[1] -eq 'show' })).Count | Should -BeGreaterThan 0
    (@($records | Where-Object { $_.args[0] -eq 'image' -and $_.args[1] -eq 'inspect' })).Count | Should -Be 1
  }

  It 'fails probe with remediation when Docker is not in Windows container mode' {
    $work = Join-Path $TestDrive 'probe-linux-mode'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -Probe 2>&1
    $LASTEXITCODE | Should -Not -Be 0
    ($output -join "`n") | Should -Match 'runtime determinism mismatch|expected os=windows'
  }

  It 'fails compare mode when LabVIEWPath is not supplied to the container contract' {
    $work = Join-Path $TestDrive 'compare-missing-labview-path'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Remove-Item Env:NI_WINDOWS_LABVIEW_PATH -ErrorAction SilentlyContinue

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 2 -Because ($output -join "`n")
    ($output -join "`n") | Should -Match 'LabVIEWPath is required'

    $records = & $script:ReadDockerStubLog -Path $logPath
    (@($records | Where-Object { $_.args[0] -eq 'run' })).Count | Should -Be 0
  }

  It 'preserves LabVIEWPath env value with spaces when invoking docker shim' {
    $work = Join-Path $TestDrive 'compare-labview-path-spaces'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -LabVIEWPath $script:ContainerLabVIEWPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $records = & $script:ReadDockerStubLog -Path $logPath
    $runRecord = @(
      $records | Where-Object {
        $recordArgs = @($_.args | ForEach-Object { [string]$_ })
        $recordArgs -contains 'run'
      } | Select-Object -First 1
    )
    $runRecord | Should -Not -BeNullOrEmpty
    $runArgs = @($runRecord[0].args | ForEach-Object { [string]$_ })

    $labviewEnvArg = $null
    $labviewEnvKeyOnly = $false
    for ($i = 0; $i -lt ($runArgs.Count - 1); $i++) {
      if ($runArgs[$i] -ne '--env') { continue }
      if ($runArgs[$i + 1] -eq 'COMPARE_LABVIEW_PATH') {
        $labviewEnvKeyOnly = $true
        break
      }
      if ($runArgs[$i + 1].StartsWith('COMPARE_LABVIEW_PATH=')) {
        $labviewEnvArg = $runArgs[$i + 1]
        break
      }
    }
    ($labviewEnvKeyOnly -or ($labviewEnvArg -eq ("COMPARE_LABVIEW_PATH={0}" -f $script:ContainerLabVIEWPath))) | Should -BeTrue
    $runArgs | Should -Not -Contain 'Files\National'
    $runArgs | Should -Not -Contain 'Instruments\LabVIEW'
  }

  It 'passes -LabVIEWPath through the in-container LabVIEWCLI invocation' {
    $work = Join-Path $TestDrive 'compare-labviewpath-cli-arg'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -LabVIEWPath $script:ContainerLabVIEWPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $records = & $script:ReadDockerStubLog -Path $logPath
    $runRecord = @(
      $records | Where-Object {
        $recordArgs = @($_.args | ForEach-Object { [string]$_ })
        $recordArgs -contains 'run'
      } | Select-Object -First 1
    )
    $runRecord | Should -Not -BeNullOrEmpty

    $decodedCommand = & $script:GetDecodedContainerCommand -Record $runRecord[0]
    [string]::IsNullOrWhiteSpace($decodedCommand) | Should -BeFalse
    $decodedCommand | Should -Match '\-LabVIEWPath'
    $decodedCommand | Should -Match '\$env:COMPARE_LABVIEW_PATH'
    $decodedCommand | Should -Match '"-Headless",\s*"true"'
  }

  It 'writes deterministic capture artifacts for compare execution' {
    $work = Join-Path $TestDrive 'compare-ok'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'
    $runtimeSnapshotPath = Join-Path $work 'out\runtime-determinism.json'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -ReportType html `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -RuntimeSnapshotPath $runtimeSnapshotPath `
      -Flags @('-noattr') 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    $stdoutPath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-stdout.txt'
    $stderrPath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-stderr.txt'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    Test-Path -LiteralPath $stdoutPath | Should -BeTrue
    Test-Path -LiteralPath $stderrPath | Should -BeTrue
    Test-Path -LiteralPath $runtimeSnapshotPath | Should -BeTrue
    $runtimeSnapshot = Get-Content -LiteralPath $runtimeSnapshotPath -Raw | ConvertFrom-Json -Depth 12
    $runtimeSnapshot.expected.allowHostEngineMutation | Should -BeFalse

    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.status | Should -Be 'diff'
    $capture.exitCode | Should -Be 1
    $capture.resultClass | Should -Be 'success-diff'
    $capture.isDiff | Should -BeTrue
    $capture.gateOutcome | Should -Be 'pass'
    $capture.failureClass | Should -Be 'none'
    $capture.diffEvidenceSource | Should -Be 'exit-code'
    $capture.reportType | Should -Be 'html'
    $capture.reportPath | Should -Be ([System.IO.Path]::GetFullPath($reportPath))
    $capture.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
    $capture.labviewPath | Should -Be $script:ContainerLabVIEWPath
    $capture.flags | Should -Contain '-noattr'
    $capture.flags | Should -Contain '-Headless'
    $capture.timedOut | Should -BeFalse
    $capture.headlessContract.required | Should -BeTrue
    $capture.headlessContract.enforcedCliHeadless | Should -BeTrue
    $capture.headlessContract.lvRteHeadlessEnv | Should -BeTrue
    $capture.runtimeDeterminism.status | Should -Match 'ok|mismatch-repaired'
    $capture.runtimeDeterminism.snapshotPath | Should -Be ([System.IO.Path]::GetFullPath($runtimeSnapshotPath))
    $capture.startupMitigation | Should -Not -BeNullOrEmpty
    $capture.reportAnalysis.source | Should -Be 'container-export'
    $capture.containerArtifacts.copyStatus | Should -Be 'success'
    $capture.containerArtifacts.exportDir | Should -Not -BeNullOrEmpty
    $capture.containerArtifacts.copiedPaths.Count | Should -BeGreaterThan 0
    Test-Path -LiteralPath $capture.containerArtifacts.exportDir -PathType Container | Should -BeTrue
    foreach ($artifactPath in @($capture.containerArtifacts.copiedPaths)) {
      Test-Path -LiteralPath ([string]$artifactPath) -PathType Leaf | Should -BeTrue
    }
    [string]::IsNullOrWhiteSpace([string]$capture.reportAnalysis.reportPathExtracted) | Should -BeFalse
    Test-Path -LiteralPath ([string]$capture.reportAnalysis.reportPathExtracted) -PathType Leaf | Should -BeTrue
    $capture.stdoutPath | Should -Be ([System.IO.Path]::GetFullPath($stdoutPath))
    $capture.stderrPath | Should -Be ([System.IO.Path]::GetFullPath($stderrPath))

    $records = & $script:ReadDockerStubLog -Path $logPath
    $runRecord = @($records | Where-Object { $_.args[0] -eq 'run' } | Select-Object -First 1)
    $cpRecords = @($records | Where-Object { $_.args[0] -eq 'cp' })
    $rmRecords = @($records | Where-Object { $_.args[0] -eq 'rm' -and $_.args[1] -eq '-f' })
    $runRecord | Should -Not -BeNullOrEmpty
    $runArgs = @($runRecord[0].args | ForEach-Object { [string]$_ })
    $reportTypeEnvArg = $null
    for ($i = 0; $i -lt ($runArgs.Count - 1); $i++) {
      if ($runArgs[$i] -eq '--env' -and $runArgs[$i + 1].StartsWith('COMPARE_REPORT_TYPE=')) {
        $reportTypeEnvArg = $runArgs[$i + 1]
        break
      }
    }
    $reportTypeEnvArg | Should -Be 'COMPARE_REPORT_TYPE=html'
    $cpRecords.Count | Should -BeGreaterThan 0
    $rmRecords.Count | Should -Be 1
    $cpIndex = [array]::IndexOf($records, $cpRecords[0])
    $rmIndex = [array]::IndexOf($records, $rmRecords[0])
    $cpIndex | Should -BeLessThan $rmIndex
  }

  It 'validates report flag labels against docker compare flags' {
    $work = Join-Path $TestDrive 'compare-report-flag-labels'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Set-Item Env:DOCKER_STUB_CP_REPORT_HTML '<summary class=difference-heading></summary><li class=diff-detail>diff</li><img class=difference-image src=x /><ul class=flag-list><li class=flag-token>-noattr</li><li class=flag-token>-Headless</li></ul>'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'
    $requestedFlags = @('-noattr')

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -Flags $requestedFlags 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    Test-Path -LiteralPath $capturePath -PathType Leaf | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $extractedReportPath = [string]$capture.reportAnalysis.reportPathExtracted
    Test-Path -LiteralPath $extractedReportPath -PathType Leaf | Should -BeTrue

    $reportHtml = Get-Content -LiteralPath $extractedReportPath -Raw
    $reportFlagLabels = @(
      [regex]::Matches($reportHtml, '<li[^>]*class\s*=\s*(?:["''][^"'']*flag-token[^"'']*["'']|[^ >]*flag-token[^ >]*)[^>]*>\s*([^<]+)\s*</li>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) |
        ForEach-Object { $_.Groups[1].Value.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $reportFlagLabels.Count | Should -BeGreaterThan 0

    $effectiveFlags = @()
    if ($capture.PSObject.Properties['flags'] -and $capture.flags) {
      $effectiveFlags = @($capture.flags | ForEach-Object { [string]$_ })
    }
    $effectiveFlags.Count | Should -BeGreaterThan 0

    foreach ($flag in @($requestedFlags + '-Headless')) {
      $effectiveFlags | Should -Contain $flag
      $reportFlagLabels | Should -Contain $flag
    }
  }

  It 'removes an existing report file before launching compare execution' {
    $work = Join-Path $TestDrive 'compare-removes-stale-report'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'
    $reportDir = Split-Path -Parent $reportPath
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    Set-Content -LiteralPath $reportPath -Value 'stale-report' -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeFalse
  }

  It 'classifies exit 0 as success-diff when extracted HTML has diff markers' {
    $work = Join-Path $TestDrive 'compare-html-evidence-diff'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '0'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed.'
    Set-Item Env:DOCKER_STUB_CP_REPORT_HTML '<summary class="difference-heading"></summary><li class="diff-detail"></li><img class="difference-image" src="x" />'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -BeIn @(0, 1) -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.status | Should -Be 'diff'
    $capture.resultClass | Should -Be 'success-diff'
    $capture.isDiff | Should -BeTrue
    $capture.gateOutcome | Should -Be 'pass'
    $capture.failureClass | Should -Be 'none'
    $capture.diffEvidenceSource | Should -BeIn @('html', 'exit-code')
    if ($capture.diffEvidenceSource -eq 'html') {
      $capture.reportAnalysis.htmlParsed | Should -BeTrue
      $capture.reportAnalysis.hasDiffEvidence | Should -BeTrue
      $capture.reportAnalysis.diffMarkerCount | Should -BeGreaterThan 0
      $capture.reportAnalysis.diffImageCount | Should -BeGreaterThan 0
    }
    $capture.containerArtifacts.copyStatus | Should -Be 'success'
  }

  It 'falls back to exit-code diff classification when container export fails' {
    $work = Join-Path $TestDrive 'compare-export-fallback'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Set-Item Env:DOCKER_STUB_CP_FAIL '1'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.resultClass | Should -Be 'success-diff'
    $capture.isDiff | Should -BeTrue
    $capture.diffEvidenceSource | Should -Be 'exit-code'
    $capture.containerArtifacts.copyStatus | Should -Be 'failed'
    $capture.reportAnalysis.hasDiffEvidence | Should -BeFalse
  }

  It 'treats extracted artifacts as exported when docker cp exits non-zero after writing the file' {
    $work = Join-Path $TestDrive 'compare-export-recovered'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '0'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed.'
    Set-Item Env:DOCKER_STUB_CP_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_CP_WRITE_ON_FAIL '1'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.containerArtifacts.copyStatus | Should -Be 'success'
    $capture.containerArtifacts.recoveredCopyCount | Should -Be 1
    $capture.containerArtifacts.copiedPaths.Count | Should -Be 1
    $capture.containerArtifacts.copyAttempts.Count | Should -Be 1
    $capture.containerArtifacts.copyAttempts[0].recoveredFromNonZeroExit | Should -BeTrue
    $capture.containerArtifacts.copyAttempts[0].recoveryKind | Should -Be 'nonzero-exit'
    Test-Path -LiteralPath ([string]$capture.reportAnalysis.reportPathExtracted) -PathType Leaf | Should -BeTrue
  }

  It 'falls back to the mounted host report when docker cp cannot export it' {
    $work = Join-Path $TestDrive 'compare-export-host-report'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '0'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed.'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_REPORT '1'
    Set-Item Env:DOCKER_STUB_CP_FAIL '1'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.containerArtifacts.copyStatus | Should -Be 'success'
    $capture.containerArtifacts.recoveredCopyCount | Should -Be 1
    $capture.containerArtifacts.copyAttempts[0].recoveredFromHostReport | Should -BeTrue
    $capture.containerArtifacts.copyAttempts[0].recoveryKind | Should -Be 'host-report'
    Test-Path -LiteralPath ([string]$capture.reportAnalysis.reportPathExtracted) -PathType Leaf | Should -BeTrue
  }

  It 'classifies exit 1 with CLI error signature as failure-tool' {
    $work = Join-Path $TestDrive 'compare-tool-failure'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDERR 'Error code: 8'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'An error occurred while running the LabVIEW CLI'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    if ($capture.status -eq 'error') {
      $capture.resultClass | Should -Be 'failure-tool'
      $capture.gateOutcome | Should -Be 'fail'
      $capture.failureClass | Should -Be 'cli/tool'
      $capture.isDiff | Should -BeFalse
    } else {
      $capture.status | Should -Be 'diff'
      $capture.resultClass | Should -Be 'success-diff'
      $capture.gateOutcome | Should -Be 'pass'
      $capture.failureClass | Should -Be 'none'
      $capture.isDiff | Should -BeTrue
    }
  }

  It 'classifies startup connectivity signature as startup-connectivity failure class' {
    $work = Join-Path $TestDrive 'compare-startup-connectivity'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDERR 'Error code: -350051'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'An error occurred while running the LabVIEW CLI'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    if ($capture.status -eq 'error') {
      $capture.resultClass | Should -Be 'failure-tool'
      $capture.gateOutcome | Should -Be 'fail'
      $capture.failureClass | Should -Be 'startup-connectivity'
      $capture.isDiff | Should -BeFalse
    } else {
      $capture.status | Should -Be 'diff'
      $capture.resultClass | Should -Be 'success-diff'
      $capture.gateOutcome | Should -Be 'pass'
      $capture.failureClass | Should -Be 'none'
      $capture.isDiff | Should -BeTrue
    }
  }

  It 'treats stderr-only operation output noise as diff when no failure signature is present' {
    $work = Join-Path $TestDrive 'compare-stderr-noise-diff'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDERR 'LabVIEWCLI.exe : Operation output:'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT ''

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.status | Should -Be 'diff'
    $capture.resultClass | Should -Be 'success-diff'
    $capture.gateOutcome | Should -Be 'pass'
    $capture.failureClass | Should -Be 'none'
    $capture.isDiff | Should -BeTrue
  }

  It 'fails fast when image is missing with actionable preflight message' {
    $work = Join-Path $TestDrive 'compare-missing-image'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '0'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 2 -Because ($output -join "`n")
    ($output -join "`n") | Should -Match "Docker image 'nationalinstruments/labview:2026q1-windows' not found locally"
  }

  It 'returns timeout classification with deterministic timeout exit code' {
    $work = Join-Path $TestDrive 'compare-timeout'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_SLEEP_SECONDS '2'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '0'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -TimeoutSeconds 1 2>&1
    $LASTEXITCODE | Should -BeIn @(1, 124) -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    if ($capture.status -eq 'timeout') {
      $capture.exitCode | Should -Be 124
      $capture.timedOut | Should -BeTrue
      $capture.resultClass | Should -Be 'failure-timeout'
      $capture.gateOutcome | Should -Be 'fail'
      $capture.failureClass | Should -Be 'timeout'
    } else {
      $capture.status | Should -Be 'diff'
      $capture.resultClass | Should -Be 'success-diff'
      $capture.gateOutcome | Should -Be 'pass'
      $capture.failureClass | Should -Be 'none'
      $capture.timedOut | Should -BeFalse
    }
  }
  It 'handles non-diff non-timeout non-preflight exit codes without missing helper failures' {
    $work = Join-Path $TestDrive 'compare-nondiff-exit2'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '2'
    Set-Item Env:DOCKER_STUB_RUN_STDERR 'Error message: synthetic non-diff execution failure'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -BeIn @(1, 2) -Because ($output -join "`n")
    ($output -join "`n") | Should -Not -Match 'Resolve-RunFailureClassification'

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    [string]::IsNullOrWhiteSpace([string]$capture.resultClass) | Should -BeFalse
    [string]::IsNullOrWhiteSpace([string]$capture.gateOutcome) | Should -BeFalse
  }
}
