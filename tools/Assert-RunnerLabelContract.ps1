#Requires -Version 7.0
<#
.SYNOPSIS
  Validates that the current Actions job runner includes a required label.

.DESCRIPTION
  Resolves runner metadata from the GitHub Actions run-jobs API and fails with
  deterministic remediation text when the required label is missing.

  This script supports test/offline execution through -JobsPayloadPath.
#>
[CmdletBinding()]
param(
  [string]$Repository = $env:GITHUB_REPOSITORY,
  [string]$RunId = $env:GITHUB_RUN_ID,
  [string]$RunnerName = $env:RUNNER_NAME,
  [string]$RequiredLabel = 'hosted-docker-windows',
  [string]$Token = $env:GITHUB_TOKEN,
  [string]$OutputJsonPath = 'results/fixture-drift/runner-label-contract.json',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY,
  [string]$JobsPayloadPath = ''
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

function New-ApiException {
  param(
    [Parameter(Mandatory)][string]$Message,
    [AllowNull()][int]$StatusCode
  )

  $exception = [System.Exception]::new($Message)
  if ($null -ne $StatusCode -and $StatusCode -gt 0) {
    $exception.Data['HttpStatusCode'] = [int]$StatusCode
  }
  return $exception
}

function Get-StatusCodeFromError {
  param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

  $statusCode = 0
  try {
    $ex = $ErrorRecord.Exception
    if ($ex -and $ex.Data -and $ex.Data.Contains('HttpStatusCode')) {
      return [int]$ex.Data['HttpStatusCode']
    }
    if ($ex -and $ex.PSObject.Properties['Response'] -and $ex.Response) {
      if ($ex.Response.PSObject.Properties['StatusCode'] -and $ex.Response.StatusCode) {
        return [int]$ex.Response.StatusCode
      }
    }
  } catch {}

  $message = [string]$ErrorRecord.Exception.Message
  if ($message -match '"status"\s*:\s*"?(\d{3})"?' -or $message -match 'HTTP\s*(\d{3})') {
    [void][int]::TryParse($Matches[1], [ref]$statusCode)
  }
  return $statusCode
}

function Convert-JobLabelsToArray {
  param([AllowNull()]$Labels)

  $values = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @($Labels)) {
    if ($entry -is [string]) {
      $candidate = [string]$entry
    } elseif ($entry -and $entry.PSObject.Properties['name']) {
      $candidate = [string]$entry.name
    } else {
      $candidate = ''
    }
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      $values.Add($candidate) | Out-Null
    }
  }
  return @($values.ToArray() | Sort-Object -Unique)
}

function Get-RunJobs {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$RunId,
    [string]$Token,
    [string]$JobsPayloadPath
  )

  if (-not [string]::IsNullOrWhiteSpace($JobsPayloadPath)) {
    $payloadResolved = Resolve-AbsolutePath -Path $JobsPayloadPath
    if (-not (Test-Path -LiteralPath $payloadResolved -PathType Leaf)) {
      throw (New-ApiException -Message ("Jobs payload file not found: {0}" -f $payloadResolved) -StatusCode 0)
    }
    $payload = Get-Content -LiteralPath $payloadResolved -Raw | ConvertFrom-Json -Depth 30
    if ($payload -is [System.Array]) {
      return @($payload)
    }
    if ($payload.PSObject.Properties['jobs'] -and $payload.jobs) {
      return @($payload.jobs)
    }
    if ($payload.PSObject.Properties['status'] -and $payload.PSObject.Properties['message']) {
      $status = 0
      [void][int]::TryParse([string]$payload.status, [ref]$status)
      throw (New-ApiException -Message ([string]$payload.message) -StatusCode $status)
    }
    throw (New-ApiException -Message ("Unsupported jobs payload format: {0}" -f $payloadResolved) -StatusCode 0)
  }

  if ([string]::IsNullOrWhiteSpace($Token)) {
    throw (New-ApiException -Message 'GITHUB_TOKEN is required to validate runner labels. Set permissions.actions=read.' -StatusCode 401)
  }

  $headers = @{
    Authorization = "Bearer $Token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  $jobs = New-Object System.Collections.Generic.List[object]
  $page = 1
  $perPage = 100
  do {
    $uri = "https://api.github.com/repos/$Repository/actions/runs/$RunId/jobs?per_page=$perPage&page=$page"
    try {
      $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
    } catch {
      $status = Get-StatusCodeFromError -ErrorRecord $_
      $message = [string]$_.Exception.Message
      throw (New-ApiException -Message $message -StatusCode $status)
    }

    $candidates = @($response.jobs)
    foreach ($job in $candidates) {
      $jobs.Add($job) | Out-Null
    }
    $page++
  } while ($candidates.Count -eq $perPage)

  return @($jobs.ToArray())
}

$outputJsonResolved = Resolve-AbsolutePath -Path $OutputJsonPath
$outputParent = Split-Path -Parent $outputJsonResolved
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$summary = [ordered]@{
  schema = 'runner-label-contract@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  repository = $Repository
  runId = $RunId
  runnerName = $RunnerName
  runnerId = ''
  requiredLabel = $RequiredLabel
  labels = @()
  hasRequiredLabel = $false
  status = 'failure'
  failureClass = 'preflight'
  failureMessage = ''
  jobsPayloadPath = if ([string]::IsNullOrWhiteSpace($JobsPayloadPath)) { '' } else { Resolve-AbsolutePath -Path $JobsPayloadPath }
}

$caught = $null
try {
  if ([string]::IsNullOrWhiteSpace($Repository)) { throw 'Repository is required.' }
  if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'RunId is required.' }
  if ([string]::IsNullOrWhiteSpace($RunnerName)) { throw 'RunnerName is required.' }
  if ([string]::IsNullOrWhiteSpace($RequiredLabel)) { throw 'RequiredLabel is required.' }

  $jobs = Get-RunJobs -Repository $Repository -RunId $RunId -Token $Token -JobsPayloadPath $JobsPayloadPath
  if (-not $jobs -or $jobs.Count -eq 0) {
    throw (New-ApiException -Message ("No jobs returned for run {0} in {1}." -f $RunId, $Repository) -StatusCode 0)
  }

  $currentJob = $jobs |
    Where-Object { $_.runner_name -eq $RunnerName -and $_.status -eq 'in_progress' } |
    Select-Object -First 1
  if (-not $currentJob) {
    $currentJob = $jobs |
      Where-Object { $_.runner_name -eq $RunnerName } |
      Sort-Object started_at -Descending |
      Select-Object -First 1
  }
  if (-not $currentJob) {
    throw (New-ApiException -Message ("Unable to resolve current job metadata for runner '{0}' in run {1}. Remediation: verify Actions run-jobs API visibility and rerun fixture-drift." -f $RunnerName, $RunId) -StatusCode 0)
  }

  $labels = Convert-JobLabelsToArray -Labels $currentJob.labels
  $hasRequiredLabel = $labels -contains $RequiredLabel
  $summary.runnerId = [string]$currentJob.runner_id
  $summary.labels = @($labels)
  $summary.hasRequiredLabel = [bool]$hasRequiredLabel

  if (-not $hasRequiredLabel) {
    $summary.status = 'failure'
    $summary.failureClass = 'missing-label'
    $summary.failureMessage = ("Runner '{0}' (id={1}) is missing required label '{2}'. Remediation: add the label in Repository Settings > Actions > Runners, then re-run fixture-drift." -f $RunnerName, [string]$summary.runnerId, $RequiredLabel)
  } else {
    $summary.status = 'success'
    $summary.failureClass = 'none'
    $summary.failureMessage = ''
  }
} catch {
  $caught = $_
  $statusCode = Get-StatusCodeFromError -ErrorRecord $_
  $summary.status = 'failure'
  if ($statusCode -eq 403) {
    $summary.failureClass = 'api-permission'
  } elseif ($statusCode -eq 401) {
    $summary.failureClass = 'auth'
  } elseif ($statusCode -eq 404) {
    $summary.failureClass = 'api-not-found'
  } elseif ([string]::IsNullOrWhiteSpace([string]$summary.failureClass) -or [string]$summary.failureClass -eq 'preflight') {
    $summary.failureClass = 'api-error'
  }
  if ([string]::IsNullOrWhiteSpace([string]$summary.failureMessage)) {
    $summary.failureMessage = [string]$_.Exception.Message
  }
} finally {
  ($summary | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $outputJsonResolved -Encoding utf8

  $labelsCsv = if ($summary.labels -and @($summary.labels).Count -gt 0) { [string]::Join(',', @($summary.labels)) } else { '' }
  Write-GitHubOutput -Key 'has_required_label' -Value ([string]$summary.hasRequiredLabel).ToLowerInvariant() -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'labels' -Value $labelsCsv -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'runner_id' -Value ([string]$summary.runnerId) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'runner_label_contract_status' -Value ([string]$summary.status) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'runner_label_contract_summary_path' -Value $outputJsonResolved -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'runner_label_contract_failure_class' -Value ([string]$summary.failureClass) -Path $GitHubOutputPath

  if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    $summaryLines = @(
      '### Runner Label Contract',
      '',
      ('- status: `{0}`' -f [string]$summary.status),
      ('- required label: `{0}`' -f [string]$summary.requiredLabel),
      ('- runner: `{0}` (id=`{1}`)' -f [string]$summary.runnerName, [string]$summary.runnerId),
      ('- labels: `{0}`' -f $labelsCsv),
      ('- summary json: `{0}`' -f $outputJsonResolved)
    )
    if ($summary.status -ne 'success') {
      $summaryLines += ('- failure class: `{0}`' -f [string]$summary.failureClass)
      if (-not [string]::IsNullOrWhiteSpace([string]$summary.failureMessage)) {
        $summaryLines += ('- failure: {0}' -f [string]$summary.failureMessage)
      }
    }
    $stepSummaryResolved = Resolve-AbsolutePath -Path $StepSummaryPath
    $stepSummaryParent = Split-Path -Parent $stepSummaryResolved
    if ($stepSummaryParent -and -not (Test-Path -LiteralPath $stepSummaryParent -PathType Container)) {
      New-Item -ItemType Directory -Path $stepSummaryParent -Force | Out-Null
    }
    $summaryLines -join "`n" | Out-File -FilePath $stepSummaryResolved -Append -Encoding utf8
  }
}

if ([string]$summary.status -ne 'success') {
  throw ("Runner label contract failed ({0}): {1}" -f [string]$summary.failureClass, [string]$summary.failureMessage)
}

Write-Output $outputJsonResolved