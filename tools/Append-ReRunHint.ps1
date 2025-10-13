#Requires -Version 7.0
<#
.SYNOPSIS
  Append the "Re-run With Same Inputs" block to the current step summary.

.DESCRIPTION
  Reusable helper for local smoke tests and CI workflows. Values fall back to the
  environment variables populated by GitHub Actions. When running locally, supply
  parameters directly or set the corresponding environment variables along with
  GITHUB_STEP_SUMMARY.

.PARAMETER WorkflowName
  Workflow name (defaults to $env:WORKFLOW_NAME or the GitHub Actions value).

.PARAMETER RefName
  Git ref name (defaults to $env:REF_NAME).

.PARAMETER SampleId
  Optional sample id to include in the generated command.

.PARAMETER WorkflowRef
  Workflow ref string (defaults to $env:WORKFLOW_REF).

.PARAMETER Repository
  Repository slug owner/name (defaults to $env:REPOSITORY or $env:GITHUB_REPOSITORY).

.PARAMETER StepSummaryPath
  Optional explicit step summary path. Falls back to $env:GITHUB_STEP_SUMMARY.
#>
[CmdletBinding()]
param(
  [string]$WorkflowName = $env:WORKFLOW_NAME,
  [string]$RefName = $env:REF_NAME,
  [string]$SampleId = $env:SAMPLE_ID,
  [string]$WorkflowRef = $env:WORKFLOW_REF,
  [string]$Repository = $(if ($env:REPOSITORY) { $env:REPOSITORY } else { $env:GITHUB_REPOSITORY }),
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  return
}

if (-not (Test-Path -LiteralPath (Split-Path -Parent $StepSummaryPath))) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $StepSummaryPath) -Force | Out-Null
}

function Get-QuotedCommand([string]$workflow,[string]$ref,[string]$sample) {
  $parts = @("gh workflow run `"$workflow`"", "-r `"$ref`"")
  if ($sample) { $parts += "-f sample_id=$sample" }
  return ($parts -join ' ')
}

$workflowName = if ($WorkflowName) { $WorkflowName } else { '<unknown workflow>' }
$refName = if ($RefName) { $RefName } else { '<unknown ref>' }
$command = Get-QuotedCommand -workflow $workflowName -ref $refName -sample $SampleId

$workflowPath = ''
if ($WorkflowRef -and ($WorkflowRef -match '\.github/workflows/(?<path>[^@]+)@')) {
  $workflowPath = $Matches['path']
}

$repo = if ($Repository) { $Repository } else { '<unknown repository>' }
$lines = @('### Re-run With Same Inputs','',('- Command: `{0}`' -f $command))
if (-not $SampleId) {
  $lines += '- sample_id omitted; workflow will auto-generate if supported.'
}
if ($workflowPath) {
  $lines += ('- Workflow: https://github.com/{0}/actions/workflows/{1}' -f $repo, $workflowPath)
}

($lines -join [Environment]::NewLine) | Out-File -FilePath $StepSummaryPath -Append -Encoding utf8
