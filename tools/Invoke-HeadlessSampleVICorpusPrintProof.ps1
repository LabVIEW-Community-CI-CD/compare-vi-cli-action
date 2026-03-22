#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$CatalogPath = 'fixtures/headless-corpus/sample-vi-corpus.targets.json',
  [string]$TargetId = 'icon-editor-demo-canaryprobe-print',
  [string]$PayloadBundlePath = 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml',
  [string]$ResultsRoot = 'tests/results/_agent/headless-sample-corpus/print-proof',
  [string]$ReportPath = '',
  [string]$MarkdownPath = '',
  [string]$InspectionScriptPath = '',
  [string]$RunnerScriptPath = '',
  [string]$PayloadFinalizationContractPath = 'docs/schemas/operation-payload-authoring-finalization-v1.schema.json',
  [string]$TargetRepositoryPath = '',
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

function New-DirectoryIfMissing {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
      New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
  }

  return (Resolve-Path -LiteralPath $Path).Path
}

function Convert-ToRepoRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PathValue
  )

  $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $PathValue
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

function Resolve-ScriptPath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [AllowEmptyString()][string]$PathValue,
    [Parameter(Mandatory)][string]$DefaultRelativePath
  )

  $effective = if ([string]::IsNullOrWhiteSpace($PathValue)) { $DefaultRelativePath } else { $PathValue }
  $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $effective
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "Script path was not found: '$resolved'."
  }
  return $resolved
}

function Assert-Tool {
  param([Parameter(Mandatory)][string]$Name)

  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw ("Required tool not found on PATH: {0}" -f $Name)
  }
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

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$Arguments,
    [string]$WorkingDirectory = '',
    [Parameter(Mandatory)][string]$FailureContext
  )

  $output = @()
  $exitCode = 0
  try {
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
      Push-Location $WorkingDirectory
    }
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
      Pop-Location
    }
  }

  if ($exitCode -ne 0) {
    $message = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "{0} failed with exit code {1}: {2}" -f $FailureContext, $exitCode, $message
  }

  return @($output)
}

function Materialize-PinnedRepository {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$RepoUrl,
    [Parameter(Mandatory)][string]$RepoSlug,
    [Parameter(Mandatory)][string]$PinnedCommit,
    [Parameter(Mandatory)][string]$DestinationRoot
  )

  Assert-Tool -Name 'git'

  $slugSegment = ($RepoSlug -replace '[^A-Za-z0-9._-]+', '-')
  $commitSegment = if ($PinnedCommit.Length -ge 12) { $PinnedCommit.Substring(0, 12) } else { $PinnedCommit }
  $destination = Join-Path $DestinationRoot ("sample-repo-{0}-{1}" -f $slugSegment, $commitSegment)
  if (Test-Path -LiteralPath $destination) {
    Remove-Item -LiteralPath $destination -Recurse -Force
  }
  New-Item -ItemType Directory -Path $destination -Force | Out-Null

  Invoke-NativeCommand -FilePath 'git' -Arguments @('init') -WorkingDirectory $destination -FailureContext 'git init'
  Invoke-NativeCommand -FilePath 'git' -Arguments @('remote', 'add', 'origin', $RepoUrl) -WorkingDirectory $destination -FailureContext 'git remote add origin'
  Invoke-NativeCommand -FilePath 'git' -Arguments @('fetch', '--depth', '1', 'origin', $PinnedCommit) -WorkingDirectory $destination -FailureContext 'git fetch pinned commit'
  Invoke-NativeCommand -FilePath 'git' -Arguments @('checkout', '--detach', 'FETCH_HEAD') -WorkingDirectory $destination -FailureContext 'git checkout detached'

  return (Resolve-Path -LiteralPath $destination).Path
}

$repoRoot = Resolve-RepoRoot
$catalogResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $CatalogPath
if (-not (Test-Path -LiteralPath $catalogResolved -PathType Leaf)) {
  throw "Headless sample VI corpus catalog not found at '$catalogResolved'."
}

$inspectionScriptResolved = if ([string]::IsNullOrWhiteSpace($InspectionScriptPath)) {
  Join-Path $repoRoot 'tools' 'Inspect-OperationPayloadSourceBundle.ps1'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $InspectionScriptPath
}
if (-not (Test-Path -LiteralPath $inspectionScriptResolved -PathType Leaf)) {
  throw "Inspection script not found at '$inspectionScriptResolved'."
}

$catalogSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'headless-sample-vi-corpus-targets-v1.schema.json'
$proofSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'headless-sample-vi-corpus-print-proof-v1.schema.json'
if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $catalogSchemaPath -DataPath $catalogResolved
}

$catalog = Get-Content -LiteralPath $catalogResolved -Raw | ConvertFrom-Json -Depth 32
$target = @($catalog.targets | Where-Object { [string]$_.id -eq $TargetId } | Select-Object -First 1)
if ($target.Count -eq 0) {
  throw "Target '$TargetId' was not found in '$catalogResolved'."
}
$target = $target[0]

$changeKind = [string]$target.source.changeKind
$certificationSurface = [string]$target.renderStrategy.certificationSurface
$operation = [string]$target.renderStrategy.operation
if ($changeKind -notin @('added', 'deleted')) {
  throw "Target '$TargetId' must be an added/deleted print target; observed changeKind '$changeKind'."
}
if ($certificationSurface -ne 'print-single-file' -or $operation -ne 'PrintToSingleFileHtml') {
  throw "Target '$TargetId' is not aligned to the PrintToSingleFileHtml proof surface."
}

$resultsRootResolved = New-DirectoryIfMissing -Path (Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ResultsRoot)
$reportResolved = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  Join-Path $resultsRootResolved ("print-proof-{0}.json" -f $TargetId)
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReportPath
}
$markdownResolved = if ([string]::IsNullOrWhiteSpace($MarkdownPath)) {
  Join-Path $resultsRootResolved ("print-proof-{0}.md" -f $TargetId)
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $MarkdownPath
}
New-DirectoryIfMissing -Path (Split-Path -Parent $reportResolved) | Out-Null
New-DirectoryIfMissing -Path (Split-Path -Parent $markdownResolved) | Out-Null

$inspectionReportPath = Join-Path $resultsRootResolved ("payload-inspection-{0}.json" -f $TargetId)
$inspectionMarkdownPath = Join-Path $resultsRootResolved ("payload-inspection-{0}.md" -f $TargetId)
$inspectionArgs = @(
  '-NoLogo',
  '-NoProfile',
  '-File', $inspectionScriptResolved,
  '-BundlePath', $PayloadBundlePath,
  '-ReportPath', $inspectionReportPath,
  '-MarkdownPath', $inspectionMarkdownPath
)
if ($SkipSchemaValidation.IsPresent) {
  $inspectionArgs += '-SkipSchemaValidation'
}
$inspectionOutput = & pwsh @inspectionArgs 2>&1
if ($LASTEXITCODE -ne 0) {
  $message = ($inspectionOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  throw "Payload inspection failed: $message"
}

$inspectionReport = Get-Content -LiteralPath $inspectionReportPath -Raw | ConvertFrom-Json -Depth 20
$observedExecutableState = [string]$inspectionReport.observedExecutableState
$declaredExecutableState = [string]$inspectionReport.declaredExecutableState
$payloadFinalizationContractResolved = $null
$payloadFinalizationContractAvailable = $false
if (-not [string]::IsNullOrWhiteSpace($PayloadFinalizationContractPath)) {
  $payloadFinalizationContractCandidate = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $PayloadFinalizationContractPath
  if (Test-Path -LiteralPath $payloadFinalizationContractCandidate -PathType Leaf) {
    $payloadFinalizationContractResolved = $payloadFinalizationContractCandidate
    $payloadFinalizationContractAvailable = $true
  }
}

$runnerScriptResolved = Resolve-ScriptPath -RepoRoot $repoRoot -PathValue $RunnerScriptPath -DefaultRelativePath 'tools/Run-NILinuxContainerCustomOperation.ps1'
$targetRepositoryResolved = $null
$targetRepositoryMaterialized = $false
$executionResultsRoot = $null
$executionCapturePath = $null
$scenarioResultPath = $null
$renderedOutputPath = $null
$executionExitCode = $null
$executionStatus = $null
$finalExitCode = 0

$finalStatus = if ($observedExecutableState -eq 'source-only') { 'blocked' } else { 'succeeded' }
$blockingReason = if ($finalStatus -eq 'blocked') { 'payload-source-only' } else { $null }
$notes = New-Object System.Collections.Generic.List[string]
if ($finalStatus -eq 'blocked') {
  $notes.Add('Proof execution was not attempted because the repo-owned payload bundle is still source-only.') | Out-Null
  $notes.Add('This is the intended fail-closed state until runnable repo-owned payload files land.') | Out-Null
  if ($payloadFinalizationContractAvailable) {
    $notes.Add(("Finalization contract reference available at {0} for the repo-owned payload handoff." -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $payloadFinalizationContractResolved))) | Out-Null
  }
} else {
  if ([string]::IsNullOrWhiteSpace($TargetRepositoryPath)) {
    $targetRepositoryResolved = Materialize-PinnedRepository `
      -RepoRoot $repoRoot `
      -RepoUrl ([string]$target.source.repoUrl) `
      -RepoSlug ([string]$target.source.repoSlug) `
      -PinnedCommit ([string]$target.source.pinnedCommit) `
      -DestinationRoot $resultsRootResolved
    $targetRepositoryMaterialized = $true
  } else {
    $targetRepositoryResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $TargetRepositoryPath
  }
  if (-not (Test-Path -LiteralPath $targetRepositoryResolved -PathType Container)) {
    throw "Target repository path was not found at '$targetRepositoryResolved'."
  }

  $targetFileResolved = Resolve-AbsolutePath -BasePath $targetRepositoryResolved -PathValue ([string]$target.source.targetPath)
  if (-not (Test-Path -LiteralPath $targetFileResolved -PathType Leaf)) {
    throw "Target VI path was not found at '$targetFileResolved'."
  }

  $executionResultsRoot = New-DirectoryIfMissing -Path (Join-Path $resultsRootResolved ("execution-{0}" -f $TargetId))
  $renderedOutputResolved = Join-Path $executionResultsRoot 'print-output.html'
  $targetPathUnix = ([string]$target.source.targetPath).Replace('\', '/').TrimStart('/')
  $containerTargetPath = '/target-repo/{0}' -f $targetPathUnix
  $containerOutputPath = '/capture/print-output.html'
  $runnerArgumentsJson = (@('-VI', $containerTargetPath, '-OutputPath', $containerOutputPath) | ConvertTo-Json -Compress)

  $runnerArgs = @(
    '-NoLogo',
    '-NoProfile',
    '-File', $runnerScriptResolved,
    '-OperationName', 'PrintToSingleFileHtml',
    '-AdditionalOperationDirectory', (Resolve-AbsolutePath -BasePath $repoRoot -PathValue $PayloadBundlePath),
    '-ResultsRoot', $executionResultsRoot,
    '-AdditionalMount', ('{0}::/target-repo' -f $targetRepositoryResolved),
    '-ArgumentsJson', $runnerArgumentsJson,
    '-ExpectedOutputPath', $containerOutputPath,
    '-Headless',
    '-LogToConsole'
  )
  $runnerOutput = @(& pwsh @runnerArgs 2>&1)
  $executionExitCode = $LASTEXITCODE
  $executionCapturePath = Join-Path $executionResultsRoot 'ni-linux-custom-operation-capture.json'
  $scenarioResultPath = Join-Path $executionResultsRoot 'scenario-result.json'
  $renderedOutputPath = $renderedOutputResolved
  if (Test-Path -LiteralPath $scenarioResultPath -PathType Leaf) {
    $scenarioResult = Get-Content -LiteralPath $scenarioResultPath -Raw | ConvertFrom-Json -Depth 20
    $executionStatus = [string]$scenarioResult.status
  }

  if ($executionExitCode -ne 0 -or -not (Test-Path -LiteralPath $executionCapturePath -PathType Leaf) -or -not (Test-Path -LiteralPath $renderedOutputResolved -PathType Leaf)) {
    $finalStatus = 'failed'
    $finalExitCode = if ($executionExitCode -ne 0) { [int]$executionExitCode } else { 1 }
    $notes.Add('Payload inspection reported runnable and the Linux execution lane was attempted, but the proof did not finish cleanly.') | Out-Null
  } else {
    $notes.Add('Payload inspection reported runnable and the Linux execution lane produced a rendered print artifact.') | Out-Null
  }
}

$report = [ordered]@{
  schema = 'vi-headless/sample-print-proof@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  catalogPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $catalogResolved
  targetId = $TargetId
  targetPath = [string]$target.source.targetPath
  changeKind = $changeKind
  certificationSurface = $certificationSurface
  operation = $operation
  payloadBundlePath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue (Resolve-AbsolutePath -BasePath $repoRoot -PathValue $PayloadBundlePath)
  payloadInspectionPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $inspectionReportPath
  payloadInspectionMarkdownPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $inspectionMarkdownPath
  payloadDeclaredExecutableState = $declaredExecutableState
  payloadObservedExecutableState = $observedExecutableState
  payloadFinalizationContractPath = if ($payloadFinalizationContractResolved) { Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $payloadFinalizationContractResolved } else { $null }
  payloadFinalizationContractAvailable = [bool]$payloadFinalizationContractAvailable
  runnerPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $runnerScriptResolved
  targetRepositoryPath = if ($targetRepositoryResolved) { Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $targetRepositoryResolved } else { $null }
  targetRepositoryMaterialized = [bool]$targetRepositoryMaterialized
  executionAttempted = ($finalStatus -ne 'blocked')
  executionResultsRoot = if ($executionResultsRoot) { Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $executionResultsRoot } else { $null }
  executionCapturePath = if ($executionCapturePath) { Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $executionCapturePath } else { $null }
  scenarioResultPath = if ($scenarioResultPath) { Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $scenarioResultPath } else { $null }
  renderedOutputPath = if ($renderedOutputPath) { Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $renderedOutputPath } else { $null }
  executionExitCode = $executionExitCode
  executionStatus = $executionStatus
  finalStatus = $finalStatus
  blockingReason = $blockingReason
  notes = @($notes.ToArray())
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportResolved -Encoding utf8

$markdownLines = @(
  '# Headless Sample VI Corpus Print Proof',
  '',
  ('- Target: `{0}`' -f $TargetId),
  ('- Target Path: `{0}`' -f $report.targetPath),
  ('- Final Status: `{0}`' -f $finalStatus),
  ('- Payload Declared Executable State: `{0}`' -f $declaredExecutableState),
  ('- Payload Observed Executable State: `{0}`' -f $observedExecutableState),
  ('- Execution Attempted: `{0}`' -f $report.executionAttempted.ToString().ToLowerInvariant()),
  ''
)
if ($blockingReason) {
  $markdownLines += ('- Blocking Reason: `{0}`' -f $blockingReason)
  $markdownLines += ''
}
$markdownLines += ('- Runner: `{0}`' -f $report.runnerPath)
if ($report.targetRepositoryPath) {
  $markdownLines += ('- Target Repository Path: `{0}`' -f $report.targetRepositoryPath)
}
if ($report.payloadFinalizationContractPath) {
  $markdownLines += ('- Payload Finalization Contract: `{0}`' -f $report.payloadFinalizationContractPath)
}
if ($report.renderedOutputPath) {
  $markdownLines += ('- Rendered Output Path: `{0}`' -f $report.renderedOutputPath)
}
if ($null -ne $report.executionExitCode) {
  $markdownLines += ('- Execution Exit Code: `{0}`' -f $report.executionExitCode)
}
if ($report.executionStatus) {
  $markdownLines += ('- Execution Status: `{0}`' -f $report.executionStatus)
}
$markdownLines += ''
$markdownLines += '## Notes'
$markdownLines += ''
foreach ($note in @($report.notes)) {
  $markdownLines += ('- {0}' -f [string]$note)
}
$markdownLines += ''
$markdownLines += ('- Payload Inspection Report: `{0}`' -f $report.payloadInspectionPath)
$markdownLines += ('- Payload Inspection Summary: `{0}`' -f $report.payloadInspectionMarkdownPath)
if ($report.executionCapturePath) {
  $markdownLines += ('- Execution Capture: `{0}`' -f $report.executionCapturePath)
}
if ($report.scenarioResultPath) {
  $markdownLines += ('- Execution Scenario Result: `{0}`' -f $report.scenarioResultPath)
}

$markdownLines -join [Environment]::NewLine | Set-Content -LiteralPath $markdownResolved -Encoding utf8

if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $proofSchemaPath -DataPath $reportResolved
}

Write-Output ("Headless sample print proof report: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $reportResolved))
Write-Output ("Headless sample print proof summary: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $markdownResolved))

if ($PassThru.IsPresent) {
  [pscustomobject]$report
}

exit $finalExitCode
