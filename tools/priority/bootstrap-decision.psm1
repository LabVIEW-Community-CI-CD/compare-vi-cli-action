Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DevelopCheckoutDecision {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$CurrentBranch,
    [bool]$IsDirty,
    [bool]$HasDevelop,
    [AllowNull()][hashtable]$RemoteDevelopRef,
    [AllowNull()][object[]]$AttachedDevelopWorktreeRoots
  )

  if ([string]::IsNullOrWhiteSpace($CurrentBranch)) {
    return [pscustomobject]@{
      Action = 'skip-unknown-branch'
      Message = '[bootstrap] Unable to determine current git branch; skipping develop checkout.'
      Remote = $null
      Ref = $null
    }
  }

  if ($CurrentBranch -eq 'develop') {
    return [pscustomobject]@{
      Action = 'noop-already-develop'
      Message = $null
      Remote = $null
      Ref = $null
    }
  }

  if ($CurrentBranch -match '^(issue/|feature/|release/|hotfix/|bugfix/)') {
    return [pscustomobject]@{
      Action = 'skip-work-branch'
      Message = "[bootstrap] Current branch '$CurrentBranch' appears to be a work branch; leaving as-is."
      Remote = $null
      Ref = $null
    }
  }

  if ($CurrentBranch -notin @('main', 'master', 'HEAD')) {
    return [pscustomobject]@{
      Action = 'skip-retain-branch'
      Message = "[bootstrap] Current branch '$CurrentBranch' retained."
      Remote = $null
      Ref = $null
    }
  }

  if ($IsDirty) {
    return [pscustomobject]@{
      Action = 'skip-dirty'
      Message = '[bootstrap] Working tree has local changes; skipping automatic checkout of develop.'
      Remote = $null
      Ref = $null
    }
  }

  if (-not $HasDevelop) {
    if (-not $RemoteDevelopRef) {
      return [pscustomobject]@{
        Action = 'skip-no-remote-develop'
        Message = '[bootstrap] develop branch not found on upstream/origin; skipping automatic checkout.'
        Remote = $null
        Ref = $null
      }
    }

    return [pscustomobject]@{
      Action = 'create-develop-from-remote'
      Message = "[bootstrap] Creating local develop from $($RemoteDevelopRef.Ref)."
      Remote = $RemoteDevelopRef.Remote
      Ref = $RemoteDevelopRef.Ref
    }
  }

  $normalizedAttachedDevelopRoots = @(
    @(
      foreach ($root in @($AttachedDevelopWorktreeRoots)) {
        $normalizedCandidate = Normalize-BootstrapHelperCandidate -Candidate $root
        if ($null -ne $normalizedCandidate) {
          $normalizedCandidate.Root
        }
      }
    ) | Select-Object -Unique
  )

  if ($CurrentBranch -eq 'HEAD' -and $normalizedAttachedDevelopRoots.Count -gt 0) {
    $attachedRoot = $normalizedAttachedDevelopRoots[0]
    return [pscustomobject]@{
      Action = 'skip-detached-develop-attached'
      Message = "[bootstrap] Detached HEAD already has develop attached at '$attachedRoot'; keeping the detached checkout."
      Remote = $null
      Ref = $null
    }
  }

  return [pscustomobject]@{
    Action = 'checkout-develop'
    Message = '[bootstrap] Checking out develop.'
    Remote = $null
    Ref = $null
  }
}

function Normalize-BootstrapDecisionPath {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  try {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\','/')
  } catch {
    return $null
  }
}

function Normalize-BootstrapHelperCandidate {
  param(
    $Candidate
  )

  if ($null -eq $Candidate) {
    return $null
  }

  if ($Candidate -is [string]) {
    $normalizedRoot = Normalize-BootstrapDecisionPath -Path $Candidate
    if ([string]::IsNullOrWhiteSpace($normalizedRoot)) {
      return $null
    }

    return [pscustomobject]@{
      Root = $normalizedRoot
      IsClean = $true
    }
  }

  $candidateRoot = $null
  foreach ($propertyName in @('Root', 'Path', 'WorktreeRoot')) {
    if ($Candidate.PSObject.Properties[$propertyName]) {
      $candidateRoot = $Candidate.$propertyName
      break
    }
  }

  $normalizedCandidateRoot = Normalize-BootstrapDecisionPath -Path $candidateRoot
  if ([string]::IsNullOrWhiteSpace($normalizedCandidateRoot)) {
    return $null
  }

  $isClean = $true
  foreach ($propertyName in @('IsClean', 'Clean')) {
    if ($Candidate.PSObject.Properties[$propertyName]) {
      $isClean = [bool]$Candidate.$propertyName
      break
    }
  }

  return [pscustomobject]@{
    Root = $normalizedCandidateRoot
    IsClean = $isClean
  }
}

function Get-BootstrapHelperRootDecision {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$CurrentBranch,
    [AllowNull()][string]$CurrentRepoRoot,
    [AllowNull()][object[]]$DevelopWorktreeRoots
  )

  $normalizedCurrentRepoRoot = Normalize-BootstrapDecisionPath -Path $CurrentRepoRoot
  $normalizedDevelopCandidates = @(
    foreach ($root in @($DevelopWorktreeRoots)) {
      $normalizedCandidate = Normalize-BootstrapHelperCandidate -Candidate $root
      if ($null -ne $normalizedCandidate) {
        $normalizedCandidate
      }
    }
  )
  $normalizedDevelopRoots = @(
    $normalizedDevelopCandidates |
      Select-Object -ExpandProperty Root -Unique
  )

  if ([string]::IsNullOrWhiteSpace($normalizedCurrentRepoRoot)) {
    return [pscustomobject]@{
      Action = 'use-current-root'
      HelperRoot = $null
      Message = '[bootstrap] Unable to resolve the current repo root; using the caller checkout for priority helpers.'
    }
  }

  $currentRootCandidate = @(
    $normalizedDevelopCandidates |
      Where-Object { $_.Root -eq $normalizedCurrentRepoRoot } |
      Select-Object -First 1
  )
  $cleanAlternateRoot = @(
    $normalizedDevelopCandidates |
      Where-Object { $_.Root -ne $normalizedCurrentRepoRoot -and $_.IsClean } |
      Select-Object -First 1
  )

  if (
    $CurrentBranch -eq 'develop' -or
    $normalizedDevelopRoots -contains $normalizedCurrentRepoRoot
  ) {
    if (
      $CurrentBranch -eq 'develop' -and
      $currentRootCandidate.Count -gt 0 -and
      -not $currentRootCandidate[0].IsClean -and
      $cleanAlternateRoot.Count -gt 0 -and
      -not [string]::IsNullOrWhiteSpace($cleanAlternateRoot[0].Root)
    ) {
      return [pscustomobject]@{
        Action = 'delegate-clean-develop-worktree'
        HelperRoot = $cleanAlternateRoot[0].Root
        Message = "[bootstrap] Current develop checkout '$normalizedCurrentRepoRoot' is dirty; using clean develop helper checkout '$($cleanAlternateRoot[0].Root)' for priority helpers."
      }
    }

    return [pscustomobject]@{
      Action = 'use-current-root'
      HelperRoot = $normalizedCurrentRepoRoot
      Message = $null
    }
  }

  if ($CurrentBranch -match '^(issue/|feature/|release/|hotfix/|bugfix/)') {
    if ($cleanAlternateRoot.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($cleanAlternateRoot[0].Root)) {
      return [pscustomobject]@{
        Action = 'delegate-develop-worktree'
        HelperRoot = $cleanAlternateRoot[0].Root
        Message = "[bootstrap] Current branch '$CurrentBranch' is a work branch; using clean develop helper checkout '$($cleanAlternateRoot[0].Root)' for standing-priority refresh."
      }
    }

    if ($normalizedDevelopCandidates.Count -gt 0) {
      return [pscustomobject]@{
        Action = 'use-current-root'
        HelperRoot = $normalizedCurrentRepoRoot
        Message = "[bootstrap] Current branch '$CurrentBranch' has only dirty develop helper checkouts; using the caller checkout for priority helpers."
      }
    }
  }

  return [pscustomobject]@{
    Action = 'use-current-root'
    HelperRoot = $normalizedCurrentRepoRoot
    Message = $null
  }
}

Export-ModuleMember -Function Get-DevelopCheckoutDecision, Get-BootstrapHelperRootDecision
