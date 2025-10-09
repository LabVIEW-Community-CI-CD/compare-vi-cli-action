<#
.SYNOPSIS
  One-stop warm-up command to prep local agent context for #88 (watch telemetry + session lock).

.DESCRIPTION
  - Sets the LV_* focus-protection toggles and WATCH_RESULTS_DIR.
  - Runs the Watch smoke test via tools/Watch-Pester.ps1 in single-run mode.
  - Validates the generated watch telemetry against schema-lite (watch-last + watch-log entries).
  - Runs the Session-Lock unit suite using a cached Pester configuration footprint.

.PARAMETER WatchTestsPath
  Path to the watch smoke test file (default: tests/WatchSmoke.Tests.ps1).

.PARAMETER SessionLockTestsPath
  Path to the Session-Lock test file (default: tests/SessionLock.Tests.ps1).

.PARAMETER WatchResultsDir
  Directory for watch telemetry output. Defaults to tests/results/_watch under the repo root.

.PARAMETER SchemaRoot
  Directory that contains the JSON schemas (default: docs/schemas).

.PARAMETER SkipSchemaValidation
  Skip schema-lite validation of the watch telemetry artifacts.

.PARAMETER SkipWatch
  Skips the watch smoke execution (schema validation is also skipped unless explicitly forced via schema params).

.PARAMETER SkipSessionLock
  Skips the Session-Lock unit suite.

.PARAMETER Quiet
  Suppress informational log output (errors still surface).
#>
[CmdletBinding()]
param(
  [string]$WatchTestsPath = 'tests/WatchSmoke.Tests.ps1',
  [string]$SessionLockTestsPath = 'tests/SessionLock.Tests.ps1',
  [string]$WatchResultsDir,
  [string]$SchemaRoot = 'docs/schemas',
  [switch]$SkipSchemaValidation,
  [switch]$SkipWatch,
  [switch]$SkipSessionLock,
  [switch]$SkipRogueScan,
  [switch]$SkipAgentWaitValidation,
  [switch]$GenerateDashboard,
  [switch]$GenerateDashboardHtml,
  [string]$DashboardGroup = 'pester-selfhosted',
  [string]$DashboardResultsRoot = 'tests/results',
  [string]$DashboardHtmlPath,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

function Write-Info {
  param([string]$Message)
  if (-not $Quiet) {
    Write-Host "[warmup] $Message"
  }
}

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Set-EnvToggle {
  param([string]$Name,[string]$Value)
  Set-Item -Path ("Env:{0}" -f $Name) -Value $Value
}

function Resolve-RepoPath {
  param([string]$Relative)
  $target = Join-Path $script:RepoRoot $Relative
  try {
    $resolved = Resolve-Path -LiteralPath $target -ErrorAction Stop
    return $resolved.ProviderPath
  } catch {
    return $target
  }
}

function Invoke-WatchSmoke {
  param(
    [string]$TestPath,
    [string]$ResultsDir,
    [switch]$SkipSchema,
    [switch]$ValidateAgentWait
  )

  $watchScript = Resolve-RepoPath -Relative 'tools/Watch-Pester.ps1'
  $schemaLite = Resolve-RepoPath -Relative 'tools/Invoke-JsonSchemaLite.ps1'
  $watchLastSchema = Resolve-RepoPath -Relative (Join-Path $SchemaRoot 'watch-last-v1.schema.json')
  $watchLogSchema = Resolve-RepoPath -Relative (Join-Path $SchemaRoot 'watch-log-item-v1.schema.json')
  $testPath = Resolve-RepoPath -Relative $TestPath

  Ensure-Directory -Path $ResultsDir

  Write-Info "Running watch smoke via tools/Watch-Pester.ps1 (SingleRun)."
  $env:PS_SESSION_NAME = 'agent-warmup-watch'
  $env:WATCH_RESULTS_DIR = $ResultsDir
  & $watchScript -SingleRun -RunAllOnStart -TestPath $testPath -Tag 'WatchSmoke' -Quiet

  if ($SkipSchema) {
    Write-Info "Skipping schema validation of watch telemetry (per flag)."
    return
  }

  $watchLast = Join-Path $ResultsDir 'watch-last.json'
  $watchLog = Join-Path $ResultsDir 'watch-log.ndjson'
  if (-not (Test-Path -LiteralPath $watchLast)) {
    throw "watch-last.json not found at $watchLast after watch smoke run."
  }

  Write-Info "Validating watch-last.json against schema-lite."
  & $schemaLite -JsonPath $watchLast -SchemaPath $watchLastSchema | Out-Null

  if (Test-Path -LiteralPath $watchLog) {
    Write-Info "Validating watch-log.ndjson entries against schema-lite."
    $raw = Get-Content -Raw -LiteralPath $watchLog
    $entries = $raw -split "\r?\n\r?\n+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($entry in $entries) {
      $temp = [System.IO.Path]::GetTempFileName()
      try {
        Set-Content -LiteralPath $temp -Value $entry -Encoding utf8
        & $schemaLite -JsonPath $temp -SchemaPath $watchLogSchema | Out-Null
      } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
      }
    }
  } else {
    Write-Info "watch-log.ndjson not found — skipping log validation."
  }

  if (-not $ValidateAgentWait) {
    Write-Info "Skipping agent-wait validation (per flag)."
    return
  }

  $agentDir = Resolve-RepoPath -Relative 'tests/results/_agent'
  $waitLast = Join-Path $agentDir 'wait-last.json'
  if (-not (Test-Path -LiteralPath $waitLast)) {
    Write-Info "Agent wait telemetry not present (skip validation)."
    return
  }

  Write-Info "Validating agent wait telemetry (agent-wait-result/v1)."
  $waitJson = Get-Content -Raw -LiteralPath $waitLast | ConvertFrom-Json
  if (-not $waitJson.schema -or $waitJson.schema -ne 'agent-wait-result/v1') {
    throw "Unexpected agent wait schema in wait-last.json (found '$($waitJson.schema)')."
  }
  foreach ($required in @('reason','expectedSeconds','startedUtc','endedUtc','elapsedSeconds','withinMargin')) {
    if (-not ($waitJson.PSObject.Properties.Name -contains $required)) {
      throw "Agent wait last.json missing required field '$required'."
    }
  }

  $waitLog = Join-Path $agentDir 'wait-log.ndjson'
  if (Test-Path -LiteralPath $waitLog) {
    $rawWait = (Get-Content -Raw -LiteralPath $waitLog).Trim()
    if ($rawWait) {
      $jsonArray = '[{0}]' -f ($rawWait -replace "}\s*\r?\n\s*{", "},{")
      $objects = $jsonArray | ConvertFrom-Json
      foreach ($obj in $objects) {
        if ($obj.schema -ne 'agent-wait-result/v1') {
          throw "Agent wait log entry has unexpected schema '$($obj.schema)'."
        }
      }
    }
  }
}

function Invoke-SessionLockUnitSuite {
  param(
    [string]$TestPath
  )

  $cacheDir = Resolve-RepoPath -Relative 'tests/results/_warmup'
  Ensure-Directory -Path $cacheDir
  $configMetadataPath = Join-Path $cacheDir 'sessionlock-config.json'

  $defaultConfig = [ordered]@{
    version = 1
    path = $TestPath
    verbosity = 'Normal'
    tags = @()
    excludeTags = @()
  }

  $configData = $defaultConfig
  if (Test-Path -LiteralPath $configMetadataPath) {
    try {
      $loaded = Get-Content -Raw -LiteralPath $configMetadataPath | ConvertFrom-Json -ErrorAction Stop
      if ($loaded -and $loaded.path) {
        $configData = $loaded
      }
    } catch {
      Write-Info "Failed to deserialize cached session-lock config. Recreating it."
    }
  } else {
    Ensure-Directory -Path (Split-Path -Parent $configMetadataPath)
  }

  # Always (re)write the metadata so updates propagate.
  $configData | ConvertTo-Json -Depth 4 | Out-File -FilePath $configMetadataPath -Encoding utf8

  Import-Module Pester -ErrorAction Stop | Out-Null

  $config = New-PesterConfiguration
  $config.Run.PassThru = $true
  $config.Run.Path = Resolve-RepoPath -Relative $configData.path
  $config.Output.Verbosity = $configData.verbosity
  if ($configData.tags -and $configData.tags.Count -gt 0) {
    $config.Filter.Tag = @($configData.tags)
  }
  if ($configData.excludeTags -and $configData.excludeTags.Count -gt 0) {
    $config.Filter.ExcludeTag = @($configData.excludeTags)
  }

  $env:PS_SESSION_NAME = 'agent-warmup-session-lock'
  Write-Info "Running Session-Lock unit suite via Invoke-Pester."
  $result = Invoke-Pester -Configuration $config -ErrorAction Stop
  $failedCount = ($result.FailedCount -as [int])
  $failedBlocks = 0
  if ($result.PSObject.Properties.Name -contains 'FailedBlocks') {
    $failedBlocks = @($result.FailedBlocks).Count
  }
  if ($failedCount -gt 0 -or $failedBlocks -gt 0) {
    throw "Session-Lock tests reported failures (Failed=$failedCount FailedBlocks=$failedBlocks)."
  }

  $summaryPath = Join-Path $cacheDir 'sessionlock-last.json'
  $summary = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    total = $result.TotalCount
    failed = $result.FailedCount
    durationSeconds = [math]::Round($result.Duration.TotalSeconds, 3)
  }
  $summary | ConvertTo-Json -Depth 3 | Out-File -FilePath $summaryPath -Encoding utf8
  Write-Info ("Session-Lock suite completed: {0} tests in {1}s." -f $summary.total, $summary.durationSeconds)
}

function Invoke-RogueScan {
  param(
    [string]$ResultsRoot
  )
  $rogueScript = Resolve-RepoPath -Relative 'tools/Detect-RogueLV.ps1'
  $resultsPath = Resolve-RepoPath -Relative $ResultsRoot
  Write-Info "Running rogue LV scan (lookback 900s)."
  & $rogueScript -ResultsDir $resultsPath -LookBackSeconds 900 -AppendToStepSummary | Out-Null
}

function Invoke-DashboardSnapshot {
  param(
    [string]$Group,
    [string]$ResultsRoot,
    [switch]$EmitHtml,
    [string]$HtmlPath
  )

  $dashboardScript = Resolve-RepoPath -Relative 'tools/Dev-Dashboard.ps1'
  $resultsPath = Resolve-RepoPath -Relative $ResultsRoot
  Write-Info ("Generating dashboard snapshot (group={0}, results={1})." -f $Group, $resultsPath)
  $json = & $dashboardScript -Group $Group -ResultsRoot $resultsPath -Quiet -Json
  $jsonText = $json | Out-String
  $snapshot = $jsonText | ConvertFrom-Json
  $summaryPath = Resolve-RepoPath -Relative 'tests/results/_warmup/dashboard-last.json'
  Ensure-Directory -Path (Split-Path -Parent $summaryPath)
  $snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $summaryPath -Encoding utf8
  if ($EmitHtml) {
    $target = if ($HtmlPath) { Resolve-RepoPath -Relative $HtmlPath } else { Resolve-RepoPath -Relative 'tests/results/dashboard-warmup.html' }
    Write-Info ("Rendering dashboard HTML to {0}." -f $target)
    & $dashboardScript -Group $Group -ResultsRoot $resultsPath -Quiet -Html -HtmlPath $target | Out-Null
  }
  Write-Info "Dashboard snapshot stored."
}

Write-Info "Starting agent warm-up."

Set-EnvToggle -Name 'LV_SUPPRESS_UI' -Value '1'
Set-EnvToggle -Name 'LV_NO_ACTIVATE' -Value '1'
Set-EnvToggle -Name 'LV_CURSOR_RESTORE' -Value '1'
Set-EnvToggle -Name 'LV_IDLE_WAIT_SECONDS' -Value '2'
Set-EnvToggle -Name 'LV_IDLE_MAX_WAIT_SECONDS' -Value '5'

if (-not $WatchResultsDir) {
  $WatchResultsDir = Resolve-RepoPath -Relative 'tests/results/_watch'
} else {
  $WatchResultsDir = Resolve-RepoPath -Relative $WatchResultsDir
}

if (-not $SkipWatch) {
  Invoke-WatchSmoke -TestPath $WatchTestsPath -ResultsDir $WatchResultsDir -SkipSchema:$SkipSchemaValidation.IsPresent -ValidateAgentWait:(! $SkipAgentWaitValidation.IsPresent)
} else {
  Write-Info "Skipping watch smoke execution (per flag)."
}

if (-not $SkipSessionLock) {
  Invoke-SessionLockUnitSuite -TestPath $SessionLockTestsPath
} else {
  Write-Info "Skipping Session-Lock unit suite (per flag)."
}

if (-not $SkipRogueScan) {
  Invoke-RogueScan -ResultsRoot $DashboardResultsRoot
} else {
  Write-Info "Skipping rogue LV scan (per flag)."
}

if ($GenerateDashboard) {
  Invoke-DashboardSnapshot -Group $DashboardGroup -ResultsRoot $DashboardResultsRoot -EmitHtml:$GenerateDashboardHtml.IsPresent -HtmlPath $DashboardHtmlPath
}

Write-Info "Agent warm-up completed successfully."
