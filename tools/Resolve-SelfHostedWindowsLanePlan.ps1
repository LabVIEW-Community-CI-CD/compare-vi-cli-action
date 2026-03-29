#Requires -Version 7.0
<#
.SYNOPSIS
  Resolves the availability plan for a self-hosted Windows LV32 lane.

.DESCRIPTION
  Emits a deterministic planning artifact for a repository runner that must
  advertise the required ingress plus LV32 capability labels. The helper uses
  the repository runner inventory API or an injected inventory fixture.
#>
[CmdletBinding()]
param(
  [string]$Repository = $env:GITHUB_REPOSITORY,
  [string[]]$RequiredLabels = @(
    'self-hosted',
    'Windows',
    'X64',
    'comparevi',
    'capability-ingress',
    'labview-2026',
    'lv32'
  ),
  [string]$Token = $env:GITHUB_TOKEN,
  [string]$OutputJsonPath = 'tests/results/_agent/vi-history-dispatch/validate-vi-history-windows-lv32-plan.json',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY,
  [string]$RunnerInventoryPath = ''
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
  } catch {
    $statusCode = 0
  }

  $message = [string]$ErrorRecord.Exception.Message
  if ($message -match '"status"\s*:\s*"?(\d{3})"?' -or $message -match 'HTTP\s*(\d{3})') {
    [void][int]::TryParse($Matches[1], [ref]$statusCode)
  }
  return $statusCode
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

function Get-RepositoryRunnerInventory {
  param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$Token,
    [string]$RunnerInventoryPath
  )

  if (-not [string]::IsNullOrWhiteSpace($RunnerInventoryPath)) {
    $payloadResolved = Resolve-AbsolutePath -Path $RunnerInventoryPath
    if (-not (Test-Path -LiteralPath $payloadResolved -PathType Leaf)) {
      throw (Get-ApiException -Message ("Runner inventory file not found: {0}" -f $payloadResolved) -StatusCode 0)
    }
    $payload = Get-Content -LiteralPath $payloadResolved -Raw | ConvertFrom-Json -Depth 30
    if ($payload -is [System.Array]) {
      return @($payload)
    }
    $payloadRunners = Get-PropertyValue -InputObject $payload -Name 'runners'
    if ($null -ne $payloadRunners) {
      return @($payloadRunners)
    }
    $payloadStatus = Get-PropertyValue -InputObject $payload -Name 'status'
    $payloadMessage = Get-PropertyValue -InputObject $payload -Name 'message'
    if ($null -ne $payloadStatus -and $null -ne $payloadMessage) {
      $status = 0
      [void][int]::TryParse([string]$payloadStatus, [ref]$status)
      throw (Get-ApiException -Message ([string]$payloadMessage) -StatusCode $status)
    }
    throw (Get-ApiException -Message ("Unsupported runner inventory payload format: {0}" -f $payloadResolved) -StatusCode 0)
  }

  if ([string]::IsNullOrWhiteSpace($Token)) {
    throw (Get-ApiException -Message 'GITHUB_TOKEN is required to inspect repository runners. Set permissions.actions=read.' -StatusCode 401)
  }

  $headers = @{
    Authorization = "Bearer $Token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  $runners = New-Object System.Collections.Generic.List[object]
  $page = 1
  $perPage = 100
  do {
    $uri = "https://api.github.com/repos/$Repository/actions/runners?per_page=$perPage&page=$page"
    try {
      $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
    } catch {
      $status = Get-StatusCodeFromError -ErrorRecord $_
      $message = [string]$_.Exception.Message
      throw (Get-ApiException -Message $message -StatusCode $status)
    }

    $candidates = @($response.runners)
    foreach ($runner in $candidates) {
      $runners.Add($runner) | Out-Null
    }
    $page++
  } while ($candidates.Count -eq $perPage)

  return @($runners.ToArray())
}

$summary = [ordered]@{
  schema = 'priority/self-hosted-windows-lane-plan@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  repository = $Repository
  requiredLabels = @($RequiredLabels)
  matchingRunners = @()
  matchingRunnerCount = 0
  available = $false
  status = 'unavailable'
  skipReason = ''
  failureClass = 'none'
  failureMessage = ''
  executionModel = 'self-hosted-windows-lv32'
  runnerImage = 'self-hosted-windows-lv32'
  expectedContext = 'headless-labview-32'
  expectedOs = 'windows'
  requiredHealthReceipts = @('labview-2026-host-plane-report')
  notes = @(
    'Availability means an online, idle repository runner advertises every required label.',
    'The lane must skip rather than queue indefinitely when no matching runner is available.'
  )
}

try {
  if ([string]::IsNullOrWhiteSpace($Repository)) {
    throw 'Repository is required.'
  }
  if (-not $RequiredLabels -or @($RequiredLabels).Count -eq 0) {
    throw 'RequiredLabels is required.'
  }

  $required = @($RequiredLabels | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
  if ($required.Count -eq 0) {
    throw 'RequiredLabels is required.'
  }
  $summary.requiredLabels = @($required)

  $runners = Get-RepositoryRunnerInventory -Repository $Repository -Token $Token -RunnerInventoryPath $RunnerInventoryPath
  if (-not $runners -or $runners.Count -eq 0) {
    throw (Get-ApiException -Message ("No repository runners returned for {0}." -f $Repository) -StatusCode 0)
  }

  $candidateMatches = New-Object System.Collections.Generic.List[object]
  foreach ($runner in $runners) {
    if ($null -eq $runner) { continue }
    $runnerLabelValues = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($runner.labels)) {
      if ($entry -is [string]) {
        $candidate = [string]$entry
      } elseif ($entry -and $entry.PSObject.Properties['name']) {
        $candidate = [string]$entry.name
      } else {
        $candidate = ''
      }
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $runnerLabelValues.Add($candidate) | Out-Null
      }
    }

    $runnerLabels = @($runnerLabelValues.ToArray() | Sort-Object -Unique)
    $labelMatch = $true
    foreach ($requiredLabel in @($required)) {
      if (-not ($runnerLabels -contains $requiredLabel)) {
        $labelMatch = $false
        break
      }
    }

    if (-not $labelMatch) {
      continue
    }

    $runnerStatus = if ($runner.PSObject.Properties['status']) { [string]$runner.status } else { 'online' }
    $runnerBusy = if ($runner.PSObject.Properties['busy']) { [bool]$runner.busy } else { $false }
    $candidate = [ordered]@{
      id = if ($runner.PSObject.Properties['id']) { [string]$runner.id } else { '' }
      name = if ($runner.PSObject.Properties['name']) { [string]$runner.name } else { '' }
      status = $runnerStatus
      busy = $runnerBusy
      labels = @($runnerLabels)
      available = ($runnerStatus -eq 'online' -and -not $runnerBusy)
    }
    $candidateMatches.Add([pscustomobject]$candidate) | Out-Null
  }

  $matchingRunners = @($candidateMatches.ToArray())
  $summary.matchingRunners = @($matchingRunners)
  $summary.matchingRunnerCount = $matchingRunners.Count

  $availableMatches = @($matchingRunners | Where-Object { $_.available -eq $true })
  if ($availableMatches.Count -gt 0) {
    $summary.available = $true
    $summary.status = 'available'
    $summary.skipReason = ''
  } elseif ($matchingRunners.Count -gt 0) {
    $allBusy = @($matchingRunners | Where-Object { $_.busy -eq $true }).Count -eq $matchingRunners.Count
    $summary.available = $false
    $summary.status = if ($allBusy) { 'busy' } else { 'offline' }
    $summary.skipReason = if ($allBusy) {
      'matching runner(s) exist but are busy'
    } else {
      'matching runner(s) exist but are not online'
    }
  } else {
    $summary.available = $false
    $summary.status = 'missing-label'
    $summary.skipReason = 'no online self-hosted Windows LV32 runner matched the required capability labels'
  }
} catch {
  $summary.available = $false
  $summary.status = 'error'
  $summary.failureClass = 'plan-error'
  $summary.failureMessage = [string]$_.Exception.Message
  $summary.failureDetail = [string]$_.ScriptStackTrace
  if ([string]::IsNullOrWhiteSpace($summary.skipReason)) {
    $summary.skipReason = $summary.failureMessage
  }
}

$outputJsonResolved = Resolve-AbsolutePath -Path $OutputJsonPath
$parent = Split-Path -Parent $outputJsonResolved
if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
($summary | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $outputJsonResolved -Encoding utf8

Write-GitHubOutput -Key 'available' -Value ([string]$summary.available).ToLowerInvariant() -Path $GitHubOutputPath
Write-GitHubOutput -Key 'status' -Value ([string]$summary.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'skip_reason' -Value ([string]$summary.skipReason) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'summary_path' -Value $outputJsonResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'execution_model' -Value ([string]$summary.executionModel) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'runner_image' -Value ([string]$summary.runnerImage) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'expected_context' -Value ([string]$summary.expectedContext) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'expected_os' -Value ([string]$summary.expectedOs) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'matching_runner_count' -Value ([string]$summary.matchingRunnerCount) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'required_labels' -Value (($summary.requiredLabels -join ',')) -Path $GitHubOutputPath

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $matchingNames = if ($summary.matchingRunners -and @($summary.matchingRunners).Count -gt 0) {
    @($summary.matchingRunners | ForEach-Object { [string]$_.name }) -join ', '
  } else {
    'none'
  }
  $summaryLines = @(
    '### Self-Hosted Windows LV32 Lane Plan',
    '',
    ('- status: `{0}`' -f [string]$summary.status),
    ('- available: `{0}`' -f ([string]([bool]$summary.available)).ToLowerInvariant()),
    ('- execution_model: `{0}`' -f [string]$summary.executionModel),
    ('- runner_image: `{0}`' -f [string]$summary.runnerImage),
    ('- expected_context: `{0}`' -f [string]$summary.expectedContext),
    ('- expected_os: `{0}`' -f [string]$summary.expectedOs),
    ('- required_labels: `{0}`' -f ($summary.requiredLabels -join ', ')),
    ('- matching_runners: `{0}`' -f $matchingNames),
    ('- skip_reason: `{0}`' -f [string]$summary.skipReason)
  )
  $summaryLines -join "`n" | Out-File -LiteralPath (Resolve-AbsolutePath -Path $StepSummaryPath) -Encoding utf8 -Append
}

Write-Output $outputJsonResolved
