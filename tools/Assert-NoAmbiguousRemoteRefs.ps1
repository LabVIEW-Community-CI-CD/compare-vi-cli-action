#Requires -Version 7.0
<#
.SYNOPSIS
  Fails when a remote-tracking ref name is ambiguous.
.DESCRIPTION
  Scans git references for duplicate display names (e.g. "origin/develop") and
  throws when a remote-tracking branch shares its display name with any other
  ref (typically a tag or local branch). This prevents Git from guessing which
  ref a caller intended when running commands such as `git merge origin/develop`.
.PARAMETER Remote
  Remote name to guard (defaults to "origin"). Only display names that start
  with "<Remote>/" are considered for ambiguity checking.
.PARAMETER GitPath
  Override the git executable path (defaults to "git").
#>
param(
  [string]$Remote = 'origin',
  [string]$GitPath = 'git'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Git([string[]]$Arguments) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $GitPath
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  foreach ($arg in $Arguments) {
    $null = $psi.ArgumentList.Add($arg)
  }

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  $null = $process.Start()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  if ($process.ExitCode -ne 0) {
    throw "git $($Arguments -join ' ') failed (exit=$($process.ExitCode)): $stderr"
  }

  return $stdout
}

function Get-DisplayName([string]$RefName) {
  if ($RefName -match '^refs/(remotes|heads|tags)/(.+)$') {
    return $Matches[2]
  }
  return $null
}

$showRefOutput = Invoke-Git @('show-ref')
$entries = @{}

foreach ($line in $showRefOutput -split "`n") {
  $trimmed = $line.Trim()
  if (-not $trimmed) {
    continue
  }

  $parts = $trimmed -split '\s+'
  if ($parts.Count -lt 2) {
    continue
  }

  $fullRef = $parts[1]
  $display = Get-DisplayName $fullRef
  if (-not $display) {
    continue
  }

  if (-not $entries.ContainsKey($display)) {
    $entries[$display] = [System.Collections.Generic.List[string]]::new()
  }
  $entries[$display].Add($fullRef)
}

$ambiguous = @()
foreach ($pair in $entries.GetEnumerator()) {
  $displayName = $pair.Key
  if (-not $displayName.StartsWith("$Remote/")) {
    continue
  }

  $refs = $pair.Value
  if ($refs.Count -le 1) {
    continue
  }

  $hasRemote = $refs | Where-Object { $_ -like "refs/remotes/$Remote/*" }
  if ($hasRemote) {
    $ambiguous += [PSCustomObject]@{
      DisplayName = $displayName
      Refs        = $refs
    }
  }
}

if ($ambiguous.Count -gt 0) {
  $messages = foreach ($item in $ambiguous) {
    "- $($item.DisplayName):`n  " + ($item.Refs -join "`n  ")
  }

  $guidance = @(
    'Ambiguous git references detected.',
    'Clean up duplicate refs (e.g. tags or local branches shadowing remote-tracking branches) before proceeding.',
    'Example cleanup commands:',
    '  git tag -d <duplicate>',
    '  git branch -D <duplicate>',
    ''
  )

  throw ($guidance + $messages) -join "`n"
}
