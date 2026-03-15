Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DevelopCheckoutDecision {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$CurrentBranch,
    [bool]$IsDirty,
    [bool]$HasDevelop,
    [AllowNull()][hashtable]$RemoteDevelopRef
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

function Get-BootstrapHelperRootDecision {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$CurrentBranch,
    [AllowNull()][string]$CurrentRepoRoot,
    [AllowNull()][string[]]$DevelopWorktreeRoots
  )

  $normalizedCurrentRepoRoot = Normalize-BootstrapDecisionPath -Path $CurrentRepoRoot
  $normalizedDevelopRoots = @(
    foreach ($root in @($DevelopWorktreeRoots)) {
      $normalizedRoot = Normalize-BootstrapDecisionPath -Path $root
      if (-not [string]::IsNullOrWhiteSpace($normalizedRoot)) {
        $normalizedRoot
      }
    }
  ) | Select-Object -Unique

  if ([string]::IsNullOrWhiteSpace($normalizedCurrentRepoRoot)) {
    return [pscustomobject]@{
      Action = 'use-current-root'
      HelperRoot = $null
      Message = '[bootstrap] Unable to resolve the current repo root; using the caller checkout for priority helpers.'
    }
  }

  if (
    $CurrentBranch -eq 'develop' -or
    $normalizedDevelopRoots -contains $normalizedCurrentRepoRoot
  ) {
    return [pscustomobject]@{
      Action = 'use-current-root'
      HelperRoot = $normalizedCurrentRepoRoot
      Message = $null
    }
  }

  if ($CurrentBranch -match '^(issue/|feature/|release/|hotfix/|bugfix/)') {
    $delegateRoot = @($normalizedDevelopRoots | Where-Object { $_ -ne $normalizedCurrentRepoRoot } | Select-Object -First 1)
    if ($delegateRoot.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($delegateRoot[0])) {
      return [pscustomobject]@{
        Action = 'delegate-develop-worktree'
        HelperRoot = $delegateRoot[0]
        Message = "[bootstrap] Current branch '$CurrentBranch' is a work branch; using develop helper checkout '$($delegateRoot[0])' for standing-priority refresh."
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
