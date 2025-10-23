Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-PathSafe {
  param([string]$Path)
  if (-not $Path) { return $null }
  try {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    return $resolved.ProviderPath
  } catch {
    return $null
  }
}

function Read-JsonFile {
  param([string]$Path)
  $info = [ordered]@{
    Exists = $false
    Path   = Resolve-PathSafe -Path $Path
    Data   = $null
    Error  = $null
  }
  if (-not $info.Path) { return [pscustomobject]$info }

  $info.Exists = $true
  try {
    $raw = Get-Content -LiteralPath $info.Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]$info }
    $info.Data = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $info.Error = $_.Exception.Message
  }
  return [pscustomobject]$info
}

function Read-FileLines {
  param([string]$Path)
  $resolved = Resolve-PathSafe -Path $Path
  if (-not $resolved) { return [pscustomobject]@{ Exists = $false; Path = $resolved; Lines = @(); Error = $null } }
  try {
    $lines = Get-Content -LiteralPath $resolved -ErrorAction Stop
  } catch {
    return [pscustomobject]@{ Exists = $false; Path = $resolved; Lines = @(); Error = $_.Exception.Message }
  }
  return [pscustomobject]@{ Exists = $true; Path = $resolved; Lines = $lines; Error = $null }
}

function Read-NdjsonFile {
  param([string]$Path)
  $info = [ordered]@{
    Exists = $false
    Path   = Resolve-PathSafe -Path $Path
    Items  = @()
    Error  = $null
  }
  if (-not $info.Path) { return [pscustomobject]$info }

  $info.Exists = $true
  try {
    $builder = New-Object System.Text.StringBuilder
    foreach ($line in Get-Content -LiteralPath $info.Path) {
      if ([string]::IsNullOrWhiteSpace($line)) {
        if ($builder.Length -gt 0) {
          $info.Items += ($builder.ToString() | ConvertFrom-Json -ErrorAction Stop)
          $null = $builder.Clear()
        }
      } else {
        $null = $builder.AppendLine($line)
      }
    }
    if ($builder.Length -gt 0) {
      $info.Items += ($builder.ToString() | ConvertFrom-Json -ErrorAction Stop)
    }
  } catch {
    $info.Error = $_.Exception.Message
  }
  return [pscustomobject]$info
}

function ConvertTo-DateTime {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  try {
    $style = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    return [DateTime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $style)
  } catch { return $null }
}

function Get-LabVIEWSnapshot {
  [CmdletBinding()]
  param(
    [string]$SnapshotPath
  )

  if (-not $SnapshotPath) {
    $snapshotDefault = Join-Path $script:repoRoot 'tests' 'results' '_warmup' 'labview-processes.json'
    $SnapshotPath = $snapshotDefault
  }

  $info = Read-JsonFile -Path $SnapshotPath
  $errors = @()
  if ($info.Error) { $errors += "labview-processes.json: $($info.Error)" }

  $data = $info.Data
  $processes = @()
  $processCount = 0
  $labviewObject = $null
  $lvcompareObject = $null
  if ($data) {
    if ($data.PSObject.Properties.Name -contains 'labview' -and $data.labview) {
      $labviewObject = [pscustomobject]@{
        Count     = ($data.labview.count ?? $data.labview.processes.Count)
        Processes = @($data.labview.processes)
      }
      $processes = $labviewObject.Processes
      $processCount = $labviewObject.Count
    } elseif ($data.PSObject.Properties.Name -contains 'processes') {
      $processes = @($data.processes)
      $processCount = if ($data.PSObject.Properties.Name -contains 'processCount') {
        try { [int]$data.processCount } catch { $processes.Count }
      } else { $processes.Count }
    }

    if ($data.PSObject.Properties.Name -contains 'lvcompare' -and $data.lvcompare) {
      $lvcompareObject = [pscustomobject]@{
        Count     = ($data.lvcompare.count ?? $data.lvcompare.processes.Count)
        Processes = @($data.lvcompare.processes)
      }
    }
  }

  if (-not $labviewObject) {
    $labviewObject = [pscustomobject]@{ Count = $processCount; Processes = $processes }
  }
  if (-not $lvcompareObject) {
    $lvcompareObject = [pscustomobject]@{ Count = 0; Processes = @() }
  }

  return [pscustomobject][ordered]@{
    SnapshotPath = $info.Path
    Exists       = $info.Exists
    Snapshot     = $data
    ProcessCount = $processCount
    Processes    = $processes
    LabVIEW      = $labviewObject
    LVCompare    = $lvcompareObject
    Errors       = $errors
  }
}

function Get-CompareOutcomeTelemetry {
  [CmdletBinding()]
  param(
    [string]$ResultsRoot
  )

  if (-not $ResultsRoot) {
    $ResultsRoot = Join-Path $script:repoRoot 'tests' 'results'
  }

  $resolvedRoot = Resolve-PathSafe -Path $ResultsRoot
  if (-not $resolvedRoot) { return $null }

  $latestOutcome = $null
  $outcome = Get-ChildItem -Path $resolvedRoot -Filter 'compare-outcome.json' -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($outcome) {
    try {
      $data = Get-Content -LiteralPath $outcome.FullName -Raw | ConvertFrom-Json -Depth 8
      $latestOutcome = [pscustomobject][ordered]@{
        Source       = if ($data.source) { $data.source } else { 'compare-outcome' }
        JsonPath     = $outcome.FullName
        CapturePath  = if ($data.captureJson) { $data.captureJson } else { $data.file }
        ReportPath   = if ($data.reportPath) { $data.reportPath } else { $null }
        ExitCode     = if ($data.exitCode -ne $null) { [int]$data.exitCode } else { $null }
        Diff         = if ($data.diff -ne $null) { [bool]$data.diff } else { $null }
        DurationMs   = if ($data.durationMs -ne $null) { [double]$data.durationMs } else { $null }
        CliPath      = if ($data.cliPath) { $data.cliPath } else { $null }
        Command      = if ($data.command) { $data.command } else { $null }
        CliArtifacts = if ($data.cliArtifacts) { $data.cliArtifacts } else { $null }
      }
    } catch {
      $latestOutcome = $null
    }
  }

  if (-not $latestOutcome) {
    $capture = Get-ChildItem -Path $resolvedRoot -Filter 'lvcompare-capture.json' -Recurse -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

    if ($capture) {
      try {
        $cap = Get-Content -LiteralPath $capture.FullName -Raw | ConvertFrom-Json -Depth 6
        $exitCode = if ($cap.exitCode -ne $null) { [int]$cap.exitCode } else { $null }
        $diff = if ($exitCode -ne $null) { $exitCode -eq 1 } else { $null }
        $durationMs = $null
        if ($cap.seconds -ne $null) { $durationMs = [math]::Round([double]$cap.seconds * 1000, 3) }
        $cliPath = if ($cap.cliPath) { [string]$cap.cliPath } else { $null }
        $command = if ($cap.command) { [string]$cap.command } else { $null }

        $artifacts = $null
        if ($cap.environment -and $cap.environment.cli -and $cap.environment.cli.PSObject.Properties.Name -contains 'artifacts') {
          $artifacts = $cap.environment.cli.artifacts
        }

        $reportPath = $null
        if ($cap.environment -and $cap.environment.cli -and $cap.environment.cli.PSObject.Properties.Name -contains 'reportPath') {
          $reportPath = $cap.environment.cli.reportPath
        }
        if (-not $reportPath) {
          $compareHtml = Join-Path (Split-Path -Parent $capture.FullName) 'compare-report.html'
          if (Test-Path -LiteralPath $compareHtml) { $reportPath = $compareHtml }
          $cliHtml = Join-Path (Split-Path -Parent $capture.FullName) 'cli-report.html'
          if (Test-Path -LiteralPath $cliHtml) { $reportPath = $cliHtml }
        }

        $latestOutcome = [pscustomobject][ordered]@{
          Source       = 'capture'
          JsonPath     = $null
          CapturePath  = $capture.FullName
          ReportPath   = $reportPath
          ExitCode     = $exitCode
          Diff         = $diff
          DurationMs   = $durationMs
          CliPath      = $cliPath
          Command      = $command
          CliArtifacts = $artifacts
        }
      } catch {
        $latestOutcome = $null
      }
    }
  }

  $historySuite = $null
  $historyRoot = Join-Path $resolvedRoot 'ref-compare' 'history'
  $suiteManifestPath = Join-Path $historyRoot 'manifest.json'
  if (Test-Path -LiteralPath $suiteManifestPath) {
    try {
      $suiteRaw = Get-Content -LiteralPath $suiteManifestPath -Raw
      if ($suiteRaw -and $suiteRaw.Trim()) {
        $suite = $suiteRaw | ConvertFrom-Json -Depth 10
        if ($suite -and $suite.schema -eq 'vi-compare/history-suite@v1') {
          $suiteManifestResolved = Resolve-PathSafe -Path $suiteManifestPath

          $modeSummaries = @()
          $modeManifestEntries = @()
          foreach ($mode in @($suite.modes)) {
            if (-not $mode) { continue }
            $modeName = if ($mode.PSObject.Properties.Name -contains 'name') { [string]$mode.name } else { $null }
            $modeSlug = if ($mode.PSObject.Properties.Name -contains 'slug') { [string]$mode.slug } else { $null }
            $modeManifest = if ($mode.PSObject.Properties.Name -contains 'manifestPath') { [string]$mode.manifestPath } else { $null }
            $modeResultsDir = if ($mode.PSObject.Properties.Name -contains 'resultsDir') { [string]$mode.resultsDir } else { $null }
            $modeStatus = if ($mode.PSObject.Properties.Name -contains 'status') { [string]$mode.status } else { $null }
            $statsObj = if ($mode.PSObject.Properties.Name -contains 'stats') { $mode.stats } else { $null }
            $processed = $null
            $diffs = $null
            $errors = $null
            $missing = $null
            $lastDiffIndex = $null
            $lastDiffCommit = $null
            $stopReason = $null
            if ($statsObj) {
              if ($statsObj.PSObject.Properties.Name -contains 'processed') { $processed = $statsObj.processed }
              if ($statsObj.PSObject.Properties.Name -contains 'diffs') { $diffs = $statsObj.diffs }
              if ($statsObj.PSObject.Properties.Name -contains 'errors') { $errors = $statsObj.errors }
              if ($statsObj.PSObject.Properties.Name -contains 'missing') { $missing = $statsObj.missing }
              if ($statsObj.PSObject.Properties.Name -contains 'lastDiffIndex') { $lastDiffIndex = $statsObj.lastDiffIndex }
              if ($statsObj.PSObject.Properties.Name -contains 'lastDiffCommit') { $lastDiffCommit = $statsObj.lastDiffCommit }
              if ($statsObj.PSObject.Properties.Name -contains 'stopReason') { $stopReason = $statsObj.stopReason }
            }

            $resolvedManifestPath = Resolve-PathSafe -Path $modeManifest
            if (-not $resolvedManifestPath) { $resolvedManifestPath = $modeManifest }
            $resolvedResultsDir = Resolve-PathSafe -Path $modeResultsDir
            if (-not $resolvedResultsDir) { $resolvedResultsDir = $modeResultsDir }

            $modeManifestEntries += [ordered]@{
              mode      = $modeName
              slug      = $modeSlug
              manifest  = $resolvedManifestPath
              resultsDir= $resolvedResultsDir
              processed = $processed
              diffs     = $diffs
              status    = $modeStatus
            }

            $modeSummaries += [pscustomobject][ordered]@{
              Mode           = $modeName
              Slug           = $modeSlug
              ManifestPath   = $resolvedManifestPath
              ResultsDir     = $resolvedResultsDir
              Processed      = $processed
              Diffs          = $diffs
              Errors         = $errors
              Missing        = $missing
              Status         = $modeStatus
              StopReason     = $stopReason
              LastDiffIndex  = $lastDiffIndex
              LastDiffCommit = $lastDiffCommit
            }
          }

          $modeManifestsJson = if ($modeManifestEntries.Count -gt 0) {
            (ConvertTo-Json $modeManifestEntries -Depth 4 -Compress)
          } else {
            '[]'
          }

          $historySuite = [pscustomobject][ordered]@{
            ManifestPath      = $suiteManifestResolved
            ResultsDir        = if ($suite.PSObject.Properties.Name -contains 'resultsDir') { $suite.resultsDir } else { $null }
            TargetPath        = if ($suite.PSObject.Properties.Name -contains 'targetPath') { $suite.targetPath } else { $null }
            RequestedStartRef = if ($suite.PSObject.Properties.Name -contains 'requestedStartRef') { $suite.requestedStartRef } else { $null }
            StartRef          = if ($suite.PSObject.Properties.Name -contains 'startRef') { $suite.startRef } else { $null }
            EndRef            = if ($suite.PSObject.Properties.Name -contains 'endRef') { $suite.endRef } else { $null }
            MaxPairs          = if ($suite.PSObject.Properties.Name -contains 'maxPairs') { $suite.maxPairs } else { $null }
            GeneratedAt       = if ($suite.PSObject.Properties.Name -contains 'generatedAt') { $suite.generatedAt } else { $null }
            Stats             = if ($suite.PSObject.Properties.Name -contains 'stats') { $suite.stats } else { $null }
            Status            = if ($suite.PSObject.Properties.Name -contains 'status') { $suite.status } else { $null }
            ModeCount         = $modeSummaries.Count
            Modes             = $modeSummaries
            ModeManifestsJson = $modeManifestsJson
          }
        }
      }
    } catch {
      $historySuite = $null
    }
  }

  if (-not $latestOutcome -and -not $historySuite) { return $null }

  $resultOrdered = [ordered]@{}
  if ($latestOutcome) {
    foreach ($prop in $latestOutcome.PSObject.Properties) {
      $resultOrdered[$prop.Name] = $prop.Value
    }
    $resultOrdered['LatestOutcome'] = $latestOutcome
  }
  if ($historySuite) {
    $resultOrdered['HistorySuite'] = $historySuite
  }

  return [pscustomobject]$resultOrdered
}

function Get-SessionLockStatus {
  [CmdletBinding()]
  param(
    [string]$Group = 'pester-selfhosted',
    [string]$ResultsRoot,
    [string]$LockRoot
  )

  if (-not $ResultsRoot) {
    $ResultsRoot = Join-Path $script:repoRoot 'tests' 'results'
  }
  if (-not $LockRoot) {
    $LockRoot = Join-Path $ResultsRoot '_session_lock'
  }

  $groupDir = Join-Path $LockRoot $Group
  $lockPath = Join-Path $groupDir 'lock.json'
  $statusPath = Join-Path $groupDir 'status.md'

  if (-not (Test-Path -LiteralPath $lockPath) -and (Test-Path -LiteralPath (Join-Path $LockRoot 'lock.json'))) {
    $groupDir = $LockRoot
    $lockPath = Join-Path $groupDir 'lock.json'
    $statusPath = Join-Path $groupDir 'status.md'
  }
  if (-not (Test-Path -LiteralPath $lockPath)) {
    $parentRoot = Split-Path -Parent $LockRoot
    if ($parentRoot -and (Test-Path -LiteralPath (Join-Path $parentRoot 'lock.json'))) {
      $groupDir = $parentRoot
      $lockPath = Join-Path $groupDir 'lock.json'
      $statusPath = Join-Path $groupDir 'status.md'
    }
  }

  $lockInfo = Read-JsonFile -Path $lockPath
  $statusInfo = Read-FileLines -Path $statusPath

  $statusPairs = @{}
  if ($statusInfo.Exists) {
    foreach ($line in $statusInfo.Lines) {
      if ($line -match '^\s*-\s*(?<key>[^:]+):\s*(?<value>.*)$') {
        $key = $matches.key.Trim()
        $value = $matches.value.Trim()
        $statusPairs[$key] = $value
      }
    }
  }

  $lock = $lockInfo.Data
  $acquiredAt = if ($lock) { ConvertTo-DateTime -Value $lock.acquiredAt } else { $null }
  $heartbeatAt = if ($lock) { ConvertTo-DateTime -Value $lock.heartbeatAt } else { $null }
  $heartbeatAge = $null
  if ($heartbeatAt) {
    $heartbeatAge = ([DateTime]::UtcNow - $heartbeatAt).TotalSeconds
    if ($heartbeatAge -lt 0) { $heartbeatAge = 0 }
  }

  $queueWait = $null
  if ($lock -and $lock.PSObject.Properties.Name -contains 'queueWaitSeconds') {
    $queueWait = [int]$lock.queueWaitSeconds
  } elseif ($statusPairs.ContainsKey('Queue wait (s)')) {
    if ([double]::TryParse($statusPairs['Queue wait (s)'], [ref]([double]0))) {
      $queueWait = [int][double]::Parse($statusPairs['Queue wait (s)'], [System.Globalization.CultureInfo]::InvariantCulture)
    }
  }

  $status = 'missing'
  if ($statusPairs.ContainsKey('Status')) {
    $status = $statusPairs['Status']
  } elseif ($lock) {
    $status = 'acquired'
  }

  $errors = @()
  if ($lockInfo.Error) { $errors += "lock.json: $($lockInfo.Error)" }
  if ($statusInfo.Error) { $errors += "status.md: $($statusInfo.Error)" }

  return [pscustomobject][ordered]@{
    Group               = $Group
    LockDirectory       = Resolve-PathSafe -Path $groupDir
    LockPath            = $lockInfo.Path
    StatusPath          = $statusInfo.Path
    Exists              = $lockInfo.Exists
    Status              = $status
    Lock                = $lock
    SessionName         = if ($lock -and $lock.PSObject.Properties.Name -contains 'sessionName') { $lock.sessionName } else { $null }
    StatusPairs         = $statusPairs
    QueueWaitSeconds    = $queueWait
    AcquiredAt          = $acquiredAt
    HeartbeatAt         = $heartbeatAt
    HeartbeatAgeSeconds = $heartbeatAge
    Takeover            = if ($lock -and $lock.PSObject.Properties.Name -contains 'takeover') { [bool]$lock.takeover } else { $false }
    TakeoverReason      = if ($lock -and $lock.PSObject.Properties.Name -contains 'takeoverReason') { $lock.takeoverReason } else { $null }
    Errors              = $errors
  }
}

function Get-PesterTelemetry {
  [CmdletBinding()]
  param(
    [string]$ResultsRoot
  )

  if (-not $ResultsRoot) {
    $ResultsRoot = Join-Path $script:repoRoot 'tests' 'results'
  }

  $summaryPath = Join-Path $ResultsRoot 'pester-summary.json'
  $resultsPath = Join-Path $ResultsRoot 'pester-results.xml'
  $dispatcherPath = Join-Path $ResultsRoot 'pester-dispatcher.log'

  $summaryInfo = Read-JsonFile -Path $summaryPath
  $dispatcherInfo = Read-FileLines -Path $dispatcherPath

  $totals = [ordered]@{
    Total    = 0
    Passed   = 0
    Failed   = 0
    Errors   = 0
    Skipped  = 0
    Duration = $null
  }

  $failedTests = @()
  if ($summaryInfo.Data) {
    $model = $summaryInfo.Data
    foreach ($name in @('total','passed','failed','errors','skipped')) {
      if ($model.PSObject.Properties.Name -contains $name) {
        $totals[$name.Substring(0,1).ToUpper() + $name.Substring(1)] = [int]$model.$name
      }
    }
    if ($model.PSObject.Properties.Name -contains 'duration_s') {
      $totals.Duration = [double]$model.duration_s
    }
    if ($model.PSObject.Properties.Name -contains 'tests') {
      foreach ($test in $model.tests) {
        if ($test.result -and $test.result -ne 'Passed') {
          $failedTests += [pscustomobject]@{
            Name   = $test.name
            Result = $test.result
          }
        }
      }
    }
  }

  $dispatcherErrors = @()
  $dispatcherWarnings = @()
  if ($dispatcherInfo.Exists) {
    foreach ($line in $dispatcherInfo.Lines) {
      if ($line -match '##\[error\](?<msg>.+)$') {
        $dispatcherErrors += $matches.msg.Trim()
      } elseif ($line -match '##\[warning\](?<msg>.+)$') {
        $dispatcherWarnings += $matches.msg.Trim()
      }
    }
  }

  $errors = @()
  if ($summaryInfo.Error) { $errors += "pester-summary.json: $($summaryInfo.Error)" }
  if ($dispatcherInfo.Error) { $errors += "pester-dispatcher.log: $($dispatcherInfo.Error)" }

  $sessionIndexPath = Join-Path $ResultsRoot 'session-index.json'
  $sessionIndexInfo = Read-JsonFile -Path $sessionIndexPath
  if ($sessionIndexInfo.Error) { $errors += "session-index.json: $($sessionIndexInfo.Error)" }
  $sessionStatus = $null
  $sessionIncludeIntegration = $null
  $runnerInfo = $null
  if ($sessionIndexInfo.Data) {
    $sessionData = $sessionIndexInfo.Data
    if ($sessionData.PSObject.Properties.Name -contains 'status') {
      $sessionStatus = $sessionData.status
    }
    if ($sessionData.PSObject.Properties.Name -contains 'includeIntegration') {
      try { $sessionIncludeIntegration = [bool]$sessionData.includeIntegration } catch { $sessionIncludeIntegration = $sessionData.includeIntegration }
    }
    $runContext = if ($sessionData.PSObject.Properties.Name -contains 'runContext') { $sessionData.runContext } else { $null }
    if ($runContext) {
      $runnerProps = [ordered]@{}
      $nameProp = $runContext.PSObject.Properties['runner']
      if ($nameProp -and $nameProp.Value) { $runnerProps['Name'] = $nameProp.Value }
      $osProp = $runContext.PSObject.Properties['runnerOS']
      $archProp = $runContext.PSObject.Properties['runnerArch']
      if ($osProp -and $osProp.Value -and $archProp -and $archProp.Value) {
        $runnerProps['OS'] = $osProp.Value
        $runnerProps['Arch'] = $archProp.Value
      } elseif ($osProp -and $osProp.Value) {
        $runnerProps['OS'] = $osProp.Value
      } elseif ($archProp -and $archProp.Value) {
        $runnerProps['Arch'] = $archProp.Value
      }
      $envProp = $runContext.PSObject.Properties['runnerEnvironment']
      if ($envProp -and $envProp.Value) { $runnerProps['Environment'] = $envProp.Value }
      $machineProp = $runContext.PSObject.Properties['runnerMachine']
      if ($machineProp -and $machineProp.Value) { $runnerProps['Machine'] = $machineProp.Value }
      $imageOsProp = $runContext.PSObject.Properties['runnerImageOS']
      $imageVersionProp = $runContext.PSObject.Properties['runnerImageVersion']
      if ($imageOsProp -and $imageOsProp.Value) { $runnerProps['ImageOS'] = $imageOsProp.Value }
      if ($imageVersionProp -and $imageVersionProp.Value) { $runnerProps['ImageVersion'] = $imageVersionProp.Value }
      $labelsList = @()
      if ($runContext.PSObject.Properties.Name -contains 'runnerLabels') {
        $rawLabels = $runContext.runnerLabels
        if ($null -ne $rawLabels) {
          if ($rawLabels -is [System.Collections.IEnumerable] -and -not ($rawLabels -is [string])) {
            foreach ($label in $rawLabels) {
              if ($label -and "$label" -ne '') { $labelsList += "$label" }
            }
          } elseif ($rawLabels -and "$rawLabels" -ne '') {
            $labelsList += "$rawLabels"
          }
        }
      }
      if ($labelsList.Count -gt 0) {
        $unique = $labelsList | Where-Object { $_ -and $_ -ne '' } | Select-Object -Unique
        if ($unique.Count -gt 0) { $runnerProps['Labels'] = $unique }
      }
      if ($runnerProps.Count -gt 0) {
        $runnerInfo = [pscustomobject]$runnerProps
      }
    }
  }

  return [pscustomobject][ordered]@{
    SummaryPath        = $summaryInfo.Path
    ResultsPath        = Resolve-PathSafe -Path $resultsPath
    DispatcherLogPath  = $dispatcherInfo.Path
    Totals             = $totals
    FailedTests        = $failedTests
    DispatcherErrors   = $dispatcherErrors
    DispatcherWarnings = $dispatcherWarnings
    SessionIndexPath   = $sessionIndexInfo.Path
    SessionStatus      = $sessionStatus
    SessionIncludeIntegration = $sessionIncludeIntegration
    Runner             = $runnerInfo
    Errors             = $errors
  }
}

function Get-AgentWaitTelemetry {
  [CmdletBinding()]
  param(
    [string]$ResultsRoot
  )

  if (-not $ResultsRoot) {
    $ResultsRoot = Join-Path $script:repoRoot 'tests' 'results'
  }

  $waitPath = Join-Path $ResultsRoot '_agent' 'wait-last.json'
  if (-not (Test-Path -LiteralPath $waitPath) -and (Test-Path -LiteralPath (Join-Path $ResultsRoot 'wait-last.json'))) {
    $waitPath = Join-Path $ResultsRoot 'wait-last.json'
  }
  $waitInfo = Read-JsonFile -Path $waitPath

  $waitLogPath = Join-Path $ResultsRoot '_agent' 'wait-log.ndjson'
  if (-not (Test-Path -LiteralPath $waitLogPath) -and (Test-Path -LiteralPath (Join-Path $ResultsRoot 'wait-log.ndjson'))) {
    $waitLogPath = Join-Path $ResultsRoot 'wait-log.ndjson'
  }
  $waitLogInfo = Read-NdjsonFile -Path $waitLogPath

  $started = $null
  $completed = $null
  $duration = $null

  if ($waitInfo.Data) {
    if ($waitInfo.Data.PSObject.Properties.Name -contains 'StartedAt') {
      $started = ConvertTo-DateTime -Value $waitInfo.Data.StartedAt
    }
    if ($waitInfo.Data.PSObject.Properties.Name -contains 'CompletedAt') {
      $completed = ConvertTo-DateTime -Value $waitInfo.Data.CompletedAt
    }
    if ($waitInfo.Data.PSObject.Properties.Name -contains 'WaitSeconds') {
      $duration = [double]$waitInfo.Data.WaitSeconds
    } elseif ($started -and $completed) {
      $duration = ($completed - $started).TotalSeconds
    }
  }

  $errors = @()
  if ($waitInfo.Error) { $errors += "wait-last.json: $($waitInfo.Error)" }
  if ($waitLogInfo.Error) { $errors += "wait-log.ndjson: $($waitLogInfo.Error)" }

  $history = @()
  if ($waitLogInfo.Items) {
    foreach ($entry in $waitLogInfo.Items) {
      $history += [pscustomobject][ordered]@{
        Reason        = $entry.reason
        Expected      = if ($entry.PSObject.Properties.Name -contains 'expectedSeconds') { [double]$entry.expectedSeconds } else { $null }
        Elapsed       = if ($entry.PSObject.Properties.Name -contains 'elapsedSeconds') { [double]$entry.elapsedSeconds } else { $null }
        Difference    = if ($entry.PSObject.Properties.Name -contains 'differenceSeconds') { [double]$entry.differenceSeconds } else { $null }
        WithinMargin  = if ($entry.PSObject.Properties.Name -contains 'withinMargin') { [bool]$entry.withinMargin } else { $null }
        StartedAt     = ConvertTo-DateTime -Value $entry.startedUtc
        EndedAt       = ConvertTo-DateTime -Value $entry.endedUtc
      }
    }
  }
  $longest = $null
  if ($history.Count -gt 0) {
    $longest = ($history | Sort-Object -Property Elapsed -Descending | Select-Object -First 1)
  }

  return [pscustomobject][ordered]@{
    WaitPath      = $waitInfo.Path
    WaitLogPath   = $waitLogInfo.Path
    Exists        = $waitInfo.Exists
    Reason        = if ($waitInfo.Data) { $waitInfo.Data.Reason } else { $null }
    StartedAt     = $started
    CompletedAt   = $completed
    DurationSeconds = $duration
    Raw           = $waitInfo.Data
    History       = $history
    Longest       = $longest
    Errors        = $errors
  }
}

function Get-WatchTelemetry {
  [CmdletBinding()]
  param(
    [string]$ResultsRoot
  )

  if (-not $ResultsRoot) {
    $ResultsRoot = Join-Path $script:repoRoot 'tests' 'results'
  }

  $watchDir = Join-Path $ResultsRoot '_watch'
  $lastPath = Join-Path $watchDir 'watch-last.json'
  $logPath = Join-Path $watchDir 'watch-log.ndjson'
  if (-not (Test-Path -LiteralPath $lastPath) -and (Test-Path -LiteralPath (Join-Path $ResultsRoot 'watch-last.json'))) {
    $lastPath = Join-Path $ResultsRoot 'watch-last.json'
  }
  if (-not (Test-Path -LiteralPath $logPath) -and (Test-Path -LiteralPath (Join-Path $ResultsRoot 'watch-log.ndjson'))) {
    $logPath = Join-Path $ResultsRoot 'watch-log.ndjson'
  }

  $lastInfo = Read-JsonFile -Path $lastPath
  $logInfo = Read-NdjsonFile -Path $logPath

  $errors = @()
  if ($lastInfo.Error) { $errors += "watch-last.json: $($lastInfo.Error)" }
  if ($logInfo.Error) { $errors += "watch-log.ndjson: $($logInfo.Error)" }

  $last = $lastInfo.Data
  $history = @()
  if ($logInfo.Items) {
    foreach ($entry in $logInfo.Items) {
      $history += [pscustomobject][ordered]@{
        Timestamp     = ConvertTo-DateTime -Value $entry.timestamp
        Status        = $entry.status
        Classification= $entry.classification
        Tests         = if ($entry.stats) { [int]$entry.stats.tests } else { $null }
        Failed        = if ($entry.stats) { [int]$entry.stats.failed } else { $null }
        Skipped       = if ($entry.stats) { [int]$entry.stats.skipped } else { $null }
        RunSequence   = $entry.runSequence
      }
    }
  }
  $stalled = $false
  $stalledSeconds = $null
  if ($history.Count -gt 0) {
    $lastTs = $history[-1].Timestamp
    if ($lastTs) {
      $stalledSeconds = ([DateTime]::UtcNow - $lastTs).TotalSeconds
      if ($stalledSeconds -gt 600) { $stalled = $true }
    }
  }

  return [pscustomobject][ordered]@{
    LastPath      = $lastInfo.Path
    LogPath       = $logInfo.Path
    Last          = $last
    History       = $history
    Stalled       = $stalled
    StalledSeconds= $stalledSeconds
    Errors        = $errors
  }
}

function Get-StakeholderInfo {
  [CmdletBinding()]
  param(
    [string]$Group,
    [string]$StakeholderPath
  )

  if (-not $StakeholderPath) {
    $StakeholderPath = Join-Path $PSScriptRoot 'dashboard' 'stakeholders.json'
  }

  $info = Read-JsonFile -Path $StakeholderPath

  $entry = $null
  if ($info.Data -and $Group) {
    foreach ($property in $info.Data.PSObject.Properties) {
      if ($property.Name -ieq $Group) {
        $entry = $property.Value
        break
      }
    }
  }

  $channels = @()
  if ($entry -and $entry.channels) {
    $channels = @($entry.channels | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -ne '' })
  }
  $errorList = @()
  if ($info.Error) {
    $errorList = @("stakeholders.json: $($info.Error)")
  }

  return [pscustomobject][ordered]@{
    ConfigPath   = $info.Path
    Found        = [bool]$entry
    Group        = $Group
    PrimaryOwner = if ($entry) { $entry.primaryOwner } else { $null }
    Backup       = if ($entry) { $entry.backup } else { $null }
    Channels     = $channels
    DxIssue      = if ($entry) { $entry.dxIssue } else { $null }
    Errors       = $errorList
  }
}

function Get-ActionItems {
  [CmdletBinding()]
  param(
    [pscustomobject]$SessionLock,
    [pscustomobject]$PesterTelemetry,
    [pscustomobject]$AgentWait,
    [pscustomobject]$Stakeholder,
    [pscustomobject]$WatchTelemetry,
    [pscustomobject]$LabVIEWSnapshot
  )

  $items = @()

  if ($SessionLock) {
    if (-not $SessionLock.Exists) {
      $items += [pscustomobject]@{
        Category = 'SessionLock'
        Severity = 'info'
        Message  = "No session lock data found for group '$($SessionLock.Group)'. Run the workflow or inspect local artifacts under $($SessionLock.LockDirectory)."
      }
    } else {
      if ($SessionLock.Status -match 'stale') {
        $target = if ($Stakeholder -and $Stakeholder.PrimaryOwner) { "@$($Stakeholder.PrimaryOwner)" } else { 'owner' }
        $items += [pscustomobject]@{
          Category = 'SessionLock'
          Severity = 'warning'
          Message  = "Stale session lock detected; contact $target or run `tools/Session-Lock.ps1 -Action Inspect -Group $($SessionLock.Group)` and takeover if appropriate."
        }
      } elseif ($SessionLock.Status -match 'queue-timeout') {
        $items += [pscustomobject]@{
          Category = 'SessionLock'
          Severity = 'warning'
          Message  = "Session lock queue timed out after $($SessionLock.QueueWaitSeconds) seconds. Re-run with `SESSION_FORCE_TAKEOVER=1` if the lock is safe to reclaim."
        }
      } elseif ($SessionLock.QueueWaitSeconds -and $SessionLock.QueueWaitSeconds -gt 180) {
        $items += [pscustomobject]@{
          Category = 'SessionLock'
          Severity = 'info'
          Message  = "Queue wait reached $($SessionLock.QueueWaitSeconds) seconds; monitor runner availability or prepare for takeover if delays persist."
        }
      } elseif ($SessionLock.HeartbeatAgeSeconds -and $SessionLock.HeartbeatAgeSeconds -gt 120) {
        $items += [pscustomobject]@{
          Category = 'SessionLock'
          Severity = 'warning'
          Message  = "Heartbeat older than $([math]::Round($SessionLock.HeartbeatAgeSeconds,0)) seconds. Inspect the lock and ensure the heartbeat job is running."
        }
      }
      if ($SessionLock.Takeover -or ($SessionLock.Status -match 'takeover')) {
        $reason = if ($SessionLock.TakeoverReason) { "Reason: $($SessionLock.TakeoverReason)." } else { '' }
        $items += [pscustomobject]@{
          Category = 'SessionLock'
          Severity = 'info'
          Message  = "Session lock takeover recorded for '$($SessionLock.Group)'. $reason Review the summary to confirm ownership."
        }
      }
    }
    $sessionErrors = @()
    if ($SessionLock.Errors) {
      $sessionErrors = @($SessionLock.Errors | Where-Object { $_ -and $_ -ne '' })
    }
    foreach ($error in $sessionErrors) {
      $items += [pscustomobject]@{
        Category = 'SessionLock'
        Severity = 'error'
        Message  = "Unable to load session lock artifact ($error)."
      }
    }
  }

  if ($PesterTelemetry) {
    if ($PesterTelemetry.Totals.Failed -gt 0 -or $PesterTelemetry.Totals.Errors -gt 0) {
      $resultsReference = $PesterTelemetry.ResultsPath
      if (-not $resultsReference) {
        $resultsReference = $PesterTelemetry.SummaryPath
      }
      if (-not $resultsReference) {
        $resultsReference = 'tests/results'
      }
      $items += [pscustomobject]@{
        Category = 'Pester'
        Severity = 'error'
        Message  = "Pester reported $($PesterTelemetry.Totals.Failed) failures and $($PesterTelemetry.Totals.Errors) errors; inspect $resultsReference for details."
      }
    } elseif (-not $PesterTelemetry.SummaryPath) {
      $items += [pscustomobject]@{
        Category = 'Pester'
        Severity = 'info'
        Message  = "No pester-summary.json found. Run `./Invoke-PesterTests.ps1` to populate telemetry."
      }
    }

    foreach ($msg in $PesterTelemetry.DispatcherErrors) {
      $items += [pscustomobject]@{
        Category = 'Pester'
        Severity = 'error'
        Message  = "Dispatcher error: $msg"
      }
    }
    foreach ($msg in $PesterTelemetry.DispatcherWarnings) {
      $items += [pscustomobject]@{
        Category = 'Pester'
        Severity = 'warning'
        Message  = "Dispatcher warning: $msg"
      }
    }
    foreach ($error in $PesterTelemetry.Errors) {
      $items += [pscustomobject]@{
        Category = 'Pester'
        Severity = 'error'
        Message  = "Unable to parse Pester artifact ($error)."
      }
    }
  }

  if ($AgentWait) {
    if ($AgentWait.Exists -and $AgentWait.DurationSeconds -gt 0) {
      $items += [pscustomobject]@{
        Category = 'Queue'
        Severity = if ($AgentWait.DurationSeconds -gt 600) { 'warning' } else { 'info' }
        Message  = "Recent agent wait: $([math]::Round($AgentWait.DurationSeconds,0)) seconds for '$($AgentWait.Reason)'. Review concurrency or runner availability."
      }
    }
    $agentErrors = @()
    if ($AgentWait.Errors) {
      $agentErrors = @($AgentWait.Errors | Where-Object { $_ -and $_ -ne '' })
    }
    foreach ($error in $agentErrors) {
      $items += [pscustomobject]@{
        Category = 'Queue'
        Severity = 'error'
        Message  = "Unable to read Agent-Wait telemetry ($error)."
      }
    }
    if ($AgentWait.History -and $AgentWait.History.Count -gt 0) {
      $latest = $AgentWait.History[-1]
      if ($latest -and $latest.WithinMargin -eq $false) {
        $items += [pscustomobject]@{
          Category = 'Queue'
          Severity = 'warning'
          Message  = "Latest agent wait for '$($latest.Reason)' exceeded tolerance (elapsed $([math]::Round($latest.Elapsed,0))s vs expected $([math]::Round($latest.Expected,0))s)."
        }
      }
      if ($AgentWait.Longest -and $AgentWait.Longest.Elapsed -gt 600) {
        $items += [pscustomobject]@{
          Category = 'Queue'
          Severity = 'warning'
          Message  = "Longest recorded agent wait is $([math]::Round($AgentWait.Longest.Elapsed,0)) seconds for '$($AgentWait.Longest.Reason)'. Consider scaling runner capacity."
        }
      }
    }
  }

  if ($Stakeholder -and -not $Stakeholder.Found) {
    $items += [pscustomobject]@{
      Category = 'Stakeholders'
      Severity = 'info'
      Message  = "Stakeholder mapping missing for group '$($Stakeholder.Group)'. Update $($Stakeholder.ConfigPath) to include owners and channels."
    }
  } elseif ($Stakeholder -and $Stakeholder.Found -and $Stakeholder.DxIssue) {
    $issue = $Stakeholder.DxIssue
    $message = "Consult DX issue #$issue for mitigation steps."
    if ($env:GITHUB_REPOSITORY) {
      $message += " https://github.com/$env:GITHUB_REPOSITORY/issues/$issue"
    }
    $items += [pscustomobject]@{
      Category = 'Stakeholders'
      Severity = 'info'
      Message  = $message
    }
  }

  if ($WatchTelemetry) {
    if ($WatchTelemetry.Stalled -and $WatchTelemetry.StalledSeconds -gt 0) {
      $items += [pscustomobject]@{
        Category = 'Watch'
        Severity = 'warning'
        Message  = "Watch loop appears stalled (last update $([math]::Round($WatchTelemetry.StalledSeconds,0)) seconds ago)."
      }
    }
    if ($WatchTelemetry.Last -and $WatchTelemetry.Last.classification -eq 'worsened' -and $WatchTelemetry.Last.stats -and $WatchTelemetry.Last.stats.failed -gt 0) {
      $items += [pscustomobject]@{
        Category = 'Watch'
        Severity = 'warning'
        Message  = "Watch-mode trend worsened: failed=$($WatchTelemetry.Last.stats.failed), tests=$($WatchTelemetry.Last.stats.tests)."
      }
    }
    if ($WatchTelemetry.Last -and $WatchTelemetry.Last.flaky -and $WatchTelemetry.Last.flaky.recoveredAfter) {
      $items += [pscustomobject]@{
        Category = 'Watch'
        Severity = 'info'
        Message  = "Flaky recovery observed after $($WatchTelemetry.Last.flaky.recoveredAfter) retry attempts."
      }
    }
  }

  if ($LabVIEWSnapshot) {
    $snapshotErrors = @()
    if ($LabVIEWSnapshot.Errors) {
      $snapshotErrors = @($LabVIEWSnapshot.Errors | Where-Object { $_ -and $_ -ne '' })
    }
    foreach ($error in $snapshotErrors) {
      $items += [pscustomobject]@{
        Category = 'LabVIEW'
        Severity = 'error'
        Message  = "Unable to read LabVIEW snapshot ($error)."
      }
    }
    $lvCount = $LabVIEWSnapshot.LabVIEW.Count
    $lcCount = $LabVIEWSnapshot.LVCompare.Count
    if ($lvCount -gt 0 -or $lcCount -gt 0) {
      $lvPids = $LabVIEWSnapshot.LabVIEW.Processes | ForEach-Object { $_.pid } | Where-Object { $_ } | Sort-Object
      $lcPids = $LabVIEWSnapshot.LVCompare.Processes | ForEach-Object { $_.pid } | Where-Object { $_ } | Sort-Object
      $lvList = if ($lvPids) { $lvPids -join ',' } else { 'none' }
      $lcList = if ($lcPids) { $lcPids -join ',' } else { 'none' }
      $items += [pscustomobject]@{
        Category = 'LabVIEW'
        Severity = 'info'
        Message  = "Warm-up snapshot: LabVIEW=$lvCount (PID(s): $lvList), LVCompare=$lcCount (PID(s): $lcList). Review tests/results/_warmup for details."
      }
    }
  }

  return $items
}

Export-ModuleMember -Function *
