param(
  [string]$Remote = 'origin'
)

<#
.SYNOPSIS
Ensures the specified remote does not publish multiple refs (branch/tag)
that collapse to the same short name.

.DESCRIPTION
`git checkout` / `git fetch` operations become ambiguous when a remote
contains both a branch and a tag (or multiple tag ref forms) with the
same short name.  The policy guard relies on fast, unambiguous fetches,
so we fail early if the remote advertises such duplicates.

.PARAMETER Remote
Remote name to inspect. Defaults to `origin`.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'git must be available on PATH.'
}

$remoteTrim = $Remote.Trim()
if (-not $remoteTrim) {
  throw 'Remote name cannot be empty.'
}

$lsRemoteArgs = @('ls-remote', '--heads', '--tags', $remoteTrim)
$rawRefs = git @lsRemoteArgs
if ($LASTEXITCODE -ne 0) {
  throw "git ls-remote failed (exit $LASTEXITCODE)."
}

if (-not $rawRefs) {
  Write-Verbose ("Remote '{0}' advertises no heads/tags." -f $remoteTrim)
  return
}

$entries = @()
foreach ($line in $rawRefs -split "`n") {
  $parts = $line.Trim() -split "`t"
  if ($parts.Count -lt 2) { continue }
  $sha = $parts[0].Trim()
  $ref = $parts[1].Trim()
  if (-not $ref) { continue }

  $kind = $null
  $short = $null
  if ($ref -like 'refs/heads/*') {
    $kind = 'head'
    $short = $ref.Substring('refs/heads/'.Length)
  } elseif ($ref -like 'refs/tags/*') {
    $kind = 'tag'
    $short = $ref.Substring('refs/tags/'.Length)
    # Strip dereferenced suffix produced for annotated tags
    if ($short.EndsWith('^{}')) {
      $short = $short.Substring(0, $short.Length - 3)
    }
  } else {
    continue
  }

  if (-not [string]::IsNullOrWhiteSpace($short)) {
    $entries += [pscustomobject]@{
      Ref   = $ref
      Kind  = $kind
      Short = $short
      Sha   = $sha
    }
  }
}

if ($entries.Count -eq 0) {
  Write-Verbose ("Remote '{0}' advertises no branch/tag refs." -f $remoteTrim)
  return
}

$ambiguous = @(
  $entries |
    Group-Object Short |
    Where-Object {
      $kinds = @(
        $_.Group |
          Select-Object -ExpandProperty Kind -Unique
      )

      $kinds.Count -gt 1
    }
)

if ($ambiguous.Count -gt 0) {
  $details = @()
  foreach ($group in $ambiguous) {
    $items = $group.Group | ForEach-Object { "{0} ({1})" -f $_.Ref, $_.Kind }
    $details += ("- {0}: {1}" -f $group.Name, ($items -join ', '))
  }
  $message = @(
    "Ambiguous remote refs detected on '$remoteTrim'.",
    "Branches and tags must not share the same short name:",
    ""
  ) + $details
  throw ($message -join [Environment]::NewLine)
}

Write-Verbose ("Remote '{0}' passed ambiguity checks." -f $remoteTrim)
