#Requires -Version 7.0
<#
.SYNOPSIS
  Resolves whether an online runner with a required label is available.

.DESCRIPTION
  Queries the repository Actions runners API (or a supplied payload file) and
  emits a deterministic planning artifact plus GitHub outputs suitable for
  gating expensive hosted runner workflow lanes.
#>
[CmdletBinding()]
param(
  [string]$Repository = $env:GITHUB_REPOSITORY,
  [string]$Token = $env:GITHUB_TOKEN,
  [string]$RequiredLabel = 'hosted-docker-windows',
  [string]$RequiredOs = 'Windows',
  [string]$OutputJsonPath = 'tests/results/_agent/runner-availability/runner-availability.json',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY,
  [string]$RunnersPayloadPath = ''
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

function Get-ApiException {
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
  } catch {
    Write-Verbose ('Unable to extract HTTP status directly from error object: {0}' -f $ErrorRecord.Exception.Message)
  }

  $message = [string]$ErrorRecord.Exception.Message
  $parsedStatusCode = 0
  if (($message -match '"status"\s*:\s*"?(\d{3})"?' -or $message -match 'HTTP\s*(\d{3})') -and [int]::TryParse($Matches[1], [ref]$parsedStatusCode)) {
    return $parsedStatusCode
  }
  return 0
}

function Convert-RunnerLabelsToArray {
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

function Get-RepositoryRunnerInventory {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$Token,
    [string]$RunnersPayloadPath
  )

  if (-not [string]::IsNullOrWhiteSpace($RunnersPayloadPath)) {
    $payloadResolved = Resolve-AbsolutePath -Path $RunnersPayloadPath
    if (-not (Test-Path -LiteralPath $payloadResolved -PathType Leaf)) {
      throw (Get-ApiException -Message ("Runners payload file not found: {0}" -f $payloadResolved) -StatusCode 0)
    }
    $payload = Get-Content -LiteralPath $payloadResolved -Raw | ConvertFrom-Json -Depth 30
    if ($payload -is [System.Array]) {
      return @($payload)
    }
    if ($payload.PSObject.Properties['runners'] -and $payload.runners) {
      return @($payload.runners)
    }
    if ($payload.PSObject.Properties['status'] -and $payload.PSObject.Properties['message']) {
      $status = 0
      [void][int]::TryParse([string]$payload.status, [ref]$status)
      throw (Get-ApiException -Message ([string]$payload.message) -StatusCode $status)
    }
    throw (Get-ApiException -Message ("Unsupported runners payload format: {0}" -f $payloadResolved) -StatusCode 0)
  }

  if ([string]::IsNullOrWhiteSpace($Token)) {
    throw (Get-ApiException -Message 'GITHUB_TOKEN is required to resolve runner availability. Set permissions.actions=read.' -StatusCode 401)
  }

  $headers = @{
    Authorization = "Bearer $Token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  try {
    $response = Invoke-RestMethod -Method Get -Uri ("https://api.github.com/repos/{0}/actions/runners?per_page=100" -f $Repository) -Headers $headers -ErrorAction Stop
  } catch {
    $status = Get-StatusCodeFromError -ErrorRecord $_
    $message = [string]$_.Exception.Message
    throw (Get-ApiException -Message $message -StatusCode $status)
  }
  return @($response.runners)
}

$outputJsonResolved = Resolve-AbsolutePath -Path $OutputJsonPath
$outputParent = Split-Path -Parent $outputJsonResolved
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$summary = [ordered]@{
  schema = 'runner-availability-plan@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  repository = $Repository
  requiredLabel = $RequiredLabel
  requiredOs = $RequiredOs
  status = 'error'
  available = $false
  skipReason = 'runner-availability-api-error'
  failureClass = 'api-error'
  failureMessage = ''
  totalRunnerCount = 0
  matchingRunnerCount = 0
  onlineMatchingRunnerCount = 0
  matchingRunners = @()
  onlineMatchingRunners = @()
  runnersPayloadPath = if ([string]::IsNullOrWhiteSpace($RunnersPayloadPath)) { '' } else { Resolve-AbsolutePath -Path $RunnersPayloadPath }
}

try {
  if ([string]::IsNullOrWhiteSpace($Repository)) { throw 'Repository is required.' }
  if ([string]::IsNullOrWhiteSpace($RequiredLabel)) { throw 'RequiredLabel is required.' }

  $allRunners = @(Get-RepositoryRunnerInventory -Repository $Repository -Token $Token -RunnersPayloadPath $RunnersPayloadPath)
  $summary.totalRunnerCount = $allRunners.Count

  $matchingRunners = foreach ($runner in $allRunners) {
    if (-not $runner) { continue }
    $labels = Convert-RunnerLabelsToArray -Labels $runner.labels
    $osMatches = [string]::IsNullOrWhiteSpace($RequiredOs) -or [string]::Equals([string]$runner.os, $RequiredOs, [System.StringComparison]::OrdinalIgnoreCase)
    if (($labels -contains $RequiredLabel) -and $osMatches) {
      [ordered]@{
        id = [string]$runner.id
        name = [string]$runner.name
        os = [string]$runner.os
        status = [string]$runner.status
        busy = [bool]$runner.busy
        labels = @($labels)
      }
    }
  }

  $onlineMatching = @($matchingRunners | Where-Object { [string]::Equals([string]$_.status, 'online', [System.StringComparison]::OrdinalIgnoreCase) })

  $summary.matchingRunnerCount = @($matchingRunners).Count
  $summary.onlineMatchingRunnerCount = @($onlineMatching).Count
  $summary.matchingRunners = @($matchingRunners)
  $summary.onlineMatchingRunners = @($onlineMatching)

  if (@($onlineMatching).Count -gt 0) {
    $summary.status = 'available'
    $summary.available = $true
    $summary.skipReason = ''
    $summary.failureClass = 'none'
    $summary.failureMessage = ''
  } else {
    $summary.status = 'unavailable'
    $summary.available = $false
    $summary.skipReason = 'runner-unavailable'
    $summary.failureClass = 'runner-unavailable'
    $summary.failureMessage = if (@($matchingRunners).Count -gt 0) {
      ("No online runner currently matches label '{0}' and OS '{1}'." -f $RequiredLabel, $RequiredOs)
    } else {
      ("No registered runner matches label '{0}' and OS '{1}'." -f $RequiredLabel, $RequiredOs)
    }
  }
} catch {
  $statusCode = Get-StatusCodeFromError -ErrorRecord $_
  $summary.available = $false
  $summary.status = 'error'
  if ($statusCode -eq 403) {
    $summary.failureClass = 'api-permission'
    $summary.skipReason = 'runner-availability-api-permission'
  } elseif ($statusCode -eq 401) {
    $summary.failureClass = 'auth'
    $summary.skipReason = 'runner-availability-auth'
  } elseif ($statusCode -eq 404) {
    $summary.failureClass = 'api-not-found'
    $summary.skipReason = 'runner-availability-api-not-found'
  } else {
    $summary.failureClass = 'api-error'
    $summary.skipReason = 'runner-availability-api-error'
  }
  $summary.failureMessage = [string]$_.Exception.Message
} finally {
  ($summary | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $outputJsonResolved -Encoding utf8

  $matchingNames = if ($summary.matchingRunners -and @($summary.matchingRunners).Count -gt 0) {
    [string]::Join(',', @($summary.matchingRunners | ForEach-Object { [string]$_.name }))
  } else {
    ''
  }
  $onlineMatchingNames = if ($summary.onlineMatchingRunners -and @($summary.onlineMatchingRunners).Count -gt 0) {
    [string]::Join(',', @($summary.onlineMatchingRunners | ForEach-Object { [string]$_.name }))
  } else {
    ''
  }

  Write-GitHubOutput -Key 'available' -Value ([string]([bool]$summary.available)).ToLowerInvariant() -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'status' -Value ([string]$summary.status) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'skip_reason' -Value ([string]$summary.skipReason) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'failure_class' -Value ([string]$summary.failureClass) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'summary_path' -Value $outputJsonResolved -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'matching_runner_count' -Value ([string]$summary.matchingRunnerCount) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'online_matching_runner_count' -Value ([string]$summary.onlineMatchingRunnerCount) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'matching_runner_names' -Value $matchingNames -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'online_matching_runner_names' -Value $onlineMatchingNames -Path $GitHubOutputPath

  if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    $lines = @(
      '### Runner Availability',
      '',
      ('- required label: `{0}`' -f [string]$summary.requiredLabel),
      ('- required OS: `{0}`' -f [string]$summary.requiredOs),
      ('- status: `{0}`' -f [string]$summary.status),
      ('- available: `{0}`' -f ([string]([bool]$summary.available)).ToLowerInvariant()),
      ('- skip_reason: `{0}`' -f [string]$summary.skipReason),
      ('- matching runners: `{0}`' -f [string]$summary.matchingRunnerCount),
      ('- online matching runners: `{0}`' -f [string]$summary.onlineMatchingRunnerCount)
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$summary.failureMessage)) {
      $lines += ('- detail: `{0}`' -f ([string]$summary.failureMessage -replace '`', "'"))
    }
    $lines -join "`n" | Out-File -LiteralPath (Resolve-AbsolutePath -Path $StepSummaryPath) -Encoding utf8 -Append
  }
}

Write-Output $outputJsonResolved

