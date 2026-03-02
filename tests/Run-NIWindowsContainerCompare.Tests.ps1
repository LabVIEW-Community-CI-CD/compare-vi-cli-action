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
  $failCopy = Get-StubEnvValue -Name 'DOCKER_STUB_CP_FAIL'
  if ([string]::Equals($failCopy, '1', [System.StringComparison]::OrdinalIgnoreCase)) {
    [Console]::Error.WriteLine('docker cp failed')
    exit 1
  }
  if ($Args.Count -ge 3) {
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
  exit 0
}

if ($Args[0] -eq 'rm') {
  Write-Output 'removed'
  exit 0
}

if ($Args[0] -eq 'run') {
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
      $env:DOCKER_COMMAND_OVERRIDE = (Join-Path $binDir 'docker.cmd')
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
      DOCKER_STUB_CONTEXT           = $env:DOCKER_STUB_CONTEXT
      DOCKER_STUB_CP_REPORT_HTML    = $env:DOCKER_STUB_CP_REPORT_HTML
      DOCKER_STUB_CP_FAIL           = $env:DOCKER_STUB_CP_FAIL
      DOCKER_COMMAND_OVERRIDE       = $env:DOCKER_COMMAND_OVERRIDE
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

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -ReportType html `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
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
    $capture.resultClass | Should -Be 'success-diff'
    $capture.isDiff | Should -BeTrue
    $capture.gateOutcome | Should -Be 'pass'
    $capture.failureClass | Should -Be 'none'
    $capture.diffEvidenceSource | Should -Be 'exit-code'
    $capture.reportType | Should -Be 'html'
    $capture.reportPath | Should -Be ([System.IO.Path]::GetFullPath($reportPath))
    $capture.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
    $capture.timedOut | Should -BeFalse
    $capture.headlessContract.required | Should -BeTrue
    $capture.headlessContract.enforcedCliHeadless | Should -BeTrue
    $capture.headlessContract.lvRteHeadlessEnv | Should -BeTrue
    $capture.runtimeDeterminism.status | Should -Match 'ok|mismatch-repaired'
    $capture.startupMitigation | Should -Not -BeNullOrEmpty
    $capture.reportAnalysis.source | Should -Be 'container-export'
    $capture.containerArtifacts.copyStatus | Should -Be 'success'
    $capture.containerArtifacts.exportDir | Should -Not -BeNullOrEmpty
    $capture.containerArtifacts.copiedPaths.Count | Should -BeGreaterThan 0

    $records = & $script:ReadDockerStubLog -Path $logPath
    $cpRecords = @($records | Where-Object { $_.args[0] -eq 'cp' })
    $rmRecords = @($records | Where-Object { $_.args[0] -eq 'rm' -and $_.args[1] -eq '-f' })
    $cpRecords.Count | Should -BeGreaterThan 0
    $rmRecords.Count | Should -Be 1
    $cpIndex = [array]::IndexOf($records, $cpRecords[0])
    $rmIndex = [array]::IndexOf($records, $rmRecords[0])
    $cpIndex | Should -BeLessThan $rmIndex
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
    Set-Item Env:DOCKER_STUB_RUN_STDERR 'Error code: -350000'
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


