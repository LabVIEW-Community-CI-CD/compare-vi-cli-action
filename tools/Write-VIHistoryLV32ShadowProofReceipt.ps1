#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$LaneName,
  [string[]]$RunnerLabelContractPaths = @(),
  [string]$HostPlaneReportPath = '',
  [string]$CompareSummaryPath = '',
  [string]$CompareReportPath = '',
  [string]$OutputJsonPath = 'tests/results/_agent/promotion/vi-history-lv32-shadow-proof-receipt.json',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
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

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [AllowNull()][AllowEmptyString()][string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  $dest = Resolve-AbsolutePath -Path $Path
  $parent = Split-Path -Parent $dest
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  Add-Content -LiteralPath $dest -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

function Get-JsonPayload {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = Resolve-AbsolutePath -Path $Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }

  try {
    return [pscustomobject]@{
      path = $resolved
      payload = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 30
    }
  } catch {
    return [pscustomobject]@{
      path = $resolved
      payload = $null
      error = $_.Exception.Message
    }
  }
}

function Get-PropertyValue {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory)][string]$Name
  )

  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
    return $null
  }
  $property = $InputObject.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function ConvertTo-NormalizedText {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return '' }
  return ([string]$Value).Trim()
}

function Add-StepSummaryContent {
  param([string[]]$Lines)
  if ([string]::IsNullOrWhiteSpace($StepSummaryPath)) { return }
  $resolved = Resolve-AbsolutePath -Path $StepSummaryPath
  $parent = Split-Path -Parent $resolved
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $Lines -join "`n" | Out-File -LiteralPath $resolved -Encoding utf8 -Append
}

$labelContracts = New-Object System.Collections.Generic.List[object]
foreach ($pathValue in @($RunnerLabelContractPaths)) {
  if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
  $artifact = Get-JsonPayload -Path $pathValue
  if ($null -eq $artifact) { continue }
  $payload = $artifact.payload
  $labelContracts.Add([pscustomobject]@{
    path = $artifact.path
    schema = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $payload -Name 'schema')
    status = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $payload -Name 'status')
    runnerName = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $payload -Name 'runnerName')
    runnerId = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $payload -Name 'runnerId')
    requiredLabel = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $payload -Name 'requiredLabel')
    labels = @($payload.labels | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    hasRequiredLabel = if ($payload.PSObject.Properties['hasRequiredLabel']) { [bool]$payload.hasRequiredLabel } else { $false }
    failureClass = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $payload -Name 'failureClass')
    failureMessage = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $payload -Name 'failureMessage')
  }) | Out-Null
}

$hostPlaneArtifact = Get-JsonPayload -Path $HostPlaneReportPath
$hostPlane = if ($null -ne $hostPlaneArtifact) { $hostPlaneArtifact.payload } else { $null }
$hostPlaneSchema = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $hostPlane -Name 'schema')
$x32Plane = Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $hostPlane -Name 'native') -Name 'planes'
$x32Plane = Get-PropertyValue -InputObject $x32Plane -Name 'x32'
$x32Status = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $x32Plane -Name 'status')
$x32LabVIEWPath = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $x32Plane -Name 'labviewPath')
$x32CliPath = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $x32Plane -Name 'cliPath')
$x32ComparePath = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $x32Plane -Name 'comparePath')
$compareMode = ConvertTo-NormalizedText $env:LVCI_COMPARE_MODE
$comparePolicy = ConvertTo-NormalizedText $env:LVCI_COMPARE_POLICY
$headlessExecutionMode = if (
  [string]::Equals($compareMode, 'labview-cli', [System.StringComparison]::OrdinalIgnoreCase) -and
  [string]::Equals($comparePolicy, 'cli-only', [System.StringComparison]::OrdinalIgnoreCase)
) {
  'labview-cli-headless'
} elseif (-not [string]::IsNullOrWhiteSpace($compareMode) -or -not [string]::IsNullOrWhiteSpace($comparePolicy)) {
  '{0}:{1}' -f ($(if ([string]::IsNullOrWhiteSpace($compareMode)) { 'default' } else { $compareMode })), ($(if ([string]::IsNullOrWhiteSpace($comparePolicy)) { 'default' } else { $comparePolicy }))
} else {
  'unspecified'
}
$headlessRequired = $true
$hostPlaneReady = (
  $hostPlaneSchema -eq 'labview-2026-host-plane-report@v1' -and
  $x32Status -eq 'ready' -and
  -not [string]::IsNullOrWhiteSpace($x32LabVIEWPath) -and
  -not [string]::IsNullOrWhiteSpace($x32CliPath)
)

$compareSummaryArtifact = Get-JsonPayload -Path $CompareSummaryPath
$compareSummary = if ($null -ne $compareSummaryArtifact) { $compareSummaryArtifact.payload } else { $null }
$compareSummaryStatus = ConvertTo-NormalizedText (Get-PropertyValue -InputObject $compareSummary -Name 'status')
if ([string]::IsNullOrWhiteSpace($compareSummaryStatus) -and $compareSummary) {
  $compareSummaryStatus = ConvertTo-NormalizedText (Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $compareSummary -Name 'summary') -Name 'status')
}

$requiredLabels = @(
  'self-hosted',
  'Windows',
  'X64',
  'comparevi',
  'capability-ingress',
  'labview-2026',
  'lv32'
)
$labelsMatched = (
  $labelContracts.Count -gt 0 -and
  (@($labelContracts | Where-Object { $_.status -eq 'success' }).Count -eq $labelContracts.Count)
)
$actualLabels = @(
  $labelContracts |
    ForEach-Object { @($_.labels) } |
    ForEach-Object { $_ }
) | Sort-Object -Unique
$hostPlaneStatus = if ($hostPlaneReady) {
  'ready'
} elseif (-not [string]::IsNullOrWhiteSpace($x32Status)) {
  $x32Status
} else {
  'unavailable'
}
$headlessEnforced = $hostPlaneReady -and $headlessExecutionMode -eq 'labview-cli-headless'
$verificationStatus = if ($labelsMatched -and $headlessEnforced -and ($compareSummaryStatus -in @('ok', 'pass', 'passed'))) {
  'pass'
} elseif (-not $labelsMatched -or -not $headlessEnforced) {
  'blocked'
} else {
  'fail'
}
$verificationRunUrl = ConvertTo-NormalizedText $env:GITHUB_RUN_URL

$receipt = [ordered]@{
  schema = 'priority/vi-history-lv32-shadow-proof-receipt@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  repository = ConvertTo-NormalizedText $env:GITHUB_REPOSITORY
  sourceCommitSha = ConvertTo-NormalizedText $env:GITHUB_SHA
  lane = [ordered]@{
    id = $LaneName
  }
  runner = [ordered]@{
    name = if ($labelContracts.Count -gt 0) { $labelContracts[0].runnerName } else { ConvertTo-NormalizedText $env:RUNNER_NAME }
    requiredLabels = @($requiredLabels)
    actualLabels = @($actualLabels)
    labelsMatched = [bool]$labelsMatched
  }
  headless = [ordered]@{
    required = [bool]$headlessRequired
    enforced = [bool]$headlessEnforced
    executionMode = $headlessExecutionMode
  }
  hostPlane = [ordered]@{
    status = $hostPlaneStatus
    native32Status = if ([string]::IsNullOrWhiteSpace($x32Status)) { 'unavailable' } else { $x32Status }
    reportPath = if ($hostPlaneArtifact) { $hostPlaneArtifact.path } else { Resolve-AbsolutePath -Path ($HostPlaneReportPath ?? '') }
    labviewPath = $x32LabVIEWPath
    cliPath = $x32CliPath
    comparePath = $x32ComparePath
  }
  verification = [ordered]@{
    status = $verificationStatus
    runUrl = if ([string]::IsNullOrWhiteSpace($verificationRunUrl)) { $null } else { $verificationRunUrl }
    summaryPath = if ($compareSummaryArtifact) { $compareSummaryArtifact.path } else { Resolve-AbsolutePath -Path ($CompareSummaryPath ?? '') }
    reportPath = if ([string]::IsNullOrWhiteSpace($CompareReportPath)) { '' } else { Resolve-AbsolutePath -Path $CompareReportPath }
  }
}

$outputResolved = Resolve-AbsolutePath -Path $OutputJsonPath
$outputParent = Split-Path -Parent $outputResolved
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}
($receipt | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $outputResolved -Encoding utf8

Write-GitHubOutput -Key 'vi_history_lv32_shadow_proof_receipt_path' -Value $outputResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_lv32_shadow_proof_status' -Value ([string]$receipt.verification.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_lv32_shadow_proof_promotion_ready' -Value ([string]([bool]($receipt.verification.status -eq 'pass'))).ToLowerInvariant() -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_lv32_shadow_proof_host_plane_status' -Value ([string]$receipt.hostPlane.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_lv32_shadow_proof_labels_status' -Value ($(if ($receipt.runner.labelsMatched) { 'pass' } else { 'fail' })) -Path $GitHubOutputPath

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $summaryLines = @(
    '### VI History LV32 Shadow Proof Receipt',
    '',
    ('- lane: `{0}`' -f $LaneName),
    ('- verification_status: `{0}`' -f [string]$receipt.verification.status),
    ('- promotion_ready: `{0}`' -f ([string]([bool]($receipt.verification.status -eq 'pass'))).ToLowerInvariant()),
    ('- labels_matched: `{0}`' -f [string]$receipt.runner.labelsMatched),
    ('- host_plane_status: `{0}`' -f [string]$receipt.hostPlane.status),
    ('- host_plane_native32_status: `{0}`' -f [string]$receipt.hostPlane.native32Status),
    ('- headless_execution_mode: `{0}`' -f [string]$receipt.headless.executionMode),
    ('- host_plane_report_path: `{0}`' -f [string]$receipt.hostPlane.reportPath),
    ('- host_plane_labview_path: `{0}`' -f [string]$receipt.hostPlane.labviewPath),
    ('- host_plane_cli_path: `{0}`' -f [string]$receipt.hostPlane.cliPath),
    ('- verification_report_path: `{0}`' -f [string]$receipt.verification.reportPath),
    ('- receipt_json: `{0}`' -f $outputResolved)
  )
  Add-StepSummaryContent -Lines $summaryLines
}

Write-Output $outputResolved
