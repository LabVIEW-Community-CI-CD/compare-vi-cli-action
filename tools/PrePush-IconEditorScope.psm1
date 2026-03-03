Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:IconEditorPathPrefixes = @(
  '.github/actions/apply-vipc/',
  'docs/icon_editor_package.md',
  'fixtures/icon-editor-history/',
  'tests/fixtures/icon-editor/',
  'tools/icon-editor/',
  'vendor/icon-editor/'
)

function Normalize-ChangedPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }
  return ($Path.Trim() -replace '\\', '/').ToLowerInvariant()
}

function Test-IsZeroOid {
  param([string]$Oid)
  return (-not [string]::IsNullOrWhiteSpace($Oid)) -and ($Oid -match '^[0]+$')
}

function Get-PrePushRefUpdates {
  [CmdletBinding()]
  param([string[]]$RefUpdateLines = @())

  $updates = New-Object System.Collections.Generic.List[object]
  foreach ($line in ($RefUpdateLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $parts = @($line -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -lt 4) { continue }
    $updates.Add([pscustomobject]@{
      LocalRef  = $parts[0]
      LocalOid  = "$($parts[1])".ToLowerInvariant()
      RemoteRef = $parts[2]
      RemoteOid = "$($parts[3])".ToLowerInvariant()
    })
  }

  return $updates.ToArray()
}

function Add-NormalizedPathToList {
  param(
    [System.Collections.IList]$List,
    [string]$CandidatePath
  )
  if ($null -eq $List) { return }
  $normalized = Normalize-ChangedPath -Path $CandidatePath
  if ($normalized) { [void]$List.Add($normalized) }
}

function Get-ChangedPathsFromRefUpdates {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][object[]]$RefUpdates
  )

  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($update in @($RefUpdates)) {
    $localOid = "$($update.LocalOid)".ToLowerInvariant()
    $remoteOid = "$($update.RemoteOid)".ToLowerInvariant()
    if (Test-IsZeroOid -Oid $localOid) {
      # Deletion pushes do not add new changed content to validate locally.
      continue
    }

    if (-not (Test-IsZeroOid -Oid $remoteOid)) {
      $range = "$remoteOid..$localOid"
      $rangePaths = & git -C $RepoRoot diff --name-only --diff-filter=ACMRTUXB $range 2>$null
      if ($LASTEXITCODE -ne 0) { continue }
      foreach ($candidate in @($rangePaths)) {
        Add-NormalizedPathToList -List $paths -CandidatePath $candidate
      }
      continue
    }

    # New remote ref: diff each locally unpushed commit to avoid full-repo fallback noise.
    $unpushedCommits = & git -C $RepoRoot rev-list --reverse --not --remotes $localOid 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $unpushedCommits) {
      $unpushedCommits = @($localOid)
    }
    foreach ($commit in @($unpushedCommits)) {
      $commitPaths = & git -C $RepoRoot diff-tree --no-commit-id --name-only -r --diff-filter=ACMRTUXB $commit 2>$null
      if ($LASTEXITCODE -ne 0) { continue }
      foreach ($candidate in @($commitPaths)) {
        Add-NormalizedPathToList -List $paths -CandidatePath $candidate
      }
    }
  }

  return @($paths | Sort-Object -Unique)
}

function Get-PrePushChangedPaths {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [string[]]$RefUpdateLines = @()
  )

  $paths = New-Object System.Collections.Generic.List[string]
  $effectiveRefLines = @($RefUpdateLines)
  if ($effectiveRefLines.Count -eq 0) {
    try {
      if ([Console]::IsInputRedirected) {
        $rawInput = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
          $effectiveRefLines = @($rawInput -split "(`r`n|`n)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
      }
    } catch {}
  }
  $refUpdates = @(Get-PrePushRefUpdates -RefUpdateLines $effectiveRefLines)
  $refUpdatePaths = @()
  if ($refUpdates.Count -gt 0) {
    $refUpdatePaths = @(Get-ChangedPathsFromRefUpdates -RepoRoot $RepoRoot -RefUpdates $refUpdates)
    foreach ($candidate in $refUpdatePaths) {
      Add-NormalizedPathToList -List $paths -CandidatePath $candidate
    }
  }

  if ($refUpdatePaths.Count -eq 0) {
    $upstreamResult = & git -C $RepoRoot rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $upstreamResult) {
      $upstream = ($upstreamResult | Select-Object -First 1).Trim()
      if ($upstream) {
        $rangePaths = & git -C $RepoRoot diff --name-only --diff-filter=ACMRTUXB "$upstream...HEAD" 2>$null
        if ($LASTEXITCODE -eq 0 -and $rangePaths) {
          foreach ($candidate in $rangePaths) {
            Add-NormalizedPathToList -List $paths -CandidatePath $candidate
          }
        }
      }
    }
  }

  # Keep status-based additions to surface local staged/unstaged edits during manual pre-push runs.
  $statusLines = & git -C $RepoRoot status --porcelain 2>$null
  if ($LASTEXITCODE -eq 0 -and $statusLines) {
    foreach ($line in $statusLines) {
      $text = "$line"
      if ($text.Length -lt 4) { continue }
      $pathPart = $text.Substring(3).Trim()
      if ($pathPart -match ' -> ') {
        $pathPart = ($pathPart -split ' -> ')[-1]
      }
      Add-NormalizedPathToList -List $paths -CandidatePath $pathPart
    }
  }

  $deduped = $paths | Sort-Object -Unique
  return @($deduped)
}

function Test-IconEditorFixtureCheckRequired {
  [CmdletBinding()]
  param(
    [string[]]$ChangedPaths = @(),
    [switch]$Force
  )

  if ($Force) { return $true }
  foreach ($path in $ChangedPaths) {
    $normalized = Normalize-ChangedPath -Path $path
    if (-not $normalized) { continue }
    foreach ($prefix in $script:IconEditorPathPrefixes) {
      if ($normalized.StartsWith($prefix)) {
        return $true
      }
    }
  }
  return $false
}

Export-ModuleMember -Function Get-PrePushChangedPaths, Get-PrePushRefUpdates, Get-ChangedPathsFromRefUpdates, Test-IconEditorFixtureCheckRequired
