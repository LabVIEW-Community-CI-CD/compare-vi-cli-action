[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Category,
  [Parameter()][ValidateSet('auto','include','exclude')][string]$IntegrationMode = 'include',
  [Parameter()][string]$IncludeIntegration,
  [Parameter()][ValidateNotNullOrEmpty()][string]$ResultsRoot = 'tests/results/categories'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PesterExecutionPacks.ps1')

function Resolve-LegacyIncludeIntegration {
  param(
    [object]$Value,
    [switch]$WarnOnUnrecognized
  )

  if ($null -eq $Value) { return $null }
  if ($Value -is [bool]) { return [bool]$Value }
  try {
    $text = $Value.ToString()
  } catch {
    return $null
  }
  $normalized = $text.Trim()
  if ($normalized.Length -eq 0) { return $null }
  $lower = $normalized.ToLowerInvariant()
  switch ($lower) {
    'true' { return $true }
    'false' { return $false }
    '1' { return $true }
    '0' { return $false }
    'yes' { return $true }
    'no' { return $false }
    'y' { return $true }
    'n' { return $false }
    'on' { return $true }
    'off' { return $false }
    'include' { return $true }
    'exclude' { return $false }
    'auto' { return $null }
    default {
      if ($WarnOnUnrecognized) {
        Write-Warning "Invoke-CompareCli: unrecognized IncludeIntegration value '$Value'. Defaulting to include via auto mode."
      }
      return $true
    }
  }
}

function Resolve-AutoIntegrationPreference {
  param([bool]$Default = $true)

  $envPriority = @(
    @{ Name='INCLUDE_INTEGRATION';        Label='env:INCLUDE_INTEGRATION' },
    @{ Name='INPUT_INCLUDE_INTEGRATION'; Label='env:INPUT_INCLUDE_INTEGRATION' },
    @{ Name='GITHUB_INPUT_INCLUDE_INTEGRATION'; Label='env:GITHUB_INPUT_INCLUDE_INTEGRATION' },
    @{ Name='EV_INCLUDE_INTEGRATION';    Label='env:EV_INCLUDE_INTEGRATION' },
    @{ Name='CI_INCLUDE_INTEGRATION';    Label='env:CI_INCLUDE_INTEGRATION' },
    @{ Name='GH_INCLUDE_INTEGRATION';    Label='env:GH_INCLUDE_INTEGRATION' },
    @{ Name='include_integration';       Label='env:include_integration' }
  )

  foreach ($entry in $envPriority) {
    try {
      $raw = [System.Environment]::GetEnvironmentVariable($entry.Name)
    } catch {
      continue
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $parsed = Resolve-LegacyIncludeIntegration -Value $raw
    if ($null -ne $parsed) {
      return [pscustomobject]@{
        Include = [bool]$parsed
        Source  = ("{0}={1}" -f $entry.Label,$raw)
      }
    }
  }

  return [pscustomobject]@{
    Include = [bool]$Default
    Source  = 'default:auto'
  }
}

$resultsDir = Join-Path $ResultsRoot $Category
if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}

$executionPack = Resolve-PesterExecutionPack -ExecutionPack $Category

Write-Host "[cli] category=$Category results=$resultsDir executionPack=$($executionPack.executionPack) include=$($executionPack.effectiveIncludePatterns -join ',')" -ForegroundColor Cyan

$legacyIncludeSpecified = $PSBoundParameters.ContainsKey('IncludeIntegration')
$modeSpecified = $PSBoundParameters.ContainsKey('IntegrationMode')
$integrationModeResolved = $IntegrationMode
$integrationReason = $null

if ($legacyIncludeSpecified) {
  $warn = -not $modeSpecified
  $legacyValue = Resolve-LegacyIncludeIntegration -Value $IncludeIntegration -WarnOnUnrecognized:$warn
  Write-Warning "Invoke-CompareCli: -IncludeIntegration is deprecated; use -IntegrationMode include|exclude|auto."
  if ($modeSpecified) {
    Write-Warning "Invoke-CompareCli: ignoring legacy IncludeIntegration because IntegrationMode was supplied."
  } else {
    if ($legacyValue -eq $true) { $integrationModeResolved = 'include' }
    elseif ($legacyValue -eq $false) { $integrationModeResolved = 'exclude' }
    else { $integrationModeResolved = 'auto' }
  }
}

switch ($integrationModeResolved) {
  'include' {
    $includeIntegrationBool = $true
    $integrationReason = 'mode:include'
  }
  'exclude' {
    $includeIntegrationBool = $false
    $integrationReason = 'mode:exclude'
  }
  default {
    $autoDecision = Resolve-AutoIntegrationPreference -Default:$true
    $includeIntegrationBool = [bool]$autoDecision.Include
    $integrationReason = "auto:$($autoDecision.Source)"
  }
}

Write-Host "[cli] integrationMode=$integrationModeResolved includeIntegration=$includeIntegrationBool source=$integrationReason" -ForegroundColor DarkCyan

& "$PSScriptRoot/Invoke-PesterTests.ps1" `
  -TestsPath 'tests' `
  -ExecutionPack $executionPack.executionPack `
  -IntegrationMode $integrationModeResolved `
  -ResultsPath $resultsDir `
  -EmitFailuresJsonAlways
$pesterExit = $LASTEXITCODE

$summaryPath = Join-Path $resultsDir 'pester-summary.json'
$cliRun = [ordered]@{
  schema              = 'compare-cli-run/v1'
  generatedAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
  category            = $Category
  executionPack       = $executionPack.executionPack
  includeIntegration  = [bool]$includeIntegrationBool
  integrationMode     = $integrationModeResolved
  integrationSource   = $integrationReason
  resultsDir          = $resultsDir
  summaryPath         = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { $summaryPath } else { $null }
  status              = 'unknown'
  exitCode            = $pesterExit
}
if ($cliRun.summaryPath) {
  try {
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $cliRun.status = if ($summary.failed -gt 0 -or $summary.errors -gt 0) { 'fail' } else { 'ok' }
    $cliRun.summary = [ordered]@{
      total      = $summary.total
      passed     = $summary.passed
      failed     = $summary.failed
      errors     = $summary.errors
      skipped    = $summary.skipped
      duration_s = $summary.duration_s
    }
  } catch {
    Write-Warning "[cli] failed to parse pester summary for $Category: $_"
  }
}

$cliRunPath = Join-Path $resultsDir 'cli-run.json'
$cliRun | ConvertTo-Json -Depth 4 | Out-File -FilePath $cliRunPath -Encoding utf8
Write-Host "[cli] wrote summary to $cliRunPath"

exit $pesterExit
