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

Describe 'Run-NILinuxContainerCompare.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RepoRoot = $repoRoot
    $script:RunnerScript = Join-Path $repoRoot 'tools' 'Run-NILinuxContainerCompare.ps1'
    if (-not (Test-Path -LiteralPath $script:RunnerScript -PathType Leaf)) {
      throw "Run-NILinuxContainerCompare.ps1 not found at $script:RunnerScript"
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
    if ($spec -match '^(?<host>.+):(?<container>/.*)$') {
      $volumeMap += [pscustomobject]@{
        host = [string]$Matches['host']
        container = ([string]$Matches['container']).TrimEnd('/')
      }
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
function Resolve-StubHostPathFromContainerPath {
  param([Parameter(Mandatory)][string]$ContainerPath)

  $normalizedContainerPath = $ContainerPath.Replace('\', '/')
  foreach ($mapping in $volumeMap) {
    $containerRoot = [string]$mapping.container
    if ([string]::IsNullOrWhiteSpace($containerRoot)) {
      continue
    }
    $normalizedRoot = $containerRoot.Replace('\', '/')
    if ($normalizedContainerPath -eq $normalizedRoot) {
      return [string]$mapping.host
    }
    $prefix = '{0}/' -f $normalizedRoot.TrimEnd('/')
    if ($normalizedContainerPath.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
      $relative = $normalizedContainerPath.Substring($prefix.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
      return (Join-Path ([string]$mapping.host) $relative)
    }
  }
  return $ContainerPath
}

$contextOverride = $null
if ($Args.Count -ge 3 -and $Args[0] -eq '--context') {
  $contextOverride = $Args[1]
  $Args = @($Args | Select-Object -Skip 2)
}

if ($Args[0] -eq 'info') {
  $infoJson = Get-StubEnvValue -Name 'DOCKER_STUB_INFO_JSON'
  if ($Args -contains '{{json .}}' -and -not [string]::IsNullOrWhiteSpace($infoJson)) {
    Write-Output $infoJson
    exit 0
  }
  $osType = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_OSTYPE')
  if ([string]::IsNullOrWhiteSpace($osType)) { $osType = 'linux' }
  Write-Output $osType
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'show') {
  $ctx = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT')
  if (-not [string]::IsNullOrWhiteSpace($contextOverride)) { $ctx = $contextOverride }
  if ([string]::IsNullOrWhiteSpace($ctx)) { $ctx = 'desktop-linux' }
  Write-Output $ctx
  exit 0
}

if ($Args[0] -eq 'context' -and $Args.Count -ge 2 -and $Args[1] -eq 'ls') {
  $ctx = [System.Environment]::GetEnvironmentVariable('DOCKER_STUB_CONTEXT')
  if (-not [string]::IsNullOrWhiteSpace($contextOverride)) { $ctx = $contextOverride }
  if ([string]::IsNullOrWhiteSpace($ctx)) { $ctx = 'desktop-linux' }
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

if ($Args[0] -eq 'inspect' -and $Args.Count -ge 2) {
  $inspectJson = Get-StubEnvValue -Name 'DOCKER_STUB_CONTAINER_INSPECT_JSON'
  if (-not [string]::IsNullOrWhiteSpace($inspectJson)) {
    Write-Output $inspectJson
    exit 0
  }
  [Console]::Error.WriteLine('Error: No such container')
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
  $writeVisibleArtifactOnFailure = (
    $Args.Count -ge 3 -and
    $copyExitCode -ne 0 -and
    [string]::Equals((Get-StubEnvValue -Name 'DOCKER_STUB_RUN_WRITE_REPORT'), '1', [System.StringComparison]::OrdinalIgnoreCase)
  )
  if (
    $Args.Count -ge 3 -and
    (
      $copyExitCode -eq 0 -or
      [string]::Equals($writeOnFail, '1', [System.StringComparison]::OrdinalIgnoreCase) -or
      $writeVisibleArtifactOnFailure
    )
  ) {
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
    $copyStdErr = Get-StubEnvValue -Name 'DOCKER_STUB_CP_STDERR'
    if ([string]::IsNullOrWhiteSpace($copyStdErr)) {
      $copyStdErr = 'docker cp failed'
    }
    [Console]::Error.WriteLine($copyStdErr)
    exit $copyExitCode
  }
  exit 0
}

if ($Args[0] -eq 'rm') {
  $rmExitRaw = Get-StubEnvValue -Name 'DOCKER_STUB_RM_EXIT_CODE'
  if (-not [string]::IsNullOrWhiteSpace($rmExitRaw)) {
    $rmExitCode = [int]$rmExitRaw
    if ($rmExitCode -ne 0) {
      $rmStdErr = Get-StubEnvValue -Name 'DOCKER_STUB_RM_STDERR'
      if ([string]::IsNullOrWhiteSpace($rmStdErr)) {
        $rmStdErr = 'docker rm failed'
      }
      [Console]::Error.WriteLine($rmStdErr)
      exit $rmExitCode
    }
  }
  Write-Output 'removed'
  exit 0
}

if ($Args[0] -eq 'run') {
  $plannedExitCode = 0
  $plannedExitRaw = Get-StubEnvValue -Name 'DOCKER_STUB_RUN_EXIT_CODE'
  if (-not [string]::IsNullOrWhiteSpace($plannedExitRaw)) {
    $plannedExitCode = [int]$plannedExitRaw
  }
  $writeReport = Get-StubEnvValue -Name 'DOCKER_STUB_RUN_WRITE_REPORT'
  $failCopy = Get-StubEnvValue -Name 'DOCKER_STUB_CP_FAIL'
  $writeReportRequested = (
    [string]::Equals($writeReport, '1', [System.StringComparison]::OrdinalIgnoreCase) -or
    (
      [string]::Equals($failCopy, '1', [System.StringComparison]::OrdinalIgnoreCase) -and
      $plannedExitCode -eq 0
    )
  )
  if ($writeReportRequested -and $stubEnv.ContainsKey('COMPARE_REPORT_PATH')) {
    $reportPath = Resolve-StubHostPathFromContainerPath -ContainerPath ([string]$stubEnv['COMPARE_REPORT_PATH'])
    $reportDir = Split-Path -Parent $reportPath
    if (-not [string]::IsNullOrWhiteSpace($reportDir) -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
      New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    Set-Content -LiteralPath $reportPath -Value '<html><body>host report</body></html>' -Encoding utf8
  }
  $writeHistorySuite = Get-StubEnvValue -Name 'DOCKER_STUB_RUN_WRITE_HISTORY_SUITE'
  $hasViHistoryOutputs = $stubEnv.ContainsKey('COMPAREVI_VI_HISTORY_SUITE_MANIFEST') -or $stubEnv.ContainsKey('COMPAREVI_VI_HISTORY_CONTEXT')
  if ([string]::Equals($writeHistorySuite, '1', [System.StringComparison]::OrdinalIgnoreCase) -or $hasViHistoryOutputs) {
    $maxPairs = 1
    if ($stubEnv.ContainsKey('COMPAREVI_VI_HISTORY_MAX_PAIRS')) {
      try {
        $maxPairs = [Math]::Max(1, [int]$stubEnv['COMPAREVI_VI_HISTORY_MAX_PAIRS'])
      } catch {
        $maxPairs = 1
      }
    }
    $branchRef = Get-StubEnvValue -Name 'COMPAREVI_VI_HISTORY_SOURCE_BRANCH'
    $targetPath = Get-StubEnvValue -Name 'COMPAREVI_VI_HISTORY_TARGET_PATH'
    $resultsDir = Get-StubEnvValue -Name 'COMPAREVI_VI_HISTORY_RESULTS_DIR'
    $modeDir = if ([string]::IsNullOrWhiteSpace($resultsDir)) { $null } else { Join-Path $resultsDir 'default' }
    if ($modeDir) {
      New-Item -ItemType Directory -Path $modeDir -Force | Out-Null
    }
    $modeManifestPath = if ($modeDir) { Join-Path $modeDir 'manifest.json' } else { 'manifest.json' }
    $comparisons = @()
    for ($i = 1; $i -le $maxPairs; $i++) {
      $pairName = "pair-{0:d3}" -f $i
      $pairReport = if ($modeDir) { Join-Path $modeDir ("{0}-report.html" -f $pairName) } else { "report-{0}.html" -f $pairName }
      if ($modeDir) {
        Set-Content -LiteralPath $pairReport -Value ("<html><body>{0}</body></html>" -f $pairName) -Encoding utf8
      }
      $comparisons += [ordered]@{
        index = $i
        base = [ordered]@{
          ref = "base-$i"
          short = "base-$i"
        }
        head = [ordered]@{
          ref = "head-$i"
          short = "head-$i"
        }
        outName = $pairName
        result = [ordered]@{
          diff = $true
          exitCode = 1
          duration_s = 0
          status = 'completed'
          reportPath = $pairReport
          categories = @()
          categoryDetails = @()
          categoryBuckets = @()
          categoryBucketDetails = @()
          highlights = @()
        }
      }
    }
    if ($modeDir) {
      ([ordered]@{
        schema = 'vi-compare/history@v1'
        generatedAt = (Get-Date).ToString('o')
        targetPath = $targetPath
        requestedStartRef = 'head-1'
        startRef = 'head-1'
        endRef = 'base-1'
        maxPairs = $maxPairs
        maxSignalPairs = $maxPairs
        noisePolicy = 'collapse'
        failFast = $false
        failOnDiff = $false
        mode = 'default'
        slug = 'default'
        reportFormat = 'html'
        flags = @()
        resultsDir = $modeDir
        comparisons = $comparisons
        stats = [ordered]@{
          processed = $maxPairs
          diffs = $maxPairs
          signalDiffs = $maxPairs
          noiseCollapsed = 0
          lastDiffIndex = $maxPairs
          lastDiffCommit = "head-$maxPairs"
          stopReason = 'complete'
          errors = 0
          missing = 0
          categoryCounts = [ordered]@{}
          bucketCounts = [ordered]@{}
          collapsedNoise = [ordered]@{
            count = 0
            indices = @()
            commits = @()
            categoryCounts = [ordered]@{}
            bucketCounts = [ordered]@{}
          }
        }
        status = 'ok'
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $modeManifestPath -Encoding utf8
    }
    foreach ($envName in @('COMPAREVI_VI_HISTORY_SUITE_MANIFEST', 'COMPAREVI_VI_HISTORY_CONTEXT', 'COMPAREVI_VI_HISTORY_BOOTSTRAP_RECEIPT')) {
      if (-not $stubEnv.ContainsKey($envName)) { continue }
      $hostPath = Resolve-StubHostPathFromContainerPath -ContainerPath ([string]$stubEnv[$envName])
      $hostDir = Split-Path -Parent $hostPath
      if (-not [string]::IsNullOrWhiteSpace($hostDir) -and -not (Test-Path -LiteralPath $hostDir -PathType Container)) {
        New-Item -ItemType Directory -Path $hostDir -Force | Out-Null
      }
      $payload = switch ($envName) {
        'COMPAREVI_VI_HISTORY_SUITE_MANIFEST' {
          [ordered]@{
            schema = 'vi-compare/history-suite@v1'
            generatedAt = (Get-Date).ToString('o')
            targetPath = $targetPath
            requestedStartRef = 'head-1'
            startRef = 'head-1'
            endRef = 'base-1'
            maxPairs = $maxPairs
            maxSignalPairs = $maxPairs
            noisePolicy = 'collapse'
            failFast = $false
            failOnDiff = $false
            reportFormat = 'html'
            resultsDir = $resultsDir
            requestedModes = @('default')
            executedModes = @('default')
            modes = @(
              [ordered]@{
                name = 'default'
                slug = 'default'
                reportFormat = 'html'
                flags = @()
                manifestPath = $modeManifestPath
                resultsDir = $modeDir
                stats = [ordered]@{
                  processed = $maxPairs
                  diffs = $maxPairs
                  signalDiffs = $maxPairs
                  noiseCollapsed = 0
                  lastDiffIndex = $maxPairs
                  lastDiffCommit = "head-$maxPairs"
                  stopReason = 'complete'
                  errors = 0
                  missing = 0
                  categoryCounts = [ordered]@{}
                  bucketCounts = [ordered]@{}
                  collapsedNoise = [ordered]@{
                    count = 0
                    indices = @()
                    commits = @()
                    categoryCounts = [ordered]@{}
                    bucketCounts = [ordered]@{}
                  }
                }
                status = 'ok'
              }
            )
            stats = [ordered]@{
              modes = 1
              processed = $maxPairs
              diffs = $maxPairs
              signalDiffs = $maxPairs
              noiseCollapsed = 0
              errors = 0
              missing = 0
              categoryCounts = [ordered]@{}
              bucketCounts = [ordered]@{}
            }
            status = 'ok'
          }
        }
        'COMPAREVI_VI_HISTORY_CONTEXT' {
          [ordered]@{
            schema = 'vi-compare/history-context@v1'
            generatedAt = (Get-Date).ToString('o')
            targetPath = $targetPath
            requestedStartRef = 'head-1'
            startRef = 'head-1'
            endRef = 'base-1'
            maxPairs = $maxPairs
            requestedModes = @('default')
            executedModes = @('default')
            comparisons = @($comparisons | ForEach-Object {
              [ordered]@{
                mode = 'default'
                index = $_.index
                base = [ordered]@{
                  full = $_.base.ref
                  short = $_.base.short
                  subject = ''
                  author = ''
                  authorEmail = ''
                  date = ''
                }
                head = [ordered]@{
                  full = $_.head.ref
                  short = $_.head.short
                  subject = ''
                  author = ''
                  authorEmail = ''
                  date = ''
                }
                lineage = [ordered]@{
                  type = 'mainline'
                  parentIndex = $_.index
                  parentCount = $maxPairs
                  depth = $_.index - 1
                }
                lineageLabel = 'Mainline'
                result = $_.result
                highlights = @()
              }
            })
          }
        }
        default {
          $bootstrapMode = Get-StubEnvValue -Name 'COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE'
          if ([string]::IsNullOrWhiteSpace($bootstrapMode)) {
            $bootstrapMode = 'vi-history-suite-smoke'
          }
          [ordered]@{
            schema = 'ni-linux-runtime-bootstrap-receipt@v1'
            generatedAt = (Get-Date).ToString('o')
            mode = $bootstrapMode
            sourceBranchRef = $branchRef
            targetPath = $targetPath
            resultsDir = $resultsDir
            processedPairs = $maxPairs
            selectedPairs = $maxPairs
            compareExitCode = 1
          }
        }
      }
      ($payload | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $hostPath -Encoding utf8
    }
    if ($stubEnv.ContainsKey('COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER')) {
      $markerPath = Resolve-StubHostPathFromContainerPath -ContainerPath ([string]$stubEnv['COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER'])
      $markerDir = Split-Path -Parent $markerPath
      if (-not [string]::IsNullOrWhiteSpace($markerDir) -and -not (Test-Path -LiteralPath $markerDir -PathType Container)) {
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
      }
      @(
        'bootstrap-ready=1'
        ('branch={0}' -f (Get-StubEnvValue -Name 'COMPAREVI_VI_HISTORY_SOURCE_BRANCH'))
        ('target={0}' -f (Get-StubEnvValue -Name 'COMPAREVI_VI_HISTORY_TARGET_PATH'))
      ) | Set-Content -LiteralPath $markerPath -Encoding utf8
    }
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
  $exitCode = $plannedExitCode
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

      $stubSh = @'
#!/usr/bin/env bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "__PWSH__" -NoLogo -NoProfile -File "${script_dir}/docker.ps1" "$@"
'@.Replace('__PWSH__', $pwshPath)
      $stubShPath = Join-Path $binDir 'docker'
      Set-Content -LiteralPath $stubShPath -Value $stubSh -Encoding utf8
      if (-not $IsWindows) {
        & chmod +x $stubShPath
      }

      $pathSeparator = if ($IsWindows) { ';' } else { ':' }
      $dockerOverrideName = if ($IsWindows) { 'docker.ps1' } else { 'docker' }
      $env:PATH = "{0}{1}{2}" -f $binDir, $pathSeparator, $env:PATH
      $env:DOCKER_COMMAND_OVERRIDE = (Join-Path $binDir $dockerOverrideName)
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

    function script:Invoke-WithIsolatedGitWorkspace {
      param([Parameter(Mandatory)][scriptblock]$ScriptBlock)

      # Temp-repo tests must not inherit the mounted workspace git indirection.
      $gitEnvNames = @(
        'GIT_DIR',
        'GIT_WORK_TREE',
        'GIT_COMMON_DIR',
        'GIT_INDEX_FILE',
        'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES',
        'GIT_PREFIX',
        'GIT_CEILING_DIRECTORIES'
      )
      $savedEnv = @{}
      foreach ($name in $gitEnvNames) {
        $savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
        Remove-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
        [System.Environment]::SetEnvironmentVariable($name, $null, 'Process')
      }

      try {
        $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        function local:git {
          param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)

          $psi = [System.Diagnostics.ProcessStartInfo]::new()
          $psi.FileName = $gitPath
          $psi.WorkingDirectory = (Get-Location).Path
          $psi.UseShellExecute = $false
          $psi.RedirectStandardOutput = $true
          $psi.RedirectStandardError = $true
          foreach ($arg in @($Arguments)) {
            [void]$psi.ArgumentList.Add([string]$arg)
          }
          foreach ($envName in $gitEnvNames) {
            [void]$psi.Environment.Remove($envName)
          }

          $proc = [System.Diagnostics.Process]::new()
          $proc.StartInfo = $psi
          try {
            [void]$proc.Start()
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $global:LASTEXITCODE = [int]$proc.ExitCode
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
              [Console]::Error.Write($stderr)
            }
            if ([string]::IsNullOrWhiteSpace($stdout)) {
              return @()
            }
            return @($stdout -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          } finally {
            $proc.Dispose()
          }
        }
        & $ScriptBlock
      } finally {
        Remove-Item -Path Function:git -ErrorAction SilentlyContinue
        foreach ($name in $savedEnv.Keys) {
          if ($null -eq $savedEnv[$name]) {
            Remove-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
            [System.Environment]::SetEnvironmentVariable($name, $null, 'Process')
          } else {
            Set-Item -Path ("Env:{0}" -f $name) -Value $savedEnv[$name]
            [System.Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
          }
        }
      }
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
      DOCKER_STUB_CP_STDERR         = $env:DOCKER_STUB_CP_STDERR
      DOCKER_STUB_CP_WRITE_ON_FAIL  = $env:DOCKER_STUB_CP_WRITE_ON_FAIL
      DOCKER_STUB_RM_EXIT_CODE      = $env:DOCKER_STUB_RM_EXIT_CODE
      DOCKER_STUB_RM_STDERR         = $env:DOCKER_STUB_RM_STDERR
      DOCKER_STUB_RUN_WRITE_REPORT  = $env:DOCKER_STUB_RUN_WRITE_REPORT
      DOCKER_STUB_RUN_WRITE_HISTORY_SUITE = $env:DOCKER_STUB_RUN_WRITE_HISTORY_SUITE
      DOCKER_STUB_CONTAINER_INSPECT_JSON = $env:DOCKER_STUB_CONTAINER_INSPECT_JSON
      DOCKER_STUB_INFO_JSON         = $env:DOCKER_STUB_INFO_JSON
      DOCKER_COMMAND_OVERRIDE       = $env:DOCKER_COMMAND_OVERRIDE
      COMPAREVI_DOCKER_RUNTIME_PROVIDER = $env:COMPAREVI_DOCKER_RUNTIME_PROVIDER
      COMPAREVI_DOCKER_EXPECTED_CONTEXT = $env:COMPAREVI_DOCKER_EXPECTED_CONTEXT
      COMPAREVI_DOCKER_EXPECTED_DOCKER_HOST = $env:COMPAREVI_DOCKER_EXPECTED_DOCKER_HOST
      DOCKER_HOST                   = $env:DOCKER_HOST
      NI_LINUX_LABVIEW_PATH         = $env:NI_LINUX_LABVIEW_PATH
      RUNTIME_INJECTION_TOKEN      = $env:RUNTIME_INJECTION_TOKEN
      TEMP                          = $env:TEMP
      TMP                           = $env:TMP
      TMPDIR                        = $env:TMPDIR
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

  It 'passes probe when Linux docker mode and local image are available' {
    $work = Join-Path $TestDrive 'probe-ok'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -Probe 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
  }

  It 'uses the native-wsl runtime contract instead of hardcoding desktop-linux when daemon mode is active' {
    $work = Join-Path $TestDrive 'probe-native-wsl'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'default'
    Set-Item Env:DOCKER_STUB_INFO_JSON '{"OSType":"linux","OperatingSystem":"Ubuntu 24.04.1 LTS","Name":"ubuntu-native","Platform":{"Name":"Docker Engine - Community"},"Labels":["maintainer=comparevi"]}'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:COMPAREVI_DOCKER_RUNTIME_PROVIDER 'native-wsl'
    Set-Item Env:COMPAREVI_DOCKER_EXPECTED_CONTEXT ''
    Set-Item Env:COMPAREVI_DOCKER_EXPECTED_DOCKER_HOST 'unix:///var/run/docker.sock'
    Set-Item Env:DOCKER_HOST 'unix:///var/run/docker.sock'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -Probe 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $runtimeSnapshot = Join-Path (Join-Path (Resolve-Path '.').Path 'tests/results/ni-linux-container') 'runtime-determinism.json'
    Test-Path -LiteralPath $runtimeSnapshot | Should -BeTrue
    $snapshot = Get-Content -LiteralPath $runtimeSnapshot -Raw | ConvertFrom-Json -Depth 12
    $snapshot.expected.provider | Should -Be 'native-wsl'
    $snapshot.expected.context | Should -Be ''
    $snapshot.expected.dockerHost | Should -Be 'unix:///var/run/docker.sock'
    $snapshot.observed.desktopBacked | Should -BeFalse
    $snapshot.result.status | Should -Be 'ok'
  }

  It 'fails probe with remediation when Docker is not in Linux mode' {
    $work = Join-Path $TestDrive 'probe-win-mode'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'windows'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-windows'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -Probe 2>&1
    $LASTEXITCODE | Should -Not -Be 0
    ($output -join "`n") | Should -Match 'Runtime invariant mismatch|expectedOs=linux|expected os=linux'
  }

  It 'writes deterministic capture artifacts for Linux compare execution' {
    $work = Join-Path $TestDrive 'compare-ok'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Set-Item Env:DOCKER_HOST 'unix:///var/run/docker.sock'

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
      -ContainerNameLabel 'flag-baseline' `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -Flags @('-noattr') 2>&1
    $LASTEXITCODE | Should -BeIn @(0, 1) -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.status | Should -Be 'diff'
    $capture.resultClass | Should -Be 'success-diff'
    $capture.isDiff | Should -BeTrue
    $capture.gateOutcome | Should -Be 'pass'
    $capture.failureClass | Should -Be 'none'
    $capture.diffEvidenceSource | Should -Be 'exit-code'
    $capture.image | Should -Be 'nationalinstruments/labview:2026q1-linux'
    $capture.flags | Should -Contain '-noattr'
    $capture.flags | Should -Contain '-Headless'
    $capture.containerShellContract.plane | Should -Be 'linux'
    $capture.containerShellContract.executable | Should -Be 'bash'
    $capture.containerShellContract.family | Should -Be 'posix-bash'
    $capture.containerShellContract.encodedCommand | Should -BeFalse
    $capture.containerShellContract.pwshRequired | Should -BeFalse
    $capture.containerShellContract.hostWrapperShell | Should -Be 'pwsh'
    $capture.containerName | Should -Match '^ni-lnx-compare-flag-baseline-[a-f0-9]{8}$'
    $capture.command | Should -Match ('docker run --name {0}\b' -f [regex]::Escape([string]$capture.containerName))
    $capture.observedDockerHost | Should -Be 'unix:///var/run/docker.sock'
    $capture.runtimeDeterminism.observed.dockerHost | Should -Be 'unix:///var/run/docker.sock'
    $capture.headlessContract.required | Should -BeTrue
    $capture.headlessContract.enforcedCliHeadless | Should -BeTrue
    $capture.headlessContract.lvRteHeadlessEnv | Should -BeTrue
    $capture.runtimeDeterminism.status | Should -Match 'ok|mismatch-repaired'
    $capture.startupMitigation | Should -Not -BeNullOrEmpty
    $capture.reportAnalysis.source | Should -Be 'container-export'
    $capture.containerArtifacts.copyStatus | Should -Be 'success' -Because ($capture.containerArtifacts | ConvertTo-Json -Depth 8)
    $capture.containerArtifacts.copiedPaths.Count | Should -BeGreaterThan 0

    $records = & $script:ReadDockerStubLog -Path (Join-Path $work 'docker-log.ndjson')
    $cpRecords = @($records | Where-Object { $_.args[0] -eq 'cp' })
    $rmRecords = @($records | Where-Object { $_.args[0] -eq 'rm' -and $_.args[1] -eq '-f' })
    $capture.command | Should -Match '\bbash\b'
    $capture.command | Should -Not -Match '\bpwsh\b'
    $cpRecords.Count | Should -BeGreaterThan 0
    $rmRecords.Count | Should -Be 1
    $rmRecords[0].args[2] | Should -Be $capture.containerName
    $cpIndex = [array]::IndexOf($records, $cpRecords[0])
    $rmIndex = [array]::IndexOf($records, $rmRecords[0])
    $cpIndex | Should -BeLessThan $rmIndex
    ($output -join "`n") | Should -Match 'observedDockerHost=unix:///var/run/docker.sock'
  }

  It 'disables prelaunch when reusing an existing linux container' {
    $work = Join-Path $TestDrive 'compare-reuse-container-disables-prelaunch'
    $repoRoot = Join-Path $work 'consumer-repo'
    $resultsRoot = Join-Path $work 'results'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_CONTAINER_INSPECT_JSON '[{"State":{"Running":true,"Status":"running"},"Config":{"Image":"nationalinstruments/labview:2026q1-linux"}}]'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'

    $baseVi = Join-Path $repoRoot 'Base.vi'
    $headVi = Join-Path $repoRoot 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    $reportPath = Join-Path $resultsRoot 'compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -ReuseContainerName 'comparevi-vi-history-warm-test' `
      -ReuseRepoHostPath $repoRoot `
      -ReuseResultsHostPath $resultsRoot `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 2>&1
    $LASTEXITCODE | Should -BeIn @(0, 1) -Because ($output -join "`n")

    $records = & $script:ReadDockerStubLog -Path (Join-Path $work 'docker-log.ndjson')
    $execRecord = @($records | Where-Object { $_.args[0] -eq 'exec' } | Select-Object -First 1)
    $execRecord.Count | Should -Be 1

    $prelaunchEnv = @($execRecord[0].args | Where-Object { $_ -eq 'COMPARE_PRELAUNCH_ENABLED=0' })
    $prelaunchEnv.Count | Should -Be 1 -Because (($execRecord[0].args -join ' ') | Out-String)
    @($execRecord[0].args | Where-Object { $_ -eq 'COMPARE_PRELAUNCH_ENABLED=1' }).Count | Should -Be 0
  }

  It 'uses NI_LINUX_LABVIEW_PATH when no explicit linux container path is supplied' {
    $work = Join-Path $TestDrive 'compare-linux-labview-path-env'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '0'
    Set-Item Env:NI_LINUX_LABVIEW_PATH '/usr/local/natinst/LabVIEW-2026-64/labview'

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

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.labviewPath | Should -Be '/usr/local/natinst/LabVIEW-2026-64/labview'
  }

  It 'accepts a single-container smoke bootstrap contract for runtime injection' {
    $work = Join-Path $TestDrive 'compare-runtime-injection'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Set-Item Env:RUNTIME_INJECTION_TOKEN 'runtime-secret'

    $baseVi = Join-Path $work 'Base.vi'
    $headVi = Join-Path $work 'Head.vi'
    $runtimeScript = Join-Path $work 'runtime-injection.sh'
    $runtimeContract = Join-Path $work 'runtime-bootstrap.json'
    $runtimeConfigDir = Join-Path $work 'runtime-config'
    New-Item -ItemType Directory -Path $runtimeConfigDir -Force | Out-Null
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $runtimeConfigDir 'settings.json') -Value '{"mode":"test"}' -Encoding utf8
    Set-Content -LiteralPath $runtimeScript -Value @(
      'export RUNTIME_CONFIG_DIR=/opt/runtime/config'
      'export RUNTIME_MODE=ni-linux'
    ) -Encoding utf8
    Set-Content -LiteralPath $runtimeContract -Value @"
{
  "schema": "ni-linux-runtime-bootstrap/v1",
  "mode": "single-container-smoke",
  "branchRef": "consumer/branch",
  "maxCommitCount": 32,
  "scriptPath": "runtime-injection.sh",
  "env": [
    {
      "name": "CONFIG_TOKEN",
      "fromHostEnv": "RUNTIME_INJECTION_TOKEN"
    }
  ],
  "mounts": [
    {
      "hostPath": "runtime-config",
      "containerPath": "/opt/runtime/config"
    }
  ]
}
"@ -Encoding utf8
    $reportPath = Join-Path $work 'out\\compare-report.html'

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -BaseVi $baseVi `
      -HeadVi $headVi `
      -ReportPath $reportPath `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -RuntimeBootstrapContractPath $runtimeContract 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.runtimeInjection.enabled | Should -BeTrue
    $capture.runtimeInjection.contractPath | Should -Be (Resolve-Path -LiteralPath $runtimeContract).Path
    $capture.runtimeInjection.contractMode | Should -Be 'single-container-smoke'
    $capture.runtimeInjection.branchRef | Should -Be 'consumer/branch'
    $capture.runtimeInjection.maxCommitCount | Should -Be 32
    $capture.runtimeInjection.scriptHostPath | Should -Be (Resolve-Path -LiteralPath $runtimeScript).Path
    $capture.runtimeInjection.scriptContainerPath | Should -Match '^/compare/m\d+/runtime-injection\.sh$'
    @($capture.runtimeInjection.envNames) | Should -Contain 'CONFIG_TOKEN'
    $capture.runtimeInjection.mounts.Count | Should -Be 1
    $capture.runtimeInjection.mounts[0].hostPath | Should -Be (Resolve-Path -LiteralPath $runtimeConfigDir).Path
    $capture.runtimeInjection.mounts[0].containerPath | Should -Be '/opt/runtime/config'
    $capture.runtimeInjection.mounts[0].kind | Should -Be 'directory'
  }

  It 'accepts an explicit viHistory bootstrap contract without host base/head inputs' {
    $work = Join-Path $TestDrive 'compare-runtime-vi-history'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_REPORT '1'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_HISTORY_SUITE '1'

    $repoRoot = Join-Path $work 'consumer-repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    Invoke-WithIsolatedGitWorkspace {
      Push-Location $repoRoot
      try {
        & git init --initial-branch=develop | Out-Null
        & git config user.email 'agent@example.com'
        & git config user.name 'Agent Runner'
        $targetDir = Join-Path $repoRoot 'src'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $targetPath = Join-Path $targetDir 'Sample.vi'
        Set-Content -LiteralPath $targetPath -Value 'base' -Encoding utf8
        & git add .
        & git commit -m 'initial history repo' | Out-Null
        & git switch -c 'consumer/branch' | Out-Null
        Set-Content -LiteralPath $targetPath -Value 'head' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'update sample vi' | Out-Null
      } finally {
        Pop-Location | Out-Null
      }
    }

    $resultsDir = Join-Path $work 'vi-history-results'
    $runtimeContract = Join-Path $work 'runtime-bootstrap.json'
    $bootstrapScript = Join-Path (Split-Path -Parent $script:RunnerScript) 'NILinux-VIHistorySuiteBootstrap.sh'
    $contract = [ordered]@{
      schema = 'ni-linux-runtime-bootstrap/v1'
      mode = 'single-container-smoke'
      branchRef = 'consumer/branch'
      maxCommitCount = 32
      scriptPath = $bootstrapScript
      viHistory = [ordered]@{
        repoPath = $repoRoot
        targetPath = 'src/Sample.vi'
        resultsPath = $resultsDir
        baselineRef = 'develop'
        maxPairs = 2
      }
    }
    $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeContract -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -RuntimeBootstrapContractPath $runtimeContract 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path $resultsDir 'ni-linux-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 12
    $capture.baseVi | Should -BeNullOrEmpty
    $capture.headVi | Should -BeNullOrEmpty
    $capture.reportPath | Should -Be (Join-Path $resultsDir 'linux-compare-report.html')
    $capture.runtimeInjection.enabled | Should -BeTrue
    $capture.runtimeInjection.contractMode | Should -Be 'single-container-smoke'
    $capture.runtimeInjection.branchRef | Should -Be 'consumer/branch'
    $capture.runtimeInjection.viHistory.enabled | Should -BeTrue
    $capture.runtimeInjection.viHistory.repoHostPath | Should -Be (Resolve-Path -LiteralPath $repoRoot).Path
    $capture.runtimeInjection.viHistory.resultsHostPath | Should -Be (Resolve-Path -LiteralPath $resultsDir).Path
    $capture.runtimeInjection.viHistory.targetPath | Should -Be 'src/Sample.vi'
    $capture.runtimeInjection.viHistory.bootstrapMode | Should -Be 'single-container-smoke'
    $capture.runtimeInjection.viHistory.maxPairs | Should -Be 2
    $capture.runtimeInjection.viHistory.branchBudget.commitCount | Should -Be 1
    $capture.runtimeInjection.viHistory.branchBudget.status | Should -Be 'ok'
    $capture.runtimeInjection.viHistory.gitInjection.enabled | Should -BeTrue
    $capture.runtimeInjection.viHistory.gitInjection.strategy | Should -Be 'git-directory'
    $capture.runtimeInjection.viHistory.gitInjection.dotGitHostPath | Should -Be (Resolve-Path -LiteralPath (Join-Path $repoRoot '.git')).Path
    $capture.runtimeInjection.viHistory.gitInjection.gitDirContainerPath | Should -Be '/opt/comparevi/source/.git'
    $capture.runtimeInjection.viHistory.gitInjection.gitWorkTreeContainerPath | Should -Be '/opt/comparevi/source'
    $capture.containerName | Should -Match '^ni-lnx-compare-single-container-smoke-[a-f0-9]{8}$'

    Test-Path -LiteralPath ([string]$capture.reportAnalysis.reportPathExtracted) -PathType Leaf | Should -BeTrue
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_REPO_PATH'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_TARGET_PATH'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_RESULTS_DIR'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_SUITE_MANIFEST'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_CONTEXT'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_GIT_DIR'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_GIT_WORK_TREE'
    $capture.runtimeInjection.mounts.Count | Should -BeGreaterThan 1

  }

  It 'preserves viHistory target paths with spaces when building docker runtime-injection env args' {
    $work = Join-Path $TestDrive 'compare-runtime-vi-history-spaces'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_REPORT '1'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_HISTORY_SUITE '1'

    $repoRoot = Join-Path $work 'consumer-repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    $targetRelativePath = 'src/Sample With Spaces.vi'
    Invoke-WithIsolatedGitWorkspace {
      Push-Location $repoRoot
      try {
        & git init --initial-branch=develop | Out-Null
        & git config user.email 'agent@example.com'
        & git config user.name 'Agent Runner'
        $targetDir = Join-Path $repoRoot 'src'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $targetPath = Join-Path $targetDir 'Sample With Spaces.vi'
        Set-Content -LiteralPath $targetPath -Value 'base' -Encoding utf8
        & git add -- $targetRelativePath
        & git commit -m 'initial history repo with spaces' | Out-Null
        & git switch -c 'consumer/branch' | Out-Null
        Set-Content -LiteralPath $targetPath -Value 'head' -Encoding utf8
        & git add -- $targetRelativePath
        & git commit -m 'update sample vi with spaces' | Out-Null
      } finally {
        Pop-Location | Out-Null
      }
    }

    $resultsDir = Join-Path $work 'vi-history-results'
    $runtimeContract = Join-Path $work 'runtime-bootstrap.json'
    $bootstrapScript = Join-Path (Split-Path -Parent $script:RunnerScript) 'NILinux-VIHistorySuiteBootstrap.sh'
    $contract = [ordered]@{
      schema = 'ni-linux-runtime-bootstrap/v1'
      mode = 'single-container-smoke'
      branchRef = 'consumer/branch'
      maxCommitCount = 32
      scriptPath = $bootstrapScript
      viHistory = [ordered]@{
        repoPath = $repoRoot
        targetPath = $targetRelativePath
        resultsPath = $resultsDir
        baselineRef = 'develop'
        maxPairs = 1
      }
    }
    $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeContract -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -RuntimeBootstrapContractPath $runtimeContract 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path $resultsDir 'ni-linux-container-capture.json'
    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 12
    $capture.status | Should -Be 'diff'
    $capture.runtimeInjection.enabled | Should -BeTrue
    $capture.runtimeInjection.viHistory.enabled | Should -BeTrue
    $capture.runtimeInjection.viHistory.targetPath | Should -Be $targetRelativePath
    Test-Path -LiteralPath ([string]$capture.reportAnalysis.reportPathExtracted) -PathType Leaf | Should -BeTrue
  }

  It 'honors an explicit viHistory baseline ref when develop is absent locally' {
    $work = Join-Path $TestDrive 'compare-runtime-vi-history-explicit-baseline'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_REPORT '1'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_HISTORY_SUITE '1'

    $repoRoot = Join-Path $work 'consumer-repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    $gitSetup = Invoke-WithIsolatedGitWorkspace {
      Push-Location $repoRoot
      try {
        & git init --initial-branch=main | Out-Null
        & git config user.email 'agent@example.com'
        & git config user.name 'Agent Runner'
        $targetDir = Join-Path $repoRoot 'src'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $targetPath = Join-Path $targetDir 'Sample.vi'
        Set-Content -LiteralPath $targetPath -Value 'base' -Encoding utf8
        & git add .
        & git commit -m 'initial history repo' | Out-Null
        $baselineShaLocal = [string](& git rev-parse HEAD | Select-Object -Last 1)

        & git switch -c 'consumer/branch' | Out-Null
        1..2 | ForEach-Object {
          Set-Content -LiteralPath $targetPath -Value ("head-{0}" -f $_) -Encoding utf8
          & git add src/Sample.vi
          & git commit -m ("update sample vi {0}" -f $_) | Out-Null
        }
        $headShaLocal = [string](& git rev-parse HEAD | Select-Object -Last 1)
        return [pscustomobject]@{
          baselineSha = $baselineShaLocal
          headSha = $headShaLocal
        }
      } finally {
        Pop-Location | Out-Null
      }
    }
    $baselineSha = [string]$gitSetup.baselineSha
    $headSha = [string]$gitSetup.headSha

    $resultsDir = Join-Path $work 'vi-history-results'
    $runtimeContract = Join-Path $work 'runtime-bootstrap.json'
    $bootstrapScript = Join-Path (Split-Path -Parent $script:RunnerScript) 'NILinux-VIHistorySuiteBootstrap.sh'
    $contract = [ordered]@{
      schema = 'ni-linux-runtime-bootstrap/v1'
      mode = 'single-container-smoke'
      branchRef = $headSha
      maxCommitCount = 2
      scriptPath = $bootstrapScript
      viHistory = [ordered]@{
        repoPath = $repoRoot
        targetPath = 'src/Sample.vi'
        resultsPath = $resultsDir
        baselineRef = $baselineSha
        maxPairs = 2
      }
    }
    $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeContract -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -RuntimeBootstrapContractPath $runtimeContract 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path $resultsDir 'ni-linux-container-capture.json'
    Test-Path -LiteralPath $capturePath -PathType Leaf | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 12
    $capture.runtimeInjection.viHistory.branchBudget.sourceBranchRef | Should -Be $headSha
    $capture.runtimeInjection.viHistory.branchBudget.requestedBaselineRef | Should -Be $baselineSha
    $capture.runtimeInjection.viHistory.branchBudget.baselineRef | Should -Be $baselineSha
    $capture.runtimeInjection.viHistory.branchBudget.mergeBaseRef | Should -Be $baselineSha
    $capture.runtimeInjection.viHistory.branchBudget.commitRange | Should -Be ('{0}..{1}' -f $baselineSha, $headSha)
    $capture.runtimeInjection.viHistory.branchBudget.commitCount | Should -Be 2
    $capture.runtimeInjection.viHistory.branchBudget.status | Should -Be 'ok'

    $capture.runtimeInjection.viHistory.resultsHostPath | Should -Be (Resolve-Path -LiteralPath $resultsDir).Path
  }

  It 'preserves linked-worktree git injection for viHistory bootstrap contracts' {
    $work = Join-Path $TestDrive 'compare-runtime-vi-history-worktree'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_REPORT '1'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_HISTORY_SUITE '1'

    $primaryRepoRoot = Join-Path $work 'primary-repo'
    $linkedWorktreeRoot = Join-Path $work 'linked-worktree'
    New-Item -ItemType Directory -Path $primaryRepoRoot -Force | Out-Null
    $gitSetup = Invoke-WithIsolatedGitWorkspace {
      Push-Location $primaryRepoRoot
      try {
        & git init --initial-branch=develop | Out-Null
        & git config user.email 'agent@example.com'
        & git config user.name 'Agent Runner'
        $targetDir = Join-Path $primaryRepoRoot 'src'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $targetPath = Join-Path $targetDir 'Sample.vi'
        Set-Content -LiteralPath $targetPath -Value 'base' -Encoding utf8
        & git add .
        & git commit -m 'initial history repo' | Out-Null
        $baselineShaLocal = [string](& git rev-parse HEAD | Select-Object -Last 1)
        & git worktree add -b 'consumer/branch' $linkedWorktreeRoot | Out-Null
      } finally {
        Pop-Location | Out-Null
      }

      Push-Location $linkedWorktreeRoot
      try {
        $linkedTargetPath = Join-Path $linkedWorktreeRoot 'src' 'Sample.vi'
        Set-Content -LiteralPath $linkedTargetPath -Value 'head' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'update sample vi' | Out-Null
        return [pscustomobject]@{
          baselineSha = $baselineShaLocal
        }
      } finally {
        Pop-Location | Out-Null
      }
    }
    $baselineSha = [string]$gitSetup.baselineSha

    $resultsDir = Join-Path $work 'vi-history-results'
    $runtimeContract = Join-Path $work 'runtime-bootstrap.json'
    $bootstrapScript = Join-Path (Split-Path -Parent $script:RunnerScript) 'NILinux-VIHistorySuiteBootstrap.sh'
    $contract = [ordered]@{
      schema = 'ni-linux-runtime-bootstrap/v1'
      mode = 'single-container-smoke'
      branchRef = 'consumer/branch'
      maxCommitCount = 4
      scriptPath = $bootstrapScript
      viHistory = [ordered]@{
        repoPath = $linkedWorktreeRoot
        targetPath = 'src/Sample.vi'
        resultsPath = $resultsDir
        baselineRef = $baselineSha
        maxPairs = 2
      }
    }
    $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeContract -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -RuntimeBootstrapContractPath $runtimeContract 2>&1
    $LASTEXITCODE | Should -Be 1 -Because ($output -join "`n")

    $capturePath = Join-Path $resultsDir 'ni-linux-container-capture.json'
    Test-Path -LiteralPath $capturePath -PathType Leaf | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 12
    $capture.runtimeInjection.viHistory.gitInjection.enabled | Should -BeTrue
    $capture.runtimeInjection.viHistory.gitInjection.strategy | Should -Be 'git-worktree-file'
    $capture.runtimeInjection.viHistory.gitInjection.dotGitHostPath | Should -Be (Resolve-Path -LiteralPath (Join-Path $linkedWorktreeRoot '.git')).Path
    $capture.runtimeInjection.viHistory.gitInjection.commonGitHostPath | Should -Be (Resolve-Path -LiteralPath (Join-Path $primaryRepoRoot '.git')).Path
    $capture.runtimeInjection.viHistory.gitInjection.commonGitContainerPath | Should -Be '/opt/comparevi/git/common'
    $capture.runtimeInjection.viHistory.gitInjection.gitDirContainerPath | Should -Match '^/opt/comparevi/git/common/worktrees/.+$'
    $capture.runtimeInjection.viHistory.gitInjection.gitWorkTreeContainerPath | Should -Be '/opt/comparevi/source'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_GIT_DIR'
    @($capture.runtimeInjection.envNames) | Should -Contain 'COMPAREVI_VI_HISTORY_GIT_WORK_TREE'
    @($capture.runtimeInjection.mounts | Where-Object { $_.hostPath -eq (Resolve-Path -LiteralPath (Join-Path $primaryRepoRoot '.git')).Path }).Count | Should -Be 1
  }

  It 'emits head-first refs for direct single-pair bootstrap finalization' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'WSL bash path conversion is only exercised on Windows hosts.'
      return
    }

    $bashPath = (Get-Command bash -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($bashPath)) {
      Set-ItResult -Skipped -Because 'bash is unavailable on this host.'
      return
    }

    function Convert-TestPathToWsl {
      param([Parameter(Mandatory)][string]$Path)

      $fullPath = [System.IO.Path]::GetFullPath($Path)
      if ($fullPath -notmatch '^(?<drive>[A-Za-z]):(?<rest>.*)$') {
        throw ("Cannot translate Windows path to WSL path: {0}" -f $fullPath)
      }

      $drive = $Matches['drive'].ToLowerInvariant()
      $rest = $Matches['rest'].Replace('\', '/')
      return "/mnt/$drive$rest"
    }

    $work = Join-Path $TestDrive 'bootstrap-single-pair'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $repoRoot = Join-Path $work 'consumer-repo'
    $baseRef = ''
    $headRef = ''
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    Invoke-WithIsolatedGitWorkspace {
      Push-Location $repoRoot
      try {
        & git init --initial-branch=develop | Out-Null
        & git config user.email 'agent@example.com'
        & git config user.name 'Agent Runner'
        $targetDir = Join-Path $repoRoot 'src'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $targetPath = Join-Path $targetDir 'Sample.vi'
        Set-Content -LiteralPath $targetPath -Value 'base' -Encoding utf8
        & git add .
        & git commit -m 'initial history repo' | Out-Null
        $script:baseRef = [string](& git rev-parse HEAD).Trim()
        & git switch -c 'consumer/branch' | Out-Null
        Set-Content -LiteralPath $targetPath -Value 'head' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'update sample vi' | Out-Null
        $script:headRef = [string](& git rev-parse HEAD).Trim()
      } finally {
        Pop-Location | Out-Null
      }
    }
    $baseRef = $script:baseRef
    $headRef = $script:headRef

    $resultsDir = Join-Path $work 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $suiteManifestPath = Join-Path $resultsDir 'suite-manifest.json'
    $historyContextPath = Join-Path $resultsDir 'history-context.json'
    $receiptPath = Join-Path $resultsDir 'vi-history-bootstrap-receipt.json'
    $markerPath = Join-Path $resultsDir 'vi-history-bootstrap-ran.txt'
    $reportPath = Join-Path $resultsDir 'linux-compare-report.html'
    $historyMarkdownPath = Join-Path $resultsDir 'history-report.md'
    $historyHtmlPath = Join-Path $resultsDir 'history-report.html'
    $historySummaryPath = Join-Path $resultsDir 'history-summary.json'
    Set-Content -LiteralPath $suiteManifestPath -Value '{}' -Encoding utf8
    Set-Content -LiteralPath $historyContextPath -Value '{}' -Encoding utf8
    Set-Content -LiteralPath $reportPath -Value '<html><body>pair-001</body></html>' -Encoding utf8

    $bootstrapScript = Join-Path (Split-Path -Parent $script:RunnerScript) 'NILinux-VIHistorySuiteBootstrap.sh'
    $bashCommand = @"
set -euo pipefail
export COMPAREVI_VI_HISTORY_RESULTS_DIR='$(Convert-TestPathToWsl -Path $resultsDir)'
export COMPAREVI_VI_HISTORY_SUITE_MANIFEST='$(Convert-TestPathToWsl -Path $suiteManifestPath)'
export COMPAREVI_VI_HISTORY_CONTEXT='$(Convert-TestPathToWsl -Path $historyContextPath)'
export COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE='single-container-smoke'
export COMPAREVI_VI_HISTORY_GIT_DIR='$(Convert-TestPathToWsl -Path (Join-Path $repoRoot '.git'))'
export COMPAREVI_VI_HISTORY_GIT_WORK_TREE='$(Convert-TestPathToWsl -Path $repoRoot)'
. '$(Convert-TestPathToWsl -Path $bootstrapScript)'
export COMPAREVI_VI_HISTORY_BOOTSTRAP_RECEIPT='$(Convert-TestPathToWsl -Path $receiptPath)'
export COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER='$(Convert-TestPathToWsl -Path $markerPath)'
export COMPAREVI_VI_HISTORY_TARGET_PATH='src/Sample.vi'
export COMPAREVI_VI_HISTORY_SOURCE_BRANCH='consumer/branch'
export COMPAREVI_VI_HISTORY_BASELINE_REF='develop'
export COMPAREVI_VI_HISTORY_BASE_REF='$baseRef'
export COMPAREVI_VI_HISTORY_HEAD_REF='$headRef'
export COMPAREVI_VI_HISTORY_EMIT_SUITE_BUNDLE=1
comparevi_vi_history_emit_suite_bundle 1 '$(Convert-TestPathToWsl -Path $reportPath)' '2026-03-10T00:00:00Z'
"@

    $output = & $bashPath -lc $bashCommand 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $suiteManifest = Get-Content -LiteralPath $suiteManifestPath -Raw | ConvertFrom-Json -Depth 12
    $suiteManifest.requestedStartRef | Should -Be $headRef
    $suiteManifest.startRef | Should -Be $headRef
    $suiteManifest.endRef | Should -Be $baseRef

    $historyContext = Get-Content -LiteralPath $historyContextPath -Raw | ConvertFrom-Json -Depth 12
    $historyContext.requestedStartRef | Should -Be $headRef
    $historyContext.startRef | Should -Be $headRef
    $historyContext.endRef | Should -Be $baseRef

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 12
    $receipt.mode | Should -Be 'single-container-smoke'
    Test-Path -LiteralPath $historyMarkdownPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $historyHtmlPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $historySummaryPath -PathType Leaf | Should -BeTrue
    (Get-Content -LiteralPath $historyMarkdownPath -Raw) | Should -Match 'VI history report'
    (Get-Content -LiteralPath $historyMarkdownPath -Raw) | Should -Match 'Source Branch: `consumer/branch`'
    (Get-Content -LiteralPath $historyHtmlPath -Raw) | Should -Match 'VI history report'
    (Get-Content -LiteralPath $historyHtmlPath -Raw) | Should -Match 'Source branch'
    $schemaLitePath = Join-Path $script:RepoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
    $summarySchemaPath = Join-Path $script:RepoRoot 'docs' 'schemas' 'comparevi-tools-history-facade-v1.schema.json'
    & pwsh -NoLogo -NoProfile -File $schemaLitePath -JsonPath $historySummaryPath -SchemaPath $summarySchemaPath | Out-Null
    $LASTEXITCODE | Should -Be 0
    $historySummary = Get-Content -LiteralPath $historySummaryPath -Raw | ConvertFrom-Json -Depth 12
    $historySummary.schema | Should -Be 'comparevi-tools/history-facade@v1'
    $historySummary.summary.comparisons | Should -Be 1
    @($historySummary.execution.executedModes) | Should -Be @('default')
    $historySummary.reports.markdownPath | Should -Match 'history-report\.md$'
    $historySummary.reports.htmlPath | Should -Match 'history-report\.html$'

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 12
    $receipt.mode | Should -Be 'single-container-smoke'
    $receipt.historyReportMarkdownPath | Should -Match 'history-report\.md$'
    $receipt.historyReportHtmlPath | Should -Match 'history-report\.html$'
    $receipt.historySummaryPath | Should -Match 'history-summary\.json$'
  }

  It 'skips introduction commits that cannot materialize a base VI during bootstrap planning' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'WSL bash path conversion is only exercised on Windows hosts.'
      return
    }

    $bashPath = (Get-Command bash -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($bashPath)) {
      Set-ItResult -Skipped -Because 'bash is unavailable on this host.'
      return
    }

    function Convert-TestPathToWsl {
      param([Parameter(Mandatory)][string]$Path)

      $fullPath = [System.IO.Path]::GetFullPath($Path)
      if ($fullPath -notmatch '^(?<drive>[A-Za-z]):(?<rest>.*)$') {
        throw ("Cannot translate Windows path to WSL path: {0}" -f $fullPath)
      }

      $drive = $Matches['drive'].ToLowerInvariant()
      $rest = $Matches['rest'].Replace('\', '/')
      return "/mnt/$drive$rest"
    }

    $work = Join-Path $TestDrive 'bootstrap-skips-introduction-commit'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $repoRoot = Join-Path $work 'consumer-repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    Invoke-WithIsolatedGitWorkspace {
      Push-Location $repoRoot
      try {
        & git init --initial-branch=develop | Out-Null
        & git config user.email 'agent@example.com'
        & git config user.name 'Agent Runner'
        Set-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Value 'seed' -Encoding utf8
        & git add README.md
        & git commit -m 'seed repo' | Out-Null

        $targetDir = Join-Path $repoRoot 'src'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $targetPath = Join-Path $targetDir 'Sample.vi'
        Set-Content -LiteralPath $targetPath -Value 'baseline' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'introduce sample vi' | Out-Null

        & git switch -c 'consumer/branch' | Out-Null
        Set-Content -LiteralPath $targetPath -Value 'head-1' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'update sample vi 1' | Out-Null
        Set-Content -LiteralPath $targetPath -Value 'head-2' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'update sample vi 2' | Out-Null
      } finally {
        Pop-Location | Out-Null
      }
    }

    $resultsDir = Join-Path $work 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $suiteManifestPath = Join-Path $resultsDir 'suite-manifest.json'
    $historyContextPath = Join-Path $resultsDir 'history-context.json'
    $markerPath = Join-Path $resultsDir 'vi-history-bootstrap-ran.txt'
    $bootstrapScript = Join-Path (Split-Path -Parent $script:RunnerScript) 'NILinux-VIHistorySuiteBootstrap.sh'
    $bashCommand = @"
set -euo pipefail
export COMPAREVI_VI_HISTORY_RESULTS_DIR='$(Convert-TestPathToWsl -Path $resultsDir)'
export COMPAREVI_VI_HISTORY_SUITE_MANIFEST='$(Convert-TestPathToWsl -Path $suiteManifestPath)'
export COMPAREVI_VI_HISTORY_CONTEXT='$(Convert-TestPathToWsl -Path $historyContextPath)'
export COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER='$(Convert-TestPathToWsl -Path $markerPath)'
export COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE='vi-history-sequential-smoke'
export COMPAREVI_VI_HISTORY_REPO_PATH='$(Convert-TestPathToWsl -Path $repoRoot)'
export COMPAREVI_VI_HISTORY_GIT_DIR='$(Convert-TestPathToWsl -Path (Join-Path $repoRoot '.git'))'
export COMPAREVI_VI_HISTORY_GIT_WORK_TREE='$(Convert-TestPathToWsl -Path $repoRoot)'
export COMPAREVI_VI_HISTORY_TARGET_PATH='src/Sample.vi'
export COMPAREVI_VI_HISTORY_SOURCE_BRANCH='consumer/branch'
export COMPAREVI_VI_HISTORY_BASELINE_REF='develop'
export COMPAREVI_VI_HISTORY_MAX_PAIRS='6'
. '$(Convert-TestPathToWsl -Path $bootstrapScript)'
"@

    $output = & $bashPath -lc $bashCommand 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    Test-Path -LiteralPath $markerPath -PathType Leaf | Should -BeTrue
    $pairPlanPath = Join-Path $resultsDir 'pair-plan.tsv'
    Test-Path -LiteralPath $pairPlanPath -PathType Leaf | Should -BeTrue
    @(Get-Content -LiteralPath $pairPlanPath).Count | Should -Be 2
  }

  It 'emits container-native report artifacts for multi-pair bootstrap finalization' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'WSL bash path conversion is only exercised on Windows hosts.'
      return
    }

    $bashPath = (Get-Command bash -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($bashPath)) {
      Set-ItResult -Skipped -Because 'bash is unavailable on this host.'
      return
    }

    function Convert-TestPathToWsl {
      param([Parameter(Mandatory)][string]$Path)

      $fullPath = [System.IO.Path]::GetFullPath($Path)
      if ($fullPath -notmatch '^(?<drive>[A-Za-z]):(?<rest>.*)$') {
        throw ("Cannot translate Windows path to WSL path: {0}" -f $fullPath)
      }

      $drive = $Matches['drive'].ToLowerInvariant()
      $rest = $Matches['rest'].Replace('\', '/')
      return "/mnt/$drive$rest"
    }

    $work = Join-Path $TestDrive 'bootstrap-multi-pair-report-bundle'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $repoRoot = Join-Path $work 'consumer-repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    Invoke-WithIsolatedGitWorkspace {
      Push-Location $repoRoot
      try {
        & git init --initial-branch=develop | Out-Null
        & git config user.email 'agent@example.com'
        & git config user.name 'Agent Runner'
        Set-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Value 'seed' -Encoding utf8
        & git add README.md
        & git commit -m 'seed repo' | Out-Null

        $targetDir = Join-Path $repoRoot 'src'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $targetPath = Join-Path $targetDir 'Sample.vi'
        Set-Content -LiteralPath $targetPath -Value 'baseline' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'introduce sample vi' | Out-Null

        & git switch -c 'consumer/branch' | Out-Null
        Set-Content -LiteralPath $targetPath -Value 'head-1' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'update sample vi 1' | Out-Null
        Set-Content -LiteralPath $targetPath -Value 'head-2' -Encoding utf8
        & git add src/Sample.vi
        & git commit -m 'update sample vi 2' | Out-Null
      } finally {
        Pop-Location | Out-Null
      }
    }

    $resultsDir = Join-Path $work 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $suiteManifestPath = Join-Path $resultsDir 'suite-manifest.json'
    $historyContextPath = Join-Path $resultsDir 'history-context.json'
    $receiptPath = Join-Path $resultsDir 'vi-history-bootstrap-receipt.json'
    $markdownPath = Join-Path $resultsDir 'history-report.md'
    $htmlPath = Join-Path $resultsDir 'history-report.html'
    $summaryPath = Join-Path $resultsDir 'history-summary.json'
    $reportPath = Join-Path $resultsDir 'linux-compare-report.html'
    $bootstrapScript = Join-Path (Split-Path -Parent $script:RunnerScript) 'NILinux-VIHistorySuiteBootstrap.sh'
    $resultsDirWsl = Convert-TestPathToWsl -Path $resultsDir
    $suiteManifestWsl = Convert-TestPathToWsl -Path $suiteManifestPath
    $historyContextWsl = Convert-TestPathToWsl -Path $historyContextPath
    $receiptWsl = Convert-TestPathToWsl -Path $receiptPath
    $repoRootWsl = Convert-TestPathToWsl -Path $repoRoot
    $gitDirWsl = Convert-TestPathToWsl -Path (Join-Path $repoRoot '.git')
    $pairPlanWsl = Convert-TestPathToWsl -Path (Join-Path $resultsDir 'pair-plan.tsv')
    $ledgerWsl = Convert-TestPathToWsl -Path (Join-Path $resultsDir 'pair-results.tsv')
    $reportPathWsl = Convert-TestPathToWsl -Path $reportPath
    $bootstrapScriptWsl = Convert-TestPathToWsl -Path $bootstrapScript
    $bashScriptPath = Join-Path $work 'emit-suite-bundle.sh'
    $bashScriptWsl = Convert-TestPathToWsl -Path $bashScriptPath
    $bashScriptContent = [string]::Join("`n", @(
      '#!/usr/bin/env bash'
      'set -euo pipefail'
      ("export COMPAREVI_VI_HISTORY_RESULTS_DIR='{0}'" -f $resultsDirWsl)
      ("export COMPAREVI_VI_HISTORY_SUITE_MANIFEST='{0}'" -f $suiteManifestWsl)
      ("export COMPAREVI_VI_HISTORY_CONTEXT='{0}'" -f $historyContextWsl)
      ("export COMPAREVI_VI_HISTORY_BOOTSTRAP_RECEIPT='{0}'" -f $receiptWsl)
      "export COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE='vi-history-sequential-smoke'"
      ("export COMPAREVI_VI_HISTORY_REPO_PATH='{0}'" -f $repoRootWsl)
      ("export COMPAREVI_VI_HISTORY_GIT_DIR='{0}'" -f $gitDirWsl)
      ("export COMPAREVI_VI_HISTORY_GIT_WORK_TREE='{0}'" -f $repoRootWsl)
      "export COMPAREVI_VI_HISTORY_TARGET_PATH='src/Sample.vi'"
      "export COMPAREVI_VI_HISTORY_SOURCE_BRANCH='consumer/branch'"
      "export COMPAREVI_VI_HISTORY_BASELINE_REF='develop'"
      "export COMPAREVI_VI_HISTORY_MAX_PAIRS='2'"
      ("export COMPARE_REPORT_PATH='{0}'" -f $reportPathWsl)
      (". '{0}'" -f $bootstrapScriptWsl)
      ('awk -F ''\t'' -v ledger=''{0}'' ''{{ report=$6; report_dir=report; sub(/\/[^\/]+$/, "", report_dir); system(sprintf("mkdir -p %c%s%c", 34, report_dir, 34)); printf "<html><body>%s</body></html>\n", $7 > report; close(report); printf "%s\t1\tcompleted\ttrue\t%s\t2026-03-10T00:00:00Z\n", $1, report >> ledger; close(ledger); }}'' ''{1}''' -f $ledgerWsl, $pairPlanWsl)
      'comparevi_vi_history_emit_suite_bundle 1 "${COMPARE_REPORT_PATH}" ''2026-03-10T00:00:00Z'''
    )) + "`n"
    [System.IO.File]::WriteAllText($bashScriptPath, $bashScriptContent, [System.Text.UTF8Encoding]::new($false))

    $output = & $bashPath $bashScriptWsl 2>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    Test-Path -LiteralPath $markdownPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $htmlPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $summaryPath -PathType Leaf | Should -BeTrue
    $summarySchemaPath = Join-Path $script:RepoRoot 'docs' 'schemas' 'comparevi-tools-history-facade-v1.schema.json'
    $schemaLitePath = Join-Path $script:RepoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
    & pwsh -NoLogo -NoProfile -File $schemaLitePath -JsonPath $summaryPath -SchemaPath $summarySchemaPath | Out-Null
    $LASTEXITCODE | Should -Be 0

    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
    $summary.schema | Should -Be 'comparevi-tools/history-facade@v1'
    $summary.summary.comparisons | Should -Be 2
    $summary.summary.diffs | Should -Be 2
    @($summary.execution.executedModes) | Should -Be @('default')
    $summary.target.sourceBranchRef | Should -Be 'consumer/branch'

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 12
    $receipt.processedPairs | Should -Be 2
    $receipt.selectedPairs | Should -Be 2
    $receipt.historyReportMarkdownPath | Should -Match 'history-report\.md$'
    $receipt.historyReportHtmlPath | Should -Match 'history-report\.html$'
    $receipt.historySummaryPath | Should -Match 'history-summary\.json$'

    (Get-Content -LiteralPath $markdownPath -Raw) | Should -Match '\| default \| 2 \|'
    (Get-Content -LiteralPath $htmlPath -Raw) | Should -Match 'pair-002'
  }

  It 'blocks viHistory bootstrap when the source branch exceeds the commit safeguard before docker run' {
    $work = Join-Path $TestDrive 'compare-runtime-vi-history-budget'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'

    $repoRoot = Join-Path $work 'consumer-repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    Invoke-WithIsolatedGitWorkspace {
      Push-Location $repoRoot
      try {
        & git init --initial-branch=develop | Out-Null
        & git config user.email 'agent@example.com'
        & git config user.name 'Agent Runner'
        $targetDir = Join-Path $repoRoot 'src'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        $targetPath = Join-Path $targetDir 'Sample.vi'
        Set-Content -LiteralPath $targetPath -Value 'base' -Encoding utf8
        & git add .
        & git commit -m 'initial history repo' | Out-Null
        & git switch -c 'consumer/branch' | Out-Null
        1..3 | ForEach-Object {
          Set-Content -LiteralPath $targetPath -Value ("head-{0}" -f $_) -Encoding utf8
          & git add src/Sample.vi
          & git commit -m ("update sample vi {0}" -f $_) | Out-Null
        }
      } finally {
        Pop-Location | Out-Null
      }
    }

    $runtimeContract = Join-Path $work 'runtime-bootstrap.json'
    $bootstrapScript = Join-Path (Split-Path -Parent $script:RunnerScript) 'NILinux-VIHistorySuiteBootstrap.sh'
    $contract = [ordered]@{
      schema = 'ni-linux-runtime-bootstrap/v1'
      mode = 'vi-history-suite-smoke'
      branchRef = 'consumer/branch'
      maxCommitCount = 2
      scriptPath = $bootstrapScript
      viHistory = [ordered]@{
        repoPath = $repoRoot
        targetPath = 'src/Sample.vi'
        resultsPath = (Join-Path $work 'vi-history-results')
        baselineRef = 'develop'
      }
    }
    $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runtimeContract -Encoding utf8

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -RuntimeBootstrapContractPath $runtimeContract 2>&1
    $LASTEXITCODE | Should -Be 2
    ($output -join "`n") | Should -Match 'exceeds the commit safeguard \(3 > 2\)'

    $logEntries = & $script:ReadDockerStubLog -Path $env:DOCKER_STUB_LOG
    @($logEntries | Where-Object { $_.args[0] -eq 'run' }).Count | Should -Be 0
  }

  It 'falls back to system temp path when TEMP/TMP env vars are unset' {
    $work = Join-Path $TestDrive 'compare-temp-fallback'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed with diff.'
    Remove-Item Env:TEMP -ErrorAction SilentlyContinue
    Remove-Item Env:TMP -ErrorAction SilentlyContinue
    Remove-Item Env:TMPDIR -ErrorAction SilentlyContinue

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

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
    Test-Path -LiteralPath $capturePath -PathType Leaf | Should -BeTrue
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.status | Should -Not -Be 'preflight-error'
    ([string]$capture.message) | Should -Not -Match "Cannot bind argument to parameter 'Path' because it is null"
  }

  It 'removes an existing report file before launching Linux compare execution' {
    $work = Join-Path $TestDrive 'compare-removes-stale-report'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
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
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '0'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed.'
    Set-Item Env:DOCKER_STUB_CP_REPORT_HTML '<summary class="difference-heading"></summary><li class="diff-detail-cosmetic"></li><img class="difference-image" src="x" />'

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

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
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
      $capture.reportAnalysis.diffImageCount | Should -BeGreaterThan 0
    }
    $capture.containerArtifacts.copyStatus | Should -Be 'success' -Because ($capture.containerArtifacts | ConvertTo-Json -Depth 8)
  }

  It 'falls back to exit-code diff classification when container export fails' {
    $work = Join-Path $TestDrive 'compare-export-fallback'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
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

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
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
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
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
    $LASTEXITCODE | Should -BeIn @(0, 1) -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.containerArtifacts.copyStatus | Should -Be 'success' -Because ($capture.containerArtifacts | ConvertTo-Json -Depth 8)
    $capture.containerArtifacts.recoveredCopyCount | Should -Be 1
    $capture.containerArtifacts.copiedPaths.Count | Should -Be 1
    $capture.containerArtifacts.copyAttempts.Count | Should -Be 1
    $capture.containerArtifacts.copyAttempts[0].recoveredFromNonZeroExit | Should -BeTrue
    $capture.containerArtifacts.copyAttempts[0].recoveryKind | Should -Be 'nonzero-exit'
    Test-Path -LiteralPath ([string]$capture.reportAnalysis.reportPathExtracted) -PathType Leaf | Should -BeTrue
  }

  It 'recovers exported report artifacts when docker cp reports a failure but a host-visible report exists' {
    $work = Join-Path $TestDrive 'compare-export-host-report'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
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
    $LASTEXITCODE | Should -BeIn @(0, 1) -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.containerArtifacts.copyStatus | Should -Be 'success'
    $capture.containerArtifacts.recoveredCopyCount | Should -Be 1
    $capture.containerArtifacts.copyAttempts[0].recoveryKind | Should -BeIn @('host-report', 'nonzero-exit')
    Test-Path -LiteralPath ([string]$capture.reportAnalysis.reportPathExtracted) -PathType Leaf | Should -BeTrue
  }

  It 'suppresses daemon noise when host-report recovery succeeds after the container is already gone' {
    $work = Join-Path $TestDrive 'compare-export-container-missing'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
    Set-Item Env:DOCKER_STUB_RUN_EXIT_CODE '0'
    Set-Item Env:DOCKER_STUB_RUN_STDOUT 'CreateComparisonReport completed.'
    Set-Item Env:DOCKER_STUB_RUN_WRITE_REPORT '1'
    Set-Item Env:DOCKER_STUB_CP_FAIL '1'
    Set-Item Env:DOCKER_STUB_CP_STDERR 'Error response from daemon: No such container: synthetic-container'
    Set-Item Env:DOCKER_STUB_RM_EXIT_CODE '1'
    Set-Item Env:DOCKER_STUB_RM_STDERR 'Error response from daemon: No such container: synthetic-container'

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
    ($output -join "`n") | Should -Not -Match 'No such container'

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $capture.containerArtifacts.copyStatus | Should -Be 'success'
    $capture.containerArtifacts.recoveredCopyCount | Should -Be 1
    $capture.containerArtifacts.copyAttempts[0].recoveryKind | Should -BeIn @('host-report', 'nonzero-exit')
  }

  It 'classifies exit 1 with CLI error signature as failure-tool' {
    $work = Join-Path $TestDrive 'compare-tool-failure'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
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

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
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
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '1'
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

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
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

  It 'classifies timeout with deterministic timeout exit code' {
    $work = Join-Path $TestDrive 'compare-timeout'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
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
      -RuntimeEngineReadyTimeoutSeconds 5 `
      -RuntimeEngineReadyPollSeconds 1 `
      -TimeoutSeconds 1 2>&1
    $LASTEXITCODE | Should -BeIn @(1, 124) -Because ($output -join "`n")

    $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-linux-container-capture.json'
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

  It 'fails fast when image is missing with actionable preflight message' {
    $work = Join-Path $TestDrive 'compare-missing-image'
    New-Item -ItemType Directory -Path $work | Out-Null
    & $script:NewDockerStub -WorkRoot $work | Out-Null

    Set-Item Env:DOCKER_STUB_LOG (Join-Path $work 'docker-log.ndjson')
    Set-Item Env:DOCKER_STUB_OSTYPE 'linux'
    Set-Item Env:DOCKER_STUB_CONTEXT 'desktop-linux'
    Set-Item Env:DOCKER_STUB_IMAGE_EXISTS '0'

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
    ($output -join "`n") | Should -Match "Docker image 'nationalinstruments/labview:2026q1-linux' not found locally"
  }

  It 'prefers invoking LabVIEWCLI by PATH token inside the Linux runner script' {
    $scriptContent = Get-Content -LiteralPath $script:RunnerScript -Raw
    $scriptContent | Should -Match 'if command -v LabVIEWCLI >/dev/null 2>&1; then\s+echo "LabVIEWCLI"\s+return 0'
    $scriptContent | Should -Match 'if command -v labviewcli >/dev/null 2>&1; then\s+echo "labviewcli"\s+return 0'
    $scriptContent | Should -Match 'CLI_ARGS_BASE\+=\("-Headless" "true"\)'
  }
}
