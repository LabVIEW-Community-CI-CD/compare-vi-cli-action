<#
.SYNOPSIS
  Append a concise “Top Failures” section to the job summary from Pester outputs.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [int]$Top = 5,
  [string]$OperatorOutcomePath = 'pester-operator-outcome.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_STEP_SUMMARY) { return }

$failurePayloadTool = Join-Path $PSScriptRoot 'PesterFailurePayload.ps1'
if (Test-Path -LiteralPath $failurePayloadTool -PathType Leaf) {
  . $failurePayloadTool
}

function Add-Lines([string[]]$lines) { $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 }
function Get-OperatorOutcome([string]$ResultsDir, [string]$OutcomePath) {
  if ([string]::IsNullOrWhiteSpace($OutcomePath)) { return $null }
  $resolvedPath = if ([System.IO.Path]::IsPathRooted($OutcomePath)) { $OutcomePath } else { Join-Path $ResultsDir $OutcomePath }
  if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return $null
  }
}
function Get-FailureSummaryMeta([string]$ResultsDir) {
  $summaryPath = Join-Path $ResultsDir 'pester-summary.json'
  if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { return $null }
  try {
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    return [pscustomobject]@{
      failed = [int]($summary.failed ?? 0)
      errors = [int]($summary.errors ?? 0)
      resultsXmlStatus = if ($summary.PSObject.Properties['resultsXmlStatus']) { [string]$summary.resultsXmlStatus } else { '' }
      failureDetailsStatus = if ($summary.PSObject.Properties['failureDetailsStatus']) { [string]$summary.failureDetailsStatus } else { '' }
      failureDetailsReason = if ($summary.PSObject.Properties['failureDetailsReason']) { [string]$summary.failureDetailsReason } else { '' }
    }
  } catch {
    return $null
  }
}

$operatorOutcome = Get-OperatorOutcome -ResultsDir $ResultsDir -OutcomePath $OperatorOutcomePath

$failJson = Join-Path $ResultsDir 'pester-failures.json'
$nunitXml  = Join-Path $ResultsDir 'pester-results.xml'

$items = @()
$failurePayloadInfo = $null
if (Test-Path -LiteralPath $failJson) {
  $failurePayloadInfo = Read-PesterFailurePayloadFile -PathValue $failJson
  if ($failurePayloadInfo.parseStatus -eq 'parsed') {
    foreach ($f in (Get-PesterFailureEntries -FailurePayload $failurePayloadInfo.payload)) {
      $file = ''
      $line = ''
      if ($f.PSObject.Properties.Name -contains 'file') { $file = [string]$f.file }
      if ($f.PSObject.Properties.Name -contains 'line') { $line = [string]$f.line }
      $msg  = ''
      if ($f.PSObject.Properties.Name -contains 'message') { $msg = [string]$f.message }
      $name = ''
      if ($f.PSObject.Properties.Name -contains 'name') { $name = [string]$f.name }
      $items += [pscustomobject]@{ name=$name; file=$file; line=$line; message=$msg }
    }
  }
}
elseif (Test-Path -LiteralPath $nunitXml) {
  try {
    [xml]$xml = Get-Content -LiteralPath $nunitXml -Raw
    $nodes = $xml.SelectNodes('//test-case[failure]')
    foreach ($n in $nodes) {
      $name = $n.name
      $msg  = $n.failure.message
      $stack = $n.failure.'stack-trace'
      $file = ''
      $line = ''
      if ($stack) {
        $m = [regex]::Match($stack,'(?m)([A-Z]:\\[^\r\n]+?):line\s+(\d+)')
        if ($m.Success) { $file = $m.Groups[1].Value; $line = $m.Groups[2].Value }
      }
      $items += [pscustomobject]@{ name=$name; file=$file; line=$line; message=$msg }
    }
  } catch {}
}

if (-not $items -or $items.Count -eq 0) {
  $summaryMeta = Get-FailureSummaryMeta -ResultsDir $ResultsDir
  $detailState = Get-PesterFailureDetailState -FailurePayload $(if ($failurePayloadInfo) { $failurePayloadInfo.payload } else { $null }) -Summary $summaryMeta
  if ($summaryMeta -and (($summaryMeta.failed + $summaryMeta.errors) -gt 0)) {
    $statusSuffix = if ($summaryMeta.resultsXmlStatus) { " (resultsXmlStatus=$($summaryMeta.resultsXmlStatus))" } else { '' }
    $reasonSuffix = if ($detailState.unavailableReason) { "; reason=$($detailState.unavailableReason)" } else { '' }
    $lines = @(
      '### Top Failures',
      ("- failure details unavailable; summary reports {0} failed/error cases{1}{2}" -f ($summaryMeta.failed + $summaryMeta.errors), $statusSuffix, $reasonSuffix)
    )
    if ($operatorOutcome -and [string]$operatorOutcome.classification -ne 'ok') {
      $lines += ("- gate outcome: {0} ({1})" -f [string]$operatorOutcome.classification, [string]$operatorOutcome.gateStatus)
      $lines += ("- next action: {0}" -f [string]$operatorOutcome.nextAction)
    }
    Add-Lines $lines
  } else {
    $lines = @('### Top Failures','- (none)')
    if ($operatorOutcome -and [string]$operatorOutcome.classification -ne 'ok') {
      $lines += ("- gate outcome: {0} ({1})" -f [string]$operatorOutcome.classification, [string]$operatorOutcome.gateStatus)
      $lines += ("- next action: {0}" -f [string]$operatorOutcome.nextAction)
    }
    Add-Lines $lines
  }
  return
}

$take = [Math]::Min($Top, $items.Count)
$lines = @('### Top Failures','')
for ($i=0; $i -lt $take; $i++) {
  $it = $items[$i]
  $loc = if ($it.file) { if ($it.line) { " ($($it.file):$($it.line))" } else { " ($($it.file))" } } else { '' }
  $msg = if ($it.message) { ($it.message -split "`n")[0] } else { '' }
  $title = if ($it.name) { $it.name } else { if ($msg) { $msg } else { 'Failure' } }
  $lines += ("- {0}{1}" -f $title,$loc)
  if ($msg) { $lines += ("  - {0}" -f $msg) }
}
if ($operatorOutcome -and [string]$operatorOutcome.classification -ne 'ok') {
  $lines += ''
  $lines += ("- gate outcome: {0} ({1})" -f [string]$operatorOutcome.classification, [string]$operatorOutcome.gateStatus)
  $lines += ("- next action: {0}" -f [string]$operatorOutcome.nextAction)
}
Add-Lines $lines
