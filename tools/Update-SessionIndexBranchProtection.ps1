#Requires -Version 7.0
<#
.SYNOPSIS
  Inject branch-protection verification metadata into a session-index.json file.

.DESCRIPTION
  Reads a canonical branch→status mapping, computes its digest, compares the expected
  contexts for the current branch against the produced contexts, and records the outcome
  inside the session index. Emits a concise step-summary block for observability.

.PARAMETER ResultsDir
  Directory containing session-index.json.

.PARAMETER PolicyPath
  Path to the canonical branch required-checks JSON.

.PARAMETER ProducedContexts
  Status contexts emitted by this run (e.g., 'Validate / lint').
  If omitted, defaults to the expected contexts for the branch.

.PARAMETER Branch
  Branch name to evaluate. Defaults to $env:GITHUB_REF_NAME when available.

.PARAMETER Strict
  Escalate mismatches to result.status = 'fail' instead of 'warn'.

.PARAMETER ActualContexts
  Optional contexts retrieved from branch protection (when available). When supplied,
  actual.status is set to 'available'.

.PARAMETER ActualStatus
  Override the actual.status field. Defaults to 'available' when -ActualContexts is provided,
  otherwise 'unavailable'.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$PolicyPath = 'tools/policy/branch-required-checks.json',
  [string[]]$ProducedContexts,
  [string]$Branch = $env:GITHUB_REF_NAME,
  [switch]$Strict,
  [string[]]$ActualContexts,
  [ValidateSet('available','unavailable','error')]
  [string]$ActualStatus,
  [string[]]$AdditionalNotes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanonicalMapping {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Branch protection policy not found: $Path"
  }
  try {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Failed to parse policy file '$Path': $($_.Exception.Message)"
  }
}

function Get-FileDigestHex {
  param([string]$Path)
  & (Join-Path $PSScriptRoot 'Get-FileSha256.ps1') -Path $Path
}

function To-Ordered {
  param([psobject]$Object)
  $ordered = [ordered]@{}
  foreach ($prop in $Object.PSObject.Properties) {
    $ordered[$prop.Name] = $prop.Value
  }
  return $ordered
}

$rawBranch = $Branch
if ([string]::IsNullOrWhiteSpace($rawBranch)) {
  $Branch = 'unknown'
} else {
  $Branch = $rawBranch.Trim()
}

$refsHeadsPrefix = 'refs/heads/'
if ($Branch.StartsWith($refsHeadsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  $Branch = $Branch.Substring($refsHeadsPrefix.Length)
}

if ($Branch -match '^(?:refs/)?pull/\d+/(?:merge|head)$') {
  $baseRef = $env:GITHUB_BASE_REF
  if (-not [string]::IsNullOrWhiteSpace($baseRef)) {
    $Branch = $baseRef.Trim()
    if ($Branch.StartsWith($refsHeadsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $Branch = $Branch.Substring($refsHeadsPrefix.Length)
    }
  }
}

$idxPath = Join-Path $ResultsDir 'session-index.json'
if (-not (Test-Path -LiteralPath $idxPath -PathType Leaf)) {
  # Attempt to create a minimal session index so we have a target
  $summaryJson = 'pester-summary.json'
  & (Join-Path $PSScriptRoot 'Ensure-SessionIndex.ps1') -ResultsDir $ResultsDir -SummaryJson $summaryJson | Out-Null
  if (-not (Test-Path -LiteralPath $idxPath -PathType Leaf)) {
    throw "session-index.json not found after Ensure-SessionIndex: $idxPath"
  }
}

try {
  $idxJson = Get-Content -LiteralPath $idxPath -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
  throw "Failed to parse session-index.json: $($_.Exception.Message)"
}
$idx = To-Ordered $idxJson

$policy = Get-CanonicalMapping -Path $PolicyPath
$mappingDigest = Get-FileDigestHex -Path $PolicyPath
$branches = $policy.branches
if (-not $branches) {
  throw "Policy file '$PolicyPath' does not contain a 'branches' object."
}

$expectedRaw = @()
foreach ($prop in $branches.PSObject.Properties) {
  if ($prop.Name -eq $Branch) {
    $expectedRaw = @($prop.Value)
    break
  }
}
if ($expectedRaw.Count -eq 0) {
  foreach ($prop in $branches.PSObject.Properties) {
    if ($prop.Name -eq 'default') {
      $expectedRaw = @($prop.Value)
      break
    }
  }
}
$expected = @($expectedRaw | Where-Object { $_ } | Sort-Object -Unique)

$producedRaw = if ($PSBoundParameters.ContainsKey('ProducedContexts')) {
  $ProducedContexts
} else {
  $expected
}
$produced = @($producedRaw | Where-Object { $_ } | Sort-Object -Unique)
$missing = @($expected | Where-Object { $produced -notcontains $_ } | Sort-Object -Unique)
$extra   = @($produced | Where-Object { $expected -notcontains $_ } | Sort-Object -Unique)

$expectedCount = @($expected).Count
$missingCount  = @($missing).Count
$extraCount    = @($extra).Count

$resultStatus = 'ok'
$resultReason = 'aligned'
$notes = @()
$derivedNotes = @()

if ($expectedCount -eq 0) {
  $resultStatus = 'warn'
  $resultReason = 'mapping_missing'
  $notes += "No canonical required status checks defined for branch '$Branch'."
} elseif (($missingCount -gt 0) -or ($extraCount -gt 0)) {
  if ($missingCount -gt 0 -and $extraCount -gt 0) {
    $resultReason = 'mismatch'
  } elseif ($missingCount -gt 0) {
    $resultReason = 'missing_required'
  } else {
    $resultReason = 'extra_required'
  }
  $resultStatus = if ($Strict) { 'fail' } else { 'warn' }
  if ($missingCount -gt 0) {
    $notes += ("Missing contexts: {0}" -f ($missing -join ', '))
  }
  if ($extraCount -gt 0) {
    $notes += ("Unexpected contexts: {0}" -f ($extra -join ', '))
  }
}

# Actual contexts (optional)
$actualBlock = [ordered]@{}
if ($ActualContexts) {
  $actualBlock.status = if ($ActualStatus) { $ActualStatus } else { 'available' }
  $actualBlock.contexts = ($ActualContexts | Where-Object { $_ } | Select-Object -Unique)
} else {
  $actualBlock.status = if ($ActualStatus) { $ActualStatus } else { 'unavailable' }
  if ($ActualStatus -eq 'error') {
    $notes += 'Live branch protection context query failed.'
  }
}

# Compare live contexts to expected mapping when available
if ($actualBlock.status -eq 'available' -and $actualBlock.contexts) {
  $actualSorted = @($actualBlock.contexts | Sort-Object -Unique)
  $actualMissing = @($expected | Where-Object { $actualSorted -notcontains $_ } | Sort-Object -Unique)
  $actualExtra = @($actualSorted | Where-Object { $expected -notcontains $_ } | Sort-Object -Unique)
  if ($actualMissing.Count -gt 0) {
    $derivedNotes += ("Live branch protection missing contexts: {0}" -f ($actualMissing -join ', '))
    $resultReason = 'missing_required'
    $resultStatus = if ($Strict) { 'fail' } elseif ($resultStatus -eq 'ok') { 'warn' } else { $resultStatus }
  }
  if ($actualExtra.Count -gt 0) {
    $derivedNotes += ("Live branch protection has unexpected contexts: {0}" -f ($actualExtra -join ', '))
    if ($resultReason -eq 'aligned') {
      $resultReason = 'extra_required'
    }
    $resultStatus = if ($Strict) { 'fail' } elseif ($resultStatus -eq 'ok') { 'warn' } else { $resultStatus }
  }
}

$contract = [ordered]@{
  id           = 'bp-verify'
  version      = '1'
  issue        = 118
  mappingPath  = $PolicyPath
  mappingDigest = $mappingDigest
}

$bpObject = [ordered]@{
  contract = $contract
  branch   = $Branch
  expected = $expected
  produced = $produced
  actual   = $actualBlock
  result   = [ordered]@{
    status = $resultStatus
    reason = $resultReason
  }
  tags     = @('bp-verify','issue:118','contract:v1')
}
$allNotes = @($notes + $derivedNotes | Where-Object { $_ })
if ($AdditionalNotes) {
  $allNotes += ($AdditionalNotes | Where-Object { $_ })
}
if ($allNotes.Count -gt 0) {
  $bpObject.notes = $allNotes
}

$idx['branchProtection'] = $bpObject

$jsonOut = ($idx | ConvertTo-Json -Depth 10)
Set-Content -LiteralPath $idxPath -Value $jsonOut -Encoding UTF8

if ($env:GITHUB_STEP_SUMMARY) {
  $summaryLines = @('### Branch Protection Verification','')
  $summaryLines += ('- Branch: {0}' -f $Branch)
  $summaryLines += ('- Status: {0}' -f $resultStatus)
  $summaryLines += ('- Reason: {0}' -f $resultReason)
  if ($missingCount -gt 0) {
    $summaryLines += ('- Missing: {0}' -f ($missing -join ', '))
  }
  if ($extraCount -gt 0) {
    $summaryLines += ('- Extra: {0}' -f ($extra -join ', '))
  }
  $summaryLines += ('- Mapping digest: {0}' -f $mappingDigest)
  $summaryLines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

Write-Host ("branchProtection written to {0} (status: {1}, reason: {2})" -f $idxPath, $resultStatus, $resultReason)
