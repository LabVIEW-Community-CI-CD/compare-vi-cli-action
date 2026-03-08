Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Resolve-ValidateScopePlan' -Tag 'Unit' {
  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'Resolve-ValidateScopePlan.ps1'
  }

  It 'classifies docs or metadata changes as a lightweight no-op scope' {
    $plan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('docs/FIXTURE_DRIFT.md', 'README.md') | ConvertFrom-Json -Depth 10

    $plan.scopeCategory | Should -Be 'docs-metadata-only'
    $plan.lanes.fixtures.run | Should -BeFalse
    $plan.lanes.bundleCertification.run | Should -BeFalse
    $plan.lanes.viHistory.run | Should -BeFalse
  }

  It 'classifies tooling or policy changes as lightweight' {
    $plan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('tools/priority/check-policy.mjs', 'tools/policy/branch-required-checks.json') | ConvertFrom-Json -Depth 10

    $plan.scopeCategory | Should -Be 'tools-policy-only'
    $plan.lanes.fixtures.reason | Should -Be 'tools-policy-only'
    $plan.lanes.bundleCertification.run | Should -BeFalse
    $plan.lanes.viHistory.run | Should -BeFalse
  }

  It 'classifies tool-owned contract tests as tests-only before tools-policy' {
    $plan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('tools/priority/__tests__/validate-scope-routing-contract.test.mjs') | ConvertFrom-Json -Depth 10

    $plan.scopeCategory | Should -Be 'tests-only'
    $plan.classifiedPaths[0].label | Should -Be 'tests-only'
    $plan.lanes.fixtures.reason | Should -Be 'tests-only'
  }

  It 'classifies workflow or CI control-plane changes separately from runtime changes' {
    $plan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('.github/workflows/validate.yml', 'tools/workflows/update_workflows.py') | ConvertFrom-Json -Depth 10

    $plan.scopeCategory | Should -Be 'ci-control-plane'
    $plan.lanes.fixtures.run | Should -BeFalse
    $plan.lanes.bundleCertification.run | Should -BeFalse
    $plan.lanes.viHistory.run | Should -BeFalse
  }

  It 'uses mixed-lightweight for multi-label lightweight-only changes' {
    $plan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('.github/workflows/validate.yml', 'docs/FIXTURE_DRIFT.md', 'tools/policy/branch-required-checks.json') | ConvertFrom-Json -Depth 10

    $plan.scopeCategory | Should -Be 'mixed-lightweight'
    $plan.lanes.fixtures.run | Should -BeFalse
    $plan.lanes.fixtures.reason | Should -Be 'mixed-lightweight'
    $plan.lanes.bundleCertification.run | Should -BeFalse
    $plan.lanes.viHistory.run | Should -BeFalse
  }

  It 'runs fixtures, bundle certification, and VI history for compare engine or history contract changes' {
    $plan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('action.yml', 'tools/Compare-VIHistory.ps1', 'fixtures/vi-stage/control-rename/Base.vi') | ConvertFrom-Json -Depth 10

    $plan.scopeCategory | Should -Be 'compare-engine-history'
    $plan.lanes.fixtures.run | Should -BeTrue
    $plan.lanes.bundleCertification.run | Should -BeTrue
    $plan.lanes.viHistory.run | Should -BeTrue
  }

  It 'runs VI history but skips fixture and bundle work for Docker or VI-history lane changes' {
    $plan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('docker/validate/Dockerfile', 'tools/Test-DockerDesktopFastLoop.ps1') | ConvertFrom-Json -Depth 10

    $plan.scopeCategory | Should -Be 'docker-vi-history'
    $plan.lanes.fixtures.run | Should -BeFalse
    $plan.lanes.bundleCertification.run | Should -BeFalse
    $plan.lanes.viHistory.run | Should -BeTrue
  }

  It 'falls back to full heavy validation for mixed runtime scopes or unclassified paths' {
    $mixedPlan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('tools/Compare-VIHistory.ps1', 'tools/Test-DockerDesktopFastLoop.ps1') | ConvertFrom-Json -Depth 10

    $mixedPlan.scopeCategory | Should -Be 'mixed-runtime'
    $mixedPlan.lanes.fixtures.run | Should -BeTrue
    $mixedPlan.lanes.bundleCertification.run | Should -BeTrue
    $mixedPlan.lanes.viHistory.run | Should -BeTrue

    $unclassifiedPlan = & $scriptPath `
      -EventName 'pull_request' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -ChangedFile @('package.json') | ConvertFrom-Json -Depth 10

    $unclassifiedPlan.scopeCategory | Should -Be 'unclassified'
    $unclassifiedPlan.classifications.unclassifiedPaths | Should -Contain 'package.json'
    $unclassifiedPlan.lanes.fixtures.run | Should -BeTrue
    $unclassifiedPlan.lanes.bundleCertification.run | Should -BeTrue
    $unclassifiedPlan.lanes.viHistory.run | Should -BeTrue
  }

  It 'keeps workflow_dispatch explicit and machine-readable' {
    $summaryPath = Join-Path $TestDrive 'scope-summary.md'
    $plan = & $scriptPath `
      -EventName 'workflow_dispatch' `
      -Repository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
      -StepSummaryPath $summaryPath | ConvertFrom-Json -Depth 10

    $plan.scopeMode | Should -Be 'manual'
    $plan.scopeCategory | Should -Be 'manual-full'
    $plan.lanes.fixtures.reason | Should -Be 'workflow-dispatch-explicit'
    $plan.lanes.bundleCertification.run | Should -BeTrue
    $plan.lanes.viHistory.run | Should -BeTrue
    (Get-Content -LiteralPath $summaryPath -Raw) | Should -Match 'Validate Scope Plan'
  }
}
