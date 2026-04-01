#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RawArtifactDir,

  [Parameter(Mandatory = $false)]
  [string]$ExecutionReceiptPath,

  [Parameter(Mandatory = $false)]
  [string]$WorkspaceResultsDir = 'tests/results/pester-replay-local',

  [Parameter(Mandatory = $false)]
  [switch]$SkipSessionIndex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaToolPath = Join-Path $PSScriptRoot 'PesterServiceModelSchema.ps1'
if (-not (Test-Path -LiteralPath $schemaToolPath -PathType Leaf)) {
  throw "Schema tool not found: $schemaToolPath"
}
. $schemaToolPath

function Resolve-RepoRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Resolve-OutputPath {
  param(
    [string]$RepoRoot,
    [string]$PathValue
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)]$Payload
  )
  $dir = Split-Path -Parent $PathValue
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PathValue -Encoding UTF8
}

$repoRoot = Resolve-RepoRoot
$resolvedRawArtifactDir = Resolve-OutputPath -RepoRoot $repoRoot -PathValue $RawArtifactDir
if (-not (Test-Path -LiteralPath $resolvedRawArtifactDir -PathType Container)) {
  throw "Raw artifact directory not found: $resolvedRawArtifactDir"
}
$resolvedWorkspaceResultsDir = Resolve-OutputPath -RepoRoot $repoRoot -PathValue $WorkspaceResultsDir
$resolvedExecutionReceiptPath = if ([string]::IsNullOrWhiteSpace($ExecutionReceiptPath)) { $null } else { Resolve-OutputPath -RepoRoot $repoRoot -PathValue $ExecutionReceiptPath }

$postprocessToolPath = Join-Path $repoRoot 'tools/Invoke-PesterExecutionPostprocess.ps1'
$telemetryToolPath = Join-Path $repoRoot 'tools/Invoke-PesterExecutionTelemetry.ps1'
$totalsToolPath = Join-Path $repoRoot 'tools/Write-PesterTotals.ps1'
$classificationToolPath = Join-Path $repoRoot 'tools/Invoke-PesterEvidenceClassification.ps1'
$operatorOutcomeToolPath = Join-Path $repoRoot 'tools/Invoke-PesterOperatorOutcome.ps1'
$provenanceToolPath = Join-Path $repoRoot 'tools/Invoke-PesterEvidenceProvenance.ps1'
$sessionIndexToolPath = Join-Path $repoRoot 'tools/Ensure-SessionIndex.ps1'

$executionReceipt = $null
$executionReceiptState = $null
$stagedReceiptPath = $null

if (Test-Path -LiteralPath $resolvedWorkspaceResultsDir) {
  Remove-Item -LiteralPath $resolvedWorkspaceResultsDir -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedWorkspaceResultsDir -Force | Out-Null

Get-ChildItem -LiteralPath $resolvedRawArtifactDir -Force | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $resolvedWorkspaceResultsDir $_.Name) -Recurse -Force
}

if ($resolvedExecutionReceiptPath) {
  if (-not (Test-Path -LiteralPath $resolvedExecutionReceiptPath -PathType Leaf)) {
    throw "Execution receipt not found: $resolvedExecutionReceiptPath"
  }
  $stagedReceiptPath = Join-Path $resolvedWorkspaceResultsDir 'pester-execution-contract/pester-run-receipt.json'
  $stagedReceiptDir = Split-Path -Parent $stagedReceiptPath
  if (-not (Test-Path -LiteralPath $stagedReceiptDir -PathType Container)) {
    New-Item -ItemType Directory -Path $stagedReceiptDir -Force | Out-Null
  }
  Copy-Item -LiteralPath $resolvedExecutionReceiptPath -Destination $stagedReceiptPath -Force
  $executionReceiptState = Test-PesterServiceModelSchemaContract `
    -DocumentState (Read-PesterServiceModelJsonDocument -PathValue $stagedReceiptPath -ContractName 'execution-receipt') `
    -ExpectedSchema 'pester-execution-receipt@v1'
  if ($executionReceiptState.valid) {
    $executionReceipt = $executionReceiptState.document
  }
}

Push-Location $repoRoot
try {
  & $postprocessToolPath -ResultsDir $resolvedWorkspaceResultsDir | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Execution postprocess failed with exit code $LASTEXITCODE."
  }

  & $totalsToolPath -ResultsDir $resolvedWorkspaceResultsDir | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Pester totals generation failed with exit code $LASTEXITCODE."
  }

  & $telemetryToolPath -ResultsDir $resolvedWorkspaceResultsDir | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Execution telemetry generation failed with exit code $LASTEXITCODE."
  }

  if (-not $SkipSessionIndex) {
    & $sessionIndexToolPath -ResultsDir $resolvedWorkspaceResultsDir -SummaryJson 'pester-summary.json' | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Session index generation failed with exit code $LASTEXITCODE."
    }
  }

  $classificationArgs = @{
    ResultsDir = $resolvedWorkspaceResultsDir
    RawArtifactDownload = 'staged'
  }
  if ($stagedReceiptPath) {
    $classificationArgs.ExecutionReceiptPath = $stagedReceiptPath
  }
  if ($executionReceipt) {
    if ($executionReceipt.PSObject.Properties.Name -contains 'contextStatus') {
      $classificationArgs.ContextStatus = [string]$executionReceipt.contextStatus
    }
    if ($executionReceipt.PSObject.Properties.Name -contains 'readinessStatus') {
      $classificationArgs.ReadinessStatus = [string]$executionReceipt.readinessStatus
    }
    if ($executionReceipt.PSObject.Properties.Name -contains 'selectionStatus') {
      $classificationArgs.SelectionStatus = [string]$executionReceipt.selectionStatus
    }
    if ($executionReceipt.PSObject.Properties.Name -contains 'executionJobResult') {
      $classificationArgs.ExecutionJobResult = [string]$executionReceipt.executionJobResult
    }
    if ($executionReceipt.PSObject.Properties.Name -contains 'dispatcherExitCode') {
      $classificationArgs.DispatcherExitCode = [string]$executionReceipt.dispatcherExitCode
    }
  }
  & $classificationToolPath @classificationArgs | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Evidence classification failed with exit code $LASTEXITCODE."
  }

  & $operatorOutcomeToolPath -ResultsDir $resolvedWorkspaceResultsDir | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Operator outcome generation failed with exit code $LASTEXITCODE."
  }

  & $provenanceToolPath `
    -ResultsDir $resolvedWorkspaceResultsDir `
    -ExecutionReceiptPath $stagedReceiptPath `
    -RawArtifactName ([System.IO.Path]::GetFileName($resolvedRawArtifactDir)) `
    -RawArtifactDownload 'local-replay' `
    -ExecutionReceiptArtifactName 'pester-execution-contract' `
    -SourceRawArtifactDir $resolvedRawArtifactDir `
    -ProvenanceKind 'local-replay' | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Evidence provenance generation failed with exit code $LASTEXITCODE."
  }
} finally {
  Pop-Location
}

$classificationPath = Join-Path $resolvedWorkspaceResultsDir 'pester-evidence-classification.json'
$postprocessReportPath = Join-Path $resolvedWorkspaceResultsDir 'pester-execution-postprocess.json'
$telemetryPath = Join-Path $resolvedWorkspaceResultsDir 'pester-execution-telemetry.json'
$provenancePath = Join-Path $resolvedWorkspaceResultsDir 'pester-evidence-provenance.json'
$totalsPath = Join-Path $resolvedWorkspaceResultsDir 'pester-totals.json'
$sessionIndexPath = Join-Path $resolvedWorkspaceResultsDir 'session-index.json'
$classification = if (Test-Path -LiteralPath $classificationPath -PathType Leaf) {
  (Get-Content -LiteralPath $classificationPath -Raw | ConvertFrom-Json -ErrorAction Stop).classification
} else {
  'missing'
}
$operatorOutcomePath = Join-Path $resolvedWorkspaceResultsDir 'pester-operator-outcome.json'
$operatorOutcome = if (Test-Path -LiteralPath $operatorOutcomePath -PathType Leaf) {
  Get-Content -LiteralPath $operatorOutcomePath -Raw | ConvertFrom-Json -ErrorAction Stop
} else {
  $null
}
$telemetry = if (Test-Path -LiteralPath $telemetryPath -PathType Leaf) {
  Get-Content -LiteralPath $telemetryPath -Raw | ConvertFrom-Json -ErrorAction Stop
} else {
  $null
}
$provenance = if (Test-Path -LiteralPath $provenancePath -PathType Leaf) {
  Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json -ErrorAction Stop
} else {
  $null
}

$replayReceipt = [ordered]@{
  schema = 'pester-local-replay-receipt@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  rawArtifactDir = $resolvedRawArtifactDir
  executionReceiptPath = $resolvedExecutionReceiptPath
  stagedExecutionReceiptPath = $stagedReceiptPath
  stagedExecutionReceiptSchemaStatus = if ($executionReceiptState) { [string]$executionReceiptState.classification } else { 'missing' }
  stagedExecutionReceiptSchemaReason = if ($executionReceiptState) { [string]$executionReceiptState.reason } else { 'execution-receipt-missing' }
  workspaceResultsDir = $resolvedWorkspaceResultsDir
  postprocessReportPath = $postprocessReportPath
  telemetryPath = $telemetryPath
  telemetryPresent = [bool]$telemetry
  telemetryStatus = if ($telemetry) { [string]$telemetry.telemetryStatus } else { 'telemetry-missing' }
  telemetryLastKnownPhase = if ($telemetry) { [string]$telemetry.lastKnownPhase } else { $null }
  telemetryEventCount = if ($telemetry) { [int]$telemetry.eventCount } else { 0 }
  totalsPath = $totalsPath
  sessionIndexPath = if ($SkipSessionIndex) { $null } else { $sessionIndexPath }
  classificationPath = $classificationPath
  classification = $classification
  operatorOutcomePath = $operatorOutcomePath
  operatorOutcomePresent = [bool]$operatorOutcome
  operatorOutcomeGateStatus = if ($operatorOutcome) { [string]$operatorOutcome.gateStatus } else { 'missing' }
  operatorOutcomeNextActionId = if ($operatorOutcome) { [string]$operatorOutcome.nextActionId } else { $null }
  provenancePath = $provenancePath
  provenancePresent = [bool]$provenance
  provenanceKind = if ($provenance) { [string]$provenance.provenanceKind } else { 'missing' }
}
$replayReceiptPath = Join-Path $resolvedWorkspaceResultsDir 'pester-local-replay-receipt.json'
Write-JsonFile -PathValue $replayReceiptPath -Payload $replayReceipt

Write-Host '### Pester service-model local replay' -ForegroundColor Cyan
Write-Host ("rawArtifact : {0}" -f $resolvedRawArtifactDir)
Write-Host ("workspace   : {0}" -f $resolvedWorkspaceResultsDir)
Write-Host ("classify    : {0}" -f $classification)
Write-Host ("receipt     : {0}" -f $replayReceiptPath)

exit 0
