param(
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,

  [string]$Branch = 'develop',
  [string]$PolicyPath = 'tools/policy/branch-required-checks.json',
  [string]$Owner,
  [string]$Repository,
  [string]$WorkflowFileName = 'validate.yml',
  [int]$BurnInThreshold = 10,
  [switch]$Enforce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-GitRemoteUrlToSlug {
  param([string]$RemoteUrl)

  if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    return $null
  }

  $trimmed = $RemoteUrl.Trim()
  if ($trimmed -match '^(?:git@|ssh://git@)?github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
    return "$($Matches.owner)/$($Matches.repo)"
  }

  if ($trimmed -match '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
    return "$($Matches.owner)/$($Matches.repo)"
  }

  if ($trimmed -match '^(?<owner>[^/]+)/(?<repo>[^/]+)$') {
    return "$($Matches.owner)/$($Matches.repo)"
  }

  return $null
}

function Resolve-RepositoryContext {
  param(
    [string]$Owner,
    [string]$Repository
  )

  if (-not [string]::IsNullOrWhiteSpace($Owner) -and -not [string]::IsNullOrWhiteSpace($Repository)) {
    return [pscustomobject]@{
      Owner = $Owner
      Repository = $Repository
    }
  }

  $slug = $null
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    $slug = Convert-GitRemoteUrlToSlug -RemoteUrl $env:GITHUB_REPOSITORY
  }

  if (-not $slug) {
    foreach ($remoteName in @('upstream', 'origin')) {
      $url = (& git remote get-url $remoteName 2>$null | Out-String).Trim()
      if (-not $url) { continue }
      $slug = Convert-GitRemoteUrlToSlug -RemoteUrl $url
      if ($slug) { break }
    }
  }

  if ($slug -and $slug -match '/') {
    $parts = $slug.Split('/', 2)
    return [pscustomobject]@{
      Owner = $parts[0]
      Repository = $parts[1]
    }
  }

  return [pscustomobject]@{
    Owner = if ($Owner) { $Owner } else { 'unknown-owner' }
    Repository = if ($Repository) { $Repository } else { 'unknown-repository' }
  }
}

function Add-Failure {
  param(
    [ref]$Failures,
    [string]$Message
  )

  $Failures.Value += $Message
  Write-Host ("::warning::{0}" -f $Message)
}

$repoContext = Resolve-RepositoryContext -Owner $Owner -Repository $Repository
$Owner = $repoContext.Owner
$Repository = $repoContext.Repository

function Get-ApiHeaders {
  param([string]$Token)

  if ([string]::IsNullOrWhiteSpace($Token)) {
    return $null
  }

  return @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'comparevi-session-index-v2-contract'
  }
}

function Get-ConsecutiveSuccessCount {
  param(
    [hashtable]$Headers,
    [string]$Owner,
    [string]$Repository,
    [string]$WorkflowFileName,
    [string]$Branch,
    [string]$JobName,
    [int]$MaxRuns = 30
  )

  if (-not $Headers) {
    return [pscustomobject]@{
      status             = 'unavailable'
      reason             = 'missing_token'
      consecutiveSuccess = 0
      inspectedRuns      = 0
    }
  }

  $url = "https://api.github.com/repos/$Owner/$Repository/actions/workflows/$WorkflowFileName/runs?status=completed&branch=$Branch&per_page=$MaxRuns"
  try {
    $runs = Invoke-RestMethod -Method Get -Uri $url -Headers $Headers
  } catch {
    return [pscustomobject]@{
      status             = 'unavailable'
      reason             = 'api_error'
      error              = $_.Exception.Message
      consecutiveSuccess = 0
      inspectedRuns      = 0
    }
  }

  $count = 0
  $inspected = 0
  foreach ($run in @($runs.workflow_runs)) {
    if ($run.conclusion -ne 'success') {
      break
    }

    $inspected++
    try {
      $jobs = Invoke-RestMethod -Method Get -Uri $run.jobs_url -Headers $Headers
    } catch {
      break
    }

    $targetJob = @($jobs.jobs) | Where-Object { $_.name -eq $JobName } | Select-Object -First 1
    if (-not $targetJob) {
      break
    }
    if ($targetJob.conclusion -ne 'success') {
      break
    }

    $count++
  }

  return [pscustomobject]@{
    status             = 'ok'
    reason             = 'queried'
    consecutiveSuccess = $count
    inspectedRuns      = $inspected
  }
}

if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
  throw "ResultsDir does not exist: $ResultsDir"
}

$v1Path = Join-Path $ResultsDir 'session-index.json'
$v2Path = Join-Path $ResultsDir 'session-index-v2.json'
$reportPath = Join-Path $ResultsDir 'session-index-v2-contract.json'
$schemaPath = Join-Path (Get-Location) 'docs/schema/generated/session-index-v2.schema.json'

$failures = @()
$notes = @()

if (-not (Test-Path -LiteralPath $v1Path -PathType Leaf)) {
  Add-Failure -Failures ([ref]$failures) -Message "Missing v1 artifact: $v1Path"
}
if (-not (Test-Path -LiteralPath $v2Path -PathType Leaf)) {
  Add-Failure -Failures ([ref]$failures) -Message "Missing v2 artifact: $v2Path"
}

$v2 = $null
if (Test-Path -LiteralPath $v2Path -PathType Leaf) {
  try {
    & node tools/schemas/validate-json.js --schema $schemaPath --data $v2Path
    if ($LASTEXITCODE -ne 0) {
      Add-Failure -Failures ([ref]$failures) -Message "Schema validation failed for session-index-v2.json (exit $LASTEXITCODE)."
    }
  } catch {
    Add-Failure -Failures ([ref]$failures) -Message "Schema validation failed: $($_.Exception.Message)"
  }

  try {
    $v2 = Get-Content -Raw -LiteralPath $v2Path | ConvertFrom-Json -Depth 100
  } catch {
    Add-Failure -Failures ([ref]$failures) -Message "Unable to parse session-index-v2.json: $($_.Exception.Message)"
  }
}

$expectedContexts = @()
if (Test-Path -LiteralPath $PolicyPath -PathType Leaf) {
  try {
    $policy = Get-Content -Raw -LiteralPath $PolicyPath | ConvertFrom-Json -Depth 50
    $expectedContexts = @($policy.branches.$Branch)
  } catch {
    Add-Failure -Failures ([ref]$failures) -Message "Unable to read required-check policy: $($_.Exception.Message)"
  }
} else {
  Add-Failure -Failures ([ref]$failures) -Message "Policy file not found: $PolicyPath"
}

$missingExpected = @()
if ($v2) {
  if (-not $v2.branchProtection) {
    Add-Failure -Failures ([ref]$failures) -Message 'branchProtection block missing from session-index-v2.json.'
  } else {
    $bpExpected = @($v2.branchProtection.expected)
    $bpActual = @($v2.branchProtection.actual)
    if ($bpExpected.Count -eq 0) {
      Add-Failure -Failures ([ref]$failures) -Message 'branchProtection.expected is empty in session-index-v2.json.'
    }
    if ($bpActual.Count -eq 0) {
      Add-Failure -Failures ([ref]$failures) -Message 'branchProtection.actual is empty in session-index-v2.json.'
    }

    if ($expectedContexts.Count -gt 0) {
      $missingExpected = @($expectedContexts | Where-Object { $bpExpected -notcontains $_ })
      if ($missingExpected.Count -gt 0) {
        Add-Failure -Failures ([ref]$failures) -Message ("branchProtection.expected missing required contexts: {0}" -f ($missingExpected -join ', '))
      }
    }
  }

  if (-not $v2.artifacts -or @($v2.artifacts).Count -eq 0) {
    Add-Failure -Failures ([ref]$failures) -Message 'artifacts block is empty in session-index-v2.json.'
  }
}

$token = $env:GH_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
  $token = $env:GITHUB_TOKEN
}

$burnIn = Get-ConsecutiveSuccessCount -Headers (Get-ApiHeaders -Token $token) -Owner $Owner -Repository $Repository -WorkflowFileName $WorkflowFileName -Branch $Branch -JobName 'session-index-v2-contract'
$promotionReady = ($burnIn.status -eq 'ok' -and $burnIn.consecutiveSuccess -ge $BurnInThreshold)

if ($burnIn.status -eq 'unavailable') {
  $notes += ("Burn-in status unavailable ({0})." -f $burnIn.reason)
}

$report = [ordered]@{
  schema = 'session-index-v2-contract/v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  branch = $Branch
  status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
  enforce = [bool]$Enforce
  failures = @($failures)
  notes = @($notes)
  branchProtection = [ordered]@{
    policyPath = $PolicyPath
    requiredContexts = @($expectedContexts)
    missingContexts = @($missingExpected)
  }
  burnIn = [ordered]@{
    threshold = $BurnInThreshold
    status = $burnIn.status
    reason = $burnIn.reason
    consecutiveSuccess = $burnIn.consecutiveSuccess
    inspectedRuns = $burnIn.inspectedRuns
    promotionReady = $promotionReady
  }
}

$report | ConvertTo-Json -Depth 50 | Out-File -LiteralPath $reportPath -Encoding utf8
Write-Host ("session-index-v2 contract report written: {0}" -f $reportPath)

if ($env:GITHUB_STEP_SUMMARY) {
  $summary = @(
    '### Session Index v2 Contract',
    '',
    ("- Status: **{0}**" -f $report.status),
    ("- Enforced: **{0}**" -f ([bool]$Enforce)),
    ("- Burn-in: **{0}/{1}** consecutive successful runs" -f $burnIn.consecutiveSuccess, $BurnInThreshold),
    ("- Promotion ready: **{0}**" -f $promotionReady)
  )
  if ($failures.Count -gt 0) {
    $summary += ''
    $summary += '#### Failures'
    foreach ($failure in $failures) {
      $summary += ("- {0}" -f $failure)
    }
  }
  if ($notes.Count -gt 0) {
    $summary += ''
    $summary += '#### Notes'
    foreach ($note in $notes) {
      $summary += ("- {0}" -f $note)
    }
  }
  $summary -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($failures.Count -gt 0 -and $Enforce) {
  throw "session-index-v2 contract check failed in enforce mode."
}

if ($failures.Count -gt 0 -and -not $Enforce) {
  Write-Host '::warning::session-index-v2 contract check failed in burn-in mode (non-blocking).'
}
