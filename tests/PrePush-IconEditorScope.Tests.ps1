Describe 'PrePush-IconEditorScope' {
  BeforeAll {
    $modulePath = Join-Path (Get-Location) 'tools' 'PrePush-IconEditorScope.psm1'
    Import-Module $modulePath -Force
  }

  It 'requires fixture checks when icon-editor paths are changed' {
    $changedPaths = @(
      'tools/icon-editor/Update-IconEditorFixtureReport.ps1',
      'README.md'
    )

    $shouldRun = Test-IconEditorFixtureCheckRequired -ChangedPaths $changedPaths
    $shouldRun | Should -BeTrue
  }

  It 'skips fixture checks when no icon-editor scoped paths are changed' {
    $changedPaths = @(
      'tools/priority/sync-standing-priority.mjs',
      'docs/INTEGRATION_RUNBOOK.md'
    )

    $shouldRun = Test-IconEditorFixtureCheckRequired -ChangedPaths $changedPaths
    $shouldRun | Should -BeFalse
  }

  It 'allows explicit force override' {
    $shouldRun = Test-IconEditorFixtureCheckRequired -ChangedPaths @() -Force
    $shouldRun | Should -BeTrue
  }
}

