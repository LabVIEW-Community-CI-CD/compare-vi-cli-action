param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ResultsDir,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$JsonSummaryPath = 'pester-summary.json',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$PostprocessReportPath = 'pester-execution-postprocess.json',

  [Parameter(Mandatory = $false)]
  [ValidateRange(0, 30)]
  [int]$XmlStabilizationTimeoutSeconds = 3,

  [Parameter(Mandatory = $false)]
  [ValidateRange(25, 5000)]
  [int]$XmlPollIntervalMilliseconds = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$defaultPesterSummarySchemaVersion = '1.7.1'

$schemaToolPath = Join-Path $PSScriptRoot 'PesterServiceModelSchema.ps1'
if (-not (Test-Path -LiteralPath $schemaToolPath -PathType Leaf)) {
  throw "Schema tool not found: $schemaToolPath"
}
. $schemaToolPath

function Set-ObjectProperty {
  param(
    [Parameter(Mandatory = $true)]$InputObject,
    [Parameter(Mandatory = $true)][string]$Name,
    $Value
  )

  $property = $InputObject.PSObject.Properties[$Name]
  if ($property) {
    $property.Value = $Value
  } else {
    Add-Member -InputObject $InputObject -Name $Name -MemberType NoteProperty -Value $Value
  }
}

function Test-RepairableLegacySummaryState {
  param(
    [Parameter(Mandatory = $true)]$State
  )

  if (-not $State.present -or $State.valid) {
    return $false
  }

  if ([string]$State.reason -ne 'pester-summary-schema-version-missing') {
    return $false
  }

  $document = $State.document
  if (-not $document) {
    return $false
  }

  return (
    ($document.PSObject.Properties.Name -contains 'total') -and
    ($document.PSObject.Properties.Name -contains 'failed') -and
    ($document.PSObject.Properties.Name -contains 'errors')
  )
}

$resolvedResultsDir = [System.IO.Path]::GetFullPath($ResultsDir)
if (-not (Test-Path -LiteralPath $resolvedResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resolvedResultsDir -Force | Out-Null
}

$summaryPath = Join-Path $resolvedResultsDir $JsonSummaryPath
$reportPath = Join-Path $resolvedResultsDir $PostprocessReportPath
$xmlPath = Join-Path $resolvedResultsDir 'pester-results.xml'
$xmlSummaryToolPath = Join-Path $PSScriptRoot 'Get-PesterResultXmlSummary.ps1'
if (-not (Test-Path -LiteralPath $xmlSummaryToolPath -PathType Leaf)) {
  throw "XML summary tool not found: $xmlSummaryToolPath"
}

$existingSummaryState = Test-PesterServiceModelSchemaContract `
  -DocumentState (Read-PesterServiceModelJsonDocument -PathValue $summaryPath -ContractName 'pester-summary') `
  -ExpectedSchemaVersionMajor 1 `
  -RequireSchemaVersion
$repairableLegacySummary = Test-RepairableLegacySummaryState -State $existingSummaryState
$existingSummary = if ($existingSummaryState.valid -or $repairableLegacySummary) { $existingSummaryState.document } else { $null }
$summaryPresentBefore = [bool]$existingSummaryState.present
$xmlSummary = & $xmlSummaryToolPath -XmlPath $xmlPath -StabilizationTimeoutSeconds $XmlStabilizationTimeoutSeconds -PollIntervalMilliseconds $XmlPollIntervalMilliseconds
if (-not $xmlSummary) {
  throw 'Get-PesterResultXmlSummary.ps1 returned no result.'
}

$postprocessStatus = if ($existingSummaryState.present -and -not $existingSummaryState.valid -and -not $repairableLegacySummary) {
  'unsupported-schema'
} else {
  switch ([string]$xmlSummary.status) {
    'complete' { 'complete'; break }
    'truncated-root' { 'results-xml-truncated'; break }
    'truncated' { 'results-xml-truncated'; break }
    'invalid-root-attributes' { 'invalid-results-xml'; break }
    'invalid' { 'invalid-results-xml'; break }
    'missing' { 'missing-results-xml'; break }
    default { 'seam-defect'; break }
  }
}

$summaryWritten = $false
$summaryPayload = if ($existingSummary) { $existingSummary } else { [pscustomobject]@{} }
$passed = $null
if ($null -ne $xmlSummary.total -and $null -ne $xmlSummary.failed -and $null -ne $xmlSummary.errors) {
  $passed = [Math]::Max(0, ([int]$xmlSummary.total - [int]$xmlSummary.failed - [int]$xmlSummary.errors))
}

$canWriteSummary = $postprocessStatus -in @('complete', 'results-xml-truncated', 'invalid-results-xml')
if ($canWriteSummary) {
  Set-ObjectProperty -InputObject $summaryPayload -Name 'total' -Value $xmlSummary.total
  Set-ObjectProperty -InputObject $summaryPayload -Name 'passed' -Value $passed
  Set-ObjectProperty -InputObject $summaryPayload -Name 'failed' -Value $xmlSummary.failed
  Set-ObjectProperty -InputObject $summaryPayload -Name 'errors' -Value $xmlSummary.errors
  Set-ObjectProperty -InputObject $summaryPayload -Name 'skipped' -Value $xmlSummary.skipped
  if (-not $summaryPayload.PSObject.Properties['timestamp']) {
    Set-ObjectProperty -InputObject $summaryPayload -Name 'timestamp' -Value ([DateTime]::UtcNow.ToString('o'))
  }
  if (-not $summaryPayload.PSObject.Properties['schemaVersion']) {
    Set-ObjectProperty -InputObject $summaryPayload -Name 'schemaVersion' -Value $defaultPesterSummarySchemaVersion
  }
  Set-ObjectProperty -InputObject $summaryPayload -Name 'resultsXmlStatus' -Value ([string]$xmlSummary.status)
  Set-ObjectProperty -InputObject $summaryPayload -Name 'resultsXmlSummarySource' -Value $xmlSummary.summarySource
  Set-ObjectProperty -InputObject $summaryPayload -Name 'resultsXmlCloseTagPresent' -Value ([bool]$xmlSummary.closeTagPresent)
  Set-ObjectProperty -InputObject $summaryPayload -Name 'resultsXmlSizeBytes' -Value ([int64]$xmlSummary.sizeBytes)
  if (-not [string]::IsNullOrWhiteSpace([string]$xmlSummary.parseError)) {
    Set-ObjectProperty -InputObject $summaryPayload -Name 'resultsXmlParseError' -Value ([string]$xmlSummary.parseError)
  }
  Set-ObjectProperty -InputObject $summaryPayload -Name 'executionPostprocessStatus' -Value $postprocessStatus
  Set-ObjectProperty -InputObject $summaryPayload -Name 'executionPostprocessSchema' -Value 'pester-execution-postprocess@v1'
  $summaryPayload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
  $summaryWritten = $true
}

$report = [ordered]@{
  schema                  = 'pester-execution-postprocess@v1'
  generatedAtUtc          = [DateTime]::UtcNow.ToString('o')
  resultsDir              = $resolvedResultsDir
  xmlPath                 = $xmlPath
  summaryPath             = $summaryPath
  summaryPresentBefore    = $summaryPresentBefore
  summarySchemaStatus     = if ($summaryPresentBefore -and $repairableLegacySummary) { 'legacy-schema-lite' } elseif ($summaryPresentBefore) { [string]$existingSummaryState.classification } else { 'missing' }
  summarySchemaReason     = if ($summaryPresentBefore) { [string]$existingSummaryState.reason } else { 'pester-summary-missing' }
  summarySchemaVersion    = if ($summaryPresentBefore) { [string]$existingSummaryState.actualSchemaVersion } else { $null }
  summaryWritten          = $summaryWritten
  status                  = $postprocessStatus
  resultsXmlStatus        = [string]$xmlSummary.status
  resultsXmlSummarySource = $xmlSummary.summarySource
  resultsXmlCloseTagPresent = [bool]$xmlSummary.closeTagPresent
  resultsXmlSizeBytes     = [int64]$xmlSummary.sizeBytes
  total                   = $xmlSummary.total
  passed                  = $passed
  failed                  = $xmlSummary.failed
  errors                  = $xmlSummary.errors
  skipped                 = $xmlSummary.skipped
  parseError              = [string]$xmlSummary.parseError
  schemaClassification    = if ($summaryPresentBefore -and -not $existingSummaryState.valid -and -not $repairableLegacySummary) { 'unsupported-schema' } elseif ($repairableLegacySummary) { 'legacy-schema-lite' } else { 'ok' }
  schemaClassificationReason = if ($summaryPresentBefore -and -not $existingSummaryState.valid) { [string]$existingSummaryState.reason } else { 'schema-ok' }
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if ($env:GITHUB_OUTPUT) {
  "status=$postprocessStatus" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "results_xml_status=$($xmlSummary.status)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "summary_written=$summaryWritten" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "report_path=$reportPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester execution postprocess' -ForegroundColor Cyan
Write-Host ("status       : {0}" -f $postprocessStatus)
Write-Host ("xmlStatus    : {0}" -f $xmlSummary.status)
Write-Host ("summaryWrite : {0}" -f $summaryWritten)
Write-Host ("report       : {0}" -f $reportPath)
if ($summaryWritten) {
  Write-Host ("summary      : {0}" -f $summaryPath)
}

exit 0
