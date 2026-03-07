Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Dev Dashboard CLI' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:cliPath = Join-Path $repoRoot 'tools' 'Dev-Dashboard.ps1'
    $script:samplesRoot = Join-Path $repoRoot 'tools' 'dashboard' 'samples'
  }

  It 'returns snapshot JSON via -Quiet -Json' {
    $output = & $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $script:samplesRoot -Quiet -Json
    $jsonText = $output | Out-String
    $json = $jsonText | ConvertFrom-Json

    $json.Group | Should -Be 'pester-selfhosted'
    $json.Branch | Should -Not -BeNullOrEmpty
    $json.Commit | Should -Not -BeNullOrEmpty
    $json.SessionLock.QueueWaitSeconds | Should -Be 30
    $json.PesterTelemetry.Totals.Failed | Should -Be 1
    $json.PesterTelemetry.SessionStatus | Should -BeNullOrEmpty
    $json.PesterTelemetry.Runner | Should -BeNullOrEmpty
    $json.PesterTelemetry.RuntimeEvents.Dispatcher.Count | Should -Be 2
    $json.PesterTelemetry.RuntimeEvents.Dispatcher.Source | Should -Be 'pester-dispatcher'
    $json.PesterTelemetry.RuntimeEvents.RestWatcher.Count | Should -Be 2
    $json.PesterTelemetry.RuntimeEvents.RestWatcher.Source | Should -Be 'rest-watcher'
    $json.Stakeholders.Channels | Should -Contain 'slack://#ci-selfhosted'
    $json.WatchTelemetry.Last.status | Should -Be 'FAIL'
    $json.WatchTelemetry.History.Count | Should -Be 2
    $json.LabVIEWSnapshot.ProcessCount | Should -Be 1
    $json.LabVIEWSnapshot.LVCompare.Count | Should -Be 1
    $json.CompareOutcome.HistorySuite.ModeCount | Should -Be 2
    $json.CompareOutcome.HistorySuite.Modes[0].Slug | Should -Be 'default'
  }

  It 'writes HTML report when requested' {
    $htmlPath = Join-Path $TestDrive 'dashboard.html'
    & $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $script:samplesRoot -Quiet -Html -HtmlPath $htmlPath | Out-Null

    Test-Path -LiteralPath $htmlPath | Should -BeTrue
    $content = Get-Content -LiteralPath $htmlPath -Raw
    $content | Should -Match '<html'
    $content | Should -Match 'Session Lock'
    $content | Should -Match 'Watch Mode'
    $content | Should -Match 'LabVIEW Snapshot'
    $content | Should -Match 'Runtime Events'
    $content | Should -Match 'dispatcher-events.ndjson'
    $content | Should -Match 'History Suite'
  }

  It 'renders terminal report without throwing' {
    { & $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $script:samplesRoot | Out-Null } | Should -Not -Throw
  }
}
