#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$Scenario,
  [string]$Title,
  [int]$Issue,
  [string]$IssueTitle,
  [string]$IssueUrl,
  [string]$Base = 'develop',
  [string]$Branch,
  [switch]$StandingPriority,
  [string]$RelatedIssues,
  [string]$RepositoryContext = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$DraftOutputPath,
  [string]$PlanOutputPath,
  [switch]$Apply,
  [switch]$AsJson
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

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -NoNewline -Encoding utf8
}

$currentBranch = $null
if ([string]::IsNullOrWhiteSpace($Branch)) {
  $currentBranch = Get-CurrentGitBranch
}

$plan = New-GitHubIntakeExecutionPlan `
  -Scenario $Scenario `
  -Title $Title `
  -Issue $Issue `
  -IssueTitle $IssueTitle `
  -IssueUrl $IssueUrl `
  -Base $Base `
  -Branch $Branch `
  -StandingPriority:$StandingPriority.IsPresent `
  -RelatedIssues $RelatedIssues `
  -RepositoryContext $RepositoryContext `
  -DraftOutputPath $DraftOutputPath `
  -CurrentBranch $currentBranch

if (-not [string]::IsNullOrWhiteSpace($PlanOutputPath)) {
  Write-JsonFile -Path $PlanOutputPath -Value $plan
}

if (-not $Apply.IsPresent) {
  if ($AsJson.IsPresent) {
    $plan | ConvertTo-Json -Depth 10
    return
  }

  $plan
  return
}

$result = Invoke-GitHubIntakeExecutionPlan -Plan $plan
$payload = [pscustomobject]@{
  plan   = $plan
  result = $result
}

if ($AsJson.IsPresent) {
  $payload | ConvertTo-Json -Depth 10
  return
}

$payload
