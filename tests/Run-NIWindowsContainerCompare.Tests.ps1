Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Run-NIWindowsContainerCompare.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunnerScript = Join-Path $repoRoot 'tools' 'Run-NIWindowsContainerCompare.ps1'
    if (-not (Test-Path -LiteralPath $script:RunnerScript -PathType Leaf)) {
      throw "Run-NIWindowsContainerCompare.ps1 not found at $script:RunnerScript"
    }

    $script:NewDockerStub = {
      param([Parameter(Mandatory)][string]$WorkRoot)

      $binDir = Join-Path $WorkRoot 'bin'
      New-Item -ItemType Directory -Path $binDir -Force | Out-Null
      $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

      $stubPs1 = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$logPath = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_LOG')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  $record = [ordered]@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    args = @($Args)
  }
  ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $logPath -Encoding utf8
}

if ($Args.Count -eq 0) { exit 0 }

if ($Args[0] -eq 'info') {
  $osType = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_OSTYPE')
  if ([string]::IsNullOrWhiteSpace($osType)) { $osType = 'windows' }
  Write-Output $osType
  exit 0
}

if ($Args[0] -eq 'image' -and $Args.Count -ge 2 -and $Args[1] -eq 'inspect') {
  $exists = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_IMAGE_EXISTS')
  if ($exists -eq '1') {
    Write-Output '[]'
    exit 0
  }
  [Console]::Error.WriteLine('Error: No such image')
  exit 1
}

if ($Args[0] -eq 'rm') {
  Write-Output 'removed'
  exit 0
}

if ($Args[0] -eq 'run') {
  $sleepSecondsRaw = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_RUN_SLEEP_SECONDS')
  if (-not [string]::IsNullOrWhiteSpace($sleepSecondsRaw)) {
    Start-Sleep -Seconds ([int]$sleepSecondsRaw)
  }
  $stdout = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_RUN_STDOUT')
  if (-not [string]::IsNullOrWhiteSpace($stdout)) {
    Write-Output $stdout
  }
  $stderr = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_RUN_STDERR')
  if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    [Console]::Error.WriteLine($stderr)
  }
  $exitCode = 0
  $exitRaw = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_RUN_EXIT_CODE')
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
    }
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

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript -Probe 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $records = & $script:ReadDockerStubLog -Path $logPath
    (@($records | Where-Object { $_.args[0] -eq 'info' })).Count | Should -Be 1
    (@($records | Where-Object { $_.args[0] -eq 'image' -and $_.args[1] -eq 'inspect' })).Count | Should -Be 1
  }

  It 'fails probe with remediation when Docker is not in Windows container mode' {
    $work = Join-Path $TestDrive 'probe-linux-mode'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript -Probe 2>&1
    $LASTEXITCODE | Should -Not -Be 0
    ($output -join "`n") | Should -Match 'Switch Docker Desktop to Windows containers'
  }

  It 'writes deterministic capture artifacts for compare execution' {
    $work = Join-Path $TestDrive 'compare-ok'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
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
      -ReportType html `
      -Flags @('-noattr') 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    $stdoutPath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-stdout.txt'
    $stderrPath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-stderr.txt'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    Test-Path -LiteralPath $stdoutPath | Should -BeTrue
    Test-Path -LiteralPath $stderrPath | Should -BeTrue

    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.status | Should -Be 'diff'
    $capture.exitCode | Should -Be 1
    $capture.reportType | Should -Be 'html'
    $capture.reportPath | Should -Be ([System.IO.Path]::GetFullPath($reportPath))
    $capture.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
    $capture.timedOut | Should -BeFalse

    $records = & $script:ReadDockerStubLog -Path $logPath
    (@($records | Where-Object { $_.args[0] -eq 'run' })).Count | Should -Be 1
  }

  It 'injects -Headless into container compare flags by default' {
    $work = Join-Path $TestDrive 'compare-headless-default'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    $logPath = Join-Path $work 'docker-log.ndjson'
    Set-Item Env:DOCKER_STUB_LOG $logPath
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '0'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -Flags @('-noattr') 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 0

    $records = & $script:ReadDockerStubLog -Path $logPath
    $runRecord = @($records | Where-Object { $_.args[0] -eq 'run' } | Select-Object -First 1)
    $runRecord.Count | Should -Be 1
    $flags = & $script:GetFlagsFromDockerRunRecord -Record $runRecord[0]
    $flags | Should -Contain '-noattr'
    $flags | Should -Contain '-Headless'
    (@($flags | Where-Object { $_ -eq '-Headless' })).Count | Should -Be 1
  }

  It 'classifies report overwrite failures as error (not diff)' {
    $work = Join-Path $TestDrive 'compare-report-overwrite'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDERR @'
Operation output:
Report path already exists: C:\compare\m1\compare-report.html

Use -o to overwrite existing report.
CreateComparisonReport operation failed.
'@

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $work 'out\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.status | Should -Be 'error'
    $capture.classification | Should -Be 'run-error'
    $capture.message | Should -Match 'Report path already exists|overwrite existing report|operation failed'
  }

  It 'returns timeout classification with deterministic timeout exit code' {
    $work = Join-Path $TestDrive 'compare-timeout'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
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
      -TimeoutSeconds 1 2>&1
    $LASTEXITCODE | Should -Be 124 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.status | Should -Be 'timeout'
    $capture.exitCode | Should -Be 124
    $capture.timedOut | Should -BeTrue
  }
}
