#Requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('default', 'agent-maintenance', 'workflow-policy', 'human-change')]
  [string]$Template = 'default',
  [int]$Issue,
  [string]$IssueTitle,
  [string]$IssueUrl,
  [string]$Base = 'develop',
  [string]$Branch,
  [switch]$StandingPriority,
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
  Split-Path -Parent $PSScriptRoot
}

function Resolve-TemplatePath {
  param([string]$TemplateName)

  $repoRoot = Get-RepoRoot
  switch ($TemplateName) {
    'default' { return Join-Path $repoRoot '.github/pull_request_template.md' }
    'agent-maintenance' { return Join-Path $repoRoot '.github/PULL_REQUEST_TEMPLATE/agent-maintenance.md' }
    'workflow-policy' { return Join-Path $repoRoot '.github/PULL_REQUEST_TEMPLATE/workflow-policy.md' }
    'human-change' { return Join-Path $repoRoot '.github/PULL_REQUEST_TEMPLATE/human-change.md' }
    default { throw "Unsupported PR template '$TemplateName'." }
  }
}

function Get-TemplateLabel {
  param([string]$TemplateName)

  switch ($TemplateName) {
    'default' { return 'default-agent-template' }
    'agent-maintenance' { return 'agent-maintenance' }
    'workflow-policy' { return 'workflow-policy' }
    'human-change' { return 'human-change' }
    default { throw "Unsupported PR template '$TemplateName'." }
  }
}

$templatePath = Resolve-TemplatePath -TemplateName $Template
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
  throw "PR template not found: $templatePath"
}

$templateBody = (Get-Content -LiteralPath $templatePath -Raw).Trim()
$issueReference = if ($Issue -gt 0) { "#$Issue" } else { 'Not linked yet' }
$standingText = if ($StandingPriority.IsPresent -and $Issue -gt 0) {
  "Yes ($issueReference)"
} elseif ($StandingPriority.IsPresent) {
  'Yes'
} else {
  'No'
}
$baseText = if ([string]::IsNullOrWhiteSpace($Base)) { '(not supplied)' } else { "``$Base``" }
$branchText = if ([string]::IsNullOrWhiteSpace($Branch)) { '(not supplied)' } else { "``$Branch``" }
$issueUrlText = if ([string]::IsNullOrWhiteSpace($IssueUrl)) { '(not supplied)' } else { $IssueUrl }
$issueTitleText = if ([string]::IsNullOrWhiteSpace($IssueTitle)) { '(not supplied)' } else { $IssueTitle }
$templateLabel = Get-TemplateLabel -TemplateName $Template

$preamble = @(
  '## Issue Linkage',
  '',
  "- Primary issue: $issueReference",
  "- Issue title: $issueTitleText",
  "- Issue URL: $issueUrlText",
  "- Standing priority at PR creation: $standingText",
  "- Base branch: $baseText",
  "- Head branch: $branchText",
  "- Template variant: ``$templateLabel``",
  '- Auto-close intent: add `Closes #...` manually only when merge should resolve the linked issue.',
  ''
)

$rendered = (($preamble -join [Environment]::NewLine) + [Environment]::NewLine + $templateBody).Trim() +
  [Environment]::NewLine

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Write-Output $rendered
  return
}

$outputParent = Split-Path -Parent $OutputPath
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $rendered -NoNewline
