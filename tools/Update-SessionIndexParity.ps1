#Requires -Version 7.0
<#
.SYNOPSIS
  Injects origin/upstream parity telemetry into session-index.json.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$SessionIndexPath = '',
  [string]$ParityReportPath = '',
  [string]$StepSummaryPath = '',
  [switch]$IgnoreMissingSessionIndex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function New-UnavailableParityPayload {
  param(
    [Parameter(Mandatory)][string]$Reason,
    [string]$ReportPath = ''
  )
  return [ordered]@{
    schema      = 'origin-upstream-parity@v1'
    status      = 'unavailable'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    reason      = [string]$Reason
    reportPath  = [string]$ReportPath
    baseRef     = $null
    headRef     = $null
    tipDiff     = [ordered]@{
      fileCount = $null
    }
    treeParity = [ordered]@{
      equal = $null
      status = 'unknown'
    }
    historyParity = [ordered]@{
      equal = $null
      status = 'unknown'
    }
    recommendation = [ordered]@{
      code = ''
      summary = ''
    }
    commitDivergence = [ordered]@{
      baseOnly = $null
      headOnly = $null
    }
  }
}

function Get-ChildValue {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }
  if ($Object.PSObject -and $Object.PSObject.Properties[$Name]) {
    return $Object.$Name
  }
  return $null
}

function Convert-ToParityTelemetry {
  param(
    [Parameter(Mandatory)][psobject]$ParityReport,
    [string]$ReportPath = ''
  )

  $status = [string]$ParityReport.status
  if ([string]::IsNullOrWhiteSpace($status)) {
    $status = 'unavailable'
  }

  $tipDiffCount = $null
  $tipDiff = Get-ChildValue -Object $ParityReport -Name 'tipDiff'
  if ($null -ne $tipDiff) { $tipDiffCount = Get-ChildValue -Object $tipDiff -Name 'fileCount' }

  $treeParity = Get-ChildValue -Object $ParityReport -Name 'treeParity'
  $treeParityEqual = $null
  $treeParityStatus = 'unknown'
  if ($null -ne $treeParity) {
    $treeParityEqual = Get-ChildValue -Object $treeParity -Name 'equal'
    $candidate = Get-ChildValue -Object $treeParity -Name 'status'
    if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate)) {
      $treeParityStatus = [string]$candidate
    }
  }

  $historyParity = Get-ChildValue -Object $ParityReport -Name 'historyParity'
  $historyParityEqual = $null
  $historyParityStatus = 'unknown'
  if ($null -ne $historyParity) {
    $historyParityEqual = Get-ChildValue -Object $historyParity -Name 'equal'
    $candidate = Get-ChildValue -Object $historyParity -Name 'status'
    if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace([string]$candidate)) {
      $historyParityStatus = [string]$candidate
    }
  }

  $recommendationNode = Get-ChildValue -Object $ParityReport -Name 'recommendation'
  $recommendationCode = ''
  $recommendationSummary = ''
  if ($null -ne $recommendationNode) {
    $candidate = Get-ChildValue -Object $recommendationNode -Name 'code'
    if ($null -ne $candidate) { $recommendationCode = [string]$candidate }
    $candidate = Get-ChildValue -Object $recommendationNode -Name 'summary'
    if ($null -ne $candidate) { $recommendationSummary = [string]$candidate }
  }

  $baseOnly = $null
  $headOnly = $null
  $commitDivergence = Get-ChildValue -Object $ParityReport -Name 'commitDivergence'
  if ($null -ne $commitDivergence) {
    $baseOnly = Get-ChildValue -Object $commitDivergence -Name 'baseOnly'
    $headOnly = Get-ChildValue -Object $commitDivergence -Name 'headOnly'
  }

  return [ordered]@{
    schema      = if ($null -ne (Get-ChildValue -Object $ParityReport -Name 'schema')) { [string](Get-ChildValue -Object $ParityReport -Name 'schema') } else { 'origin-upstream-parity@v1' }
    status      = $status
    generatedAt = if ($null -ne (Get-ChildValue -Object $ParityReport -Name 'generatedAt')) { [string](Get-ChildValue -Object $ParityReport -Name 'generatedAt') } elseif ($null -ne (Get-ChildValue -Object $ParityReport -Name 'generatedAtUtc')) { [string](Get-ChildValue -Object $ParityReport -Name 'generatedAtUtc') } else { (Get-Date).ToUniversalTime().ToString('o') }
    reason      = if ($null -ne (Get-ChildValue -Object $ParityReport -Name 'reason')) { [string](Get-ChildValue -Object $ParityReport -Name 'reason') } else { '' }
    reportPath  = [string]$ReportPath
    baseRef     = if ($null -ne (Get-ChildValue -Object $ParityReport -Name 'baseRef')) { [string](Get-ChildValue -Object $ParityReport -Name 'baseRef') } else { $null }
    headRef     = if ($null -ne (Get-ChildValue -Object $ParityReport -Name 'headRef')) { [string](Get-ChildValue -Object $ParityReport -Name 'headRef') } else { $null }
    tipDiff     = [ordered]@{
      fileCount = $tipDiffCount
    }
    treeParity = [ordered]@{
      equal = $treeParityEqual
      status = $treeParityStatus
    }
    historyParity = [ordered]@{
      equal = $historyParityEqual
      status = $historyParityStatus
    }
    recommendation = [ordered]@{
      code = $recommendationCode
      summary = $recommendationSummary
    }
    commitDivergence = [ordered]@{
      baseOnly = $baseOnly
      headOnly = $headOnly
    }
  }
}

function Write-ParityStepSummary {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][psobject]$Parity
  )
  $tipDiffCount = Get-ChildValue -Object (Get-ChildValue -Object $Parity -Name 'tipDiff') -Name 'fileCount'
  $baseOnly = Get-ChildValue -Object (Get-ChildValue -Object $Parity -Name 'commitDivergence') -Name 'baseOnly'
  $headOnly = Get-ChildValue -Object (Get-ChildValue -Object $Parity -Name 'commitDivergence') -Name 'headOnly'
  $treeParityStatus = Get-ChildValue -Object (Get-ChildValue -Object $Parity -Name 'treeParity') -Name 'status'
  $historyParityStatus = Get-ChildValue -Object (Get-ChildValue -Object $Parity -Name 'historyParity') -Name 'status'
  $recommendationCode = Get-ChildValue -Object (Get-ChildValue -Object $Parity -Name 'recommendation') -Name 'code'

  $statusValue = if ($Parity.status) { [string]$Parity.status } else { 'unavailable' }
  $reasonValue = if ($Parity.reason) { [string]$Parity.reason } else { '' }
  $tipDiffValue = if ($null -ne $tipDiffCount -and "$tipDiffCount".Trim() -ne '') { [string]$tipDiffCount } else { 'n/a' }
  $divergenceValue = if (($null -ne $baseOnly -and "$baseOnly".Trim() -ne '') -and ($null -ne $headOnly -and "$headOnly".Trim() -ne '')) { ('{0}/{1}' -f $baseOnly, $headOnly) } else { 'n/a' }
  $treeParityValue = if ($null -ne $treeParityStatus -and -not [string]::IsNullOrWhiteSpace([string]$treeParityStatus)) { [string]$treeParityStatus } else { 'n/a' }
  $historyParityValue = if ($null -ne $historyParityStatus -and -not [string]::IsNullOrWhiteSpace([string]$historyParityStatus)) { [string]$historyParityStatus } else { 'n/a' }
  $recommendationValue = if ($null -ne $recommendationCode -and -not [string]::IsNullOrWhiteSpace([string]$recommendationCode)) { [string]$recommendationCode } else { 'n/a' }

  $lines = @(
    '### Origin/Upstream Parity Telemetry',
    '',
    '| Metric | Value |',
    '| --- | --- |',
    ('| Status | {0} |' -f $statusValue),
    ('| Tree Parity | {0} |' -f $treeParityValue),
    ('| History Parity | {0} |' -f $historyParityValue),
    ('| Tip Diff File Count | {0} |' -f $tipDiffValue),
    ('| Commit Divergence (base-only/head-only) | {0} |' -f $divergenceValue),
    ('| Recommendation | {0} |' -f $recommendationValue)
  )
  if (-not [string]::IsNullOrWhiteSpace($reasonValue)) {
    $lines += ('| Reason | {0} |' -f $reasonValue.Replace('|', '\|'))
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Parity.reportPath)) {
    $lines += ('| Report Path | `{0}` |' -f [string]$Parity.reportPath)
  }
  $lines += ''
  ($lines -join "`n") | Out-File -FilePath $Path -Append -Encoding utf8
}

$resultsResolved = Resolve-AbsolutePath -Path $ResultsDir
$sessionPathResolved = if ([string]::IsNullOrWhiteSpace($SessionIndexPath)) {
  Join-Path $resultsResolved 'session-index.json'
} else {
  Resolve-AbsolutePath -Path $SessionIndexPath
}
$parityPathResolved = if ([string]::IsNullOrWhiteSpace($ParityReportPath)) {
  Join-Path $resultsResolved 'origin-upstream-parity.json'
} else {
  Resolve-AbsolutePath -Path $ParityReportPath
}
$summaryPathResolved = if ([string]::IsNullOrWhiteSpace($StepSummaryPath)) { '' } else { Resolve-AbsolutePath -Path $StepSummaryPath }

if (-not (Test-Path -LiteralPath $sessionPathResolved -PathType Leaf)) {
  if ($IgnoreMissingSessionIndex) {
    Write-Host ("::warning::session-index.json not found at {0}; parity metadata was not attached." -f $sessionPathResolved)
    return
  }
  throw ("session-index.json not found: {0}" -f $sessionPathResolved)
}

$index = Get-Content -LiteralPath $sessionPathResolved -Raw | ConvertFrom-Json -Depth 30
if (-not $index.PSObject.Properties['runContext'] -or $null -eq $index.runContext) {
  $index | Add-Member -MemberType NoteProperty -Name 'runContext' -Value ([ordered]@{}) -Force
}

$parityTelemetry = $null
if (Test-Path -LiteralPath $parityPathResolved -PathType Leaf) {
  try {
    $parityJson = Get-Content -LiteralPath $parityPathResolved -Raw | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    $parityTelemetry = Convert-ToParityTelemetry -ParityReport $parityJson -ReportPath $parityPathResolved
  } catch {
    $parityTelemetry = New-UnavailableParityPayload -Reason ("invalid-report-json: {0}" -f $_.Exception.Message) -ReportPath $parityPathResolved
  }
} else {
  $parityTelemetry = New-UnavailableParityPayload -Reason 'report-missing' -ReportPath $parityPathResolved
}

if ($index.runContext -is [System.Collections.IDictionary]) {
  $index.runContext['parity'] = $parityTelemetry
} elseif ($index.runContext.PSObject -and $index.runContext.PSObject.Properties['parity']) {
  $index.runContext.parity = $parityTelemetry
} else {
  $index.runContext | Add-Member -MemberType NoteProperty -Name 'parity' -Value $parityTelemetry -Force
}
($index | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $sessionPathResolved -Encoding utf8
& (Join-Path $PSScriptRoot 'Ensure-SessionIndex.ps1') -ResultsDir $resultsResolved -RefreshSessionIndexV2 | Out-Null

if (-not [string]::IsNullOrWhiteSpace($summaryPathResolved)) {
  Write-ParityStepSummary -Path $summaryPathResolved -Parity $parityTelemetry
}

Write-Output $sessionPathResolved
