Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Update-ReleaseVIHistoryStableMonitoring.ps1' -Tag 'Unit' {
  It 'replaces next-stable placeholder row when present' {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $root 'tools/Update-ReleaseVIHistoryStableMonitoring.ps1'

    $trackerPath = Join-Path $TestDrive 'monitor.md'
    @(
      '# tracker',
      '',
      '| Date (UTC) | Tag | Tag Class | Run URL | Index Job URL | enforcementSource | enforcementMode | rawOutcome | outcome | Notes |',
      '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      '| 2026-03-03 | next-stable-tag | stable | pending-next-stable-run-url | pending-next-stable-index-job-url | migration.tagClassEnforcement.stable | expected-hard | pending | pending | prefilled row |',
      ''
    ) | Set-Content -LiteralPath $trackerPath -Encoding utf8

    $policyPath = Join-Path $TestDrive 'release-vi-history-policy.json'
    @{
      tagClass = 'stable'
      enforcementSource = 'migration.tagClassEnforcement.stable'
      enforcementMode = 'hard'
      rawOutcome = 'pass'
      outcome = 'pass'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $policyPath -Encoding utf8

    $result = & $scriptPath `
      -PolicySummaryPath $policyPath `
      -TrackerPath $trackerPath `
      -Tag 'v0.6.1' `
      -RunId 123456789 `
      -RunUrl 'https://example/run' `
      -IndexJobUrl 'https://example/job' `
      -DateUtc '2026-03-03'

    $result.action | Should -Be 'replaced-placeholder'
    $content = Get-Content -LiteralPath $trackerPath -Raw
    $content | Should -Match '\| 2026-03-03 \| v0\.6\.1 \| stable \| https://example/run \| https://example/job \| migration\.tagClassEnforcement\.stable \| hard \| pass \| pass \| auto-harvested from run 123456789 \|'
    $content | Should -Not -Match 'next-stable-tag'
  }

  It 'appends a new row when placeholder is absent' {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $root 'tools/Update-ReleaseVIHistoryStableMonitoring.ps1'

    $trackerPath = Join-Path $TestDrive 'monitor.md'
    @(
      '# tracker',
      '',
      '| Date (UTC) | Tag | Tag Class | Run URL | Index Job URL | enforcementSource | enforcementMode | rawOutcome | outcome | Notes |',
      '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      '| 2026-02-28 | v0.6.0 | stable | https://example/old-run | https://example/old-job | migration.tagClassEnforcement.stable | hard | pass | pass | prior cycle |',
      ''
    ) | Set-Content -LiteralPath $trackerPath -Encoding utf8

    $policyPath = Join-Path $TestDrive 'release-vi-history-policy.json'
    @{
      tagClass = 'stable'
      enforcementSource = 'migration.tagClassEnforcement.stable'
      enforcementMode = 'hard'
      rawOutcome = 'pass'
      outcome = 'pass'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $policyPath -Encoding utf8

    $result = & $scriptPath `
      -PolicySummaryPath $policyPath `
      -TrackerPath $trackerPath `
      -Tag 'v0.6.2' `
      -RunId 22334455 `
      -RunUrl 'https://example/new-run' `
      -IndexJobUrl 'https://example/new-job' `
      -DateUtc '2026-03-10'

    $result.action | Should -Match 'appended'
    $content = Get-Content -LiteralPath $trackerPath -Raw
    $content | Should -Match '\| 2026-03-10 \| v0\.6\.2 \| stable \| https://example/new-run \| https://example/new-job \| migration\.tagClassEnforcement\.stable \| hard \| pass \| pass \| auto-harvested from run 22334455 \|'
  }

  It 'emits PR comment body when requested' {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $root 'tools/Update-ReleaseVIHistoryStableMonitoring.ps1'

    $trackerPath = Join-Path $TestDrive 'monitor.md'
    @(
      '# tracker',
      '',
      '| Date (UTC) | Tag | Tag Class | Run URL | Index Job URL | enforcementSource | enforcementMode | rawOutcome | outcome | Notes |',
      '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
      '| 2026-03-03 | next-stable-tag | stable | pending-next-stable-run-url | pending-next-stable-index-job-url | migration.tagClassEnforcement.stable | expected-hard | pending | pending | prefilled row |',
      ''
    ) | Set-Content -LiteralPath $trackerPath -Encoding utf8

    $policyPath = Join-Path $TestDrive 'release-vi-history-policy.json'
    @{
      tagClass = 'stable'
      enforcementSource = 'migration.tagClassEnforcement.stable'
      enforcementMode = 'hard'
      rawOutcome = 'pass'
      outcome = 'pass'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $policyPath -Encoding utf8

    $commentBodyPath = Join-Path $TestDrive 'comment.md'

    $result = & $scriptPath `
      -PolicySummaryPath $policyPath `
      -TrackerPath $trackerPath `
      -Tag 'v0.6.3' `
      -RunId 55667788 `
      -RunUrl 'https://example/stable-run' `
      -IndexJobUrl 'https://example/stable-job' `
      -DateUtc '2026-03-20' `
      -EmitPrCommentBody `
      -CommentBodyPath $commentBodyPath

    $result.commentBodyPath | Should -Be $commentBodyPath
    Test-Path -LiteralPath $commentBodyPath | Should -BeTrue
    $comment = Get-Content -LiteralPath $commentBodyPath -Raw
    $comment | Should -Match 'Stable enforcement monitoring row updated\.'
    $comment | Should -Match 'v0\.6\.3'
    $comment | Should -Match 'enforcementMode: `hard`'
  }
}