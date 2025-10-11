#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Owner,
  [Parameter(Mandatory=$true)][string]$Repository,
  [Parameter(Mandatory=$true)][string]$Branch,
  [string]$Token = $env:GITHUB_TOKEN,
  [string]$ApiBaseUrl = 'https://api.github.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Repository)) {
  throw "Owner and Repository must be provided."
}
if ([string]::IsNullOrWhiteSpace($Branch)) {
  throw "Branch must be provided."
}

if ([string]::IsNullOrWhiteSpace($Token)) {
  $Token = $env:GH_TOKEN
}

if ([string]::IsNullOrWhiteSpace($Token)) {
  Write-Warning "GITHUB_TOKEN not available; returning unavailable status."
  [pscustomobject]@{
    status   = 'unavailable'
    contexts = @()
    notes    = @('No token available for branch protection query.')
  }
  return
}

$headers = @{
  Authorization          = "token $Token"
  Accept                 = 'application/vnd.github+json'
  'User-Agent'           = 'compare-vi-cli-action'
  'X-GitHub-Api-Version' = '2022-11-28'
}

$branchSegment = [System.Uri]::EscapeDataString($Branch)
$uri = '{0}/repos/{1}/{2}/branches/{3}/protection' -f $ApiBaseUrl.TrimEnd('/'), $Owner, $Repository, $branchSegment

try {
  $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
  $contexts = @()
  $statusSection = $response.required_status_checks
  if ($statusSection) {
    if ($statusSection.contexts) {
      $contexts = @($statusSection.contexts | Where-Object { $_ })
    }
    if (($contexts.Count -eq 0) -and $statusSection.checks) {
      $contexts = @($statusSection.checks | ForEach-Object { $_.context } | Where-Object { $_ })
    }
  }
  [pscustomobject]@{
    status   = 'available'
    contexts = $contexts
    notes    = @()
  }
} catch {
  $ex = $_.Exception
  $responseStatus = $null
  $responseProperty = $null
  if ($ex) {
    $responsePropertyMember = $ex.PSObject.Properties['Response']
    if ($responsePropertyMember) {
      $responseProperty = $responsePropertyMember.Value
    }
  }
  if ($responseProperty) {
    $statusMember = $responseProperty.PSObject.Properties['StatusCode']
    if ($statusMember) {
      $responseStatus = [int]$statusMember.Value
    }
  } elseif ($_.ErrorDetails -and $_.ErrorDetails.Message) {
    try {
      $json = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
      if ($json.message -match '\b404\b') {
        $responseStatus = 404
      }
    } catch { }
  }

  if ($responseStatus -eq 404) {
    [pscustomobject]@{
      status   = 'unavailable'
      contexts = @()
      notes    = @('Branch protection required status checks not configured for this branch.')
    }
  } else {
    $reason = if ($ex) { $ex.Message } else { $_.ToString() }
    [pscustomobject]@{
      status   = 'error'
      contexts = @()
      notes    = @("Branch protection query failed: $reason")
    }
  }
}
