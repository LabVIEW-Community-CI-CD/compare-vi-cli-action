Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Migration Guard (VI1/VI2 naming)' -Tag 'Unit' {
  It 'contains no unintended legacy Base.vi / Head.vi usages' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $allowPathPatterns = @(
      'schemas',
      'Schema.Negative.Tests.ps1',
      'CompareVI.Integration.Tests.ps1',
      'CompareVI.RealCli.SingleRun.Integration.Tests.ps1',
      'CompareLoop.RealCli.SingleIteration.Integration.Tests.ps1',
      'README.md',
      'Generate-PullRequestCompareReport.ps1'
    )
    $allowLinePatterns = @(
      "@\('VI1.vi','Base.vi'\)",
      "@\('VI2.vi','Head.vi'\)",
      'legacy Base.vi / Head.vi',
      'Migration Note',
      '"basePath"\s*:\s*"Base.vi"',
      '"headPath"\s*:\s*"Head.vi"'
    )
  $extensions = '.ps1','.psm1'
  $scanRoots = @((Join-Path $repoRoot.Path 'module'))
  $files = foreach ($root in $scanRoots) { if (Test-Path $root) { Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Extension -in $extensions } } }
    $violations = @()
    foreach ($f in $files) {
      $full = $f.FullName
      $rootPath = $repoRoot.Path
      if ($full.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($rootPath.Length) -replace '^[\\/]',''
      } else { $rel = $full }
      if ($rel -like 'docs/*' -or $rel -like 'tests/*') { continue }
      if ($allowPathPatterns | Where-Object { $rel -like "*$_*" }) { continue }
      $content = Get-Content -LiteralPath $f.FullName -Raw
      if ($content -notmatch 'Base\.vi' -and $content -notmatch 'Head\.vi') { continue }
      $lines = $content -split "`n"
      for ($i=0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match 'Base\.vi' -or $line -match 'Head\.vi') {
          $allowed = $false
          foreach ($pat in $allowLinePatterns) { if ($line -match $pat) { $allowed = $true; break } }
          if (-not $allowed) { $violations += [pscustomobject]@{ File=$rel; Line=$i+1; Content=$line.Trim() } }
        }
      }
    }
    # Threshold: allow up to 0 violations; if any found, surface concise report
    if ($violations.Count -gt 0) {
      $sample = ($violations | Select-Object -First 10 | ForEach-Object { "$($_.File):$($_.Line) -> $($_.Content)" }) -join [Environment]::NewLine
      Write-Host "Legacy naming violations detected (guard intentionally lenient for docs/tests; review needed):`n$sample" -ForegroundColor Yellow
    }
  # Assert zero violations in module production code
  $violations.Count | Should -Be 0
  }
}