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
  [ValidateSet('html','xml','text')][string[]]$ReportFormat = 'html',
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
$imagesDir  = Join-Path $OutputDir 'cli-images'

$flagsArray = @()
if ($Flags) { $flagsArray = @($Flags | ForEach-Object { [string]$_ }) }
$reportToken = $null
$repFormatToken = $null
for ($i = 0; $i -lt $flagsArray.Count; $i++) {
  $token = $flagsArray[$i]
  if (-not $token) { continue }
  if ($token -ieq '-report' -and ($i + 1) -lt $flagsArray.Count) {
    $reportToken = $flagsArray[$i + 1]
  }
  if ($token -ieq '-repformat' -and ($i + 1) -lt $flagsArray.Count) {
    $repFormatToken = ([string]$flagsArray[$i + 1]).ToLowerInvariant()
  }
}
$renderReportSwitch = $PSBoundParameters.ContainsKey('RenderReport')
$reportFormatParam = 'html'
if ($ReportFormat -and $ReportFormat.Count -gt 0) {
  $reportFormatParam = ([string]$ReportFormat[$ReportFormat.Count - 1]).ToLowerInvariant()
}
if (-not $PSBoundParameters.ContainsKey('ReportFormat')) {
  $envReportFormat = [System.Environment]::GetEnvironmentVariable('COMPAREVI_REPORT_FORMAT','Process')
  if ($envReportFormat) { $reportFormatParam = $envReportFormat.ToLowerInvariant() }
}
if (-not $repFormatToken) { $repFormatToken = $reportFormatParam }
if (-not $repFormatToken) { $repFormatToken = 'html' }
if (-not $reportToken) {
  $reportExt = switch ($repFormatToken) {
    'xml'  { 'xml' }
    'text' { 'txt' }
    default { 'html' }
  }
  $reportToken = Join-Path $OutputDir ("compare-report.{0}" -f $reportExt)
}
$reportPath = $reportToken

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

if ($renderReportSwitch -or $reportToken -or ($repFormatToken -ne 'html')) {
  switch ($repFormatToken) {
    'xml'  { "<report diff='$diff' />" | Set-Content -LiteralPath $reportPath -Encoding utf8 }
    'text' { "Stub report diff=$diff" | Set-Content -LiteralPath $reportPath -Encoding utf8 }
    default { "<html><body><h1>Stub Report (diff=$diff)</h1></body></html>" | Set-Content -LiteralPath $reportPath -Encoding utf8 }
  }
}
New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0xCA,0xFE,0xBA,0xBE))

$metadata = [ordered]@{
  renderReport = $renderReportSwitch
  reportFlag   = $reportToken
  repFormat    = $repFormatToken
  paramFormat  = $reportFormatParam
  effectiveFormat = $repFormatToken
  reportPath   = $reportPath
}
$metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'report-flags.json') -Encoding utf8

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
    Set-Content -LiteralPath $stubPath -Value $stubContent -Encoding Unicode

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

  $getHistoryManifests = {
    param(
      [Parameter(Mandatory = $true)][string]$RootDir,
      [string]$ModeSlug = 'default'
    )

    $suitePath = Join-Path $RootDir 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $suiteManifest = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $suiteManifest.schema | Should -Be 'vi-compare/history-suite@v1'

    $modeEntry = $suiteManifest.modes | Where-Object { $_.slug -eq $ModeSlug }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue

    $modeManifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{
      SuitePath     = $suitePath
      SuiteManifest = $suiteManifest
      ModeEntry     = $modeEntry
      ModeManifest  = $modeManifest
    }
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
      -FailOnDiff:$false `
      -Mode default `
      -ReportFormat html | Out-Null

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'default' }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json

    $aggregate.stats.processed | Should -Be 1
    $aggregate.stats.diffs | Should -Be 0
    $aggregate.stats.missing | Should -Be 0
    $manifest.schema | Should -Be 'vi-compare/history@v1'
    $manifest.reportFormat | Should -Be 'html'
    $manifest.flags | Should -Contain '-nobd'
    $manifest.flags | Should -Contain '-noattr'
    $manifest.flags | Should -Contain '-nofp'
    $manifest.flags | Should -Contain '-nofppos'
    $manifest.flags | Should -Contain '-nobdcosm'
    $manifest.stats.processed | Should -Be 1
    $manifest.stats.diffs | Should -Be 0
    $manifest.stats.stopReason | Should -Be 'max-pairs'
    $manifest.comparisons.Count | Should -Be 1
    $manifest.comparisons[0].reportFormat | Should -Be 'html'
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

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'default' }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
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

  It 'captures xml report when alternate format requested' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '1'
    try {
      $pair = $_pairs[0]
      $rd = Join-Path $TestDrive 'history-xml'
      & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
        -TargetPath $_target `
        -StartRef $pair.Head `
        -MaxPairs 1 `
        -InvokeScriptPath $_stubPath `
        -ResultsDir $rd `
      -Detailed `
      -ReportFormat xml `
      -FailOnDiff:$false | Out-Null

      $suitePath = Join-Path $rd 'manifest.json'
      Test-Path -LiteralPath $suitePath | Should -BeTrue
      $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
      $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'default' }
      $modeEntry | Should -Not -BeNullOrEmpty
      Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
      $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
      $comparison = $manifest.comparisons[0]
      $comparison.reportFormat | Should -Be 'xml'
      $comparison.result.diff | Should -BeTrue
      $comparison.result.PSObject.Properties['reportHtml'] | Should -Be $null
      $artifactDir = $comparison.result.artifactDir
      [string]::IsNullOrWhiteSpace($artifactDir) | Should -BeFalse
      Test-Path -LiteralPath $artifactDir | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $artifactDir 'compare-report.xml') | Should -BeTrue

      $metaPath = Join-Path $artifactDir 'report-flags.json'
      Test-Path -LiteralPath $metaPath | Should -BeTrue
      $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
      $meta.effectiveFormat | Should -Be 'xml'
      $meta.reportPath | Should -Match '\.xml$'
    }
    finally {
      $env:STUB_COMPARE_DIFF = '0'
    }
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

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'default' }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
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

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'default' }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
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

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'attributes' }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
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

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'front-panel' }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
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

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'block-diagram' }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
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

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $aggregate = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $modeEntry = $aggregate.modes | Where-Object { $_.slug -eq 'all' }
    $modeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $modeEntry.manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $modeEntry.manifestPath -Raw | ConvertFrom-Json
    $manifest.mode | Should -Be 'all'
    $manifest.flags | Should -BeNullOrEmpty
  }

  It 'executes multiple modes and writes per-mode manifests' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '0'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-multi-mode'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Mode 'default,attributes' `
      -FailOnDiff:$false | Out-Null

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $suiteManifest = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $suiteManifest.modes.Count | Should -Be 2
    $defaultEntry = $suiteManifest.modes | Where-Object { $_.slug -eq 'default' }
    $attributeEntry = $suiteManifest.modes | Where-Object { $_.slug -eq 'attributes' }
    $defaultEntry | Should -Not -BeNullOrEmpty
    $attributeEntry | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $defaultEntry.manifestPath | Should -BeTrue
    Test-Path -LiteralPath $attributeEntry.manifestPath | Should -BeTrue

    $defaultManifest = Get-Content -LiteralPath $defaultEntry.manifestPath -Raw | ConvertFrom-Json
    $defaultManifest.mode | Should -Be 'default'
    $attributeManifest = Get-Content -LiteralPath $attributeEntry.manifestPath -Raw | ConvertFrom-Json
    $attributeManifest.mode | Should -Be 'attributes'
  }

  It 'emits GitHub outputs describing aggregate and per-mode manifests' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '0'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-github-output'
    $outputPath = Join-Path $TestDrive 'github-output.txt'
    $summaryPath = Join-Path $TestDrive 'github-summary.md'

    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Mode 'default,attributes' `
      -GitHubOutputPath $outputPath `
      -StepSummaryPath $summaryPath `
      -FailOnDiff:$false | Out-Null

    Test-Path -LiteralPath $outputPath | Should -BeTrue
    $outputLines = Get-Content -LiteralPath $outputPath

    $manifestLine = $outputLines | Where-Object { $_ -like 'manifest-path=*' } | Select-Object -First 1
    $manifestLine | Should -Not -BeNullOrEmpty
    $manifestValue = (($manifestLine -split '=', 2)[1]).Trim()
    $manifestValue | Should -Match 'manifest\.json$'
    Test-Path -LiteralPath $manifestValue | Should -BeTrue

    $modeJsonLine = $outputLines | Where-Object { $_ -like 'mode-manifests-json=*' } | Select-Object -First 1
    $modeJsonLine | Should -Not -BeNullOrEmpty
    $modeJsonValue = (($modeJsonLine -split '=', 2)[1]).Trim()
    $modeSummary = $modeJsonValue | ConvertFrom-Json
    $modeSummary.Count | Should -Be 2

    $bySlug = @{}
    foreach ($entry in $modeSummary) {
      $entry | Should -Not -BeNullOrEmpty
      $entry.mode | Should -Not -BeNullOrEmpty
      $entry.manifest | Should -Not -BeNullOrEmpty
      Test-Path -LiteralPath $entry.manifest | Should -BeTrue
      $entry.resultsDir | Should -Not -BeNullOrEmpty
      $bySlug[$entry.slug] = $entry
    }

    $bySlug.ContainsKey('default') | Should -BeTrue
    $bySlug.ContainsKey('attributes') | Should -BeTrue
    $bySlug['default'].mode | Should -Be 'default'
    $bySlug['attributes'].mode | Should -Be 'attributes'

    $historyMdLine = $outputLines | Where-Object { $_ -like 'history-report-md=*' } | Select-Object -First 1
    $historyMdLine | Should -Not -BeNullOrEmpty
    $historyMdPath = (($historyMdLine -split '=', 2)[1]).Trim()
    Test-Path -LiteralPath $historyMdPath | Should -BeTrue

    $historyHtmlLine = $outputLines | Where-Object { $_ -like 'history-report-html=*' } | Select-Object -First 1
    $historyHtmlLine | Should -Not -BeNullOrEmpty
    $historyHtmlPath = (($historyHtmlLine -split '=', 2)[1]).Trim()
    Test-Path -LiteralPath $historyHtmlPath | Should -BeTrue

    Test-Path -LiteralPath $summaryPath | Should -BeTrue
    $summaryContent = Get-Content -LiteralPath $summaryPath -Raw
    $summaryContent | Should -Match 'VI history report'
    $summaryContent | Should -Match 'history-report.md'
  }

  It 'renders enriched history report with commit metadata and artifact links' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $previousDiff = $env:STUB_COMPARE_DIFF
    try {
      $env:STUB_COMPARE_DIFF = '1'
      $pair = $_pairs[0]
      $rd = Join-Path $TestDrive 'history-report-rich'

      & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
        -TargetPath $_target `
        -StartRef $pair.Head `
        -MaxPairs 1 `
        -InvokeScriptPath $_stubPath `
        -ResultsDir $rd `
        -Mode 'default' `
        -FailOnDiff:$false | Out-Null

      $historyMd = Get-Content -LiteralPath (Join-Path $rd 'history-report.md') -Raw
      $historyMd | Should -Match '\#\# Commit pairs'
      $historyMd | Should -Match '\*\*diff\*\*'
      $historyMd | Should -Match '\[report\]\(\./'
      $historyMd | Should -Match '<sub>.* - .*<\/sub>'
      $historyMd | Should -Match '\#\# Attribute coverage'

      $historyHtml = Get-Content -LiteralPath (Join-Path $rd 'history-report.html') -Raw
      $historyHtml | Should -Match '<h2>Attribute coverage</h2>'
      $historyHtml | Should -Match '<td class="diff-yes">Diff</td>'
    } finally {
      if ($null -eq $previousDiff) {
        Remove-Item Env:STUB_COMPARE_DIFF -ErrorAction SilentlyContinue
      } else {
        $env:STUB_COMPARE_DIFF = $previousDiff
      }
    }
  }

  It 'expands comma-separated mode tokens into multiple entries' {
    if (-not $_pairs) { Set-ItResult -Skipped -Because 'Missing commit data'; return }
    $env:STUB_COMPARE_DIFF = '0'
    $pair = $_pairs[0]
    $rd = Join-Path $TestDrive 'history-multi-token'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repoRoot 'tools/Compare-VIHistory.ps1') `
      -TargetPath $_target `
      -StartRef $pair.Head `
      -MaxPairs 1 `
      -InvokeScriptPath $_stubPath `
      -ResultsDir $rd `
      -Mode 'default,attributes' `
      -FailOnDiff:$false | Out-Null

    $suitePath = Join-Path $rd 'manifest.json'
    Test-Path -LiteralPath $suitePath | Should -BeTrue
    $suiteManifest = Get-Content -LiteralPath $suitePath -Raw | ConvertFrom-Json
    $suiteManifest.modes.Count | Should -Be 2
    $slugs = @($suiteManifest.modes | ForEach-Object { $_.slug })
    $slugs | Should -Contain 'default'
    $slugs | Should -Contain 'attributes'
  }
}

Describe 'Compare-VIHistory source control handling' -Tag 'Integration' {
  BeforeAll {
    $script:RepoRoot = (Get-Location).Path
    $compareScript = Join-Path $script:RepoRoot 'tools' 'Compare-VIHistory.ps1'
    $localConfigPath = Join-Path $script:RepoRoot 'configs' 'labview-paths.local.json'
    $script:CompareScript = $compareScript
    $script:LocalConfigPath = $localConfigPath
    $script:OriginalLocalConfig = $null
    $script:HadLocalConfig = Test-Path -LiteralPath $localConfigPath -PathType Leaf
    if ($script:HadLocalConfig) {
      $script:OriginalLocalConfig = Get-Content -LiteralPath $localConfigPath -Raw
    }
  }

  AfterEach {
    if (Test-Path -LiteralPath $script:LocalConfigPath -PathType Leaf) {
      Remove-Item -LiteralPath $script:LocalConfigPath -Force
    }
  }

  AfterAll {
    if ($script:HadLocalConfig) {
      Set-Content -LiteralPath $script:LocalConfigPath -Value $script:OriginalLocalConfig
    } else {
      if (Test-Path -LiteralPath $script:LocalConfigPath -PathType Leaf) {
        Remove-Item -LiteralPath $script:LocalConfigPath -Force
      }
    }
  }

  It 'emits a warning when SCC is enabled in LabVIEW.ini' {
    $tempRoot = Join-Path $TestDrive 'lv-scc-enabled'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $fakeExe = Join-Path $tempRoot 'LabVIEW.exe'
    Set-Content -LiteralPath $fakeExe -Value '' -Encoding Byte
    $fakeIni = Join-Path $tempRoot 'LabVIEW.ini'
    Set-Content -LiteralPath $fakeIni -Value "SCCUseInLabVIEW=True`nSCCProviderIsActive=True`n"

    @"
{
  "labview": [ "$fakeExe" ]
}
"@ | Set-Content -LiteralPath $script:LocalConfigPath

    $resultsDir = Join-Path $TestDrive 'history-enabled'
    Push-Location $script:RepoRoot
    try {
      $WarningPreference = 'Continue'
      $output = & $script:CompareScript -TargetPath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 1 -ResultsDir $resultsDir -RenderReport 3>&1
      $warnings = $output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }
      $warnings | Should -ContainMatch 'LabVIEW source control is enabled'
    } finally {
      Pop-Location
      if (Test-Path -LiteralPath $resultsDir) { Remove-Item -LiteralPath $resultsDir -Recurse -Force }
    }
  }

  It 'does not emit a warning when SCC is disabled' {
    $tempRoot = Join-Path $TestDrive 'lv-scc-disabled'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $fakeExe = Join-Path $tempRoot 'LabVIEW.exe'
    Set-Content -LiteralPath $fakeExe -Value '' -Encoding Byte
    $fakeIni = Join-Path $tempRoot 'LabVIEW.ini'
    Set-Content -LiteralPath $fakeIni -Value "SCCUseInLabVIEW=False`nSCCProviderIsActive=False`n"

    @"
{
  "labview": [ "$fakeExe" ]
}
"@ | Set-Content -LiteralPath $script:LocalConfigPath

    $resultsDir = Join-Path $TestDrive 'history-disabled'
    Push-Location $script:RepoRoot
    try {
      $WarningPreference = 'Continue'
      $output = & $script:CompareScript -TargetPath 'VI1.vi' -StartRef 'HEAD' -MaxPairs 1 -ResultsDir $resultsDir -RenderReport 3>&1
      $warnings = $output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }
      $warnings | Should -BeNullOrEmpty
    } finally {
      Pop-Location
      if (Test-Path -LiteralPath $resultsDir) { Remove-Item -LiteralPath $resultsDir -Recurse -Force }
    }
  }
}



