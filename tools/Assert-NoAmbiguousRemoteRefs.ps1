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

function Invoke-GitLsRemoteProbe {
  param(
    [Parameter(Mandatory)][string]$RemoteSpec,
    [Parameter(Mandatory)][string]$Label
  )

  $oldPrompt = $env:GIT_TERMINAL_PROMPT
  try {
    $env:GIT_TERMINAL_PROMPT = '0'
    $lines = git ls-remote --heads --tags $RemoteSpec
    $exitCode = $LASTEXITCODE
  } finally {
    $env:GIT_TERMINAL_PROMPT = $oldPrompt
  }

  [pscustomobject]@{
    Label    = $Label
    Remote   = $RemoteSpec
    ExitCode = $exitCode
    Succeeded = ($exitCode -eq 0)
    Lines    = @($lines)
  }
}

function Convert-GitHubSshToHttps {
  param([Parameter(Mandatory)][string]$RemoteUrl)

  if ($RemoteUrl -match '^(?:ssh://)?git@github\.com[:/](?<path>[^\s]+?)(?:\.git)?$') {
    $repoPath = $Matches['path']
    return "https://github.com/$repoPath.git"
  }

  return $null
}

function Get-LsRemoteFailureMessage {
  param(
    [Parameter(Mandatory)][string]$RemoteName,
    [Parameter(Mandatory)][System.Collections.IEnumerable]$Attempts,
    [Parameter()][string]$RemoteUrl,
    [Parameter()][string]$FallbackUrl
  )

  $lines = @(
    "git ls-remote probe failed for remote '$RemoteName'."
  )

  $index = 0
  foreach ($attempt in @($Attempts)) {
    $index += 1
    $lines += ("Attempt {0} ({1}: {2}) exited with code {3}." -f $index, $attempt.Label, $attempt.Remote, $attempt.ExitCode)
  }

  if (-not [string]::IsNullOrWhiteSpace($RemoteUrl)) {
    $lines += "Remote URL: $RemoteUrl"
  }
  if (-not [string]::IsNullOrWhiteSpace($FallbackUrl)) {
    $lines += "HTTPS fallback URL: $FallbackUrl"
  }

  $lines += ''
  $lines += 'Configure one of the following and retry:'
  $lines += '- SSH path: ensure an SSH key/agent is available in this shell.'
  $lines += '- HTTPS path: set remote fetch URL to https://github.com/<owner>/<repo>.git and authenticate via credential helper.'
  $lines += '- Mixed-shell recommendation: keep fetch over HTTPS and push over SSH using `git remote set-url --push`.'

  return ($lines -join [Environment]::NewLine)
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw 'git must be available on PATH.'
}

$remoteTrim = $Remote.Trim()
if (-not $remoteTrim) {
  throw 'Remote name cannot be empty.'
}

$attempts = @()
$primaryProbe = Invoke-GitLsRemoteProbe -RemoteSpec $remoteTrim -Label 'remote-name'
$attempts += $primaryProbe

$rawRefs = $null
$remoteUrl = $null
$fallbackUrl = $null

if ($primaryProbe.Succeeded) {
  $rawRefs = $primaryProbe.Lines
} else {
  $remoteUrl = (git remote get-url $remoteTrim 2>$null)
  if ($LASTEXITCODE -eq 0 -and $remoteUrl) {
    $fallbackUrl = Convert-GitHubSshToHttps -RemoteUrl $remoteUrl
  }

  if (-not [string]::IsNullOrWhiteSpace($fallbackUrl)) {
    $fallbackProbe = Invoke-GitLsRemoteProbe -RemoteSpec $fallbackUrl -Label 'https-fallback'
    $attempts += $fallbackProbe
    if ($fallbackProbe.Succeeded) {
      $rawRefs = $fallbackProbe.Lines
    }
  }

  if (-not $rawRefs) {
    throw (Get-LsRemoteFailureMessage -RemoteName $remoteTrim -Attempts $attempts -RemoteUrl $remoteUrl -FallbackUrl $fallbackUrl)
  }
}

if (-not $rawRefs) {
  Write-Verbose ("Remote '{0}' advertises no heads/tags." -f $remoteTrim)
  return
}

$entries = @()
foreach ($line in (@($rawRefs) -join "`n") -split "(`r`n|`n)") {
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
