Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-IntakeTitle {
  param([string]$Title)

  if ([string]::IsNullOrWhiteSpace($Title)) {
    return $null
  }

  $candidate = $Title.Trim()
  $candidate = $candidate -replace '^\s*\[p\d+\]\s*', ''
  $candidate = $candidate -replace '^\s*epic\s*:\s*', ''
  $candidate = $candidate.Trim()
  if (-not $candidate) {
    return $null
  }

  $first = $candidate.Substring(0, 1).ToUpperInvariant()
  if ($candidate.Length -eq 1) {
    return $first
  }

  return $first + $candidate.Substring(1)
}

function ConvertTo-IntakeSlug {
  param(
    [string]$Title,
    [string]$Fallback = 'work'
  )

  $normalized = Normalize-IntakeTitle -Title $Title
  if (-not $normalized) {
    $normalized = $Fallback
  }

  $slug = ($normalized -replace '[^a-zA-Z0-9\- ]', '' -replace '\s+', '-').ToLowerInvariant().Trim('-')
  if (-not $slug) {
    return $Fallback
  }

  return $slug
}

function Resolve-IssueBranchName {
  param(
    [int]$Number,
    [string]$Title,
    [string]$BranchPrefix = 'issue',
    [string]$CurrentBranch
  )

  if ($Number -gt 0 -and -not [string]::IsNullOrWhiteSpace($CurrentBranch)) {
    $pattern = '^{0}/{1}(?:-|$)' -f [regex]::Escape($BranchPrefix), $Number
    if ($CurrentBranch -match $pattern) {
      return $CurrentBranch
    }
  }

  $slug = ConvertTo-IntakeSlug -Title $Title
  return '{0}/{1}-{2}' -f $BranchPrefix, $Number, $slug
}

function Get-BranchHeadCommitSubject {
  param([string]$Base)

  if ([string]::IsNullOrWhiteSpace($Base)) {
    return $null
  }

  try {
    $range = "origin/$Base..HEAD"
    $countText = (& git rev-list --count $range 2>$null).Trim()
    $commitCount = 0
    if (-not [int]::TryParse($countText, [ref]$commitCount) -or $commitCount -le 0) {
      return $null
    }

    $subject = (& git log '--format=%s' '-n' '1' 'HEAD' 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($subject)) {
      return $null
    }

    return $subject.Trim()
  } catch {
    return $null
  }
}

function Resolve-PullRequestTitle {
  param(
    [int]$Issue,
    [string]$IssueTitle,
    [string]$Base
  )

  $candidate = Normalize-IntakeTitle -Title $IssueTitle
  if (-not $candidate) {
    $candidate = Get-BranchHeadCommitSubject -Base $Base
  }
  if (-not $candidate) {
    $candidate = if ($Issue -gt 0) { "Update for issue #$Issue" } else { 'Update branch' }
  }

  if ($Issue -gt 0 -and $candidate -notmatch "(?<!\d)#$Issue(?!\d)") {
    return "$candidate (#$Issue)"
  }

  return $candidate
}

Export-ModuleMember -Function Resolve-IssueBranchName, Resolve-PullRequestTitle
