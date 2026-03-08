Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Resolve-ValidateVIHistoryDispatchPlan' -Tag 'Unit' {
  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'Resolve-ValidateVIHistoryDispatchPlan.ps1'
  }

  It 'enables canonical workflow_dispatch smoke runs by default' {
    $jsonPath = Join-Path $TestDrive 'plan.json'
    $plan = pwsh -NoLogo -NoProfile -File $scriptPath `
      -EventName 'workflow_dispatch' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -HistoryScenarioSet '' `
      -JsonPath $jsonPath | ConvertFrom-Json -Depth 8

    $plan.executeLanes | Should -BeTrue
    $plan.skipReason | Should -Be 'enabled'
    $plan.requestedHistoryScenarioSet | Should -Be 'smoke'
    $plan.historyScenarioSet | Should -Be 'smoke'
  }

  It 'documents non-workflow-dispatch as an explicit no-op reason' {
    $plan = pwsh -NoLogo -NoProfile -File $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' | ConvertFrom-Json -Depth 8

    $plan.executeLanes | Should -BeFalse
    $plan.skipReason | Should -Be 'event-not-workflow-dispatch'
    $plan.historyScenarioSet | Should -Be 'smoke'
  }

  It 'documents noncanonical dispatch without override as disabled' {
    $plan = pwsh -NoLogo -NoProfile -File $scriptPath `
      -EventName 'workflow_dispatch' `
      -Repository 'someone/forked-compare-vi-cli-action' `
      -IsForkRepository:$true `
      -HistoryScenarioSet 'smoke' | ConvertFrom-Json -Depth 8

    $plan.executeLanes | Should -BeFalse
    $plan.skipReason | Should -Be 'noncanonical-disabled'
    $plan.historyScenarioSet | Should -Be 'smoke'
  }

  It 'adds a summary hint for noncanonical dispatch without override' {
    $summaryPath = Join-Path $TestDrive 'summary-noncanonical.md'
    $plan = pwsh -NoLogo -NoProfile -File $scriptPath `
      -EventName 'workflow_dispatch' `
      -Repository 'someone/forked-compare-vi-cli-action' `
      -IsForkRepository:$true `
      -HistoryScenarioSet 'smoke' `
      -StepSummaryPath $summaryPath | ConvertFrom-Json -Depth 8

    $plan.skipReason | Should -Be 'noncanonical-disabled'
    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match 'allow_noncanonical_vi_history=true'
  }

  It 'downgrades noncanonical history-core to smoke when core override is absent' {
    $plan = pwsh -NoLogo -NoProfile -File $scriptPath `
      -EventName 'workflow_dispatch' `
      -Repository 'someone/forked-compare-vi-cli-action' `
      -IsForkRepository:$true `
      -AllowNonCanonical:$true `
      -HistoryScenarioSet 'history-core' | ConvertFrom-Json -Depth 8

    $plan.executeLanes | Should -BeTrue
    $plan.skipReason | Should -Be 'enabled'
    $plan.requestedHistoryScenarioSet | Should -Be 'history-core'
    $plan.historyScenarioSet | Should -Be 'smoke'
    $plan.downgradedHistoryCore | Should -BeTrue
  }

  It 'adds a summary hint when noncanonical history-core is downgraded' {
    $summaryPath = Join-Path $TestDrive 'summary-downgraded.md'
    $plan = pwsh -NoLogo -NoProfile -File $scriptPath `
      -EventName 'workflow_dispatch' `
      -Repository 'someone/forked-compare-vi-cli-action' `
      -IsForkRepository:$true `
      -AllowNonCanonical:$true `
      -HistoryScenarioSet 'history-core' `
      -StepSummaryPath $summaryPath | ConvertFrom-Json -Depth 8

    $plan.downgradedHistoryCore | Should -BeTrue
    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match 'allow_noncanonical_history_core=true'
  }

  It 'treats history_scenario_set=none as an explicit no-op reason' {
    $plan = pwsh -NoLogo -NoProfile -File $scriptPath `
      -EventName 'workflow_dispatch' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -HistoryScenarioSet 'none' | ConvertFrom-Json -Depth 8

    $plan.executeLanes | Should -BeFalse
    $plan.skipReason | Should -Be 'history-scenario-set-none'
    $plan.historyScenarioSet | Should -Be 'none'
  }
}
