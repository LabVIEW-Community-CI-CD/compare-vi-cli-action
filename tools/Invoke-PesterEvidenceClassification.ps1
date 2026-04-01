[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$ResultsDir = 'tests/results',

  [Parameter(Mandatory = $false)]
  [string]$ExecutionReceiptPath,

  [Parameter(Mandatory = $false)]
  [string]$ContextStatus = 'unknown',

  [Parameter(Mandatory = $false)]
  [string]$ReadinessStatus = 'unknown',

  [Parameter(Mandatory = $false)]
  [string]$SelectionStatus = 'unknown',

  [Parameter(Mandatory = $false)]
  [string]$ExecutionJobResult = '',

  [Parameter(Mandatory = $false)]
  [string]$DispatcherExitCode = '',

  [Parameter(Mandatory = $false)]
  [string]$RawArtifactDownload = 'local',

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = 'pester-evidence-classification.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaToolPath = Join-Path $PSScriptRoot 'PesterServiceModelSchema.ps1'
if (-not (Test-Path -LiteralPath $schemaToolPath -PathType Leaf)) {
  throw "Schema tool not found: $schemaToolPath"
}
. $schemaToolPath

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

function Get-OptionalStringProperty {
  param(
    $InputObject,
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$DefaultValue = ''
  )

  if ($null -eq $InputObject) {
    return $DefaultValue
  }

  if (-not ($InputObject.PSObject.Properties.Name -contains $Name)) {
    return $DefaultValue
  }

  return [string]$InputObject.$Name
}

$resolvedResultsDir = [System.IO.Path]::GetFullPath($ResultsDir)
if (-not (Test-Path -LiteralPath $resolvedResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resolvedResultsDir -Force | Out-Null
}

$summaryPath = Join-Path $resolvedResultsDir 'pester-summary.json'
$resolvedReceiptPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $ExecutionReceiptPath
$resolvedOutputPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $OutputPath
if (-not $resolvedOutputPath) {
  $resolvedOutputPath = Join-Path $resolvedResultsDir 'pester-evidence-classification.json'
}

$executionReceipt = $null
$executionReceiptPresent = $false
$executionReceiptStatus = 'missing'
$executionReceiptSchemaState = $null
if ($resolvedReceiptPath -and (Test-Path -LiteralPath $resolvedReceiptPath -PathType Leaf)) {
  $executionReceiptSchemaState = Test-PesterServiceModelSchemaContract `
    -DocumentState (Read-PesterServiceModelJsonDocument -PathValue $resolvedReceiptPath -ContractName 'execution-receipt') `
    -ExpectedSchema 'pester-execution-receipt@v1'
  $executionReceiptPresent = $true
  if ($executionReceiptSchemaState.valid) {
    $executionReceipt = $executionReceiptSchemaState.document
    $executionReceiptStatus = [string]$executionReceipt.status
  } else {
    $executionReceiptStatus = 'unsupported-schema'
  }
}

$summarySchemaState = Test-PesterServiceModelSchemaContract `
  -DocumentState (Read-PesterServiceModelJsonDocument -PathValue $summaryPath -ContractName 'pester-summary') `
  -ExpectedSchemaVersionMajor 1 `
  -RequireSchemaVersion

$effectiveContextStatus = if ($ContextStatus -and $ContextStatus -ne 'unknown') { $ContextStatus } elseif ($executionReceipt) { Get-OptionalStringProperty -InputObject $executionReceipt -Name 'contextStatus' -DefaultValue 'unknown' } else { 'unknown' }
$effectiveReadinessStatus = if ($ReadinessStatus -and $ReadinessStatus -ne 'unknown') { $ReadinessStatus } elseif ($executionReceipt) { Get-OptionalStringProperty -InputObject $executionReceipt -Name 'readinessStatus' -DefaultValue 'unknown' } else { 'unknown' }
$effectiveSelectionStatus = if ($SelectionStatus -and $SelectionStatus -ne 'unknown') { $SelectionStatus } elseif ($executionReceipt) { Get-OptionalStringProperty -InputObject $executionReceipt -Name 'selectionStatus' -DefaultValue 'unknown' } else { 'unknown' }
$effectiveExecutionJobResult = if (-not [string]::IsNullOrWhiteSpace($ExecutionJobResult)) { $ExecutionJobResult } elseif ($executionReceipt -and $executionReceipt.PSObject.Properties.Name -contains 'executionJobResult') { [string]$executionReceipt.executionJobResult } else { '' }
$effectiveDispatcherExitCode = if (-not [string]::IsNullOrWhiteSpace($DispatcherExitCode)) { $DispatcherExitCode } elseif ($executionReceipt -and $executionReceipt.PSObject.Properties.Name -contains 'dispatcherExitCode') { [string]$executionReceipt.dispatcherExitCode } else { '-1' }
if ([string]::IsNullOrWhiteSpace($effectiveDispatcherExitCode)) {
  $effectiveDispatcherExitCode = '-1'
}

$classification = 'seam-defect'
$reasons = New-Object System.Collections.Generic.List[string]
if ($effectiveContextStatus -ne 'ready') {
  $reasons.Add(("context-status={0}" -f $effectiveContextStatus)) | Out-Null
}
if ($effectiveReadinessStatus -ne 'ready') {
  $reasons.Add(("readiness-status={0}" -f $effectiveReadinessStatus)) | Out-Null
}
if ($effectiveSelectionStatus -ne 'ready') {
  $reasons.Add(("selection-status={0}" -f $effectiveSelectionStatus)) | Out-Null
}
if ($effectiveExecutionJobResult -eq 'skipped') {
  $reasons.Add('execution-job-skipped') | Out-Null
} elseif ($effectiveExecutionJobResult -eq 'cancelled') {
  $reasons.Add('execution-job-cancelled') | Out-Null
} elseif ($effectiveExecutionJobResult -eq 'results-xml-truncated') {
  $reasons.Add('execution-job-results-xml-truncated') | Out-Null
} elseif ($effectiveExecutionJobResult -eq 'invalid-results-xml') {
  $reasons.Add('execution-job-invalid-results-xml') | Out-Null
} elseif ($effectiveExecutionJobResult -eq 'missing-results-xml') {
  $reasons.Add('execution-job-missing-results-xml') | Out-Null
} elseif ($effectiveExecutionJobResult -eq 'unsupported-schema') {
  $reasons.Add('execution-job-unsupported-schema') | Out-Null
} elseif ($effectiveExecutionJobResult -eq 'seam-defect') {
  $reasons.Add('execution-job-seam-defect') | Out-Null
} elseif ($effectiveExecutionJobResult -eq 'unknown') {
  $reasons.Add('execution-job-unknown') | Out-Null
}
if ($RawArtifactDownload -notin @('success', 'skipped', 'local', 'not-requested', 'staged')) {
  $reasons.Add(("raw-artifact-download={0}" -f $RawArtifactDownload)) | Out-Null
}

if (-not $executionReceiptPresent) {
  $reasons.Add('execution-receipt-missing') | Out-Null
} elseif ($executionReceiptSchemaState -and -not $executionReceiptSchemaState.valid) {
  $classification = 'unsupported-schema'
  $reasons.Add([string]$executionReceiptSchemaState.reason) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace([string]$executionReceiptSchemaState.actualSchema)) {
    $reasons.Add(("execution-receipt-schema={0}" -f [string]$executionReceiptSchemaState.actualSchema)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$executionReceiptSchemaState.actualSchemaVersion)) {
    $reasons.Add(("execution-receipt-schema-version={0}" -f [string]$executionReceiptSchemaState.actualSchemaVersion)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$executionReceiptSchemaState.parseError)) {
    $reasons.Add(("execution-receipt-parse-error={0}" -f [string]$executionReceiptSchemaState.parseError)) | Out-Null
  }
} elseif (($effectiveContextStatus -ne 'ready' -and $effectiveExecutionJobResult -in @('skipped', 'cancelled')) -or $executionReceiptStatus -eq 'context-blocked') {
  $classification = 'context-blocked'
} elseif ($effectiveReadinessStatus -ne 'ready' -and $effectiveExecutionJobResult -in @('skipped', 'cancelled')) {
  $classification = 'readiness-blocked'
} elseif (($effectiveSelectionStatus -ne 'ready' -and $effectiveExecutionJobResult -in @('skipped', 'cancelled')) -or $executionReceiptStatus -eq 'selection-blocked') {
  $classification = 'selection-blocked'
} elseif ($executionReceiptStatus -eq 'results-xml-truncated') {
  $classification = 'results-xml-truncated'
  $reasons.Add('execution-receipt-results-xml-truncated') | Out-Null
} elseif ($executionReceiptStatus -eq 'invalid-results-xml') {
  $classification = 'invalid-results-xml'
  $reasons.Add('execution-receipt-invalid-results-xml') | Out-Null
} elseif ($executionReceiptStatus -eq 'missing-results-xml') {
  $classification = 'missing-results-xml'
  $reasons.Add('execution-receipt-missing-results-xml') | Out-Null
} elseif ($executionReceiptStatus -eq 'unsupported-schema') {
  $classification = 'unsupported-schema'
  $reasons.Add('execution-receipt-unsupported-schema') | Out-Null
} elseif ($executionReceiptStatus -eq 'seam-defect') {
  $reasons.Add('execution-receipt-seam-defect') | Out-Null
} elseif ($executionReceiptStatus -eq 'test-failures') {
  $classification = 'test-failures'
} elseif ($summarySchemaState.present -and -not $summarySchemaState.valid) {
  $classification = 'unsupported-schema'
  $reasons.Add([string]$summarySchemaState.reason) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace([string]$summarySchemaState.actualSchemaVersion)) {
    $reasons.Add(("summary-schema-version={0}" -f [string]$summarySchemaState.actualSchemaVersion)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$summarySchemaState.parseError)) {
    $reasons.Add(("summary-parse-error={0}" -f [string]$summarySchemaState.parseError)) | Out-Null
  }
} elseif (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
  try {
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($executionReceipt -and $executionReceipt.PSObject.Properties.Name -contains 'dispatcherExitCode') {
      if ([string]$executionReceipt.dispatcherExitCode -and [string]$executionReceipt.dispatcherExitCode -ne $effectiveDispatcherExitCode) {
        $reasons.Add('dispatcher-exit-mismatch') | Out-Null
      }
    }
    if (($summary.PSObject.Properties.Name -contains 'resultsXmlStatus') -and [string]$summary.resultsXmlStatus -like 'truncated*') {
      $classification = 'results-xml-truncated'
      $reasons.Add(("results-xml-status={0}" -f [string]$summary.resultsXmlStatus)) | Out-Null
    } elseif (($summary.PSObject.Properties.Name -contains 'resultsXmlStatus') -and [string]$summary.resultsXmlStatus -like 'invalid*') {
      $classification = 'invalid-results-xml'
      $reasons.Add(("results-xml-status={0}" -f [string]$summary.resultsXmlStatus)) | Out-Null
    } elseif (([int]$summary.failed + [int]$summary.errors) -gt 0 -or $effectiveDispatcherExitCode -ne '0') {
      $classification = 'test-failures'
    } else {
      $classification = 'ok'
    }
  } catch {
    $classification = 'seam-defect'
    $reasons.Add('summary-unparseable') | Out-Null
  }
} else {
  $reasons.Add('summary-missing') | Out-Null
}

$payload = [ordered]@{
  schema = 'pester-evidence-classification@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  contextStatus = $effectiveContextStatus
  readinessStatus = $effectiveReadinessStatus
  selectionStatus = $effectiveSelectionStatus
  selectionExecutionPack = Get-OptionalStringProperty -InputObject $executionReceipt -Name 'selectionExecutionPack'
  selectionExecutionPackSource = Get-OptionalStringProperty -InputObject $executionReceipt -Name 'selectionExecutionPackSource'
  executionJobResult = $effectiveExecutionJobResult
  rawArtifactDownload = $RawArtifactDownload
  dispatcherExitCode = [int]$effectiveDispatcherExitCode
  summaryPresent = (Test-Path -LiteralPath $summaryPath -PathType Leaf)
  executionReceiptSchemaStatus = if ($executionReceiptSchemaState) { [string]$executionReceiptSchemaState.classification } else { 'missing' }
  summarySchemaStatus = [string]$summarySchemaState.classification
  classification = $classification
  reasons = @($reasons)
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8

if ($env:GITHUB_OUTPUT) {
  "classification=$classification" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "path=$resolvedOutputPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester evidence classification' -ForegroundColor Cyan
Write-Host ("classification : {0}" -f $classification)
Write-Host ("receiptPresent : {0}" -f $executionReceiptPresent)
Write-Host ("path           : {0}" -f $resolvedOutputPath)

exit 0
