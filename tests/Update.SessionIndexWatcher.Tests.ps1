Describe 'Update-SessionIndexWatcher' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Get-Location).Path
    $script:updateScript = Join-Path $repoRoot 'tools/Update-SessionIndexWatcher.ps1'
    $script:ensureScript = Join-Path $repoRoot 'tools/Ensure-SessionIndex.ps1'

    $newFixture = {
      param([string]$Name)

      $resultsDir = Join-Path $TestDrive $Name
      New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

      $summary = @{
        total = 1
        passed = 1
        failed = 0
        errors = 0
        skipped = 0
        duration_s = 0.1
        schemaVersion = '1.0.0'
      } | ConvertTo-Json
      Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Value $summary -Encoding UTF8

      & $script:ensureScript -ResultsDir $resultsDir -SummaryJson 'pester-summary.json' | Out-Null
      return $resultsDir
    }
    Set-Variable -Name newSessionIndexFixture -Scope Script -Value $newFixture
  }

  It 'merges valid watcher summary into session index' {
    $resultsDir = & $script:newSessionIndexFixture 'watcher-valid'
    $watcherPath = Join-Path $TestDrive 'watcher-valid.json'
    $watcher = @{
      schema = 'ci-watch/rest-v1'
      status = 'completed'
      conclusion = 'success'
      htmlUrl = 'https://example.invalid/run/1'
      polledAtUtc = (Get-Date).ToUniversalTime().ToString('o')
      jobs = @()
    } | ConvertTo-Json
    Set-Content -LiteralPath $watcherPath -Value $watcher -Encoding UTF8

    & $script:updateScript -ResultsDir $resultsDir -WatcherJson $watcherPath

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $idx.watchers.rest.status | Should -Be 'completed'
    $idx.watchers.rest.conclusion | Should -Be 'success'
    $idx.watchers.rest.schema | Should -Be 'ci-watch/rest-v1'
  }

  It 'records watcher event metadata in session index when NDJSON is available' {
    $resultsDir = & $script:newSessionIndexFixture 'watcher-events'
    $watcherPath = Join-Path $TestDrive 'watcher-events.json'
    $eventsPath = Join-Path $TestDrive 'watcher-events.ndjson'
    $watcher = @{
      schema = 'ci-watch/rest-v1'
      status = 'completed'
      conclusion = 'success'
      polledAtUtc = (Get-Date).ToUniversalTime().ToString('o')
      jobs = @()
    } | ConvertTo-Json
    @(
      '{"schema":"comparevi/runtime-event/v1","source":"rest-watcher","phase":"watch-start","level":"info","message":"watching run=1 repo=owner/repo"}',
      '{"schema":"comparevi/runtime-event/v1","source":"rest-watcher","phase":"heartbeat","level":"info","message":"heartbeat"}'
    ) | Set-Content -LiteralPath $eventsPath -Encoding UTF8
    Set-Content -LiteralPath $watcherPath -Value $watcher -Encoding UTF8

    & $script:updateScript -ResultsDir $resultsDir -WatcherJson $watcherPath -WatcherEvents $eventsPath

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $idx.watchers.rest.events.schema | Should -Be 'comparevi/runtime-event/v1'
    $idx.watchers.rest.events.path | Should -Be $eventsPath
    $idx.watchers.rest.events.present | Should -BeTrue
    $idx.watchers.rest.events.count | Should -Be 2
  }

  It 'records missing-file watcher status when watcher json path does not exist' {
    $resultsDir = & $script:newSessionIndexFixture 'watcher-missing'
    $watcherPath = Join-Path $TestDrive 'does-not-exist.json'

    & $script:updateScript -ResultsDir $resultsDir -WatcherJson $watcherPath

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $idx.watchers.rest.status | Should -Be 'missing-file'
    $idx.watchers.rest.conclusion | Should -Be 'watcher-error'
    $idx.watchers.rest.watcherPath | Should -Be $watcherPath
  }

  It 'records invalid-json watcher status when watcher payload is malformed' {
    $resultsDir = & $script:newSessionIndexFixture 'watcher-invalid'
    $watcherPath = Join-Path $TestDrive 'invalid-watcher.json'
    Set-Content -LiteralPath $watcherPath -Value '{ invalid json' -Encoding UTF8

    & $script:updateScript -ResultsDir $resultsDir -WatcherJson $watcherPath

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $idx.watchers.rest.status | Should -Be 'invalid-json'
    $idx.watchers.rest.conclusion | Should -Be 'watcher-error'
    ($idx.watchers.rest.notes | Measure-Object).Count | Should -BeGreaterThan 0
  }
}
