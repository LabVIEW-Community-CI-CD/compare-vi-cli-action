[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$ResultsDir = 'tests/results',

  [Parameter(Mandatory = $false)]
  [string]$ClassificationPath = 'pester-evidence-classification.json',

  [Parameter(Mandatory = $false)]
  [string]$SummaryPath = 'pester-summary.json',

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = 'pester-operator-outcome.json',

  [Parameter(Mandatory = $false)]
  [string]$ContinueOnError = 'false'
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

function Read-JsonObject {
  param([Parameter(Mandatory = $true)][string]$PathValue)
  if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
    throw "JSON file not found: $PathValue"
  }
  return (Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertTo-Bool {
  param($Value)
  if ($Value -is [bool]) {
    return $Value
  }
  if ($null -eq $Value) {
    return $false
  }
  return ([string]$Value).Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'on')
}

function Get-OperatorOutcomeDescriptor {
  param(
    [Parameter(Mandatory = $true)][string]$Classification,
    [Parameter(Mandatory = $true)][bool]$ContinueOnError
  )

  switch ($Classification) {
    'ok' {
      return [pscustomobject]@{
        gateStatus = 'pass'
        headline = 'Pester gate passed.'
        nextActionId = 'no-action'
        nextAction = 'No action required.'
        actionContext = @('tests/results/pester-summary.json')
      }
    }
    'context-blocked' {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate blocked before execution by context debt.'
        nextActionId = 'inspect-context-receipt'
        nextAction = 'Inspect the context receipt and trusted-routing inputs before rerunning the gate.'
        actionContext = @('tests/execution-contract/pester-run-receipt.json', 'tests/results/pester-evidence-classification.json')
      }
    }
    'readiness-blocked' {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate blocked by self-hosted readiness debt.'
        nextActionId = 'inspect-readiness-receipt'
        nextAction = 'Inspect the readiness receipt and ingress-host probe results before rerunning the gate.'
        actionContext = @('tests/execution-contract/pester-run-receipt.json', 'tests/results/pester-evidence-classification.json')
      }
    }
    'selection-blocked' {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate blocked by selection-contract debt.'
        nextActionId = 'inspect-selection-receipt'
        nextAction = 'Inspect the selection receipt, named execution pack, and include-pattern refinement before rerunning the gate.'
        actionContext = @('tests/execution-contract/pester-run-receipt.json', 'tests/results/pester-evidence-classification.json')
      }
    }
    'results-xml-truncated' {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate produced truncated XML results.'
        nextActionId = 'inspect-results-xml-truncation'
        nextAction = 'Inspect pester-execution-postprocess.json and raw pester-results.xml to resolve XML truncation before trusting summary output.'
        actionContext = @('tests/results/pester-execution-postprocess.json', 'tests/results/pester-results.xml', 'tests/results/pester-evidence-classification.json')
      }
    }
    'invalid-results-xml' {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate produced invalid XML results.'
        nextActionId = 'inspect-invalid-results-xml'
        nextAction = 'Inspect pester-execution-postprocess.json and raw pester-results.xml to resolve malformed result XML before trusting summary output.'
        actionContext = @('tests/results/pester-execution-postprocess.json', 'tests/results/pester-results.xml', 'tests/results/pester-evidence-classification.json')
      }
    }
    'missing-results-xml' {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate completed without result XML.'
        nextActionId = 'inspect-missing-results-xml'
        nextAction = 'Inspect dispatcher outputs, raw-artifact staging, and execution-post reports to determine why pester-results.xml was not produced.'
        actionContext = @('tests/results/pester-execution-postprocess.json', 'tests/results/pester-dispatcher.log', 'tests/results/pester-evidence-classification.json')
      }
    }
    'unsupported-schema' {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate encountered an unsupported retained-artifact schema.'
        nextActionId = 'reconcile-schema-contract'
        nextAction = 'Regenerate retained artifacts with the supported schema contract or update readers before rerunning the gate.'
        actionContext = @('tests/results/pester-evidence-classification.json', 'tests/execution-contract/pester-run-receipt.json', 'tests/results/pester-summary.json')
      }
    }
    'test-failures' {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate completed and reported test failures.'
        nextActionId = 'review-top-failures'
        nextAction = 'Review pester-failures.json, the top-failures summary, and the failing test names before deciding whether to rerun or fix source.'
        actionContext = @('tests/results/pester-failures.json', 'tests/results/pester-summary.json', 'tests/results/pester-evidence-classification.json')
      }
    }
    default {
      return [pscustomobject]@{
        gateStatus = if ($ContinueOnError) { 'notice' } else { 'fail' }
        headline = 'Pester gate ended with orchestration or evidence debt.'
        nextActionId = 'inspect-execution-evidence'
        nextAction = 'Inspect the execution receipt, telemetry, raw artifacts, and evidence classification to isolate the real failing seam.'
        actionContext = @('tests/execution-contract/pester-run-receipt.json', 'tests/results/pester-execution-telemetry.json', 'tests/results/pester-evidence-classification.json')
      }
    }
  }
}

$resolvedResultsDir = [System.IO.Path]::GetFullPath($ResultsDir)
if (-not (Test-Path -LiteralPath $resolvedResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resolvedResultsDir -Force | Out-Null
}

$resolvedClassificationPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $ClassificationPath
$resolvedSummaryPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $SummaryPath
$resolvedOutputPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $OutputPath
if (-not $resolvedOutputPath) {
  $resolvedOutputPath = Join-Path $resolvedResultsDir 'pester-operator-outcome.json'
}

$classification = Read-JsonObject -PathValue $resolvedClassificationPath
$summary = if ($resolvedSummaryPath -and (Test-Path -LiteralPath $resolvedSummaryPath -PathType Leaf)) {
  Read-JsonObject -PathValue $resolvedSummaryPath
} else {
  $null
}

$descriptor = Get-OperatorOutcomeDescriptor -Classification ([string]$classification.classification) -ContinueOnError (ConvertTo-Bool $ContinueOnError)
$reasons = @($classification.reasons)
$executionPack = if ($classification.PSObject.Properties.Name -contains 'selectionExecutionPack') { [string]$classification.selectionExecutionPack } else { '' }
$payload = [ordered]@{
  schema = 'pester-operator-outcome@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  gateStatus = [string]$descriptor.gateStatus
  continueOnError = ConvertTo-Bool $ContinueOnError
  classification = [string]$classification.classification
  headline = [string]$descriptor.headline
  nextActionId = [string]$descriptor.nextActionId
  nextAction = [string]$descriptor.nextAction
  reasons = $reasons
  reasonCount = @($reasons).Count
  actionContext = @($descriptor.actionContext)
  summaryPresent = [bool]$summary
  selectionExecutionPack = $executionPack
  contextStatus = [string]$classification.contextStatus
  readinessStatus = [string]$classification.readinessStatus
  selectionStatus = [string]$classification.selectionStatus
  rawArtifactDownload = [string]$classification.rawArtifactDownload
  dispatcherExitCode = if ($classification.PSObject.Properties.Name -contains 'dispatcherExitCode') { [int]$classification.dispatcherExitCode } else { -1 }
  total = if ($summary -and $summary.PSObject.Properties.Name -contains 'total') { [int]$summary.total } else { 0 }
  failed = if ($summary -and $summary.PSObject.Properties.Name -contains 'failed') { [int]$summary.failed } else { 0 }
  errors = if ($summary -and $summary.PSObject.Properties.Name -contains 'errors') { [int]$summary.errors } else { 0 }
  classificationPath = $resolvedClassificationPath
  summaryPath = $resolvedSummaryPath
}

$payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8

if ($env:GITHUB_OUTPUT) {
  "gate_status=$($payload.gateStatus)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "classification=$($payload.classification)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "next_action_id=$($payload.nextActionId)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "next_action=$($payload.nextAction)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "path=$resolvedOutputPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester operator outcome' -ForegroundColor Cyan
Write-Host ("gateStatus    : {0}" -f $payload.gateStatus)
Write-Host ("classification: {0}" -f $payload.classification)
Write-Host ("nextActionId  : {0}" -f $payload.nextActionId)
Write-Host ("path          : {0}" -f $resolvedOutputPath)

exit 0
