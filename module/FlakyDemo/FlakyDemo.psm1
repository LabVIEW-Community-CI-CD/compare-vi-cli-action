# FlakyDemo helper module
# Provides convenience functions to exercise flaky test recovery classification
# via Watch-Pester -RerunFailedAttempts.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Enable-FlakyDemoOnce {
    <#
    .SYNOPSIS
        Configure environment so that the next execution of the Flaky.Demo.Tests.ps1 test file
        fails once then passes (recovery scenario) when retried.
    .DESCRIPTION
        Sets ENABLE_FLAKY_DEMO=1 and deletes the state counter file so the next run
        starts at attempt=1 causing the controlled failure. Subsequent retry in the same
        watcher invocation should recover and classify as improved.
    #>
    param()
    $statePath = Join-Path (Resolve-Path .).Path 'tests/results/flaky-demo-state.txt'
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
    $env:ENABLE_FLAKY_DEMO = '1'
    Write-Host "[FlakyDemo] Enabled single-run flaky failure (state reset)." -ForegroundColor Yellow
}

function Disable-FlakyDemo {
    <#
    .SYNOPSIS
        Disable the flaky demo behavior for subsequent runs.
    #>
    param()
    $env:ENABLE_FLAKY_DEMO = '0'
    Write-Host "[FlakyDemo] Disabled flaky demo." -ForegroundColor Yellow
}

function Invoke-FlakyRecoveryDemo {
    <#
    .SYNOPSIS
        Run Watch-Pester once targeting only the FlakyDemo tagged tests with retry attempts.
    .PARAMETER Attempts
        Number of retry attempts for -RerunFailedAttempts.
    .PARAMETER DeltaJsonPath
        Optional path to write delta JSON for inspection.
    #>
    [CmdletBinding()]
    param(
        [int]$Attempts = 2,
        [string]$DeltaJsonPath = 'tests/results/flaky-recovery-delta.json'
    )
    Enable-FlakyDemoOnce
    # Resolve watcher script relative to repo root
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..') | Select-Object -ExpandProperty Path
    $watch = Join-Path $repoRoot 'tools' 'Watch-Pester.ps1'
    if (-not (Test-Path -LiteralPath $watch -PathType Leaf)) { throw "Watch-Pester not found: $watch" }
    Write-Host "[FlakyDemo] Executing Watch-Pester in-process (-RerunFailedAttempts $Attempts)" -ForegroundColor Cyan
    & $watch -SingleRun -Tag FlakyDemo -RerunFailedAttempts $Attempts -DeltaJsonPath $DeltaJsonPath -ShowFailed
    if (Test-Path -LiteralPath $DeltaJsonPath) {
        try {
            $j = Get-Content -LiteralPath $DeltaJsonPath -Raw | ConvertFrom-Json
            Write-Host "[FlakyDemo] Result: status=$($j.status) classification=$($j.classification) recoveredAfter=$($j.flaky.recoveredAfter)" -ForegroundColor Green
        } catch { Write-Warning "[FlakyDemo] Failed to parse delta JSON: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Enable-FlakyDemoOnce,Disable-FlakyDemo,Invoke-FlakyRecoveryDemo
