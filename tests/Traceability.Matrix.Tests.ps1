Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Traceability matrix builder' -Tag 'Unit' {
  It 'aggregates annotations and results into trace-matrix.json' {
    $root = Join-Path $TestDrive 'trace-matrix'
    New-Item -ItemType Directory -Path $root | Out-Null

    $toolsDir = Join-Path $root 'tools'
    New-Item -ItemType Directory -Path $toolsDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..' 'tools' 'Traceability-Matrix.ps1') -Destination $toolsDir -Force

    $docsReqDir = Join-Path $root 'docs/requirements'
    New-Item -ItemType Directory -Path $docsReqDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $docsReqDir 'REQ_ONE.md') -Value "# Requirement One`nDetails" -Encoding utf8
    Set-Content -LiteralPath (Join-Path $docsReqDir 'REQ_TWO.md') -Value "# Requirement Two`nUncovered" -Encoding utf8

    $docsAdrDir = Join-Path $root 'docs/adr'
    New-Item -ItemType Directory -Path $docsAdrDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $docsAdrDir '0001-sample.md') -Value "# ADR 0001`nDecision text" -Encoding utf8

    $testsDir = Join-Path $root 'tests'
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
    $sampleRequirementId = 'REQ_ONE'
    $unknownRequirementId = 'REQ_UNKNOWN'
    $sampleTest = @"
Describe 'Sample' -Tag 'Unit','REQ:$sampleRequirementId','ADR:0001' {
  It 'is covered' { 1 | Should -Be 1 }
}
"@
    Set-Content -LiteralPath (Join-Path $testsDir 'Sample.Tests.ps1') -Value $sampleTest -Encoding utf8

    $traceHeader = ('#' + ' trace: req=' + $unknownRequirementId)
    $orphanTest = @(
      $traceHeader
      "Describe 'Unknown coverage' -Tag 'Unit' {"
      "  It 'has no results' { 1 | Should -Be 1 }"
      "}"
      ''
    ) -join "`n"
    Set-Content -LiteralPath (Join-Path $testsDir 'Orphan.Tests.ps1') -Value $orphanTest -Encoding utf8

    $resultsDir = Join-Path $root 'tests/results/pester/Sample-Tests-ps1'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<test-results>
  <test-suite>
    <results>
      <test-case name="Sample::is covered" result="Passed" time="0.10" />
    </results>
  </test-suite>
</test-results>
"@
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-results.xml') -Value $xml -Encoding utf8

    Push-Location $root
    try {
      pwsh -NoLogo -NoProfile -File ./tools/Traceability-Matrix.ps1 -TestsPath 'tests' -ResultsRoot 'tests/results' | Out-Null
    } finally {
      Pop-Location
    }

    $jsonPath = Join-Path $root 'tests/results/_trace/trace-matrix.json'
    Test-Path -LiteralPath $jsonPath | Should -BeTrue
    $matrix = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json

    $matrix.summary.files.total | Should -Be 2
    $matrix.tests | Where-Object { $_.file -eq 'tests/Sample.Tests.ps1' } | Select-Object -First 1 | ForEach-Object { $_.status } | Should -Be 'Passed'
    $matrix.tests | Where-Object { $_.file -eq 'tests/Orphan.Tests.ps1' } | Select-Object -First 1 | ForEach-Object { $_.status } | Should -Be 'Unknown'

    $matrix.requirements.REQ_ONE.tests.Count | Should -Be 1
    $matrix.requirements.REQ_ONE.status      | Should -Be 'Passed'
    $matrix.requirements.REQ_TWO.status      | Should -Be 'Unknown'
    $matrix.requirements.REQ_UNKNOWN.title   | Should -Match 'Unknown requirement'

    $matrix.gaps.requirementsWithoutTests | Should -Contain 'REQ_TWO'
    $matrix.gaps.testsWithoutRequirements | Should -Contain 'tests/Orphan.Tests.ps1'
  }

  It 'does not report the repo traceability fixture IDs as production unknowns or uncovered requirements' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $resultsRoot = Join-Path $TestDrive 'repo-trace-results'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    Push-Location $repoRoot
    try {
      pwsh -NoLogo -NoProfile -File ./tools/Traceability-Matrix.ps1 -TestsPath 'tests' -ResultsRoot $resultsRoot | Out-Null
    } finally {
      Pop-Location
    }

    $jsonPath = Join-Path $resultsRoot '_trace/trace-matrix.json'
    Test-Path -LiteralPath $jsonPath | Should -BeTrue
    $matrix = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json

    @($matrix.gaps.unknownRequirementIds) | Should -Not -Contain 'REQ_ONE'
    @($matrix.gaps.unknownRequirementIds) | Should -Not -Contain 'REQ_UNKNOWN'

    foreach ($requirementId in @(
      'DOTNET_CLI_POWERSHELL_MAPPING',
      'DOTNET_CLI_RELEASE_ASSET',
      'DOTNET_CLI_RELEASE_CHECKLIST',
      'INDEX',
      'PESTER_SINGLE_INVOKER',
      'SINGLE_INVOKER_SYSTEM_DEFINITION',
      'WATCH_AND_QUEUE',
      'WATCHER_BUSY_LOOP',
      'WATCHER_LIVE_FEED'
    )) {
      @($matrix.gaps.requirementsWithoutTests) | Should -Not -Contain $requirementId
    }
  }
}
