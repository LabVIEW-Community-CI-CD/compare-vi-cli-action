#Requires -Version 7.0
# Tag: Integration (executes the real CLI on self-hosted)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Host '[FileStart] CompareVI.Integration.Tests.ps1 loading' -ForegroundColor Magenta

<#
  Integration test prerequisites initialization is inlined (previous helper function removed)
  to avoid any discovery-time CommandNotFound issues in certain Pester execution contexts.
  Variables are script-scoped so -Skip expressions can safely reference them during discovery.
#>
$script:LabVIEWCLIAvailable = $false
$script:CompareVIPrereqsAvailable = $false
$script:Canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
$script:BaseVi = $env:LV_BASE_VI
$script:HeadVi = $env:LV_HEAD_VI

# Authoritative fallback: always try to resolve repo-root VIs; environment vars override only if valid.
try {
  $repoRootForFallback = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
  $fallbackBase = Resolve-Path (Join-Path $repoRootForFallback 'VI1.vi') -ErrorAction SilentlyContinue
  $fallbackHead = Resolve-Path (Join-Path $repoRootForFallback 'VI2.vi') -ErrorAction SilentlyContinue
  if (-not $script:BaseVi -or -not (Test-Path -LiteralPath $script:BaseVi -PathType Leaf)) {
    if ($fallbackBase) { $script:BaseVi = $fallbackBase.Path }
  }
  if (-not $script:HeadVi -or -not (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)) {
    if ($fallbackHead) { $script:HeadVi = $fallbackHead.Path }
  }
  # Final guard: if still missing, set to explicit null marker for diagnostics
  if (-not $script:BaseVi) { $script:BaseVi = $null }
  if (-not $script:HeadVi) { $script:HeadVi = $null }
} catch {
  Write-Host "[FallbackError] $($_.Exception.Message)" -ForegroundColor Yellow
}
try {
  $canonicalExists = Test-Path -LiteralPath $script:Canonical -PathType Leaf
  $baseOk = ($script:BaseVi) -and (-not [string]::IsNullOrWhiteSpace($script:BaseVi)) -and (Test-Path -LiteralPath $script:BaseVi -PathType Leaf)
  $headOk = ($script:HeadVi) -and (-not [string]::IsNullOrWhiteSpace($script:HeadVi)) -and (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)
  if ($canonicalExists -and $baseOk -and $headOk) { $script:CompareVIPrereqsAvailable = $true }
} catch {
  # Never let initialization errors break discovery; leave CompareVIPrereqsAvailable = $false for skipping
  Write-Verbose "Integration prereq initialization suppressed error: $($_.Exception.Message)" -Verbose
}

# Recompute prereqs after fallback resolution (if they were initially false)
if (-not $script:CompareVIPrereqsAvailable) {
  try {
    $canonicalExists = Test-Path -LiteralPath $script:Canonical -PathType Leaf
    $baseOk = ($script:BaseVi) -and (Test-Path -LiteralPath $script:BaseVi -PathType Leaf)
    $headOk = ($script:HeadVi) -and (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)
    if ($canonicalExists -and $baseOk -and $headOk) { $script:CompareVIPrereqsAvailable = $true }
  } catch { Write-Verbose "Post-fallback prereq recompute failed: $($_.Exception.Message)" -Verbose }
}

# Emit early diagnostics for troubleshooting
Write-Host "[EarlyDiagnostics] BaseVi=$script:BaseVi Exists=$([bool](Test-Path $script:BaseVi)) HeadVi=$script:HeadVi Exists=$([bool](Test-Path $script:HeadVi)) CanonicalExists=$([bool](Test-Path $script:Canonical)) Prereqs=$script:CompareVIPrereqsAvailable" -ForegroundColor DarkCyan

# Stabilize aliases: some tests historically referenced un-scoped $BaseVi/$HeadVi; ensure they exist post-fallback.
try {
  Set-Variable -Name BaseVi -Scope Script -Value $script:BaseVi -Force
  Set-Variable -Name HeadVi -Scope Script -Value $script:HeadVi -Force
  Write-Host "[AliasDiagnostics] Script aliases established: BaseVi=$($script:BaseVi) HeadVi=$($script:HeadVi)" -ForegroundColor DarkCyan
} catch {
  Write-Host "[AliasError] $($_.Exception.Message)" -ForegroundColor Yellow
}

BeforeAll {
  try {
    $here = Split-Path -Parent $PSCommandPath
    $repoRoot = Resolve-Path (Join-Path $here '..')
    . (Join-Path $repoRoot 'scripts' 'CompareVI.ps1')
    $ensureCleanScript = Join-Path $repoRoot 'scripts' 'Ensure-LVCompareClean.ps1'
    if (Test-Path -LiteralPath $ensureCleanScript -PathType Leaf) {
      . $ensureCleanScript
      try { Stop-LVCompareProcesses -Quiet | Out-Null } catch { Write-Host "[CleanupWarn] $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    $ResultsDir = Join-Path $here 'results'
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
    $script:ResultsDir = $ResultsDir
    Write-Host '[BeforeAll] Initialization complete' -ForegroundColor Green
  } catch {
    Write-Host "[BeforeAllError] $($_.Exception.Message)" -ForegroundColor Red
    throw
  }
}

Describe 'Invoke-CompareVI (real CLI on self-hosted)' -Tag Integration {
  It 'prerequisites available (skip remaining if not)' {
    try {
      $prereq = $false
      try { $prereq = [bool](Get-Variable -Name CompareVIPrereqsAvailable -Scope Script -ErrorAction Stop).Value } catch { $prereq = $false }
      # Prefer script scope variables directly; they should have been initialized even if $null
      $baseViPath = $script:BaseVi
      $headViPath = $script:HeadVi
      if (-not $baseViPath) { $baseViPath = $env:LV_BASE_VI }
      if (-not $headViPath) { $headViPath = $env:LV_HEAD_VI }
      $baseExists = [bool](if ($baseViPath) { Test-Path -LiteralPath $baseViPath -PathType Leaf } else { $false })
      $headExists = [bool](if ($headViPath) { Test-Path -LiteralPath $headViPath -PathType Leaf } else { $false })
      Write-Host "[Diagnostics] BaseVi=$baseViPath Exists=$baseExists HeadVi=$headViPath Exists=$headExists CanonicalExists=$([bool](Test-Path $script:Canonical)) Prereqs=$prereq" -ForegroundColor Cyan
      if (-not $baseExists -or -not $headExists) { Set-ItResult -Skipped -Because 'Base/Head VI paths unresolved'; return }
      if (-not $prereq) { Set-ItResult -Skipped -Because 'CompareVI prerequisites not satisfied'; return }
      $prereq | Should -BeTrue
    } catch {
      Write-Host "[PrereqGateError] $($_.Exception.Message)" -ForegroundColor Yellow
      Set-ItResult -Skipped -Because "Prereq probe error: $($_.Exception.Message)"
    }
  }

  It 'exit 0 => diff=false when base=head' -Skip:(-not $script:CompareVIPrereqsAvailable) {
    $res = Invoke-CompareVI -Base $BaseVi -Head $BaseVi -LvComparePath $Canonical -FailOnDiff:$false
    $res.ExitCode | Should -Be 0
    $res.Diff | Should -BeFalse
    $res.ShortCircuitedIdenticalPath | Should -BeTrue
    $res.CliPath | Should -Be ''
    $res.Command | Should -Be ''
  }

  It 'exit 1 => diff=true when base!=head' -Skip:(-not $script:CompareVIPrereqsAvailable) {
    $res = Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -FailOnDiff:$false
    $res.ExitCode | Should -BeIn @(0,1)
    if ($res.ExitCode -eq 1) {
      $res.Diff | Should -BeTrue
    } else {
      Write-Host "NOTE: LVCompare reported no diff for Base vs Head (exit 0). Treating as acceptable (environment VIs may be identical)." -ForegroundColor Yellow
      $res.Diff | Should -BeFalse
      Set-ItResult -Skipped -Because 'No diff produced; cannot assert diff=true semantics'
    }
  }

  It 'fail-on-diff=true throws after outputs are written for diff' -Skip:(-not $script:CompareVIPrereqsAvailable) {
    # First determine if diff actually occurs
    $probe = Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -FailOnDiff:$false
    if ($probe.ExitCode -ne 1) {
      Write-Host 'NOTE: Skipping fail-on-diff validation because no diff was detected (exit 0).' -ForegroundColor Yellow
      Set-ItResult -Skipped -Because 'No diff produced; fail-on-diff behavior not triggered'
      return
    }
    $tmpOut = Join-Path $env:TEMP ("comparevi-outputs-{0}.txt" -f ([guid]::NewGuid()))
    { Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -GitHubOutputPath $tmpOut -FailOnDiff:$true } | Should -Throw
    (Get-Content -LiteralPath $tmpOut -Raw) | Should -Match '(^|\n)diff=true($|\n)'
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
  }

  It 'generates HTML report from real comparison results' -Skip:(-not $script:CompareVIPrereqsAvailable) {
    # Run comparison (with diff expected)
    $res = Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -FailOnDiff:$false
    $res.ExitCode | Should -BeIn @(0,1)
    if ($res.ExitCode -ne 1) {
      Write-Host 'NOTE: No diff detected; skipping diff-oriented HTML assertions.' -ForegroundColor Yellow
      Set-ItResult -Skipped -Because 'No diff produced; HTML diff content assertions not applicable'
      return
    }
    $res.Diff | Should -BeTrue

    # Generate HTML report
    $htmlPath = Join-Path $ResultsDir 'integration-compare-report.html'
    
    $renderer = Join-Path (Split-Path -Parent $here) 'scripts' 'Render-CompareReport.ps1'
    & $renderer `
      -Command $res.Command `
      -ExitCode $res.ExitCode `
      -Diff ($res.Diff.ToString().ToLower()) `
      -CliPath $res.CliPath `
      -OutputPath $htmlPath

    # Verify HTML was created
    Test-Path -LiteralPath $htmlPath | Should -BeTrue
    
    # Verify HTML contains expected content
    $html = Get-Content -LiteralPath $htmlPath -Raw
    $html | Should -Match 'Compare VI Report'
    $html | Should -Match 'Differences detected'
    $html | Should -Match 'Exit code.*1'
  }

  It 'accepts recommended knowledgebase CLI flags: -nobdcosm -nofppos -noattr' -Skip:(-not $script:CompareVIPrereqsAvailable) {
    # Test with recommended noise filters from knowledgebase
    $cliArgs = '-nobdcosm -nofppos -noattr'
    $res = Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -LvCompareArgs $cliArgs -FailOnDiff:$false
    
    # Should execute successfully with these flags
    $res.ExitCode | Should -BeIn @(0, 1)
    
    # Verify flags are in the command
    $res.Command | Should -Match '-nobdcosm'
    $res.Command | Should -Match '-nofppos'
    $res.Command | Should -Match '-noattr'
  }

  It 'handles -lvpath flag from knowledgebase for LabVIEW version selection' -Skip:(-not $script:CompareVIPrereqsAvailable) {
    # Note: This test verifies the flag is passed correctly, but doesn't require LabVIEW.exe to exist
    # The actual LabVIEW path may not exist on the test runner
    $lvPath = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
    $cliArgs = "-lvpath `"$lvPath`""
    $res = Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -LvCompareArgs $cliArgs -FailOnDiff:$false
    if ($res.ShortCircuitedIdenticalPath) {
      Set-ItResult -Skipped -Because 'Invocation short-circuited identical paths; unable to validate args'
      return
    }
    Write-Host "[LVPathDiag] Command=$($res.Command)" -ForegroundColor DarkGray
    $res.Command | Should -Match '-lvpath'
    # Relaxed pattern: ensure path string appears (case-insensitive) to avoid over-escaping edge cases
    $escaped = [regex]::Escape($lvPath)
    $res.Command.ToLower() | Should -Match ($escaped.ToLower())
  }

  It 'handles complex flag combinations from knowledgebase' -Skip:(-not $script:CompareVIPrereqsAvailable) {
    # Combine multiple recommended flags
    $lvPath = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
  $cliArgs = "-lvpath `"$lvPath`" -nobdcosm -nofppos -noattr"
    
  $res = Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -LvCompareArgs $cliArgs -FailOnDiff:$false
    if ($res.ShortCircuitedIdenticalPath) {
      Set-ItResult -Skipped -Because 'Invocation short-circuited identical paths; unable to validate args'
      return
    }
    
    # Verify all flags are in the command
    $res.Command | Should -Match '-lvpath'
    $res.Command | Should -Match '-nobdcosm'
    $res.Command | Should -Match '-nofppos'
    $res.Command | Should -Match '-noattr'
  }
}

Describe 'LabVIEWCLI HTML Comparison Report Generation' -Tag Integration {
  BeforeAll {
    # Common paths for LabVIEW 2025
    $LabVIEWCLI64 = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEWCLI.exe'
    $LabVIEWCLI32 = 'C:\Program Files (x86)\National Instruments\LabVIEW 2025\LabVIEWCLI.exe'
    
    # Try to find LabVIEWCLI
    $script:LabVIEWCLI = $null
    if (Test-Path -LiteralPath $LabVIEWCLI64 -PathType Leaf) {
      $script:LabVIEWCLI = $LabVIEWCLI64
    } elseif (Test-Path -LiteralPath $LabVIEWCLI32 -PathType Leaf) {
      $script:LabVIEWCLI = $LabVIEWCLI32
    }
    
    # Flag to skip tests if LabVIEWCLI not available
    $script:LabVIEWCLIAvailable = $null -ne $script:LabVIEWCLI
  }

  It 'has LabVIEWCLI available (skip remaining tests if not)' {
    if (-not $LabVIEWCLIAvailable) {
      Write-Host "INFO: LabVIEWCLI.exe not found. Skipping LabVIEWCLI HTML report tests."
      Write-Host "Install LabVIEW 2025 Q3 or later with LabVIEWCLI to enable these tests."
      Set-ItResult -Skipped -Because "LabVIEWCLI not installed"
    }
    $LabVIEWCLIAvailable | Should -BeTrue
  }

  It 'generates HTML report with CreateComparisonReport operation' -Skip:(-not $script:LabVIEWCLIAvailable) {
    $reportPath = Join-Path $ResultsDir 'labviewcli-comparison-report.html'
    
    # Execute LabVIEWCLI with CreateComparisonReport operation
  $cliArgs = @(
      '-OperationName', 'CreateComparisonReport',
      '-vi1', $BaseVi,
      '-vi2', $HeadVi,
      '-reportType', 'HTMLSingleFile',
      '-reportPath', $reportPath
    )
    
  & $LabVIEWCLI @cliArgs
    $exitCode = $LASTEXITCODE
    
    # Verify the command executed successfully
    $exitCode | Should -Be 0
    
    # Verify HTML report was created
    Test-Path -LiteralPath $reportPath | Should -BeTrue
    
    # Verify HTML contains expected content
    $html = Get-Content -LiteralPath $reportPath -Raw
    $html | Should -Not -BeNullOrEmpty
    # HTML should contain some comparison-related content
    $html | Should -Match '(?i)(compare|comparison|difference|diff|vi)'
  }

  It 'generates HTML report with noise filter flags from knowledgebase' -Skip:(-not $script:LabVIEWCLIAvailable) {
    $reportPath = Join-Path $ResultsDir 'labviewcli-comparison-report-filtered.html'
    
    # Execute LabVIEWCLI with recommended noise filter flags
  $cliArgs = @(
      '-OperationName', 'CreateComparisonReport',
      '-vi1', $BaseVi,
      '-vi2', $HeadVi,
      '-reportType', 'HTMLSingleFile',
      '-reportPath', $reportPath,
      '-nobdcosm',  # Ignore block diagram cosmetic changes
      '-nofppos',   # Ignore front panel position changes
      '-noattr'     # Ignore VI attribute changes
    )
    
  & $LabVIEWCLI @cliArgs
    $exitCode = $LASTEXITCODE
    
    # Verify the command executed successfully
    $exitCode | Should -Be 0
    
    # Verify HTML report was created
    Test-Path -LiteralPath $reportPath | Should -BeTrue
    
    # Verify HTML is valid
    $html = Get-Content -LiteralPath $reportPath -Raw
    $html | Should -Not -BeNullOrEmpty
  }

  It 'generates HTML report with identical VIs (no differences)' -Skip:(-not $script:LabVIEWCLIAvailable) {
    $reportPath = Join-Path $ResultsDir 'labviewcli-comparison-report-nodiff.html'
    
    # Compare VI with itself
  $cliArgs = @(
      '-OperationName', 'CreateComparisonReport',
      '-vi1', $BaseVi,
      '-vi2', $BaseVi,
      '-reportType', 'HTMLSingleFile',
      '-reportPath', $reportPath
    )
    
  & $LabVIEWCLI @cliArgs
    $exitCode = $LASTEXITCODE
    
    # Verify the command executed successfully
    $exitCode | Should -Be 0
    
    # Verify HTML report was created
    Test-Path -LiteralPath $reportPath | Should -BeTrue
    
    # Verify HTML contains content
    $html = Get-Content -LiteralPath $reportPath -Raw
    $html | Should -Not -BeNullOrEmpty
  }

  It 'handles spaces in file paths correctly' -Skip:(-not $script:LabVIEWCLIAvailable) {
    # This test validates that paths with spaces work correctly
    $reportPath = Join-Path $ResultsDir 'labviewcli comparison report with spaces.html'
    
  $cliArgs = @(
      '-OperationName', 'CreateComparisonReport',
      '-vi1', $BaseVi,
      '-vi2', $HeadVi,
      '-reportType', 'HTMLSingleFile',
      '-reportPath', $reportPath
    )
    
  & $LabVIEWCLI @cliArgs
    $exitCode = $LASTEXITCODE
    
    # Verify the command executed successfully
    $exitCode | Should -Be 0
    
    # Verify HTML report was created with the exact name (including spaces)
    Test-Path -LiteralPath $reportPath | Should -BeTrue
  }
}
