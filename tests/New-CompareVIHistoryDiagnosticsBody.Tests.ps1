Describe 'New-CompareVIHistoryDiagnosticsBody.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:scriptPath = Join-Path $script:repoRoot 'tools' 'New-CompareVIHistoryDiagnosticsBody.ps1'
  }

  It 'renders a concrete comment-gated body without literal env placeholders' {
    $body = & $script:scriptPath `
      -Variant comment-gated `
      -ActionRef 'LabVIEW-Community-CI-CD/comparevi-history@v1.0.4' `
      -IssueNumber '2' `
      -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' `
      -ContainerImage 'nationalinstruments/labview:2026q1-linux' `
      -RequestedModes 'attributes,front-panel,block-diagram' `
      -ExecutedModes 'attributes,front-panel,block-diagram' `
      -TotalProcessed '3' `
      -TotalDiffs '2' `
      -StepConclusion 'success' `
      -IsFork 'True' `
      -RunUrl 'https://github.com/example/repo/actions/runs/123' `
      -ModeSummaryMarkdown '| Mode | Diffs |'

    $body | Should -Match 'comparevi-history diagnostics finished for PR #2\.'
    $body | Should -Match 'Step conclusion: `success`'
    $body | Should -Match 'Run: https://github.com/example/repo/actions/runs/123'
    $body | Should -Not -Match '\$env:ACTION_REF|\$env:REQUESTED_MODES'
  }

  It 'renders a manual body with results dir instead of step conclusion' {
    $body = & $script:scriptPath `
      -Variant manual `
      -ActionRef 'LabVIEW-Community-CI-CD/comparevi-history@v1' `
      -PullRequestNumber '9' `
      -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' `
      -ContainerImage 'nationalinstruments/labview:2026q1-linux' `
      -RequestedModes 'attributes,front-panel,block-diagram' `
      -ExecutedModes 'attributes,front-panel,block-diagram' `
      -TotalProcessed '3' `
      -TotalDiffs '2' `
      -ResultsDir 'tests/results/pr-diagnostics/history' `
      -IsFork 'False' `
      -RunUrl 'https://github.com/example/repo/actions/runs/456' `
      -ModeSummaryMarkdown '| Mode | Diffs |'

    $body | Should -Match 'comparevi-history manual diagnostics finished for PR #9\.'
    $body | Should -Match 'Results dir: `tests/results/pr-diagnostics/history`'
    $body | Should -Not -Match 'Step conclusion'
  }

  It 'honors a custom opening sentence and fills missing optional fields with n/a' {
    $body = & $script:scriptPath `
      -Variant manual `
      -ActionRef 'LabVIEW-Community-CI-CD/comparevi-history@v1' `
      -OpeningSentence 'Mode-specific diagnostics ready for review.'

    $body | Should -Match 'Mode-specific diagnostics ready for review\.'
    $body | Should -Match 'Target path: `n/a`'
    $body | Should -Match 'Requested modes: `n/a`'
    $body | Should -Match 'Results dir: `n/a`'
    $body | Should -Match 'Mode coverage'
  }
}
