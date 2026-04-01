Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Run-PesterExecutionOnly.Local path hygiene' -Tag 'Execution' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:harnessPath = Join-Path $script:repoRoot 'tools/Run-PesterExecutionOnly.Local.ps1'
  }

  It 'blocks unsafe managed roots before dispatch and writes a blocked receipt to the safe root' {
    $tempRoot = Join-Path $TestDrive 'path-hygiene-block'
    $testsDir = Join-Path $tempRoot 'tests'
    $safeRoot = Join-Path $tempRoot 'safe-root'
    $riskyResults = Join-Path $tempRoot 'OneDrive - Contoso/results'
    $riskyLocks = Join-Path $tempRoot 'OneDrive - Contoso/locks'
    New-Item -ItemType Directory -Path $testsDir, $safeRoot -Force | Out-Null

    @'
Describe "Path hygiene block sample" {
  It "would pass if dispatch ran" {
    1 | Should -Be 1
  }
}
'@ | Set-Content -LiteralPath (Join-Path $testsDir 'PathHygiene.Block.Sample.Tests.ps1') -Encoding UTF8

    $output = & pwsh -NoLogo -NoProfile -File $script:harnessPath `
      -TestsPath $testsDir `
      -ResultsPath $riskyResults `
      -SessionLockRoot $riskyLocks `
      -PathHygieneMode block `
      -PathHygieneSafeRoot $safeRoot 2>&1

    $LASTEXITCODE | Should -Be 1 -Because (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $receiptPath = Join-Path $safeRoot 'blocked-results/pester-run-receipt.json'
    Test-Path -LiteralPath $receiptPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $riskyResults | Should -BeFalse
    Test-Path -LiteralPath $riskyLocks | Should -BeFalse

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $receipt.status | Should -Be 'path-hygiene-blocked'
    $receipt.executionJobResult | Should -Be 'skipped'
    $receipt.pathHygieneStatus | Should -Be 'path-hygiene-blocked'
    $receipt.localHarness.pathHygiene.status | Should -Be 'path-hygiene-blocked'
    $receipt.localHarness.pathHygiene.effectiveResultsPath | Should -Be ((Join-Path $safeRoot 'blocked-results') -replace '\\', '/')
    @($receipt.localHarness.pathHygiene.risks | ForEach-Object { $_.id }) | Should -Contain 'onedrive-managed-root'
  }

  It 'relocates unsafe managed roots into the safe root and completes dispatch there' {
    $tempRoot = Join-Path $TestDrive 'path-hygiene-relocate'
    $testsDir = Join-Path $tempRoot 'tests'
    $safeRoot = Join-Path $tempRoot 'safe-root'
    $riskyResults = Join-Path $tempRoot 'OneDrive - Contoso/results'
    $riskyLocks = Join-Path $tempRoot 'OneDrive - Contoso/locks'
    New-Item -ItemType Directory -Path $testsDir, $safeRoot -Force | Out-Null

    @'
Describe "Path hygiene relocate sample" {
  It "passes" {
    1 | Should -Be 1
  }
}
'@ | Set-Content -LiteralPath (Join-Path $testsDir 'PathHygiene.Relocate.Sample.Tests.ps1') -Encoding UTF8

    $output = & pwsh -NoLogo -NoProfile -File $script:harnessPath `
      -TestsPath $testsDir `
      -ResultsPath $riskyResults `
      -SessionLockRoot $riskyLocks `
      -PathHygieneMode relocate `
      -PathHygieneSafeRoot $safeRoot 2>&1

    $LASTEXITCODE | Should -Be 0 -Because (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $effectiveResults = Join-Path $safeRoot 'results'
    $effectiveLocks = Join-Path $safeRoot 'session-lock'
    $receiptPath = Join-Path $effectiveResults 'pester-run-receipt.json'
    Test-Path -LiteralPath $receiptPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $effectiveResults 'pester-summary.json') -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $riskyResults | Should -BeFalse
    Test-Path -LiteralPath $riskyLocks | Should -BeFalse

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $receipt.status | Should -Be 'completed'
    $receipt.pathHygieneStatus | Should -Be 'relocated'
    $receipt.localHarness.pathHygiene.status | Should -Be 'relocated'
    $receipt.localHarness.pathHygiene.requestedResultsPath | Should -Be ($riskyResults -replace '\\', '/')
    $receipt.localHarness.pathHygiene.effectiveResultsPath | Should -Be ($effectiveResults -replace '\\', '/')
    $receipt.localHarness.sessionLockRoot | Should -Be ($effectiveLocks -replace '\\', '/')
    @($receipt.localHarness.pathHygiene.risks | ForEach-Object { $_.id }) | Should -Contain 'onedrive-managed-root'
  }
}
