[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$ResultsDir = 'tests/results',

  [Parameter(Mandatory = $false)]
  [string]$ExecutionReceiptPath = 'tests/execution-contract/pester-run-receipt.json',

  [Parameter(Mandatory = $false)]
  [string]$ClassificationPath = 'pester-evidence-classification.json',

  [Parameter(Mandatory = $false)]
  [string]$OperatorOutcomePath = 'pester-operator-outcome.json',

  [Parameter(Mandatory = $false)]
  [string]$TelemetryPath = 'pester-execution-telemetry.json',

  [Parameter(Mandatory = $false)]
  [string]$PostprocessReportPath = 'pester-execution-postprocess.json',

  [Parameter(Mandatory = $false)]
  [string]$SummaryPath = 'pester-summary.json',

  [Parameter(Mandatory = $false)]
  [string]$FailuresPath = 'pester-failures.json',

  [Parameter(Mandatory = $false)]
  [string]$ResultsXmlPath = 'pester-results.xml',

  [Parameter(Mandatory = $false)]
  [string]$DispatcherEventsPath = 'dispatcher-events.ndjson',

  [Parameter(Mandatory = $false)]
  [string]$TotalsPath = 'pester-totals.json',

  [Parameter(Mandatory = $false)]
  [string]$SessionIndexPath = 'session-index.json',

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = 'pester-evidence-provenance.json',

  [Parameter(Mandatory = $false)]
  [string]$RawArtifactName = 'pester-run-raw',

  [Parameter(Mandatory = $false)]
  [string]$RawArtifactDownload = 'local',

  [Parameter(Mandatory = $false)]
  [string]$ExecutionReceiptArtifactName = 'pester-execution-contract',

  [Parameter(Mandatory = $false)]
  [string]$SourceRawArtifactDir,

  [Parameter(Mandatory = $false)]
  [ValidateSet('evidence', 'local-replay')]
  [string]$ProvenanceKind = 'evidence'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-OptionalPath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function ConvertTo-PortablePath {
  param([AllowNull()][string]$PathValue)

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  return ([string]$PathValue).Replace('\', '/')
}

function Get-RepoRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [AllowNull()][string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  $resolvedPath = [System.IO.Path]::GetFullPath($PathValue)
  $resolvedRoot = [System.IO.Path]::GetFullPath($RepoRoot)
  $relative = [System.IO.Path]::GetRelativePath($resolvedRoot, $resolvedPath)
  if ([string]::IsNullOrWhiteSpace($relative)) {
    return '.'
  }
  if ($relative.StartsWith('..')) {
    return $null
  }
  return ConvertTo-PortablePath $relative
}

function Get-OptionalGitValue {
  param([string[]]$Args)

  try {
    $output = & git @Args 2>$null
    if ($LASTEXITCODE -eq 0) {
      return (($output | Out-String).Trim())
    }
  } catch {
    return $null
  }

  return $null
}

function Read-OptionalJsonMetadata {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
    return $null
  }

  try {
    $document = Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json -ErrorAction Stop
    return [ordered]@{
      schema = if ($document.PSObject.Properties.Name -contains 'schema') { [string]$document.schema } else { $null }
      schemaVersion = if ($document.PSObject.Properties.Name -contains 'schemaVersion') { [string]$document.schemaVersion } else { $null }
      status = if ($document.PSObject.Properties.Name -contains 'status') { [string]$document.status } elseif ($document.PSObject.Properties.Name -contains 'classification') { [string]$document.classification } else { $null }
    }
  } catch {
    return [ordered]@{
      schema = $null
      schemaVersion = $null
      status = 'invalid-json'
    }
  }
}

function New-FileDescriptor {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Role,
    [string]$ArtifactName
  )

  $resolvedPath = [System.IO.Path]::GetFullPath($PathValue)
  $present = Test-Path -LiteralPath $resolvedPath -PathType Leaf
  $descriptor = [ordered]@{
    kind = $Kind
    role = $Role
    artifactName = if ([string]::IsNullOrWhiteSpace($ArtifactName)) { $null } else { $ArtifactName }
    path = ConvertTo-PortablePath $resolvedPath
    repoRelativePath = Get-RepoRelativePath -RepoRoot $RepoRoot -PathValue $resolvedPath
    present = $present
  }

  if (-not $present) {
    return $descriptor
  }

  $item = Get-Item -LiteralPath $resolvedPath
  $hash = Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256
  $descriptor.sizeBytes = [int64]$item.Length
  $descriptor.sha256 = $hash.Hash.ToLowerInvariant()
  $descriptor.lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')

  $metadata = Read-OptionalJsonMetadata -PathValue $resolvedPath
  if ($metadata) {
    $descriptor.schema = $metadata.schema
    $descriptor.schemaVersion = $metadata.schemaVersion
    $descriptor.status = $metadata.status
  }

  return $descriptor
}

function New-DirectoryDescriptor {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Role,
    [string]$ArtifactName
  )

  $resolvedPath = [System.IO.Path]::GetFullPath($PathValue)
  $present = Test-Path -LiteralPath $resolvedPath -PathType Container
  $descriptor = [ordered]@{
    kind = $Kind
    role = $Role
    artifactName = if ([string]::IsNullOrWhiteSpace($ArtifactName)) { $null } else { $ArtifactName }
    path = ConvertTo-PortablePath $resolvedPath
    repoRelativePath = Get-RepoRelativePath -RepoRoot $RepoRoot -PathValue $resolvedPath
    present = $present
    fileCount = 0
    files = @()
  }

  if (-not $present) {
    return $descriptor
  }

  $files = @(Get-ChildItem -LiteralPath $resolvedPath -File -Recurse | Sort-Object FullName)
  $descriptor.fileCount = $files.Count
  $descriptor.files = @(
    $files | ForEach-Object {
      $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
      [ordered]@{
        path = ConvertTo-PortablePath $_.FullName
        repoRelativePath = Get-RepoRelativePath -RepoRoot $RepoRoot -PathValue $_.FullName
        relativePath = ConvertTo-PortablePath ([System.IO.Path]::GetRelativePath($resolvedPath, $_.FullName))
        sizeBytes = [int64]$_.Length
        sha256 = $hash.Hash.ToLowerInvariant()
      }
    }
  )

  return $descriptor
}

function Get-RunContext {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$ProvenanceKind
  )

  $branch = if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { Get-OptionalGitValue -Args @('rev-parse', '--abbrev-ref', 'HEAD') }
  $headSha = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { Get-OptionalGitValue -Args @('rev-parse', 'HEAD') }
  $repository = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { Split-Path -Leaf $RepoRoot }
  $runId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { $null }
  $serverUrl = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL.TrimEnd('/') } else { 'https://github.com' }

  return [ordered]@{
    source = if ($runId) { 'github-actions' } else { 'local' }
    repository = $repository
    workflow = if ($env:GITHUB_WORKFLOW) { $env:GITHUB_WORKFLOW } else { if ($ProvenanceKind -eq 'local-replay') { 'Pester local replay' } else { 'Pester evidence' } }
    eventName = if ($env:GITHUB_EVENT_NAME) { $env:GITHUB_EVENT_NAME } else { 'local' }
    runId = $runId
    runAttempt = if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { $null }
    runUrl = if ($runId -and $repository) { "$serverUrl/$repository/actions/runs/$runId" } else { $null }
    ref = if ($env:GITHUB_REF) { $env:GITHUB_REF } else { if ($branch) { "refs/heads/$branch" } else { $null } }
    refName = $branch
    branch = $branch
    headRef = if ($env:GITHUB_HEAD_REF) { $env:GITHUB_HEAD_REF } else { $null }
    baseRef = if ($env:GITHUB_BASE_REF) { $env:GITHUB_BASE_REF } else { $null }
    headSha = $headSha
  }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedResultsDir = [System.IO.Path]::GetFullPath($ResultsDir)
if (-not (Test-Path -LiteralPath $resolvedResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resolvedResultsDir -Force | Out-Null
}
$resolvedExecutionReceiptPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $ExecutionReceiptPath
$resolvedClassificationPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $ClassificationPath
$resolvedOperatorOutcomePath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $OperatorOutcomePath
$resolvedTelemetryPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $TelemetryPath
$resolvedPostprocessReportPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $PostprocessReportPath
$resolvedSummaryPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $SummaryPath
$resolvedFailuresPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $FailuresPath
$resolvedResultsXmlPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $ResultsXmlPath
$resolvedDispatcherEventsPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $DispatcherEventsPath
$resolvedTotalsPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $TotalsPath
$resolvedSessionIndexPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $SessionIndexPath
$resolvedOutputPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $OutputPath
if (-not $resolvedOutputPath) {
  $resolvedOutputPath = Join-Path $resolvedResultsDir 'pester-evidence-provenance.json'
}
$resolvedSourceRawArtifactDir = if ([string]::IsNullOrWhiteSpace($SourceRawArtifactDir)) { $null } else { Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $SourceRawArtifactDir }

$sourceInputs = New-Object System.Collections.Generic.List[object]
if ($resolvedSourceRawArtifactDir -and ([System.IO.Path]::GetFullPath($resolvedSourceRawArtifactDir) -ne $resolvedResultsDir)) {
  $sourceInputs.Add((New-DirectoryDescriptor -RepoRoot $repoRoot -PathValue $resolvedSourceRawArtifactDir -Kind 'raw-artifact-set' -Role 'source-raw-artifacts' -ArtifactName $RawArtifactName)) | Out-Null
} else {
  foreach ($entry in @(
      @{ Path = $resolvedResultsXmlPath; Kind = 'raw-artifact'; Role = 'results-xml' },
      @{ Path = $resolvedSummaryPath; Kind = 'raw-artifact'; Role = 'summary' },
      @{ Path = $resolvedFailuresPath; Kind = 'raw-artifact'; Role = 'failures' },
      @{ Path = $resolvedPostprocessReportPath; Kind = 'raw-artifact'; Role = 'postprocess' },
      @{ Path = $resolvedTelemetryPath; Kind = 'raw-artifact'; Role = 'telemetry' },
      @{ Path = $resolvedDispatcherEventsPath; Kind = 'raw-artifact'; Role = 'dispatcher-events' }
    )) {
    $sourceInputs.Add((New-FileDescriptor -RepoRoot $repoRoot -PathValue $entry.Path -Kind $entry.Kind -Role $entry.Role -ArtifactName $RawArtifactName)) | Out-Null
  }
}
if ($resolvedExecutionReceiptPath) {
  $sourceInputs.Add((New-FileDescriptor -RepoRoot $repoRoot -PathValue $resolvedExecutionReceiptPath -Kind 'execution-receipt' -Role 'execution-receipt' -ArtifactName $ExecutionReceiptArtifactName)) | Out-Null
}

$derivedOutputs = New-Object System.Collections.Generic.List[object]
switch ($ProvenanceKind) {
  'local-replay' {
    foreach ($entry in @(
        @{ Path = $resolvedPostprocessReportPath; Kind = 'derived-evidence'; Role = 'postprocess-report' },
        @{ Path = $resolvedTelemetryPath; Kind = 'derived-evidence'; Role = 'telemetry' },
        @{ Path = $resolvedSummaryPath; Kind = 'derived-evidence'; Role = 'summary' },
        @{ Path = $resolvedTotalsPath; Kind = 'derived-evidence'; Role = 'totals' },
        @{ Path = $resolvedSessionIndexPath; Kind = 'derived-evidence'; Role = 'session-index' },
        @{ Path = $resolvedClassificationPath; Kind = 'derived-evidence'; Role = 'classification' },
        @{ Path = $resolvedOperatorOutcomePath; Kind = 'derived-evidence'; Role = 'operator-outcome' }
      )) {
      $derivedOutputs.Add((New-FileDescriptor -RepoRoot $repoRoot -PathValue $entry.Path -Kind $entry.Kind -Role $entry.Role)) | Out-Null
    }
  }
  default {
    foreach ($entry in @(
        @{ Path = $resolvedTotalsPath; Kind = 'derived-evidence'; Role = 'totals' },
        @{ Path = $resolvedSessionIndexPath; Kind = 'derived-evidence'; Role = 'session-index' },
        @{ Path = $resolvedClassificationPath; Kind = 'derived-evidence'; Role = 'classification' },
        @{ Path = $resolvedOperatorOutcomePath; Kind = 'derived-evidence'; Role = 'operator-outcome' }
      )) {
      $derivedOutputs.Add((New-FileDescriptor -RepoRoot $repoRoot -PathValue $entry.Path -Kind $entry.Kind -Role $entry.Role)) | Out-Null
    }
  }
}

$subjectId = if ($ProvenanceKind -eq 'local-replay') { 'pester-local-replay' } else { 'pester-evidence' }
$portableSourceRawArtifactDir = ConvertTo-PortablePath $resolvedSourceRawArtifactDir
$portableWorkspaceResultsDir = ConvertTo-PortablePath $resolvedResultsDir
$runContext = Get-RunContext -RepoRoot $repoRoot -ProvenanceKind $ProvenanceKind
$sourceInputsArray = @($sourceInputs.ToArray())
$derivedOutputsArray = @($derivedOutputs.ToArray())

$payload = [ordered]@{
  schema = 'pester-derived-provenance@v1'
  schemaVersion = '1.0.0'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  provenanceKind = $ProvenanceKind
  producer = [ordered]@{
    id = 'Invoke-PesterEvidenceProvenance.ps1'
    version = '1.0.0'
  }
  subject = [ordered]@{
    id = $subjectId
    rawArtifactName = $RawArtifactName
    rawArtifactDownload = $RawArtifactDownload
    executionReceiptArtifactName = $ExecutionReceiptArtifactName
    sourceRawArtifactDir = $portableSourceRawArtifactDir
    workspaceResultsDir = $portableWorkspaceResultsDir
  }
  runContext = $runContext
  sourceInputs = $sourceInputsArray
  derivedOutputs = $derivedOutputsArray
}

$payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8

if ($env:GITHUB_OUTPUT) {
  "path=$resolvedOutputPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "provenance_kind=$ProvenanceKind" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester evidence provenance' -ForegroundColor Cyan
Write-Host ("kind        : {0}" -f $ProvenanceKind)
Write-Host ("sourceCount : {0}" -f @($payload.sourceInputs).Count)
Write-Host ("derivedCount: {0}" -f @($payload.derivedOutputs).Count)
Write-Host ("path        : {0}" -f $resolvedOutputPath)

exit 0
