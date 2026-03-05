Describe 'PrePush-IconEditorScope' {
  BeforeAll {
    $modulePath = Join-Path (Get-Location) 'tools' 'PrePush-IconEditorScope.psm1'
    Import-Module $modulePath -Force
  }

  It 'parses stdin ref update tuples into structured updates' {
    $lines = @(
      'refs/heads/feature aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/heads/feature bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'invalid-line'
    )

    $updates = Get-PrePushRefUpdates -RefUpdateLines $lines
    $updates.Count | Should -Be 1
    $updates[0].LocalRef | Should -Be 'refs/heads/feature'
    $updates[0].LocalOid | Should -Be 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $updates[0].RemoteRef | Should -Be 'refs/heads/feature'
    $updates[0].RemoteOid | Should -Be 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
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

  It 'prefers stdin ref range paths before upstream fallback range' {
    $localOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $remoteOid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $stdinLine = "refs/heads/feature $localOid refs/heads/feature $remoteOid"

    function global:git {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
      $global:LASTEXITCODE = 0
      $command = ($Args -join ' ')
      if ($command -like "*diff --name-only --diff-filter=ACMRTUXB $remoteOid..$localOid*") {
        return @('tools/icon-editor/from-stdin.vi')
      }
      if ($command -like '*diff --name-only --diff-filter=ACMRTUXB origin/develop...HEAD*') {
        return @('docs/fallback-should-not-run.md')
      }
      if ($command -like '*status --porcelain*') {
        return @()
      }
      if ($command -like '*rev-parse --abbrev-ref --symbolic-full-name *@{upstream}*') {
        return @('origin/develop')
      }
      return @()
    }

    try {
      $changedPaths = Get-PrePushChangedPaths -RepoRoot (Get-Location).Path -RefUpdateLines @($stdinLine)
      $changedPaths | Should -Contain 'tools/icon-editor/from-stdin.vi'
      $changedPaths | Should -Not -Contain 'docs/fallback-should-not-run.md'
    } finally {
      Remove-Item Function:\global:git -ErrorAction SilentlyContinue
    }
  }

  It 'falls back to upstream range when stdin range produces no paths' {
    $localOid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $remoteOid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $stdinLine = "refs/heads/feature $localOid refs/heads/feature $remoteOid"

    function global:git {
      param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
      $global:LASTEXITCODE = 0
      $command = ($Args -join ' ')
      if ($command -like "*diff --name-only --diff-filter=ACMRTUXB $remoteOid..$localOid*") {
        return @()
      }
      if ($command -like '*rev-parse --abbrev-ref --symbolic-full-name *@{upstream}*') {
        return @('origin/develop')
      }
      if ($command -like '*diff --name-only --diff-filter=ACMRTUXB origin/develop...HEAD*') {
        return @('docs/fallback.md')
      }
      if ($command -like '*status --porcelain*') {
        return @(' M tools/icon-editor/local-change.vi')
      }
      return @()
    }

    try {
      $changedPaths = Get-PrePushChangedPaths -RepoRoot (Get-Location).Path -RefUpdateLines @($stdinLine)
      $changedPaths | Should -Contain 'docs/fallback.md'
      $changedPaths | Should -Contain 'tools/icon-editor/local-change.vi'
    } finally {
      Remove-Item Function:\global:git -ErrorAction SilentlyContinue
    }
  }
}
