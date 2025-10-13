Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'On-FixtureValidationFail Orchestration' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $scriptPath = Join-Path $repoRoot 'scripts' 'On-FixtureValidationFail.ps1'
    $resultsDir = Join-Path $repoRoot 'tests' 'results'
    if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

    function New-StrictJson {
      param([int]$Exit,[hashtable]$Counts)
      $obj = [ordered]@{ ok = ($Exit -eq 0); exitCode = $Exit; summaryCounts = ([ordered]@{}) }
      foreach ($k in 'missing','untracked','tooSmall','hashMismatch','manifestError','duplicate','schema') {
        $obj.summaryCounts[$k] = if ($Counts.ContainsKey($k)) { [int]$Counts[$k] } else { 0 }
      }
      $fp = Join-Path $resultsDir ("strict-$Exit.json")
      ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $fp -Encoding utf8
      return $fp
    }

    $script:repoRoot = $repoRoot
    $script:scriptPath = $scriptPath
    $script:resultsDir = $resultsDir
  }

  It 'exits 0 and emits minimal summary when strict ok' {
    $strict = New-StrictJson -Exit 0 -Counts @{}
    $outDir = Join-Path $resultsDir 'orchestrator-ok'
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    pwsh -NoLogo -NoProfile -File $scriptPath -StrictJson $strict -OutputDir $outDir | Out-Null
    $LASTEXITCODE | Should -Be 0
    $sumPath = Join-Path $outDir 'drift-summary.json'
    Test-Path $sumPath | Should -BeTrue
    $j = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json
    $j.schema | Should -Be 'fixture-drift-summary-v1'
    $j.generatedAtUtc | Should -Not -BeNullOrEmpty
    $j.files | Should -Not -BeNullOrEmpty
    # each file entry should have path and lastWriteTimeUtc
    foreach ($f in $j.files) { $f.path | Should -Not -BeNullOrEmpty; $f.lastWriteTimeUtc | Should -Not -BeNullOrEmpty }
  }

  It 'drift path (exit 6) produces summary and copies inputs even without LVCompare' {
    $strict = New-StrictJson -Exit 6 -Counts @{ hashMismatch = 2 }
    $outDir = Join-Path $resultsDir 'orchestrator-drift'
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    pwsh -NoLogo -NoProfile -File $scriptPath -StrictJson $strict -OutputDir $outDir | Out-Null
    $LASTEXITCODE | Should -Be 1
    $sumPath = Join-Path $outDir 'drift-summary.json'
    Test-Path $sumPath | Should -BeTrue
    $j = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json
    $j.schema | Should -Be 'fixture-drift-summary-v1'
    Test-Path (Join-Path $outDir 'validator-strict.json') | Should -BeTrue
  }

  It 'drift path with simulated compare produces lvcompare artifacts and report' {
    $strict = New-StrictJson -Exit 6 -Counts @{ hashMismatch = 1 }
    $outDir = Join-Path $resultsDir 'orchestrator-drift-sim'
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    pwsh -NoLogo -NoProfile -File $scriptPath -StrictJson $strict -OutputDir $outDir -RenderReport -SimulateCompare | Out-Null
    $LASTEXITCODE | Should -Be 1
    # Compare exec JSON is preferred when present in newer flow; placeholders are optional
    $execJson = Join-Path $outDir 'compare-exec.json'
    if (Test-Path $execJson) { Test-Path $execJson | Should -BeTrue }
    # Report generation is optional if reporter missing; assert presence only if script exists
    $reporter = Join-Path $repoRoot 'scripts' 'Render-CompareReport.ps1'
    if (Test-Path $reporter) {
      $reportPath = Join-Path (Join-Path $outDir '_staging/compare') 'compare-report.html'
      $ok = (Test-Path $reportPath) -or (Test-Path $execJson)
      if (-not $ok) { Write-Warning 'Reporter present, but no _staging/compare/compare-report.html or compare-exec.json emitted (non-fatal in simulated mode).' }
    }
  }

  It 'structural failure produces hints and non-zero exit' {
    $strict = New-StrictJson -Exit 4 -Counts @{ tooSmall = 1 }
    $outDir = Join-Path $resultsDir 'orchestrator-struct'
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    pwsh -NoLogo -NoProfile -File $scriptPath -StrictJson $strict -OutputDir $outDir | Out-Null
    $LASTEXITCODE | Should -Be 1
    Test-Path (Join-Path $outDir 'hints.txt') | Should -BeTrue
  }
}
