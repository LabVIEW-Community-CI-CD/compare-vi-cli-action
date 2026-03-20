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

  It 'surfaces runtime event parse warnings to JSON, action items, terminal, and HTML' {
    $resultsRoot = Join-Path $TestDrive 'samples-invalid-events'
    Copy-Item -LiteralPath $script:samplesRoot -Destination $resultsRoot -Recurse -Force
    Add-Content -LiteralPath (Join-Path $resultsRoot 'watcher-events.ndjson') -Value '{ invalid json' -Encoding utf8

    $jsonOutput = & $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $resultsRoot -Quiet -Json
    $json = (($jsonOutput | Out-String) | ConvertFrom-Json)

    $json.PesterTelemetry.RuntimeEvents.RestWatcher.Errors.Count | Should -BeGreaterThan 0
    ($json.ActionItems | Where-Object { $_.Category -eq 'RuntimeEvents' }).Count | Should -BeGreaterThan 0
    (($json.ActionItems | Where-Object { $_.Category -eq 'RuntimeEvents' } | Select-Object -ExpandProperty Message) -join "`n") | Should -Match 'REST Watcher'

    $terminalOutput = (& $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $resultsRoot 6>&1 | Out-String)
    $terminalOutput | Should -Match 'Runtime Events'
    $terminalOutput | Should -Match 'REST Watcher: count=2 present=True'
    $terminalOutput | Should -Match 'Error\s+:'

    $htmlPath = Join-Path $TestDrive 'dashboard-invalid-events.html'
    & $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $resultsRoot -Quiet -Html -HtmlPath $htmlPath | Out-Null
    $html = Get-Content -LiteralPath $htmlPath -Raw
    $html | Should -Match 'Runtime event warnings:'
    $html | Should -Match 'errors=1'
  }

  It 'handles empty session-index watcher and file containers without throwing' {
    $resultsRoot = Join-Path $TestDrive 'samples-empty-runtime-containers'
    Copy-Item -LiteralPath $script:samplesRoot -Destination $resultsRoot -Recurse -Force

    $sessionIndexPath = Join-Path $resultsRoot 'session-index.json'
    $sessionIndex = Get-Content -LiteralPath $sessionIndexPath -Raw | ConvertFrom-Json
    $sessionIndex.files = [pscustomobject]@{}
    $sessionIndex.watchers = [pscustomobject]@{}
    $sessionIndex | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sessionIndexPath -Encoding utf8

    { & $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $resultsRoot -Quiet -Json | Out-Null } | Should -Not -Throw

    $jsonOutput = & $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $resultsRoot -Quiet -Json
    $json = (($jsonOutput | Out-String) | ConvertFrom-Json)
    $json.PesterTelemetry.RuntimeEvents | Should -BeNullOrEmpty
  }

  It 'surfaces custom compare report artifacts in the CLI snapshot' {
    $resultsRoot = Join-Path $TestDrive 'samples-custom-report'
    Copy-Item -LiteralPath $script:samplesRoot -Destination $resultsRoot -Recurse -Force

    $compareDir = Join-Path $resultsRoot 'compare'
    New-Item -ItemType Directory -Path $compareDir -Force | Out-Null
    $reportPath = Join-Path $compareDir 'diff-report-Initialization_UserEvents.vi.html'
    Set-Content -LiteralPath $reportPath -Value '<html></html>' -Encoding utf8
    @'
{
  "schema": "lvcompare-capture-v1",
  "exitCode": 1,
  "seconds": 0.2,
  "environment": {
    "cli": {
      "reportPath": "./diff-report-Initialization_UserEvents.vi.html"
    }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $compareDir 'lvcompare-capture.json') -Encoding utf8

    $jsonOutput = & $script:cliPath -Group 'pester-selfhosted' -ResultsRoot $resultsRoot -Quiet -Json
    $json = (($jsonOutput | Out-String) | ConvertFrom-Json)
    $json.CompareOutcome.ReportPath | Should -Be $reportPath
  }
}
