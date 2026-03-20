#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$OperationName = 'AddTwoNumbers',
  [string]$SourceExamplePath = 'C:\Users\Public\Documents\National Instruments\LabVIEW CLI\Examples\AddTwoNumbers',
  [string]$OperationDirectory = '',
  [string]$LabVIEWPath = '',
  [int]$TimeoutSeconds = 90,
  [string]$ResultsRoot = '',
  [string]$ReportPath = '',
  [string]$SummaryPath = '',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [switch]$DryRun,
  [switch]$SkipSchemaValidation,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [Parameter(Mandatory)][string]$PathValue
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }

  return (Resolve-Path -LiteralPath $Path).Path
}

function Convert-ToRepoRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PathValue
  )

  $resolved = [System.IO.Path]::GetFullPath($PathValue)
  $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $resolved)
  if ($relative -eq '.') {
    return '.'
  }

  if ($relative -eq '..' -or
      $relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or
      $relative.StartsWith('..' + [System.IO.Path]::AltDirectorySeparatorChar)) {
    return ($resolved -replace '\\', '/')
  }

  return ($relative -replace '\\', '/')
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $directory = Split-Path -Parent $Path
  if ($directory) {
    Ensure-Directory -Path $directory | Out-Null
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    New-Item -ItemType File -Path $Path -Force | Out-Null
  }

  Add-Content -LiteralPath $Path -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

function Invoke-SchemaValidation {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$SchemaPath,
    [Parameter(Mandatory)][string]$DataPath
  )

  $runner = Join-Path $RepoRoot 'tools' 'npm' 'run-script.mjs'
  if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Schema validation runner not found at '$runner'."
  }

  $output = & node $runner 'schema:validate' '--' '--schema' $SchemaPath '--data' $DataPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $message = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Schema validation failed for '$DataPath': $message"
  }
}

function Get-PreferredLabVIEWHint {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $candidates = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in @(
    'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe',
    'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
  )) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $candidates.Add($candidate) | Out-Null
    }
  }
  foreach ($rootPath in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ([string]::IsNullOrWhiteSpace($rootPath)) { continue }
    foreach ($candidate in @(Get-ChildItem -Path (Join-Path $rootPath 'National Instruments') -Filter 'LabVIEW.exe' -File -Recurse -ErrorAction SilentlyContinue)) {
      $resolved = $candidate.FullName
      if (-not ($candidates.Contains($resolved))) {
        $candidates.Add($resolved) | Out-Null
      }
    }
  }
  $candidateList = @($candidates.ToArray())
  if ($candidateList.Count -eq 0) {
    return $null
  }

  $preferred32Bit2026 = @(
    $candidateList |
      Where-Object {
        ($_ -match 'LabVIEW\s+2026') -and
        ($_ -match '(?i)(Program Files \(x86\)|\(32-bit\))')
      } |
      Select-Object -First 1
  )
  if ($preferred32Bit2026.Count -gt 0) {
    return $preferred32Bit2026[0]
  }

  $preferred2026 = @($candidateList | Where-Object { $_ -match 'LabVIEW\s+2026' } | Select-Object -First 1)
  if ($preferred2026.Count -gt 0) {
    return $preferred2026[0]
  }

  return $candidateList[0]
}

function Get-TrackedProcessSnapshot {
  $records = New-Object System.Collections.Generic.List[object]
  foreach ($processName in @('LabVIEW.exe', 'LabVIEWCLI.exe')) {
    $escapedName = $processName.Replace("'", "''")
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = '$escapedName'" -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
      if ($null -eq $process) { continue }
      $created = $null
      if ($process.CreationDate) {
        try {
          $created = [System.Management.ManagementDateTimeConverter]::ToDateTime($process.CreationDate).ToString('o')
        } catch {}
      }
      $records.Add([pscustomobject]@{
          pid = [int]$process.ProcessId
          name = [string]$process.Name
          commandLine = [string]$process.CommandLine
          executablePath = [string]$process.ExecutablePath
          createdAt = $created
        }) | Out-Null
    }
  }
  $snapshot = @($records.ToArray())
  if ($snapshot.Count -eq 0) {
    return @()
  }
  return @($snapshot | Sort-Object name, pid)
}

function Get-NewTrackedProcesses {
  param(
    [AllowNull()][object[]]$Before,
    [AllowNull()][object[]]$After
  )

  $beforeIds = @{}
  foreach ($item in @($Before)) {
    if ($null -eq $item) { continue }
    $beforeIds["$([int]$item.pid)"] = $true
  }

  return @(
    @($After) | Where-Object {
      $null -ne $_ -and
      $_.PSObject.Properties['pid'] -and
      -not $beforeIds.ContainsKey("$([int]$_.pid)")
    }
  )
}

function Invoke-TrackedProcessCleanup {
  param([object[]]$Processes)

  $killedPids = New-Object System.Collections.Generic.List[int]
  $errors = New-Object System.Collections.Generic.List[string]
  foreach ($processInfo in @($Processes | Sort-Object pid -Descending)) {
    if ($null -eq $processInfo) { continue }
    $pid = 0
    try { $pid = [int]$processInfo.pid } catch { $pid = 0 }
    if ($pid -le 0) { continue }
    try {
      $cleanupOutput = & taskkill.exe /PID $pid /T /F 2>&1
      if ($LASTEXITCODE -ne 0) {
        $message = (($cleanupOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        if ($message) {
          $errors.Add(("PID {0}: {1}" -f $pid, $message)) | Out-Null
        } else {
          $errors.Add(("PID {0}: taskkill exited with code {1}" -f $pid, $LASTEXITCODE)) | Out-Null
        }
        continue
      }
      $killedPids.Add($pid) | Out-Null
    } catch {
      $errors.Add(("PID {0}: {1}" -f $pid, $_.Exception.Message)) | Out-Null
    }
  }

  return [pscustomobject]@{
    killedPids = @($killedPids.ToArray())
    errors = @($errors.ToArray())
  }
}

function Get-RelevantLogFiles {
  param(
    [datetime]$StartedAtUtc,
    [datetime]$FinishedAtUtc
  )

  $roots = @()
  foreach ($rootCandidate in @([System.IO.Path]::GetTempPath(), $env:TEMP, $env:TMP, (Join-Path $env:LOCALAPPDATA 'Temp'))) {
    if ([string]::IsNullOrWhiteSpace($rootCandidate)) { continue }
    try {
      $resolved = [System.IO.Path]::GetFullPath($rootCandidate)
      if (Test-Path -LiteralPath $resolved -PathType Container) {
        $roots += $resolved
      }
    } catch {}
  }
  $roots = @($roots | Select-Object -Unique)

  $lowerBound = $StartedAtUtc.AddSeconds(-5)
  $upperBound = $FinishedAtUtc.AddSeconds(5)
  $files = @()
  foreach ($rootPath in $roots) {
    foreach ($pattern in @('lvtemporary_*.log', 'LabVIEWCLI*.txt')) {
      foreach ($file in @(Get-ChildItem -LiteralPath $rootPath -Filter $pattern -File -ErrorAction SilentlyContinue)) {
        try {
          $lastWriteUtc = $file.LastWriteTimeUtc
          if ($lastWriteUtc -lt $lowerBound -or $lastWriteUtc -gt $upperBound) {
            continue
          }
          $files += $file
        } catch {}
      }
    }
  }

  return @($files | Sort-Object LastWriteTimeUtc, FullName -Unique)
}

function Copy-ScenarioLogs {
  param(
    [Parameter(Mandatory)][string]$ScenarioRoot,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][datetime]$StartedAtUtc,
    [Parameter(Mandatory)][datetime]$FinishedAtUtc
  )

  $logRoot = Ensure-Directory -Path (Join-Path $ScenarioRoot 'logs')
  $captured = @()
  foreach ($file in @(Get-RelevantLogFiles -StartedAtUtc $StartedAtUtc -FinishedAtUtc $FinishedAtUtc)) {
    $destinationName = "{0}-{1}" -f $file.LastWriteTimeUtc.ToString('yyyyMMddTHHmmssfffZ'), $file.Name
    $destinationPath = Join-Path $logRoot $destinationName
    Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    $captured += [pscustomobject]@{
      sourcePath = $file.FullName
      copiedPath = $destinationPath
      copiedPathRelative = Convert-ToRepoRelativePath -RepoRoot $RepoRoot -PathValue $destinationPath
    }
  }

  $insights = Get-LabVIEWCustomOperationLogInsights -LogPaths (@($captured | ForEach-Object { $_.copiedPath }))
  return [pscustomobject]@{
    count = @($captured).Count
    files = @($captured)
    insights = $insights
  }
}

function Get-ScenarioCatalog {
  param([AllowNull()][string]$ExplicitLabVIEWPath)

  $scenarios = New-Object System.Collections.Generic.List[object]
  $scenarios.Add([pscustomobject]@{
      name = 'default-help'
      description = 'Probe the implicit LabVIEW selection used by LabVIEWCLI when -LabVIEWPath is omitted.'
      help = $true
      headless = $false
      logToConsole = $false
      arguments = @()
      requestedLabVIEWPath = $null
    }) | Out-Null

  if (-not [string]::IsNullOrWhiteSpace($ExplicitLabVIEWPath)) {
    $scenarios.Add([pscustomobject]@{
        name = 'explicit-help'
        description = 'Run GetHelp.vi against the explicit LabVIEW 2026 host plane.'
        help = $true
        headless = $false
        logToConsole = $false
        arguments = @()
        requestedLabVIEWPath = $ExplicitLabVIEWPath
      }) | Out-Null
    $scenarios.Add([pscustomobject]@{
        name = 'explicit-headless-run'
        description = 'Run RunOperation.vi headless with explicit LabVIEW 2026 and trivial AddTwoNumbers inputs.'
        help = $false
        headless = $true
        logToConsole = $true
        arguments = @('-x', '1', '-y', '2')
        requestedLabVIEWPath = $ExplicitLabVIEWPath
      }) | Out-Null
  }

  return @($scenarios.ToArray())
}

function Invoke-CustomOperationScenario {
  param(
    [Parameter(Mandatory)]$Scenario,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ResultsRoot,
    [Parameter(Mandatory)][string]$OperationName,
    [Parameter(Mandatory)][string]$AdditionalOperationDirectory,
    [Parameter(Mandatory)][int]$TimeoutSeconds,
    [switch]$DryRun
  )

  $scenarioRoot = Ensure-Directory -Path (Join-Path $ResultsRoot $Scenario.name)
  $previewArgs = @{
    CustomOperationName = $OperationName
    AdditionalOperationDirectory = $AdditionalOperationDirectory
    Provider = 'labviewcli'
    Preview = $true
  }
  if ($Scenario.help) { $previewArgs.Help = $true }
  if ($Scenario.headless) { $previewArgs.Headless = $true }
  if ($Scenario.logToConsole) { $previewArgs.LogToConsole = $true }
  if ($Scenario.arguments.Count -gt 0) { $previewArgs.Arguments = @($Scenario.arguments) }
  if ($Scenario.requestedLabVIEWPath) { $previewArgs.LabVIEWPath = $Scenario.requestedLabVIEWPath }
  $preview = Invoke-LVCustomOperation @previewArgs

  if ($DryRun) {
    return [pscustomobject]@{
      name = $Scenario.name
      description = $Scenario.description
      status = 'planned'
      timedOut = $false
      requestedLabVIEWPath = $Scenario.requestedLabVIEWPath
      preview = $preview
      result = $null
      error = $null
      processBefore = @()
      processAfter = @()
      cleanup = [ordered]@{
        killedPids = @()
        errors = @()
      }
      lingeringProcesses = @()
      logCapture = [ordered]@{
        count = 0
        files = @()
      }
      logInsights = [ordered]@{
        observedLabVIEWPaths = @()
        observedLabVIEWPath = $null
        launchSucceeded = $false
        operationCompleted = $false
        logLineCount = 0
      }
    }
  }

  $invokeArgs = @{
    CustomOperationName = $OperationName
    AdditionalOperationDirectory = $AdditionalOperationDirectory
    Provider = 'labviewcli'
    TimeoutSeconds = $TimeoutSeconds
  }
  if ($Scenario.help) { $invokeArgs.Help = $true }
  if ($Scenario.headless) { $invokeArgs.Headless = $true }
  if ($Scenario.logToConsole) { $invokeArgs.LogToConsole = $true }
  if ($Scenario.arguments.Count -gt 0) { $invokeArgs.Arguments = @($Scenario.arguments) }
  if ($Scenario.requestedLabVIEWPath) { $invokeArgs.LabVIEWPath = $Scenario.requestedLabVIEWPath }

  $before = Get-TrackedProcessSnapshot
  $startedAtUtc = (Get-Date).ToUniversalTime()
  $result = $null
  $errorMessage = $null
  $timedOut = $false
  $status = 'failed'
  try {
    $result = Invoke-LVCustomOperation @invokeArgs
    $status = if ($result.ok) { 'succeeded' } else { 'failed' }
  } catch {
    $errorMessage = $_.Exception.Message
    if ($errorMessage -match 'timed out') {
      $timedOut = $true
      $status = 'timed-out'
    } else {
      $status = 'failed'
    }
  }

  $after = Get-TrackedProcessSnapshot
  $spawned = @(Get-NewTrackedProcesses -Before $before -After $after)
  $cleanup = Invoke-TrackedProcessCleanup -Processes $spawned
  Start-Sleep -Seconds 1
  $finalAfter = Get-TrackedProcessSnapshot
  $lingering = @(Get-NewTrackedProcesses -Before $before -After $finalAfter)
  $finishedAtUtc = (Get-Date).ToUniversalTime()
  $logCapture = Copy-ScenarioLogs -ScenarioRoot $scenarioRoot -RepoRoot $RepoRoot -StartedAtUtc $startedAtUtc -FinishedAtUtc $finishedAtUtc
  $tracker = $null
  try { $tracker = Get-LabVIEWCliPidTracker } catch {}

  return [pscustomobject]@{
    name = $Scenario.name
    description = $Scenario.description
    status = $status
    timedOut = [bool]$timedOut
    requestedLabVIEWPath = $Scenario.requestedLabVIEWPath
    preview = $preview
    result = $result
    error = $errorMessage
    processBefore = @($before)
    processAfter = @($after)
    processFinal = @($finalAfter)
    cleanup = [ordered]@{
      killedPids = @($cleanup.killedPids)
      errors = @($cleanup.errors)
    }
    lingeringProcesses = @($lingering)
    logCapture = [ordered]@{
      count = [int]$logCapture.count
      files = @($logCapture.files)
    }
    logInsights = $logCapture.insights
    labviewPidTracker = $tracker
  }
}

function New-ProofMarkdown {
  param(
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)][string]$ReportPath
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# LabVIEW CLI Custom Operation Proof') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Report: `{0}`' -f $ReportPath)) | Out-Null
  $lines.Add(('- Final status: `{0}`' -f $Report.status)) | Out-Null
  $lines.Add(('- Operation: `{0}`' -f $Report.operationName)) | Out-Null
  $lines.Add(('- Operation directory: `{0}`' -f $Report.operationDirectory)) | Out-Null
  if ($Report.explicitLabVIEWPath) {
    $lines.Add(('- Explicit LabVIEW path: `{0}`' -f $Report.explicitLabVIEWPath)) | Out-Null
  }
  $rootCauseText = if (@($Report.analysis.rootCauseCandidates).Count -gt 0) {
    (@($Report.analysis.rootCauseCandidates) -join ', ')
  } else {
    'none'
  }
  $lines.Add(("- Root-cause candidates: {0}" -f $rootCauseText)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('## Scenarios') | Out-Null
  $lines.Add('') | Out-Null

  foreach ($scenario in @($Report.scenarios)) {
    $lines.Add(('- `{0}`: status=`{1}` timedOut={2}' -f $scenario.name, $scenario.status, ([string][bool]$scenario.timedOut))) | Out-Null
    if ($scenario.requestedLabVIEWPath) {
      $lines.Add(('  requestedLabVIEWPath=`{0}`' -f $scenario.requestedLabVIEWPath)) | Out-Null
    }
    if ($scenario.logInsights.observedLabVIEWPath) {
      $lines.Add(('  observedLabVIEWPath=`{0}`' -f $scenario.logInsights.observedLabVIEWPath)) | Out-Null
    }
    if ($scenario.error) {
      $lines.Add(('  error=`{0}`' -f $scenario.error.Replace('`', "'"))) | Out-Null
    }
    if (@($scenario.cleanup.killedPids).Count -gt 0) {
      $lines.Add(("  cleanedPids={0}" -f ((@($scenario.cleanup.killedPids)) -join ','))) | Out-Null
    }
    if (@($scenario.lingeringProcesses).Count -gt 0) {
      $lines.Add(("  lingeringPids={0}" -f ((@($scenario.lingeringProcesses | ForEach-Object { $_.pid })) -join ','))) | Out-Null
    }
    if ($scenario.preview.command) {
      $lines.Add(('  command=`{0}`' -f $scenario.preview.command.Replace('`', "'"))) | Out-Null
    }
  }

  if (@($Report.analysis.notes).Count -gt 0) {
    $lines.Add('') | Out-Null
    $lines.Add('## Analysis') | Out-Null
    $lines.Add('') | Out-Null
    foreach ($note in @($Report.analysis.notes)) {
      $lines.Add(("- {0}" -f $note)) | Out-Null
    }
  }

  return ($lines -join "`n")
}

$repoRoot = Resolve-RepoRoot
Import-Module (Join-Path $repoRoot 'tools' 'LabVIEWCli.psm1') -Force | Out-Null
Import-Module (Join-Path $repoRoot 'tools' 'LabVIEWCLICustomOperationProof.psm1') -Force | Out-Null

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$resultsRootResolved = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue (Join-Path 'tests/results/_agent/custom-operation-proofs' ("{0}-{1}" -f $OperationName, $timestamp))
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ResultsRoot
}
Ensure-Directory -Path $resultsRootResolved | Out-Null

$reportResolved = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  Join-Path $resultsRootResolved 'labview-cli-custom-operation-proof.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReportPath
}
$summaryResolved = if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
  Join-Path $resultsRootResolved 'labview-cli-custom-operation-proof.md'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $SummaryPath
}

$explicitLabVIEWPath = if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) {
  Get-PreferredLabVIEWHint -RepoRoot $repoRoot
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $LabVIEWPath
}

$operationDirectoryResolved = $null
$scaffoldReceiptResolved = $null
$sourceExampleResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $SourceExamplePath
if ([string]::IsNullOrWhiteSpace($OperationDirectory)) {
  $workspaceRoot = if ($resultsRootResolved.StartsWith($repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    Join-Path $repoRoot 'tests/results/_agent/custom-operation-scaffolds' ("{0}-{1}-workspace" -f $OperationName, $timestamp)
  } else {
    Join-Path $resultsRootResolved 'workspace'
  }
  $scaffoldReceiptResolved = Join-Path $resultsRootResolved 'custom-operation-scaffold.json'
  $scaffoldScript = Join-Path $repoRoot 'tools' 'New-LabVIEWCLICustomOperationWorkspace.ps1'
  $scaffoldArgs = @{
    SourceExamplePath = $sourceExampleResolved
    DestinationPath = $workspaceRoot
    ReceiptPath = $scaffoldReceiptResolved
    Force = $true
  }
  if ($explicitLabVIEWPath) {
    $scaffoldArgs.LabVIEWPathHint = $explicitLabVIEWPath
  }
  if ($SkipSchemaValidation) {
    $scaffoldArgs.SkipSchemaValidation = $true
  }
  & $scaffoldScript @scaffoldArgs | Out-Null
  $operationDirectoryResolved = $workspaceRoot
} else {
  $operationDirectoryResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $OperationDirectory
}

if (-not (Test-Path -LiteralPath $operationDirectoryResolved -PathType Container)) {
  throw "Custom operation directory was not found at '$operationDirectoryResolved'."
}
foreach ($requiredFile in @('GetHelp.vi', 'RunOperation.vi')) {
  $requiredPath = Join-Path $operationDirectoryResolved $requiredFile
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Custom operation directory '$operationDirectoryResolved' is missing '$requiredFile'."
  }
}

$scenarioCatalog = Get-ScenarioCatalog -ExplicitLabVIEWPath $explicitLabVIEWPath
$scenarioResults = New-Object System.Collections.Generic.List[object]
foreach ($scenario in $scenarioCatalog) {
  $scenarioResults.Add(
    (Invoke-CustomOperationScenario `
      -Scenario $scenario `
      -RepoRoot $repoRoot `
      -ResultsRoot $resultsRootResolved `
      -OperationName $OperationName `
      -AdditionalOperationDirectory $operationDirectoryResolved `
      -TimeoutSeconds $TimeoutSeconds `
      -DryRun:$DryRun)
  ) | Out-Null
}
$labviewCliPath = $null
foreach ($scenarioResult in @($scenarioResults.ToArray())) {
  if ($scenarioResult.preview -and $scenarioResult.preview.cliPath) {
    $labviewCliPath = [string]$scenarioResult.preview.cliPath
    break
  }
}

$analysis = Resolve-LabVIEWCustomOperationProofAnalysis -ScenarioResults (@($scenarioResults.ToArray())) -RequestedLabVIEWPath $explicitLabVIEWPath
$status = if ($DryRun) {
  'planned'
} elseif (
  @($scenarioResults | Where-Object { $_.status -ne 'succeeded' }).Count -eq 0 -and
  -not $analysis.cleanupRequired
) {
  'succeeded'
} elseif (
  @($scenarioResults | Where-Object { $_.status -ne 'succeeded' }).Count -eq 0 -and
  $analysis.cleanupRequired -and
  $analysis.cleanupSucceeded
) {
  'succeeded'
} else {
  'blocked'
}

$report = [ordered]@{
  schema = 'labview-cli-custom-operation-proof@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  status = $status
  operationName = $OperationName
  sourceExamplePath = $sourceExampleResolved
  operationDirectory = $operationDirectoryResolved
  explicitLabVIEWPath = $explicitLabVIEWPath
  labviewCliPath = $labviewCliPath
  timeoutSeconds = [int]$TimeoutSeconds
  dryRun = [bool]$DryRun
  resultsRoot = $resultsRootResolved
  reportPath = $reportResolved
  summaryPath = $summaryResolved
  scaffoldReceiptPath = $scaffoldReceiptResolved
  analysis = $analysis
  scenarios = @($scenarioResults.ToArray())
}

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportResolved -Encoding utf8
New-ProofMarkdown -Report $report -ReportPath (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $reportResolved) |
  Set-Content -LiteralPath $summaryResolved -Encoding utf8

if (-not $SkipSchemaValidation) {
  Invoke-SchemaValidation `
    -RepoRoot $repoRoot `
    -SchemaPath (Join-Path $repoRoot 'docs' 'schemas' 'labview-cli-custom-operation-proof-v1.schema.json') `
    -DataPath $reportResolved
}

Write-Host ("LabVIEW CLI custom operation proof report: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $reportResolved))
Write-Host ("LabVIEW CLI custom operation proof summary: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $summaryResolved))
Write-GitHubOutput -Key 'labview-cli-custom-operation-proof-report' -Value $reportResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-cli-custom-operation-proof-summary' -Value $summaryResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'labview-cli-custom-operation-proof-status' -Value $status -Path $GitHubOutputPath

if ($PassThru) {
  Write-Output ([pscustomobject]$report)
}

if (-not $DryRun -and $status -ne 'succeeded') {
  throw "LabVIEW CLI custom operation proof ended with status '$status'. Review '$reportResolved'."
}
