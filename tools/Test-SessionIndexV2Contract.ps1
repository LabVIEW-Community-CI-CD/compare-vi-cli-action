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
  Write-Output ("::warning::{0}" -f $Message)
}

function Write-GitHubOutputValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [AllowEmptyString()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    return
  }

  ("{0}={1}" -f $Name, $Value) | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

$repoContext = Resolve-RepositoryContext -Owner $Owner -Repository $Repository
$Owner = $repoContext.Owner
$Repository = $repoContext.Repository
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedPolicyPath = if ([System.IO.Path]::IsPathRooted($PolicyPath)) { $PolicyPath } else { Join-Path $repoRoot $PolicyPath }

function Get-ApiHeaderSet {
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
    if ($failure -match '^branchProtection\.expected missing required contexts:') {
      [void]$classes.Add('missing-required-contexts')
      continue
    }
    if ($failure -match '^branchProtection\.(expected|actual)') {
      [void]$classes.Add('branch-protection-shape')
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

function Get-ContractArtifactBundle {
  param(
    [string[]]$Failures,
    [string[]]$Notes,
    [string]$MismatchClass,
    [string]$MismatchFingerprint,
    [string]$RecurrenceClassification,
    [pscustomobject]$BurnIn,
    [bool]$PromotionReady,
    [string]$Disposition,
    [string]$ReportPath,
    [string]$V1Path,
    [string]$V2Path,
    [string[]]$ExpectedContexts,
    [string[]]$MissingExpected
  )

  $report = [ordered]@{
    schema = 'session-index-v2-contract/v1'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    branch = $Branch
    status = if ($Failures.Count -eq 0) { 'pass' } else { 'fail' }
    enforce = [bool]$Enforce
    failures = @($Failures)
    notes = @($Notes)
    branchProtection = [ordered]@{
      policyPath = $PolicyPath
      requiredContexts = @($ExpectedContexts)
      missingContexts = @($MissingExpected)
    }
    burnIn = [ordered]@{
      threshold = $BurnInThreshold
      status = $BurnIn.status
      reason = $BurnIn.reason
      consecutiveSuccess = $BurnIn.consecutiveSuccess
      inspectedRuns = $BurnIn.inspectedRuns
      promotionReady = $PromotionReady
    }
    burnInReceipt = [ordered]@{
      schema = 'session-index-v2-burn-in-receipt@v1'
      mode = if ($Enforce) { 'enforce' } else { 'burn-in' }
      status = if ($Failures.Count -eq 0) { 'clean' } else { 'mismatch' }
      mismatchClass = $MismatchClass
      mismatchFingerprint = $MismatchFingerprint
      mismatchSummary = @($Failures)
      recurrence = [ordered]@{
        classification = $RecurrenceClassification
        burnInStatus = $BurnIn.status
        consecutiveSuccess = $BurnIn.consecutiveSuccess
      }
      evidence = [ordered]@{
        reportPath = $ReportPath
        resultsDir = $ResultsDir
        sessionIndexV1Path = $V1Path
        sessionIndexV2Path = $V2Path
        policyPath = $PolicyPath
      }
    }
  }

  $summary = [ordered]@{
    schema = 'session-index-v2-disposition-summary@v1'
    generatedAtUtc = $report.generatedAtUtc
    branch = $Branch
    mode = $report.burnInReceipt.mode
    disposition = $Disposition
    status = $report.status
    promotionReady = $PromotionReady
    mismatchClass = $MismatchClass
    recurrenceClassification = $RecurrenceClassification
    consecutiveSuccess = $BurnIn.consecutiveSuccess
    threshold = $BurnInThreshold
    evidence = [ordered]@{
      contractReportPath = $ReportPath
      sessionIndexV1Path = $V1Path
      sessionIndexV2Path = $V2Path
      policyPath = $PolicyPath
    }
  }

  return [pscustomobject]@{
    Report = $report
    Summary = $summary
  }
}

function Write-JsonArtifact {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [object]$Data,
    [int]$Depth = 50
  )

  $Data | ConvertTo-Json -Depth $Depth | Out-File -LiteralPath $Path -Encoding utf8
}

if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
  throw "ResultsDir does not exist: $ResultsDir"
}

$v1Path = Join-Path $ResultsDir 'session-index.json'
$v2Path = Join-Path $ResultsDir 'session-index-v2.json'
$reportPath = Join-Path $ResultsDir 'session-index-v2-contract.json'
$dispositionPath = Join-Path $ResultsDir 'session-index-v2-disposition.json'
$cutoverReadinessPath = Join-Path $ResultsDir 'session-index-v2-cutover-readiness.json'
$schemaPath = 'docs/schema/generated/session-index-v2.schema.json'
$resolvedSchemaPath = Join-Path $repoRoot $schemaPath
$schemaLiteValidatorPath = Join-Path $PSScriptRoot 'Invoke-JsonSchemaLite.ps1'
$cutoverHelperPath = Join-Path $PSScriptRoot 'Write-SessionIndexV2CutoverReadiness.ps1'
$consumerMatrixPath = 'docs/SESSION_INDEX_V2_CONSUMER_MATRIX.md'
$deprecationPolicyPath = 'docs/SESSION_INDEX_V1_DEPRECATION.md'

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
    & $schemaLiteValidatorPath -JsonPath $v2Path -SchemaPath $resolvedSchemaPath
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
if (Test-Path -LiteralPath $resolvedPolicyPath -PathType Leaf) {
  try {
    $expectedContexts = @(Resolve-BranchExpectedContextsFromPath -Path $resolvedPolicyPath -BranchName $Branch)
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
    $bpReason = [string]$v2.branchProtection.reason
    if ($bpExpected.Count -eq 0) {
      Add-Failure -Failures ([ref]$failures) -Message 'branchProtection.expected is empty in session-index-v2.json.'
    }
    if ($bpActual.Count -eq 0 -and $bpReason -notin @('api_unavailable', 'api_error', 'api_forbidden')) {
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

$burnIn = Get-ConsecutiveSuccessCount -Headers (Get-ApiHeaderSet -Token $token) -Owner $Owner -Repository $Repository -WorkflowFileName $WorkflowFileName -Branch $Branch -JobName 'session-index-v2-contract'
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

$artifacts = Get-ContractArtifactBundle `
  -Failures $failures `
  -Notes $notes `
  -MismatchClass $mismatchClass `
  -MismatchFingerprint $mismatchFingerprint `
  -RecurrenceClassification $recurrenceClassification `
  -BurnIn $burnIn `
  -PromotionReady $promotionReady `
  -Disposition $disposition `
  -ReportPath $reportPath `
  -V1Path $v1Path `
  -V2Path $v2Path `
  -ExpectedContexts $expectedContexts `
  -MissingExpected $missingExpected
$report = $artifacts.Report
$summary = $artifacts.Summary

Write-JsonArtifact -Path $reportPath -Data $report -Depth 50
Write-Output ("session-index-v2 contract report written: {0}" -f $reportPath)
Write-JsonArtifact -Path $dispositionPath -Data $summary -Depth 20
Write-Output ("session-index-v2 disposition summary written: {0}" -f $dispositionPath)

$cutoverReport = $null
try {
  Remove-Item -LiteralPath $cutoverReadinessPath -Force -ErrorAction SilentlyContinue

  & $cutoverHelperPath `
    -ContractReportPath $reportPath `
    -DispositionReportPath $dispositionPath `
    -ConsumerMatrixPath $consumerMatrixPath `
    -DeprecationPolicyPath $deprecationPolicyPath `
    -OutputPath $cutoverReadinessPath `
    -StepSummaryPath ''

  if (-not (Test-Path -LiteralPath $cutoverReadinessPath -PathType Leaf)) {
    throw "Cutover readiness report was not written: $cutoverReadinessPath"
  }

  $cutoverReport = Get-Content -Raw -LiteralPath $cutoverReadinessPath | ConvertFrom-Json -Depth 50
} catch {
  Remove-Item -LiteralPath $cutoverReadinessPath -Force -ErrorAction SilentlyContinue
  Add-Failure -Failures ([ref]$failures) -Message "Cutover readiness report failed: $($_.Exception.Message)"
  $mismatchClass = Get-BurnInMismatchClass -Failures $failures
  $mismatchFingerprint = Get-BurnInMismatchFingerprint -MismatchClass $mismatchClass -Failures $failures
  $recurrenceClassification = Get-BurnInRecurrenceClassification -Failures $failures -BurnIn $burnIn
  $disposition = Get-BurnInDisposition `
    -Failures $failures `
    -Enforce ([bool]$Enforce) `
    -PromotionReady $promotionReady `
    -RecurrenceClassification $recurrenceClassification

  $artifacts = Get-ContractArtifactBundle `
    -Failures $failures `
    -Notes $notes `
    -MismatchClass $mismatchClass `
    -MismatchFingerprint $mismatchFingerprint `
    -RecurrenceClassification $recurrenceClassification `
    -BurnIn $burnIn `
    -PromotionReady $promotionReady `
    -Disposition $disposition `
    -ReportPath $reportPath `
    -V1Path $v1Path `
    -V2Path $v2Path `
    -ExpectedContexts $expectedContexts `
    -MissingExpected $missingExpected
  $report = $artifacts.Report
  $summary = $artifacts.Summary

  Write-JsonArtifact -Path $reportPath -Data $report -Depth 50
  Write-JsonArtifact -Path $dispositionPath -Data $summary -Depth 20
}

Write-GitHubOutputValue -Name 'session-index-v2-status' -Value ([string]$report.status)
Write-GitHubOutputValue -Name 'session-index-v2-burn-in-status' -Value ([string]$report.burnInReceipt.status)
Write-GitHubOutputValue -Name 'session-index-v2-burn-in-query-status' -Value ([string]$burnIn.status)
Write-GitHubOutputValue -Name 'session-index-v2-disposition' -Value ([string]$disposition)
Write-GitHubOutputValue -Name 'session-index-v2-mismatch-class' -Value ([string]$mismatchClass)
Write-GitHubOutputValue -Name 'session-index-v2-mismatch-fingerprint' -Value ([string]$mismatchFingerprint)
Write-GitHubOutputValue -Name 'session-index-v2-recurrence-classification' -Value ([string]$recurrenceClassification)
Write-GitHubOutputValue -Name 'session-index-v2-promotion-ready' -Value (([string]$promotionReady).ToLowerInvariant())
Write-GitHubOutputValue -Name 'session-index-v2-contract-report-path' -Value ([string]$reportPath)
Write-GitHubOutputValue -Name 'session-index-v2-disposition-path' -Value ([string]$dispositionPath)

if ($env:GITHUB_STEP_SUMMARY) {
  $summary = @(
    '### Session Index v2 Contract',
    '',
    ("- Status: **{0}**" -f $report.status),
    ("- Enforced: **{0}**" -f ([bool]$Enforce)),
    ("- Burn-in: **{0}/{1}** consecutive successful runs" -f $burnIn.consecutiveSuccess, $BurnInThreshold),
    ('- Burn-in receipt status: `{0}`' -f $report.burnInReceipt.status),
    ('- Burn-in query status: `{0}`' -f $burnIn.status),
    ("- Promotion ready: **{0}**" -f $promotionReady),
    ("- Disposition: **{0}**" -f $disposition),
    ('- Mismatch class: `{0}`' -f $mismatchClass),
    ('- Mismatch fingerprint: `{0}`' -f $mismatchFingerprint),
    ('- Recurrence: `{0}`' -f $recurrenceClassification),
    ('- Contract report: `{0}`' -f $reportPath),
    ('- Disposition report: `{0}`' -f $dispositionPath)
  )
  if ($cutoverReport) {
    $summary += ('- Cutover readiness report: `{0}`' -f $cutoverReadinessPath)
    $summary += ('- Cutover status: `{0}`' -f $cutoverReport.status)
    $summary += ('- Cutover ready: `{0}`' -f $cutoverReport.cutoverReady)
  }
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
  Write-Output '::warning::session-index-v2 contract check failed in burn-in mode (non-blocking).'
}
