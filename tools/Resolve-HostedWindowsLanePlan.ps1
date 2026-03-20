#Requires -Version 7.0
<#
.SYNOPSIS
  Resolves the portable hosted Windows execution plan for NI Windows lanes.

.DESCRIPTION
  Emits a deterministic planning artifact for GitHub-hosted Windows lanes that
  run the pinned NI Windows container image without depending on repository
  runner inventory or custom runner labels.
#>
[CmdletBinding()]
param(
  [string]$RunnerImage = 'windows-2022',
  [string]$ContainerImage = 'nationalinstruments/labview:2026q1-windows',
  [string]$ExpectedContext = 'default',
  [ValidateSet('windows')]
  [string]$ExpectedOs = 'windows',
  [string]$OutputJsonPath = 'tests/results/_agent/vi-history-dispatch/validate-vi-history-windows-hosted-plan.json',
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

$outputJsonResolved = Resolve-AbsolutePath -Path $OutputJsonPath
$outputParent = Split-Path -Parent $outputJsonResolved
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$summary = [ordered]@{
  schema = 'hosted-windows-lane-plan@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  status = 'portable-hosted'
  available = $true
  skipReason = ''
  failureClass = 'none'
  failureMessage = ''
  executionModel = 'github-hosted-windows'
  runnerImage = $RunnerImage
  containerImage = $ContainerImage
  expectedContext = $ExpectedContext
  expectedOs = $ExpectedOs
  hostEngineMutationAllowed = $false
  notes = @(
    'Portable hosted Windows lanes do not depend on repository-scoped runner registration.',
    'The pinned NI Windows image must run on the GitHub-hosted Windows runner with no Docker Desktop engine mutation.'
  )
}

($summary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $outputJsonResolved -Encoding utf8

Write-GitHubOutput -Key 'available' -Value 'true' -Path $GitHubOutputPath
Write-GitHubOutput -Key 'status' -Value ([string]$summary.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'skip_reason' -Value '' -Path $GitHubOutputPath
Write-GitHubOutput -Key 'failure_class' -Value 'none' -Path $GitHubOutputPath
Write-GitHubOutput -Key 'summary_path' -Value $outputJsonResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'execution_model' -Value ([string]$summary.executionModel) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'runner_image' -Value ([string]$summary.runnerImage) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'expected_context' -Value ([string]$summary.expectedContext) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'expected_os' -Value ([string]$summary.expectedOs) -Path $GitHubOutputPath

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $summaryLines = @(
    '### Hosted Windows Lane Plan',
    '',
    ('- status: `{0}`' -f [string]$summary.status),
    ('- available: `{0}`' -f ([string]([bool]$summary.available)).ToLowerInvariant()),
    ('- execution_model: `{0}`' -f [string]$summary.executionModel),
    ('- runner_image: `{0}`' -f [string]$summary.runnerImage),
    ('- expected_context: `{0}`' -f [string]$summary.expectedContext),
    ('- expected_os: `{0}`' -f [string]$summary.expectedOs),
    ('- container_image: `{0}`' -f [string]$summary.containerImage)
  )
  $summaryLines -join "`n" | Out-File -LiteralPath (Resolve-AbsolutePath -Path $StepSummaryPath) -Encoding utf8 -Append
}

Write-Output $outputJsonResolved
