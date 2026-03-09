Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Agent Handoff entrypoint contract' -Tag 'Unit' {
  It 'writes a passing status summary for the checked-in handoff entrypoint' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'Test-AgentHandoffEntryPoint.ps1'
    $resultsRoot = Join-Path $TestDrive 'results'

    & pwsh -NoLogo -NoProfile -File $scriptPath -ResultsRoot $resultsRoot | Out-Null

    $statusPath = Join-Path $resultsRoot '_agent/handoff/entrypoint-status.json'
    Test-Path -LiteralPath $statusPath | Should -BeTrue

    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -Depth 6
    $status.schema | Should -Be 'agent-handoff/entrypoint-status-v1'
    $status.status | Should -Be 'pass'
    ($status.actualLineCount -le 80) | Should -BeTrue
    $status.checks.primaryHeading | Should -BeTrue
    $status.checks.lineBudget | Should -BeTrue
    $status.checks.requiredHeadings | Should -BeTrue
    $status.checks.liveArtifactGuidance | Should -BeTrue
    $status.checks.stableEntrypointGuidance | Should -BeTrue
    $status.checks.noStatusLogGuidance | Should -BeTrue
    $status.checks.machineGeneratedArtifactGuidance | Should -BeTrue
    $status.checks.noDatedHistorySections | Should -BeTrue
    $status.commands.bootstrap | Should -Be 'pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1'
    $status.commands.printHandoff | Should -Be 'pwsh -NoLogo -NoProfile -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim'
    $status.artifacts.entrypointStatus | Should -Be 'tests/results/_agent/handoff/entrypoint-status.json'
    $status.artifacts.router | Should -Be 'tests/results/_agent/issue/router.json'
    $status.artifacts.noStandingPriority | Should -Be 'tests/results/_agent/issue/no-standing-priority.json'
    @($status.violations).Count | Should -Be 0
  }
}
