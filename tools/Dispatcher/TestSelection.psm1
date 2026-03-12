Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DispatcherTestMetadata {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.IO.FileInfo]$File
  )

  $text = ''
  try {
    $text = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop
  } catch {
    $text = ''
  }

  $tags = New-Object System.Collections.Generic.List[string]
  if ($text -match "(?im)-Tag\s*(?:'Integration'|""Integration""|Integration\b)") {
    $tags.Add('Integration') | Out-Null
  }

  $executionPlane = 'host-neutral'
  $planeMatch = [regex]::Match($text, '(?im)^\s*#\s*CompareVI-TestPlane\s*:\s*(?<plane>[A-Za-z0-9._-]+)\s*$')
  if ($planeMatch.Success) {
    $executionPlane = $planeMatch.Groups['plane'].Value.Trim().ToLowerInvariant()
  }

  $modes = New-Object System.Collections.Generic.List[string]
  $modesMatch = [regex]::Match($text, '(?im)^\s*#\s*CompareVI-TestModes\s*:\s*(?<modes>.+?)\s*$')
  if ($modesMatch.Success) {
    foreach ($token in ($modesMatch.Groups['modes'].Value -split '[,;]')) {
      $mode = $token.Trim().ToLowerInvariant()
      if ([string]::IsNullOrWhiteSpace($mode)) { continue }
      if (-not $modes.Contains($mode)) {
        $modes.Add($mode) | Out-Null
      }
    }
  }

  [pscustomobject]@{
    File           = $File
    Path           = $File.FullName
    FullName       = $File.FullName
    Tags           = @($tags.ToArray())
    ExecutionPlane = $executionPlane
    Modes          = @($modes.ToArray())
  }
}

function Invoke-DispatcherExecutionPlaneFilter {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][psobject[]]$Metadata,
    [switch]$AllowLegacyHostLabVIEW,
    [switch]$ExplicitSelection
  )

  $allowed = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  $excluded = New-Object System.Collections.Generic.List[object]

  foreach ($entry in $Metadata) {
    if ($entry.ExecutionPlane -eq 'legacy-host-labview' -and -not $AllowLegacyHostLabVIEW) {
      $excluded.Add($entry) | Out-Null
      continue
    }
    $allowed.Add($entry.File) | Out-Null
  }

  $excludedList = @($excluded.ToArray())
  $allowedList = @($allowed.ToArray())

  [pscustomobject]@{
    Files           = $allowedList
    Excluded        = $excludedList
    ExcludedCount   = $excludedList.Count
    ExplicitBlocked = ($ExplicitSelection -and $excludedList.Count -gt 0 -and $allowedList.Count -eq 0)
  }
}

function Test-DispatcherPatternMatch {
  param(
    [Parameter(Mandatory)][System.IO.FileInfo]$File,
    [string[]]$Patterns
  )

  if (-not $Patterns -or $Patterns.Count -eq 0) {
    return $false
  }

  foreach ($pattern in $Patterns) {
    if (-not $pattern) { continue }
    if ($pattern -match '[\\/]') {
      $normalizedPattern = ($pattern -replace '\\', '/')
      $candidates = New-Object System.Collections.Generic.List[string]
      $candidates.Add(($File.FullName -replace '\\', '/')) | Out-Null

      try {
        $repoRelative = [System.IO.Path]::GetRelativePath((Get-Location).Path, $File.FullName)
        if (-not [string]::IsNullOrWhiteSpace($repoRelative)) {
          $candidates.Add(($repoRelative -replace '\\', '/')) | Out-Null
        }
      } catch {}

      foreach ($candidate in $candidates) {
        if ($candidate -like $normalizedPattern) {
          return $true
        }
      }

      continue
    }

    if ($File.Name -like $pattern) {
      return $true
    }
  }

  return $false
}

function Invoke-DispatcherIncludeExcludeFilter {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.IO.FileInfo[]]$Files,
    [string[]]$IncludePatterns,
    [string[]]$ExcludePatterns
  )

  $filtered = @($Files)
  $includeBefore = $filtered.Count
  $includeAfter = $includeBefore
  $includeApplied = $false

  if ($IncludePatterns -and $IncludePatterns.Count -gt 0) {
    $filtered = @($filtered | Where-Object { Test-DispatcherPatternMatch -File $_ -Patterns $IncludePatterns })
    $includeApplied = $true
    $includeAfter = $filtered.Count
  }

  $excludeBefore = $filtered.Count
  $excludeAfter = $excludeBefore
  $excludeRemoved = 0
  $excludeApplied = $false

  if ($ExcludePatterns -and $ExcludePatterns.Count -gt 0) {
    $excludeApplied = $true
    $filtered = @($filtered | Where-Object { -not (Test-DispatcherPatternMatch -File $_ -Patterns $ExcludePatterns) })
    $excludeAfter = $filtered.Count
    $excludeRemoved = $excludeBefore - $excludeAfter
  }

  [pscustomobject]@{
    Files = $filtered
    Include = [pscustomobject]@{
      Applied = $includeApplied
      Patterns = $IncludePatterns
      Before   = $includeBefore
      After    = $includeAfter
    }
    Exclude = [pscustomobject]@{
      Applied = $excludeApplied
      Patterns = $ExcludePatterns
      Before   = $excludeBefore
      After    = $excludeAfter
      Removed  = $excludeRemoved
    }
  }
}

function Invoke-DispatcherPatternSelfTestSuppression {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][System.IO.FileInfo[]]$Files,
    [string]$PatternSelfTestLeaf = 'Invoke-PesterTests.Patterns.Tests.ps1',
    [string]$SingleTestFile,
    [switch]$LimitToSingle
  )

  $filtered = @($Files)
  $before = $filtered.Count
  $filtered = @(
    $filtered | Where-Object { $_.Name -ne $PatternSelfTestLeaf -and -not ($_.FullName -like "*${PatternSelfTestLeaf}") }
  )
  $removed = $before - $filtered.Count
  $singleCleared = $false

  if ($removed -gt 0 -and $LimitToSingle -and $SingleTestFile) {
    $singleLeaf = Split-Path -Leaf $SingleTestFile
    if ($singleLeaf -eq $PatternSelfTestLeaf) {
      $singleCleared = $true
    }
  }

  [pscustomobject]@{
    Files = $filtered
    Removed = $removed
    SingleCleared = $singleCleared
  }
}

Export-ModuleMember -Function `
  Get-DispatcherTestMetadata, `
  Invoke-DispatcherExecutionPlaneFilter, `
  Test-DispatcherPatternMatch, `
  Invoke-DispatcherIncludeExcludeFilter, `
  Invoke-DispatcherPatternSelfTestSuppression
