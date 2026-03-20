#Requires -Version 7.0

param(
  [string]$RepoPath,
  [string]$BaseRef,
  [string]$HeadRef = 'HEAD',
  [int]$MaxCommits = 50,
  [string[]]$Kinds = @('vi'),
  [string[]]$IncludePatterns,
  [string[]]$Extensions,
  [switch]$IncludeMergeCommits,
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$binaryToolsModule = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'LabVIEWBinaryTools.psm1'
if (-not (Test-Path -LiteralPath $binaryToolsModule -PathType Leaf)) {
  throw ("LabVIEWBinaryTools.psm1 not found: {0}" -f $binaryToolsModule)
}
Import-Module $binaryToolsModule -Force

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try {
    return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim()
  } catch {
    return $StartPath
  }
}

function Resolve-PathMaybeRelative {
  param(
    [string]$Path,
    [string]$Base
  )
  if (-not $Path) {
    return $null
  }
  $anchor = if ($Base) { [System.IO.Path]::GetFullPath($Base) } else { (Get-Location).Path }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $anchor $Path))
}

function Invoke-Git {
  param([string[]]$Arguments)
  $psi = New-Object System.Diagnostics.ProcessStartInfo 'git'
  foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  try {
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
      throw "git $($Arguments -join ' ') failed: $stderr"
    }
    return $stdout
  } finally {
    if ($null -ne $proc) { $proc.Dispose() }
  }
}

$repoRoot = Resolve-RepoRoot
$repoPathInput = if ([string]::IsNullOrWhiteSpace($RepoPath)) { $null } else { $RepoPath }
if (-not $repoPathInput) {
  throw 'RepoPath is required. Pass an explicit repository path now that the vendored icon-editor baseline is removed.'
}
$repoResolved = Resolve-PathMaybeRelative -Path $repoPathInput -Base $repoRoot
if (-not $repoResolved -or -not (Test-Path -LiteralPath $repoResolved -PathType Container)) {
  throw "Repository path '$repoResolved' not found."
}

$knownKinds = @{
  vi = @{
    Extensions      = @(Get-LabVIEWKnownFileExtensions)
    IncludePatterns = @('resource/', 'Resource/', 'Test/', 'tests/', 'compare/', 'Support/', 'support/', 'LVCompare/')
  }
}

if (-not $Kinds -or $Kinds.Count -eq 0) {
  $Kinds = @('vi')
}

$resolvedExtensions = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
$resolvedPatterns = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

foreach ($kind in $Kinds) {
  if (-not $knownKinds.ContainsKey($kind)) {
    throw "Unknown change kind '$kind'. Supported kinds: $($knownKinds.Keys -join ', ')."
  }
  foreach ($ext in $knownKinds[$kind].Extensions) {
    if ($ext) { [void]$resolvedExtensions.Add($ext) }
  }
  foreach ($pattern in $knownKinds[$kind].IncludePatterns) {
    if ($pattern) { [void]$resolvedPatterns.Add($pattern) }
  }
}

if ($Extensions) {
  $resolvedExtensions.Clear()
  foreach ($ext in $Extensions) {
    if ($ext) {
      $normalized = $ext.StartsWith('.') ? $ext : ".$ext"
      [void]$resolvedExtensions.Add($normalized)
    }
  }
}

$explicitExtensionsProvided = [bool]$Extensions

function Test-IsCandidateLabVIEWBinaryChange {
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [AllowEmptyString()][string]$BaseRefValue,
    [Parameter(Mandatory)][string]$HeadRefValue,
    [AllowEmptyString()][string]$StatusCode,
    [AllowEmptyString()][string]$PathValue,
    [AllowEmptyString()][string]$OldPathValue,
    [string[]]$KnownExtensions = @()
  )

  $normalizedStatus = if ([string]::IsNullOrWhiteSpace($StatusCode)) { '' } else { $StatusCode.Substring(0, 1).ToUpperInvariant() }
  $knownExtensionSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($extension in @($KnownExtensions)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$extension)) {
      [void]$knownExtensionSet.Add([string]$extension)
    }
  }

  $testPathAtRef = {
    param(
      [string]$RefValue,
      [string]$CandidatePath,
      [bool]$AllowExtensionFallback
    )

    if ([string]::IsNullOrWhiteSpace($RefValue) -or [string]::IsNullOrWhiteSpace($CandidatePath)) {
      return $false
    }

    if (Test-IsLabVIEWBinaryAtGitPath -RepoPath $RepoPath -Ref $RefValue -Path $CandidatePath) {
      return $true
    }

    if ($AllowExtensionFallback) {
      $candidateExtension = [System.IO.Path]::GetExtension($CandidatePath)
      if (-not [string]::IsNullOrWhiteSpace($candidateExtension) -and $knownExtensionSet.Contains($candidateExtension)) {
        return $true
      }
    }

    return $false
  }

  switch ($normalizedStatus) {
    'A' { return (& $testPathAtRef $HeadRefValue $PathValue $false) }
    'M' {
      if (& $testPathAtRef $HeadRefValue $PathValue $false) { return $true }
      return (& $testPathAtRef $BaseRefValue $PathValue ([string]::IsNullOrWhiteSpace($BaseRefValue)))
    }
    'D' { return (& $testPathAtRef $BaseRefValue $PathValue $true) }
    'R' {
      if (& $testPathAtRef $HeadRefValue $PathValue $false) { return $true }
      return (& $testPathAtRef $BaseRefValue $OldPathValue $true)
    }
    default {
      if (& $testPathAtRef $HeadRefValue $PathValue $false) { return $true }
      return (& $testPathAtRef $BaseRefValue $OldPathValue $true)
    }
  }
}

if ($IncludePatterns) {
  $resolvedPatterns.Clear()
  foreach ($pattern in $IncludePatterns) {
    if ($pattern) { [void]$resolvedPatterns.Add($pattern) }
  }
}

$headRefResolved = if ($HeadRef) { $HeadRef } else { 'HEAD' }
Invoke-Git @('-C', $repoResolved, 'rev-parse', '--verify', $headRefResolved) | Out-Null
if ($BaseRef) {
  Invoke-Git @('-C', $repoResolved, 'rev-parse', '--verify', $BaseRef) | Out-Null
}

$rangeArg = if ($BaseRef) { "$BaseRef..$headRefResolved" } else { $headRefResolved }
$logArgs = @('-C', $repoResolved, 'log', '--name-status', '--no-color', "--pretty=format:%H|%ct|%an|%s")
if (-not $IncludeMergeCommits.IsPresent) {
  $logArgs += '--no-merges'
}
if ($MaxCommits -gt 0) {
  $logArgs += @('-n', [string]$MaxCommits)
}
$logArgs += $rangeArg
if ($resolvedPatterns.Count -gt 0) {
  $logArgs += '--'
  foreach ($pattern in $resolvedPatterns) {
    $logArgs += $pattern
  }
}

$rawLog = Invoke-Git -Arguments $logArgs
$lines = $rawLog -split "`n"

$commitsList = New-Object System.Collections.Generic.List[object]
$current = $null

foreach ($line in $lines) {
  $trimmed = $line.TrimEnd("`r")
  if (-not $trimmed) { continue }
  if ($trimmed -match '^[0-9a-f]{40}\|') {
    if ($null -ne $current -and $current.files.Count -gt 0) {
      $commitsList.Add($current) | Out-Null
    }
    $parts = $trimmed.Split('|', 4, [System.StringSplitOptions]::None)
    $current = [pscustomobject]@{
      commit     = $parts[0]
      authorDate = [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$parts[1]).ToString('o')
      author     = $parts[2]
      subject    = $parts[3]
      files      = New-Object System.Collections.Generic.List[object]
    }
    continue
  }
  if (-not $current) { continue }
  $statusParts = $trimmed -split "`t"
  if ($statusParts.Count -lt 2) { continue }
  $statusCode = $statusParts[0]
  $path = $statusParts[-1]
  $oldPath = $null
  if ($statusParts.Count -gt 2) {
    $oldPath = $statusParts[1]
  }
  $path = $path.Trim()
  if (-not $path) { continue }

  $matchesPattern = $true
  if ($resolvedPatterns.Count -gt 0) {
    $matchesPattern = $false
    foreach ($pattern in $resolvedPatterns) {
      if ($path.StartsWith($pattern, [System.StringComparison]::OrdinalIgnoreCase)) {
        $matchesPattern = $true
        break
      }
    }
  }
  if (-not $matchesPattern) { continue }

  $extension = [System.IO.Path]::GetExtension($path)
  if ($explicitExtensionsProvided) {
    if ($resolvedExtensions.Count -gt 0 -and -not $resolvedExtensions.Contains($extension)) {
      continue
    }
  } else {
    $oldPathForDetection = if ([string]::IsNullOrWhiteSpace($oldPath)) { $path } else { $oldPath }
    if (-not (Test-IsCandidateLabVIEWBinaryChange `
      -RepoPath $repoResolved `
      -BaseRefValue $BaseRef `
      -HeadRefValue $headRefResolved `
      -StatusCode $statusCode `
      -PathValue $path `
      -OldPathValue $oldPathForDetection `
      -KnownExtensions $knownKinds['vi'].Extensions)) {
      continue
    }
  }

  $fileInfo = [pscustomobject]@{
    status     = $statusCode
    path       = $path
    oldPath    = $oldPath
    extension  = $extension
  }
  $current.files.Add($fileInfo)
}

if ($null -ne $current -and $current.files.Count -gt 0) {
  $commitsList.Add($current) | Out-Null
}

$commitObjects = @()
foreach ($item in $commitsList) {
  $files = $item.files.ToArray()
  $commitObjects += [pscustomobject]@{
    commit     = $item.commit
    author     = $item.author
    authorDate = $item.authorDate
    subject    = $item.subject
    fileCount  = $files.Count
    files      = $files
  }
}

$totalCommits = $commitObjects.Count
$totalFiles = if ($totalCommits -gt 0) {
  ($commitObjects | Measure-Object -Property fileCount -Sum).Sum
} else {
  0
}

$result = [pscustomobject]@{
  repoPath     = $repoResolved
  baseRef      = $BaseRef
  headRef      = $headRefResolved
  kinds        = $Kinds
  totalCommits = $totalCommits
  totalFiles   = $totalFiles
  commits      = $commitObjects
}

if ($OutputPath) {
  $outputDir = Split-Path -Parent $OutputPath
  if ($outputDir -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $outputDir -Force)
  }
  $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

return $result
