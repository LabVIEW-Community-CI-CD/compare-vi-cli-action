#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$Scenario,
  [int]$Issue,
  [string]$IssueTitle,
  [string]$IssueUrl,
  [string]$Base = 'develop',
  [string]$Branch,
  [switch]$StandingPriority,
  [string]$RelatedIssues,
  [string]$RepositoryContext = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GitHubIntake.psm1') -Force

function Get-CurrentGitBranch {
  try {
    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
      $trimmed = $branch.Trim()
      if ($trimmed -and $trimmed -ne 'HEAD') {
        return $trimmed
      }
    }
  } catch {
  }

  return $null
}

$currentBranch = $null
if ([string]::IsNullOrWhiteSpace($Branch)) {
  $currentBranch = Get-CurrentGitBranch
}

$context = Resolve-GitHubIntakeDraftContext `
  -Scenario $Scenario `
  -Issue $Issue `
  -IssueTitle $IssueTitle `
  -IssueUrl $IssueUrl `
  -Branch $Branch `
  -StandingPriority:$StandingPriority.IsPresent `
  -CurrentBranch $currentBranch

switch ([string]$context.routeType) {
  'issue-template' {
    $scriptPath = Join-Path $PSScriptRoot 'New-IssueBody.ps1'
    $params = @{
      Template          = [string]$context.templateKey
      RepositoryContext = $RepositoryContext
    }
    if ($StandingPriority.IsPresent) { $params['StandingPriority'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($RelatedIssues)) { $params['RelatedIssues'] = $RelatedIssues }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { $params['OutputPath'] = $OutputPath }

    & $scriptPath @params
    return
  }
  'pull-request-template' {
    $scriptPath = Join-Path $PSScriptRoot 'New-PullRequestBody.ps1'
    $params = @{
      Template = [string]$context.templateKey
      Issue    = $context.issue
      Base     = $Base
    }
    if (-not [string]::IsNullOrWhiteSpace($context.issueTitle)) { $params['IssueTitle'] = $context.issueTitle }
    if (-not [string]::IsNullOrWhiteSpace($context.issueUrl)) { $params['IssueUrl'] = $context.issueUrl }
    if (-not [string]::IsNullOrWhiteSpace($context.branch)) { $params['Branch'] = $context.branch }
    if ($context.standingPriority) { $params['StandingPriority'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { $params['OutputPath'] = $OutputPath }

    & $scriptPath @params
    return
  }
  default {
    throw "Scenario '$Scenario' resolves to unsupported draft route type '$($context.routeType)'."
  }
}
