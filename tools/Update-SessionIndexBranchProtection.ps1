#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'GitHub Actions annotations and step-summary notices intentionally use the host stream.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', 'To-Ordered', Justification = 'Helper name is stable and scoped locally within this script.')]
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

function ConvertTo-Ordered {
  param([psobject]$Object)
  $ordered = [ordered]@{}
  foreach ($prop in $Object.PSObject.Properties) {
    $ordered[$prop.Name] = $prop.Value
  }
  return $ordered
}

function Get-ContextAliasSet {
  param([string]$Context)

  $aliases = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  if ([string]::IsNullOrWhiteSpace($Context)) {
    return @()
  }

  $normalized = $Context.Trim()
  [void]$aliases.Add($normalized)

  if ($normalized -match '\s/\s') {
    $parts = $normalized -split '\s/\s'
    if ($parts.Count -gt 1) {
      $suffix = ($parts[-1]).Trim()
      if (-not [string]::IsNullOrWhiteSpace($suffix)) {
        [void]$aliases.Add($suffix)
      }
    }
  }

  return @($aliases)
}

function Test-ContextMatch {
  param(
    [string]$Left,
    [string]$Right
  )

  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
    return $false
  }

  $leftAliases = Get-ContextAliasSet -Context $Left
  $rightAliases = Get-ContextAliasSet -Context $Right

  foreach ($leftAlias in $leftAliases) {
    foreach ($rightAlias in $rightAliases) {
      if ($leftAlias -eq $rightAlias) {
        return $true
      }
    }
  }

  return $false
}

function Resolve-PatternValue {
  param(
    [psobject]$Mapping,
    [string]$BranchName
  )

  if (-not $Mapping) {
    return $null
  }

  foreach ($prop in $Mapping.PSObject.Properties) {
    if ($prop.Name -eq $BranchName) {
      return $prop.Value
    }
  }

  $bestMatch = $null
  $bestSpecificity = -1
  foreach ($prop in $Mapping.PSObject.Properties) {
    $pattern = $prop.Name
    if ($pattern -eq 'default') {
      continue
    }
    if ($pattern -notmatch '[\*\?]') {
      continue
    }
    if ($BranchName -like $pattern) {
      $specificity = ($pattern -replace '[\*\?]', '').Length
      if ($specificity -gt $bestSpecificity) {
        $bestSpecificity = $specificity
        $bestMatch = $prop.Value
      }
    }
  }

  if ($null -ne $bestMatch) {
    return $bestMatch
  }

  foreach ($prop in $Mapping.PSObject.Properties) {
    if ($prop.Name -eq 'default') {
      return $prop.Value
    }
  }

  return $null
}

function Resolve-BranchExpectedContextSet {
  param(
    [psobject]$Branches,
    [string]$BranchName
  )

  $resolved = Resolve-PatternValue -Mapping $Branches -BranchName $BranchName
  if ($null -eq $resolved) {
    return @()
  }
  return @($resolved)
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
$summaryJson = 'pester-summary.json'
& (Join-Path $PSScriptRoot 'Ensure-SessionIndex.ps1') -ResultsDir $ResultsDir -SummaryJson $summaryJson -DisableSessionIndexV2 | Out-Null
if (-not (Test-Path -LiteralPath $idxPath -PathType Leaf)) {
  throw "session-index.json not found after Ensure-SessionIndex: $idxPath"
}

try {
  $idxJson = Get-Content -LiteralPath $idxPath -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
  throw "Failed to parse session-index.json: $($_.Exception.Message)"
}
$idx = ConvertTo-Ordered $idxJson

$policy = Get-CanonicalMapping -Path $PolicyPath
$mappingDigest = Get-FileDigestHex -Path $PolicyPath
$branches = $policy.branches
if (-not $branches) {
  throw "Policy file '$PolicyPath' does not contain a 'branches' object."
}
$branchClassBindings = $policy.branchClassBindings
$branchClassRequiredChecks = $policy.branchClassRequiredChecks
$branchClassId = $null
if ($branchClassBindings) {
  $resolvedBranchClass = Resolve-PatternValue -Mapping $branchClassBindings -BranchName $Branch
  if ($resolvedBranchClass) {
    $branchClassId = [string]$resolvedBranchClass
  }
}

$expectedRaw = @()
if ($branchClassId -and $branchClassRequiredChecks) {
  $expectedRaw = @(Resolve-BranchExpectedContextSet -Branches $branchClassRequiredChecks -BranchName $branchClassId)
}
if ($expectedRaw.Count -eq 0) {
  $expectedRaw = @(Resolve-BranchExpectedContextSet -Branches $branches -BranchName $Branch)
}
$expected = @($expectedRaw | Where-Object { $_ } | Sort-Object -Unique)

$producedRaw = if ($PSBoundParameters.ContainsKey('ProducedContexts')) {
  $ProducedContexts
} else {
  $expected
}
$produced = @($producedRaw | Where-Object { $_ } | Sort-Object -Unique)
$missing = @(
  $expected |
    Where-Object {
      $expectedContext = $_
      -not ($produced | Where-Object { Test-ContextMatch -Left $expectedContext -Right $_ })
    } |
    Sort-Object -Unique
)
$extra   = @(
  $produced |
    Where-Object {
      $producedContext = $_
      -not ($expected | Where-Object { Test-ContextMatch -Left $producedContext -Right $_ })
    } |
    Sort-Object -Unique
)

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
  $actualMissing = @(
    $expected |
      Where-Object {
        $expectedContext = $_
        -not ($actualSorted | Where-Object { Test-ContextMatch -Left $expectedContext -Right $_ })
      } |
      Sort-Object -Unique
  )
  $actualExtra = @(
    $actualSorted |
      Where-Object {
        $actualContext = $_
        -not ($expected | Where-Object { Test-ContextMatch -Left $actualContext -Right $_ })
      } |
      Sort-Object -Unique
  )
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
  branchClassId = $branchClassId
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
& (Join-Path $PSScriptRoot 'Ensure-SessionIndex.ps1') -ResultsDir $ResultsDir -SummaryJson $summaryJson -ForceSessionIndexV2 | Out-Null

if ($env:GITHUB_STEP_SUMMARY) {
  $summaryLines = @('### Branch Protection Verification','')
  $summaryLines += ('- Branch: {0}' -f $Branch)
  if ($branchClassId) {
    $summaryLines += ('- Branch class: {0}' -f $branchClassId)
  }
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
