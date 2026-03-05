#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$ResultsRoot = 'tests/results',
  [string]$OutputDir = 'tests/results/_agent/health-snapshot',
  [string]$Owner = 'LabVIEW-Community-CI-CD',
  [string]$Repository = 'compare-vi-cli-action',
  [string]$Branch = 'develop',
  [string]$BaseRef = 'upstream/develop',
  [string]$HeadRef = 'origin/develop',
  [int]$IncidentLimit = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Token {
  if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { return $env:GH_TOKEN }
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { return $env:GITHUB_TOKEN }

  $candidatePaths = @(
    'C:\github_token.txt',
    '/mnt/c/github_token.txt'
  )

  foreach ($candidate in $candidatePaths) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
      $value = (Get-Content -LiteralPath $candidate -Raw -Encoding utf8).Trim()
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value
      }
    } catch {
      continue
    }
  }

  return $null
}

function Invoke-GitText {
  param([string[]]$Arguments)
  $output = & git @Arguments 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  return ($output | Out-String).Trim()
}

function Get-PreferredSessionIndex {
  param([string]$ResultsDir)

  $modulePath = Join-Path (Join-Path (Get-Location).Path 'tools') 'SessionIndex-Readers.psm1'
  if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    return [pscustomobject]@{ Source = 'missing'; Path = $null; Data = $null; Error = "SessionIndex-Readers module missing: $modulePath" }
  }

  Import-Module $modulePath -Force
  $preferred = Read-PreferredSessionIndex -ResultsDir $ResultsDir
  return [pscustomobject]@{
    Source = $preferred.Source
    Path = $preferred.Path
    Data = $preferred.Data
    Error = $preferred.Error
  }
}

function Convert-ParityVerdict {
  param($Parity)
  if (-not $Parity -or $Parity.status -ne 'ok') {
    return 'degraded'
  }
  if ($Parity.tipDiff -and $Parity.tipDiff.fileCount -eq 0 -and $Parity.treeParity -and $Parity.treeParity.equal) {
    return 'pass'
  }
  return 'fail'
}

function Get-RequiredContextVerdict {
  param(
    $SessionIndex,
    [string]$Owner,
    [string]$Repository,
    [string]$Branch,
    [string]$Token
  )

  if ($SessionIndex) {
    $bp = $null
    if ($SessionIndex.PSObject.Properties.Name -contains 'branchProtection') {
      $bp = $SessionIndex.branchProtection
    }
    if ($bp) {
      $status = $null
      if ($bp.PSObject.Properties.Name -contains 'result' -and $bp.result -and $bp.result.PSObject.Properties.Name -contains 'status') {
        $status = [string]$bp.result.status
      } elseif ($bp.PSObject.Properties.Name -contains 'status') {
        $status = [string]$bp.status
      }

      if ($status) {
        $normalized = $status.ToLowerInvariant()
        $verdict = switch ($normalized) {
          'ok' { 'pass' }
          'aligned' { 'pass' }
          'success' { 'pass' }
          'warn' { 'degraded' }
          'unavailable' { 'degraded' }
          default { 'fail' }
        }

        return [pscustomobject]@{
          verdict = $verdict
          status = $status
          source = 'session-index'
          expectedCount = if ($bp.PSObject.Properties.Name -contains 'expected') { @($bp.expected).Count } else { 0 }
          actualCount = if ($bp.PSObject.Properties.Name -contains 'actual') { @($bp.actual).Count } else { 0 }
          missing = @()
        }
      }
    }
  }

  $policyPath = Join-Path (Join-Path (Get-Location).Path 'tools') 'policy/branch-required-checks.json'
  $expected = @()
  if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
    try {
      $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -Depth 30
      $expected = @($policy.branches.$Branch)
    } catch {
      $expected = @()
    }
  }

  $scriptPath = Join-Path (Join-Path (Get-Location).Path 'tools') 'Get-BranchProtectionRequiredChecks.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return [pscustomobject]@{
      verdict = 'degraded'
      status = 'script_missing'
      source = 'fallback'
      expectedCount = $expected.Count
      actualCount = 0
      missing = @($expected)
    }
  }

  $result = & $scriptPath -Owner $Owner -Repository $Repository -Branch $Branch -Token $Token
  $actual = @($result.contexts)
  $missing = @($expected | Where-Object { $actual -notcontains $_ })
  $status = if ($result.status) { [string]$result.status } else { 'unavailable' }

  $verdict = if ($status -eq 'available') {
    if ($missing.Count -eq 0) { 'pass' } else { 'fail' }
  } else {
    'degraded'
  }

  return [pscustomobject]@{
    verdict = $verdict
    status = $status
    source = 'fallback'
    expectedCount = $expected.Count
    actualCount = $actual.Count
    missing = $missing
  }
}

function Get-IncidentRunsFromSessionIndex {
  param($SessionIndex)

  $incidents = @()
  if (-not $SessionIndex) { return $incidents }

  $watchers = $null
  if ($SessionIndex.PSObject.Properties.Name -contains 'watchers') {
    $watchers = $SessionIndex.watchers
  }
  if (-not $watchers) { return $incidents }

  $rest = $null
  if ($watchers.PSObject.Properties.Name -contains 'rest') {
    $rest = $watchers.rest
  }
  if (-not $rest) { return $incidents }

  $runId = $null
  if ($rest.PSObject.Properties.Name -contains 'runId') { $runId = $rest.runId }
  if (-not $runId -and $rest.PSObject.Properties.Name -contains 'id') { $runId = $rest.id }

  $conclusion = if ($rest.PSObject.Properties.Name -contains 'conclusion') { $rest.conclusion } else { $null }
  $status = if ($rest.PSObject.Properties.Name -contains 'status') { $rest.status } else { $null }
  $url = if ($rest.PSObject.Properties.Name -contains 'htmlUrl') { $rest.htmlUrl } else { $null }

  if ($runId -or $conclusion -or $status) {
    $incidents += [pscustomobject]@{
      runId = $runId
      conclusion = if ($conclusion) { $conclusion } else { $status }
      workflow = 'watchers.rest'
      htmlUrl = $url
      source = 'session-index'
    }
  }

  return $incidents
}

function Get-IncidentRunsFromApi {
  param(
    [string]$Owner,
    [string]$Repository,
    [string]$Branch,
    [string]$Token,
    [int]$Limit
  )

  if ([string]::IsNullOrWhiteSpace($Token)) { return @() }

  $headers = @{
    Authorization = "Bearer $Token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'comparevi-health-snapshot'
  }

  $uri = "https://api.github.com/repos/$Owner/$Repository/actions/runs?branch=$Branch&status=completed&per_page=50"
  try {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
  } catch {
    return @()
  }

  $items = @()
  foreach ($run in @($response.workflow_runs)) {
    if (-not $run) { continue }
    $conclusion = [string]$run.conclusion
    if ([string]::IsNullOrWhiteSpace($conclusion) -or $conclusion -eq 'success') { continue }

    $items += [pscustomobject]@{
      runId = $run.id
      conclusion = $conclusion
      workflow = $run.name
      htmlUrl = $run.html_url
      source = 'fallback-api'
    }

    if ($items.Count -ge $Limit) { break }
  }

  return $items
}

function Write-MarkdownSummary {
  param(
    [string]$Path,
    $Snapshot
  )

  $lines = @()
  $lines += '# Health Snapshot'
  $lines += ''
  $lines += "- GeneratedAtUtc: $($Snapshot.generatedAtUtc)"
  $lines += "- Telemetry Source: session-index-$($Snapshot.sessionIndex.source)"
  $lines += "- Upstream develop SHA: $($Snapshot.shas.upstreamDevelop)"
  $lines += "- Fork develop SHA: $($Snapshot.shas.forkDevelop)"
  $lines += "- Parity verdict: **$($Snapshot.parity.verdict)** (source: $($Snapshot.parity.source))"
  $lines += "- Required-context verdict: **$($Snapshot.requiredContexts.verdict)** (source: $($Snapshot.requiredContexts.source))"
  $lines += ''
  $lines += '## Latest Incidents'
  if (@($Snapshot.incidents).Count -eq 0) {
    $lines += '- none found'
  } else {
    foreach ($incident in @($Snapshot.incidents)) {
      $incidentRunId = if ($incident.runId) { $incident.runId } else { 'n/a' }
      $conc = if ($incident.conclusion) { $incident.conclusion } else { 'unknown' }
      $wf = if ($incident.workflow) { $incident.workflow } else { 'unknown-workflow' }
      if ($incident.htmlUrl) {
        $lines += ('- {0} run {1}: {2} ({3})' -f $wf, $incidentRunId, $conc, $incident.htmlUrl)
      } else {
        $lines += ('- {0} run {1}: {2}' -f $wf, $incidentRunId, $conc)
      }
    }
  }

  if (@($Snapshot.degradedNotes).Count -gt 0) {
    $lines += ''
    $lines += '## Degraded Mode Notes'
    foreach ($note in @($Snapshot.degradedNotes)) {
      $lines += "- $note"
    }
  }

  $lines -join "`n" | Out-File -LiteralPath $Path -Encoding utf8
}

if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$token = Get-Token
$degradedNotes = @()

# Keep refs fresh where possible.
& git fetch upstream develop --quiet 2>$null | Out-Null
& git fetch origin develop --quiet 2>$null | Out-Null

$upstreamSha = Invoke-GitText -Arguments @('rev-parse', '--verify', $BaseRef)
$forkSha = Invoke-GitText -Arguments @('rev-parse', '--verify', $HeadRef)
if (-not $upstreamSha) { $upstreamSha = 'unavailable'; $degradedNotes += "Unable to resolve $BaseRef." }
if (-not $forkSha) { $forkSha = 'unavailable'; $degradedNotes += "Unable to resolve $HeadRef." }

$parityOutputPath = Join-Path $OutputDir 'origin-upstream-parity.json'
try {
  & node tools/priority/report-origin-upstream-parity.mjs --base-ref $BaseRef --head-ref $HeadRef --output-path $parityOutputPath | Out-Null
} catch {
  $degradedNotes += 'Parity report command failed; using degraded verdict.'
}

$parity = $null
if (Test-Path -LiteralPath $parityOutputPath -PathType Leaf) {
  try {
    $parity = Get-Content -LiteralPath $parityOutputPath -Raw | ConvertFrom-Json -Depth 30
  } catch {
    $degradedNotes += "Parity report parse failed: $($_.Exception.Message)"
  }
} else {
  $degradedNotes += 'Parity report not produced.'
}

$sessionPreferred = Get-PreferredSessionIndex -ResultsDir $ResultsRoot
if ($sessionPreferred.Error) {
  $degradedNotes += "Session index read degraded: $($sessionPreferred.Error)"
}

$requiredContexts = Get-RequiredContextVerdict -SessionIndex $sessionPreferred.Data -Owner $Owner -Repository $Repository -Branch $Branch -Token $token
if ($requiredContexts.verdict -eq 'degraded') {
  $degradedNotes += 'Required-context verdict is degraded (missing canonical branch protection telemetry).'
}

$incidents = @(Get-IncidentRunsFromSessionIndex -SessionIndex $sessionPreferred.Data)
if ($incidents.Count -eq 0) {
  $incidents = @(Get-IncidentRunsFromApi -Owner $Owner -Repository $Repository -Branch $Branch -Token $token -Limit $IncidentLimit)
  if ($incidents.Count -eq 0) {
    $degradedNotes += 'Incident run extraction unavailable from session-index and API fallback.'
  }
}

$parityVerdict = Convert-ParityVerdict -Parity $parity
if ($parityVerdict -eq 'degraded') {
  $degradedNotes += 'Parity verdict degraded due to unavailable parity telemetry.'
}

$snapshot = [ordered]@{
  schema = 'health-snapshot/v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  sessionIndex = [ordered]@{
    source = $sessionPreferred.Source
    path = $sessionPreferred.Path
  }
  shas = [ordered]@{
    upstreamDevelop = $upstreamSha
    forkDevelop = $forkSha
  }
  parity = [ordered]@{
    verdict = $parityVerdict
    source = if ($parity -and $parity.status -eq 'ok') { 'origin-upstream-parity' } else { 'fallback' }
    status = if ($parity) { $parity.status } else { 'unavailable' }
    tipDiffFileCount = if ($parity -and $parity.tipDiff) { $parity.tipDiff.fileCount } else { $null }
    recommendationCode = if ($parity -and $parity.recommendation) { $parity.recommendation.code } else { $null }
  }
  requiredContexts = [ordered]@{
    verdict = $requiredContexts.verdict
    source = $requiredContexts.source
    status = $requiredContexts.status
    expectedCount = $requiredContexts.expectedCount
    actualCount = $requiredContexts.actualCount
    missing = @($requiredContexts.missing)
  }
  incidents = @($incidents)
  degradedNotes = @($degradedNotes | Select-Object -Unique)
}

$jsonPath = Join-Path $OutputDir 'health-snapshot.json'
$mdPath = Join-Path $OutputDir 'health-snapshot.md'
$snapshot | ConvertTo-Json -Depth 50 | Out-File -LiteralPath $jsonPath -Encoding utf8
Write-MarkdownSummary -Path $mdPath -Snapshot $snapshot

Write-Host "Health snapshot JSON: $jsonPath"
Write-Host "Health snapshot Markdown: $mdPath"
