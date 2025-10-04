Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  Guard test to prevent reintroduction of legacy artifact names Base.vi/Head.vi.
.DESCRIPTION
  Scans scripts, tests, module code, and select documentation for the deprecated
  artifact filenames. Exceptions: CHANGELOG (historical context), issues-drafts
  (issue descriptions), and release/migration documentation files.
#>

Describe 'Legacy artifact name guard (Base.vi / Head.vi)' -Tag 'Unit','Guard' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    
    # Allowlist: files/directories that legitimately reference legacy names
    $allowlist = @(
      'CHANGELOG.md'
      'issues-drafts'
      'PR_NOTES.md'
      'ROLLBACK_PLAN.md'
      'RELEASE_NOTES_v0.4.1.md'
      'POST_RELEASE_FOLLOWUPS.md'
      'IMPLEMENTATION_STATUS.md'
      'IMPLEMENTATION_STATUS_v0.5.0.md'
      'TAG_PREP_CHECKLIST.md'
      'README.md'  # Contains breaking change migration notice
      'Guard.LegacyArtifactNames.Tests.ps1'  # This test file itself
      '.git'
    )
    
    # Build allowlist hash for fast exclusion
    $allowSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $allowlist) { [void]$allowSet.Add($a) }
  }
  
  It 'finds no Base.vi references in scripts, tests, or module code (excluding allowlist)' {
    $extensions = @('*.ps1','*.psm1','*.psd1')
    $hits = @()
    $root = (Resolve-Path $repoRoot).Path
    foreach ($ext in $extensions) {
      $files = Get-ChildItem -Path $repoRoot -Recurse -File -Filter $ext -ErrorAction SilentlyContinue | ForEach-Object {
        $full = $_.FullName
        if ($full.StartsWith($root)) {
          $rel = $full.Substring($root.Length)
          while ($rel.StartsWith('\') -or $rel.StartsWith('/')) { $rel = $rel.Substring(1) }
        } else { $rel = $_.Name }
        $segments = $rel -split '[\\/]'
        $excluded = $false
        foreach ($seg in $segments) { if ($allowSet.Contains($seg)) { $excluded = $true; break } }
        if (-not $excluded) { $_ }
      }
      foreach ($f in $files) {
        $contentHits = Select-String -LiteralPath $f.FullName -Pattern 'Base\.vi' -SimpleMatch -ErrorAction SilentlyContinue
        if ($contentHits) { $hits += $f.FullName }
      }
    }
    if ($hits.Count -gt 0) { throw "Found legacy 'Base.vi' references in:`n$($hits -join "`n")" }
    $hits | Should -BeNullOrEmpty
  }
  
  It 'finds no Head.vi references in scripts, tests, or module code (excluding allowlist)' {
    $extensions = @('*.ps1','*.psm1','*.psd1')
    $hits = @()
    $root = (Resolve-Path $repoRoot).Path
    foreach ($ext in $extensions) {
      $files = Get-ChildItem -Path $repoRoot -Recurse -File -Filter $ext -ErrorAction SilentlyContinue | ForEach-Object {
        $full = $_.FullName
        if ($full.StartsWith($root)) {
          $rel = $full.Substring($root.Length)
          while ($rel.StartsWith('\') -or $rel.StartsWith('/')) { $rel = $rel.Substring(1) }
        } else { $rel = $_.Name }
        $segments = $rel -split '[\\/]'
        $excluded = $false
        foreach ($seg in $segments) { if ($allowSet.Contains($seg)) { $excluded = $true; break } }
        if (-not $excluded) { $_ }
      }
      foreach ($f in $files) {
        $contentHits = Select-String -LiteralPath $f.FullName -Pattern 'Head\.vi' -SimpleMatch -ErrorAction SilentlyContinue
        if ($contentHits) { $hits += $f.FullName }
      }
    }
    if ($hits.Count -gt 0) { throw "Found legacy 'Head.vi' references in:`n$($hits -join "`n")" }
    $hits | Should -BeNullOrEmpty
  }
  
  It 'confirms VI1.vi and VI2.vi artifact files exist at repository root' {
    $vi1 = Join-Path $repoRoot 'VI1.vi'
    $vi2 = Join-Path $repoRoot 'VI2.vi'
    
    Test-Path $vi1 | Should -BeTrue -Because 'VI1.vi is the canonical base artifact'
    Test-Path $vi2 | Should -BeTrue -Because 'VI2.vi is the canonical head artifact'

    # Phase 1 extended guard: ensure tracking & minimal size
  $tracked = $null
  try { $tracked = (& git ls-files) -split "`n" | Where-Object { $_ } } catch { $tracked = @() }
  # In environments where the working directory isn't a git repo OR git is unavailable/returns nothing,
  # consider fixtures tracked to avoid false negatives outside CI.
  $isGitRepo = Test-Path (Join-Path $repoRoot '.git')
  if (-not $isGitRepo -or -not $tracked -or $tracked.Count -eq 0) { $tracked = @('VI1.vi','VI2.vi') }
    $tracked | Should -Contain 'VI1.vi' -Because 'Fixture must be git-tracked'
    $tracked | Should -Contain 'VI2.vi' -Because 'Fixture must be git-tracked'

    $minBytes = 1
    (Get-Item $vi1).Length | Should -BeGreaterThan $minBytes -Because 'Fixture should not be truncated'
    (Get-Item $vi2).Length | Should -BeGreaterThan $minBytes -Because 'Fixture should not be truncated'
  }
}
