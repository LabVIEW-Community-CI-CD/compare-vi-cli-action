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

Import-Module (Join-Path $PSScriptRoot 'BranchExpectedContexts.psm1') -Force -DisableNameChecking

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

function Get-BurnInMismatchClass {
  param([string[]]$Failures)

  $normalizedFailures = @($Failures | ForEach-Object { [string]$_ })
  if ($normalizedFailures.Count -eq 0) {
    return 'none'
  }

  $classes = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
  foreach ($failure in $normalizedFailures) {
    if ($failure -match '^Missing v[12] artifact:') {
      [void]$classes.Add('missing-artifact')
      continue
    }
    if ($failure -match '^Schema validation failed') {
      [void]$classes.Add('schema-validation')
      continue
    }
    if ($failure -match '^Unable to resolve required contexts from branch policy') {
      [void]$classes.Add('branch-policy-projection')
      continue
    }
    if ($failure -match '^branchProtection\.(expected|actual)') {
      [void]$classes.Add('branch-protection-shape')
      continue
    }
    if ($failure -match '^branchProtection\.expected missing required contexts:') {
      [void]$classes.Add('missing-required-contexts')
      continue
    }
    if ($failure -match '^artifacts block is empty') {
      [void]$classes.Add('artifact-catalog')
      continue
    }
    [void]$classes.Add('unknown')
  }

  $classList = @($classes)
  if ($classList.Count -eq 1) {
    return [string]$classList[0]
  }
  return 'multiple'
}

function Get-BurnInMismatchFingerprint {
  param(
    [string]$MismatchClass,
    [string[]]$Failures
  )

  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $payload = [string]::Join("`n", @([string]$MismatchClass) + @($Failures | Sort-Object))
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $hash = $hasher.ComputeHash($bytes)
  } finally {
    $hasher.Dispose()
  }

  return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-BurnInRecurrenceClassification {
  param(
    [string[]]$Failures,
    [pscustomobject]$BurnIn
  )

  if (@($Failures).Count -eq 0) {
    return 'clean'
  }
  if ($null -eq $BurnIn -or [string]$BurnIn.status -ne 'ok') {
    return 'unknown'
  }
  if ([int]$BurnIn.consecutiveSuccess -gt 0) {
    return 'new-after-success-streak'
  }
  return 'recurring-or-persistent'
}

function Get-BurnInDisposition {
  param(
    [string[]]$Failures,
    [bool]$Enforce,
    [bool]$PromotionReady,
    [string]$RecurrenceClassification
  )

  if (@($Failures).Count -eq 0) {
    if ($PromotionReady) {
      return 'promotion-ready'
    }
    return 'clean-burn-in'
  }

  if ($Enforce) {
    return 'promotion-blocking'
  }

  if ([string]$RecurrenceClassification -eq 'recurring-or-persistent') {
    return 'recurring-burn-in-mismatch'
  }

  return 'burn-in-mismatch'
}

if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
  throw "ResultsDir does not exist: $ResultsDir"
}

$v1Path = Join-Path $ResultsDir 'session-index.json'
$v2Path = Join-Path $ResultsDir 'session-index-v2.json'
$reportPath = Join-Path $ResultsDir 'session-index-v2-contract.json'
$dispositionPath = Join-Path $ResultsDir 'session-index-v2-disposition.json'
$schemaPath = Join-Path (Get-Location) 'docs/schema/generated/session-index-v2.schema.json'
$schemaLiteValidatorPath = Join-Path $PSScriptRoot 'Invoke-JsonSchemaLite.ps1'

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
    & $schemaLiteValidatorPath -JsonPath $v2Path -SchemaPath $schemaPath
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
    $expectedContexts = @(Resolve-BranchExpectedContextsFromPath -Path $PolicyPath -BranchName $Branch)
    if ($expectedContexts.Count -eq 0) {
      Add-Failure -Failures ([ref]$failures) -Message ("Unable to resolve required contexts from branch policy for branch '{0}'." -f $Branch)
    }
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
$mismatchClass = Get-BurnInMismatchClass -Failures $failures
$mismatchFingerprint = Get-BurnInMismatchFingerprint -MismatchClass $mismatchClass -Failures $failures
$recurrenceClassification = Get-BurnInRecurrenceClassification -Failures $failures -BurnIn $burnIn
$disposition = Get-BurnInDisposition `
  -Failures $failures `
  -Enforce ([bool]$Enforce) `
  -PromotionReady $promotionReady `
  -RecurrenceClassification $recurrenceClassification

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
  burnInReceipt = [ordered]@{
    schema = 'session-index-v2-burn-in-receipt@v1'
    mode = if ($Enforce) { 'enforce' } else { 'burn-in' }
    status = if ($failures.Count -eq 0) { 'clean' } else { 'mismatch' }
    mismatchClass = $mismatchClass
    mismatchFingerprint = $mismatchFingerprint
    mismatchSummary = @($failures)
    recurrence = [ordered]@{
      classification = $recurrenceClassification
      burnInStatus = $burnIn.status
      consecutiveSuccess = $burnIn.consecutiveSuccess
    }
    evidence = [ordered]@{
      reportPath = $reportPath
      resultsDir = $ResultsDir
      sessionIndexV1Path = $v1Path
      sessionIndexV2Path = $v2Path
      policyPath = $PolicyPath
    }
  }
}

$report | ConvertTo-Json -Depth 50 | Out-File -LiteralPath $reportPath -Encoding utf8
Write-Host ("session-index-v2 contract report written: {0}" -f $reportPath)

$summary = [ordered]@{
  schema = 'session-index-v2-disposition-summary@v1'
  generatedAtUtc = $report.generatedAtUtc
  branch = $Branch
  mode = $report.burnInReceipt.mode
  disposition = $disposition
  status = $report.status
  promotionReady = $promotionReady
  mismatchClass = $mismatchClass
  recurrenceClassification = $recurrenceClassification
  consecutiveSuccess = $burnIn.consecutiveSuccess
  threshold = $BurnInThreshold
  evidence = [ordered]@{
    contractReportPath = $reportPath
    sessionIndexV1Path = $v1Path
    sessionIndexV2Path = $v2Path
    policyPath = $PolicyPath
  }
}

$summary | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $dispositionPath -Encoding utf8
Write-Host ("session-index-v2 disposition summary written: {0}" -f $dispositionPath)

if ($env:GITHUB_STEP_SUMMARY) {
  $summary = @(
    '### Session Index v2 Contract',
    '',
    ("- Status: **{0}**" -f $report.status),
    ("- Enforced: **{0}**" -f ([bool]$Enforce)),
    ("- Burn-in: **{0}/{1}** consecutive successful runs" -f $burnIn.consecutiveSuccess, $BurnInThreshold),
    ("- Promotion ready: **{0}**" -f $promotionReady),
    ("- Disposition: **{0}**" -f $disposition)
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
