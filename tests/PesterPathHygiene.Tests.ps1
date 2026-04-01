Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Pester path hygiene helper' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:repoRoot 'tools/PesterPathHygiene.ps1')
  }

  It 'detects OneDrive-like managed roots as path-hygiene risks' {
    $riskyPath = Join-Path $TestDrive 'OneDrive - Contoso/results'

    $risks = @(Get-PesterPathHygieneRisks -PathValue $riskyPath)

    $risks.Count | Should -BeGreaterThan 0
    $risks[0].id | Should -Be 'onedrive-managed-root'
  }

  It 'relocates risky results and session-lock roots into a safe root' {
    $riskyResults = Join-Path $TestDrive 'OneDrive - Contoso/results'
    $riskyLocks = Join-Path $TestDrive 'OneDrive - Contoso/locks'
    $safeRoot = Join-Path $TestDrive 'safe-root'

    $plan = Resolve-PesterPathHygienePlan -ResultsPath $riskyResults -SessionLockRoot $riskyLocks -Mode relocate -SafeRoot $safeRoot

    $plan.status | Should -Be 'relocated'
    $plan.effectiveResultsPath | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $safeRoot 'results')))
    $plan.effectiveSessionLockRoot | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $safeRoot 'session-lock')))
    @($plan.risks).Count | Should -BeGreaterThan 0
  }

  It 'blocks risky results and session-lock roots when block mode is requested' {
    $riskyResults = Join-Path $TestDrive 'OneDrive - Contoso/results'
    $riskyLocks = Join-Path $TestDrive 'OneDrive - Contoso/locks'
    $safeRoot = Join-Path $TestDrive 'safe-root'

    $plan = Resolve-PesterPathHygienePlan -ResultsPath $riskyResults -SessionLockRoot $riskyLocks -Mode block -SafeRoot $safeRoot

    $plan.status | Should -Be 'path-hygiene-blocked'
    $plan.receiptRoot | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $safeRoot 'blocked-results')))
    $plan.effectiveSessionLockRoot | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $safeRoot 'blocked-session-lock')))
    @($plan.risks | ForEach-Object { $_.id }) | Should -Contain 'onedrive-managed-root'
  }
}
