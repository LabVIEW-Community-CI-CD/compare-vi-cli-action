Describe 'Compare-VIHistory helper' -Tag 'Integration' {
  BeforeAll {
    $ErrorActionPreference = 'Stop'
    try { git --version | Out-Null } catch { throw 'git is required for this test' }

    $repoRoot = (Get-Location).Path
    $target = 'VI1.vi'
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $target))) {
      Set-ItResult -Skipped -Because "Target file not found: $target"
    }

    $revList = & git rev-list --max-count=12 HEAD -- $target
    if (-not $revList) { Set-ItResult -Skipped -Because 'No commit history for target'; return }

    $pairs = @()
    foreach ($head in $revList) {
      $parent = (& git rev-parse "$head^" 2>$null)
      if (-not $parent) { continue }
      $parent = ($parent -split "`n")[0].Trim()
      if (-not $parent) { continue }
      $pairs += [pscustomobject]@{
        Head = $head.Trim()
        Base = $parent
      }
    }
    if (-not $pairs) { Set-ItResult -Skipped -Because 'No parent commit pairs available'; return }

    $stubPath = Join-Path $TestDrive 'Invoke-LVCompare.stub.ps1'
    $stubContent = @'
param(
  [Parameter(Mandatory=$true)][string]$BaseVi,
  [Parameter(Mandatory=$true)][string]$HeadVi,
  [string]$OutputDir,
  [string]$LabVIEWExePath,
  [string]$LVComparePath,
  [string[]]$Flags,
  [switch]$RenderReport,
  [switch]$Quiet,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $OutputDir) {
  $OutputDir = Join-Path $env:TEMP ("history-stub-" + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$exitPath   = Join-Path $OutputDir 'lvcompare-exitcode.txt'
$capturePath= Join-Path $OutputDir 'lvcompare-capture.json'
$reportPath = Join-Path $OutputDir 'compare-report.html'
$imagesDir  = Join-Path $OutputDir 'cli-images'

$diff = if ($env:STUB_COMPARE_DIFF -eq '1') { $true } else { $false }
$exitCode = if ($diff) { 1 } else { 0 }

$stdoutLines = @(
  "Compare stub (diff=$diff)",
  "Base=$BaseVi",
  "Head=$HeadVi"
)
$stdoutLines | Set-Content -LiteralPath $stdoutPath -Encoding utf8
'' | Set-Content -LiteralPath $stderrPath -Encoding utf8
$exitCode.ToString() | Set-Content -LiteralPath $exitPath -Encoding utf8

if ($RenderReport.IsPresent) {
  "<html><body><h1>Stub Report (diff=$diff)</h1></body></html>" | Set-Content -LiteralPath $reportPath -Encoding utf8
}
New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0xCA,0xFE,0xBA,0xBE))

$capture = [ordered]@{
  schema    = 'lvcompare-capture-v1'
  timestamp = (Get-Date).ToString('o')
  base      = $BaseVi
  head      = $HeadVi
  cliPath   = if ($LVComparePath) { $LVComparePath } else { 'C:\Stub\LVCompare.exe' }
  args      = $Flags
  exitCode  = $exitCode
  seconds   = 0.05
  stdoutLen = $stdoutLines.Count
  stderrLen = 0
  command   = ("Stub LVCompare ""{0}"" ""{1}""" -f $BaseVi,$HeadVi)
}
$capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capturePath -Encoding utf8
exit $exitCode
'@
    Set-Content -LiteralPath $stubPath -Value $stubContent -Encoding utf8

    Set-Variable -Name '_repoRoot' -Value $repoRoot -Scope Script
    Set-Variable -Name '_pairs' -Value $pairs -Scope Script
    Set-Variable -Name '_target' -Value $target -Scope Script
    Set-Variable -Name '_stubPath' -Value $stubPath -Scope Script

    $firstParent = & git rev-list --first-parent HEAD
    $commits = @($firstParent | Where-Object { $_ })
    $touchMap = @{}
    foreach ($commit in $commits) {
      $changed = & git diff-tree --no-commit-id --name-only -r $commit -- $target
      $touchMap[$commit] = -not [string]::IsNullOrWhiteSpace($changed)
    }

    $candidateUp = $null
    $recentChange = $null
    foreach ($commit in $commits) {
      if ($touchMap[$commit]) {
        if (-not $recentChange) { $recentChange = $commit }
      } elseif ($recentChange) {
        $candidateUp = [pscustomobject]@{
          start    = $commit
          expected = $recentChange
        }
        break
      }
    }

    $candidateDown = $null
    $firstChange = $null
    foreach ($commit in $commits) {
      if ($touchMap[$commit]) { $firstChange = $commit; break }
    }
    if ($firstChange) {
      foreach ($commit in $commits) {
        if ($commit -eq $firstChange) { break }
        if (-not $touchMap[$commit]) {
          $candidateDown = [pscustomobject]@{
            start    = $commit
            expected = $firstChange
          }
          break
        }
      }
    }

    Set-Variable -Name '_shiftUpCandidate' -Value $candidateUp -Scope Script
    Set-Variable -Name '_shiftDownCandidate' -Value $candidateDown -Scope Script
  }

  AfterAll {
    Remove-Item Env:STUB_COMPARE_DIFF -ErrorAction SilentlyContinue
  }

  It 'produces manifest without artifacts when no diffs detected' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '0'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-no-diff'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Detailed `
      -RenderReport `
      -FailOnDiff:$false `
      -Mode default | Out-Null

    $manifestPath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    $manifest.schema | Should -Be 'vi-compare/history@v1'
    $manifest.flags | Should -Contain '-nobd'
    $manifest.flags | Should -Contain '-noattr'
    $manifest.flags | Should -Contain '-nofp'
    $manifest.flags | Should -Contain '-nofppos'
    $manifest.flags | Should -Contain '-nobdcosm'
    $manifest.stats.processed | Should -Be 1
    $manifest.stats.diffs | Should -Be 0
    $manifest.stats.stopReason | Should -Be 'max-pairs'
    $manifest.comparisons.Count | Should -Be 1
    $manifest.comparisons[0].result.diff | Should -BeFalse
    ($manifest.comparisons[0].result.PSObject.Properties['artifactDir']) | Should -Be $null
  }

  It 'retains artifact directory when the stub reports a diff' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '1'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-diff'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Detailed `
      -RenderReport `
      -FailOnDiff:$false `
      -Mode default | Out-Null

    $manifestPath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    $manifest.stats.diffs | Should -Be 1
    $manifest.flags | Should -Contain '-nobd'
    $manifest.flags | Should -Contain '-noattr'
    $manifest.flags | Should -Contain '-nofp'
    $manifest.flags | Should -Contain '-nofppos'
    $manifest.flags | Should -Contain '-nobdcosm'
    $manifest.stats.lastDiffIndex | Should -Be 1
    $manifest.comparisons[0].result.diff | Should -BeTrue
    $artifactDir = $manifest.comparisons[0].result.artifactDir
    [string]::IsNullOrWhiteSpace($artifactDir) | Should -BeFalse
    Test-Path -LiteralPath $artifactDir | Should -BeTrue
  }

  It 'shifts start ref to the next change when a more recent commit modified the VI' {
    if (-not $_shiftUpCandidate) { Set-ItResult -Skipped -Because 'No suitable ancestor commit without change found'; return }
    $candidate = $_shiftUpCandidate
    $rd = Join-Path $TestDrive 'history-shift-up'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $candidate.start `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Detailed `
      -RenderReport `
      -FailOnDiff:$false | Out-Null

    $manifestPath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.requestedStartRef | Should -Be $candidate.start
    $manifest.startRef | Should -Be $candidate.expected
    $manifest.comparisons.Count | Should -Be 1
    $manifest.comparisons[0].head.ref | Should -Be $candidate.expected
  }

  It 'falls back to the previous change when no newer commits touched the VI' {
    if (-not $_shiftDownCandidate) { Set-ItResult -Skipped -Because 'No suitable descendant commit without change found'; return }
    $candidate = $_shiftDownCandidate
    $rd = Join-Path $TestDrive 'history-shift-down'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $candidate.start `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Detailed `
      -RenderReport `
      -FailOnDiff:$false | Out-Null

    $manifestPath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.requestedStartRef | Should -Be $candidate.start
    $manifest.startRef | Should -Be $candidate.expected
    $manifest.comparisons.Count | Should -BeGreaterThan 0
    $manifest.comparisons[0].head.ref | Should -Be $candidate.expected
  }

  It 'exposes attribute-focused mode when requested' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '0'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-attributes'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Detailed `
      -RenderReport `
      -FailOnDiff:$false `
      -Mode attributes | Out-Null

    $manifestPath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.mode | Should -Be 'attributes'
    ($manifest.flags -contains '-noattr') | Should -BeFalse
    $manifest.flags | Should -Contain '-nobd'
    $manifest.flags | Should -Contain '-nofp'
    $manifest.flags | Should -Contain '-nofppos'
    $manifest.flags | Should -Contain '-nobdcosm'
    $manifest.comparisons.Count | Should -Be 1
    $manifest.comparisons[0].mode | Should -Be 'attributes'
  }

  It 'drops front panel ignores when front-panel mode is selected' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '0'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-frontpanel'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Mode 'front-panel' `
      -FailOnDiff:$false | Out-Null

    $manifestPath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.mode | Should -Be 'front-panel'
    ($manifest.flags -contains '-nofp') | Should -BeFalse
    ($manifest.flags -contains '-nofppos') | Should -BeFalse
    $manifest.flags | Should -Contain '-nobd'
    $manifest.flags | Should -Contain '-noattr'
    $manifest.flags | Should -Contain '-nobdcosm'
  }

  It 'drops block diagram cosmetic ignore when block-diagram mode is selected' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '0'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-blockdiagram'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Mode 'block-diagram' `
      -FailOnDiff:$false | Out-Null

    $manifestPath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.mode | Should -Be 'block-diagram'
    ($manifest.flags -contains '-nobdcosm') | Should -BeFalse
    $manifest.flags | Should -Contain '-nobd'
    $manifest.flags | Should -Contain '-noattr'
    $manifest.flags | Should -Contain '-nofp'
    $manifest.flags | Should -Contain '-nofppos'
  }

  It 'removes all ignore flags when mode is "all"' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '0'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-all-diffs'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Mode 'all' `
      -FailOnDiff:$false | Out-Null

    $manifestPath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.mode | Should -Be 'all'
    $manifest.flags | Should -BeNullOrEmpty
  }
}
