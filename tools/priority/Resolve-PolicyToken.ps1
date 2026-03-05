[CmdletBinding()]
param(
  [string]$Repository = $env:GITHUB_REPOSITORY,
  [string]$PrimaryToken = $env:INPUT_TOKEN_PRIMARY,
  [string]$SecondaryToken = $env:INPUT_TOKEN_SECONDARY,
  [string]$TertiaryToken = $env:INPUT_TOKEN_TERTIARY,
  [string]$TokenFileName = 'policy-gh-token.txt',
  [bool]$RequireAdmin = $true,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Repository)) {
  throw 'Repository slug is required (owner/repo). Set GITHUB_REPOSITORY or pass -Repository.'
}

function New-CandidateEntry {
  param(
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$Source
  )

  [PSCustomObject]@{
    Token   = $Token
    Sources = @($Source)
  }
}

function Add-TokenCandidate {
  param(
    [System.Collections.Generic.List[object]]$Candidates,
    [hashtable]$ByToken,
    [string]$Token,
    [string]$Source
  )

  $normalized = if ($Token) { $Token.Trim() } else { '' }
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return
  }

  if ($ByToken.ContainsKey($normalized)) {
    $entry = $ByToken[$normalized]
    if (-not ($entry.Sources -contains $Source)) {
      $entry.Sources += $Source
    }
    return
  }

  $candidate = New-CandidateEntry -Token $normalized -Source $Source
  $ByToken[$normalized] = $candidate
  [void]$Candidates.Add($candidate)
}

function Invoke-RepositoryProbe {
  param(
    [Parameter(Mandatory)][string]$RepoSlug,
    [Parameter(Mandatory)][string]$Token
  )

  $uri = "https://api.github.com/repos/$RepoSlug"
  $headers = @{
    Authorization         = "Bearer $Token"
    Accept                = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'          = 'priority-policy-token-resolver'
  }

  try {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    $isAdmin = $response.permissions.admin -eq $true
    return [PSCustomObject]@{
      Success    = $true
      StatusCode = 200
      Message    = 'ok'
      IsAdmin    = $isAdmin
    }
  } catch {
    $statusCode = $null
    $statusDescription = ''
    if ($_.Exception.Response) {
      try {
        $statusCode = [int]$_.Exception.Response.StatusCode
      } catch {
        $statusCode = $null
      }
      try {
        $statusDescription = [string]$_.Exception.Response.StatusDescription
      } catch {
        $statusDescription = ''
      }
    }

    $message = if ($statusCode) {
      "$statusCode $statusDescription".Trim()
    } else {
      $_.Exception.Message
    }

    return [PSCustomObject]@{
      Success    = $false
      StatusCode = $statusCode
      Message    = $message
      IsAdmin    = $false
    }
  }
}

$candidateList = [System.Collections.Generic.List[object]]::new()
$candidateByToken = @{}

Add-TokenCandidate -Candidates $candidateList -ByToken $candidateByToken -Token $PrimaryToken -Source 'secrets.GH_TOKEN'
Add-TokenCandidate -Candidates $candidateList -ByToken $candidateByToken -Token $SecondaryToken -Source 'secrets.GITHUB_TOKEN'
Add-TokenCandidate -Candidates $candidateList -ByToken $candidateByToken -Token $TertiaryToken -Source 'github.token'

if ($candidateList.Count -eq 0) {
  throw 'No policy token candidates were provided. Populate secrets.GH_TOKEN (preferred) or secrets.GITHUB_TOKEN.'
}

$probeResults = [System.Collections.Generic.List[object]]::new()
$selected = $null

foreach ($candidate in $candidateList) {
  $probe = Invoke-RepositoryProbe -RepoSlug $Repository -Token $candidate.Token
  $sourceSummary = ($candidate.Sources -join ' + ')
  $resultLabel = if (-not $probe.Success) {
    if ($probe.StatusCode -eq 401) { 'unauthorized' }
    elseif ($probe.StatusCode -eq 403) { 'forbidden' }
    elseif ($probe.StatusCode) { "error-$($probe.StatusCode)" }
    else { 'error' }
  } elseif ($RequireAdmin -and -not $probe.IsAdmin) {
    'authenticated-no-admin'
  } else {
    'selected'
  }

  [void]$probeResults.Add([PSCustomObject]@{
      source = $sourceSummary
      status = $resultLabel
      detail = $probe.Message
    })

  if ($resultLabel -eq 'selected') {
    $selected = [PSCustomObject]@{
      Token  = $candidate.Token
      Source = $sourceSummary
      Probe  = $probe
    }
    break
  }
}

if (-not $selected) {
  $resultText = ($probeResults | ForEach-Object { "$($_.source)=$($_.status)" }) -join '; '
  $guidance = if ($RequireAdmin) {
    'No admin-capable token resolved. Rotate/update secrets.GH_TOKEN (preferred) or secrets.GITHUB_TOKEN with repository administration access.'
  } else {
    'No authenticated token resolved.'
  }
  throw "$guidance Candidates: $resultText"
}

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { (Get-Location).Path }
$tokenFilePath = Join-Path $tempRoot $TokenFileName
Set-Content -Path $tokenFilePath -Value $selected.Token -Encoding utf8 -NoNewline

if ([string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
  throw 'GITHUB_ENV is not set; cannot export resolved policy token.'
}

Add-Content -Path $env:GITHUB_ENV -Value "GH_TOKEN=$($selected.Token)"
Add-Content -Path $env:GITHUB_ENV -Value "GH_TOKEN_FILE=$tokenFilePath"
Add-Content -Path $env:GITHUB_ENV -Value "POLICY_TOKEN_SOURCE=$($selected.Source)"
Add-Content -Path $env:GITHUB_ENV -Value "POLICY_TOKEN_REPOSITORY=$Repository"

Write-Host "Policy token source: $($selected.Source)"
Write-Host "Policy token file: $tokenFilePath"
Write-Host "Policy token admin: $($selected.Probe.IsAdmin)"

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $summaryLines = @(
    '### Policy Token Resolution',
    '',
    "- Repository: $Repository",
    "- Require admin: $RequireAdmin",
    "- Selected source: $($selected.Source)",
    "- Selected token admin: $($selected.Probe.IsAdmin)",
    '- Candidate probe results:'
  )

  foreach ($result in $probeResults) {
    $summaryLines += "  - $($result.source): $($result.status)"
  }

  ($summaryLines -join "`n") | Out-File -FilePath $StepSummaryPath -Append -Encoding utf8
}
