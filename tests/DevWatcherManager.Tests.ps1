Describe 'Dev Watcher Manager' -Tag 'Unit' {
  BeforeAll {
    Get-Command node -ErrorAction Stop | Out-Null
  }

  It 'ensures watcher and reports enriched status' {
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Ensure -ResultsDir $resultsDir -WarnSeconds 1 -HangSeconds 2 -NoProgressSeconds 0 -PollMs 200 | Out-Null

    $status = $null
    $statusPath = $null
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
      $statusJson = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Status -ResultsDir $resultsDir
      $status = $statusJson | ConvertFrom-Json
      $statusPath = $status.files.status.path
      if ($status.files.status.exists -or (Test-Path -LiteralPath $statusPath)) {
        break
      }
      Start-Sleep -Milliseconds 400
    }

    $status.schema | Should -Be 'dev-watcher/status-v2'
    $status.state | Should -Not -BeNullOrEmpty
    $status.files.status.path | Should -Not -BeNullOrEmpty
    $status.files.heartbeat.path | Should -Not -BeNullOrEmpty
    $status.thresholds | Should -Not -BeNullOrEmpty

    pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Stop -ResultsDir $resultsDir | Out-Null
    Start-Sleep -Milliseconds 200

    $afterStop = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Status -ResultsDir $resultsDir | ConvertFrom-Json
    $afterStop.alive | Should -BeFalse
    $afterStop.files.heartbeat.exists | Should -BeFalse
  }

  It 'records trim metadata and enforces cooldown for auto-trim' {
    $resultsDir = Join-Path $TestDrive 'trim-results'
    $watchDir = Join-Path $resultsDir '_agent' 'watcher'
    New-Item -ItemType Directory -Path $watchDir -Force | Out-Null

    $logPath = Join-Path $watchDir 'watch.out'
    $payload = 'X' * 980
    for ($i = 0; $i -lt 6000; $i++) {
      Add-Content -LiteralPath $logPath -Value ("Line {0:D4} {1}" -f $i, $payload) -Encoding utf8
    }

    $manualOutput = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Trim -ResultsDir $resultsDir
    $manualOutput | Should -Match 'Trimmed watcher logs'

    $metaPath = Join-Path $watchDir 'watcher-trim.json'
    Test-Path -LiteralPath $metaPath | Should -BeTrue
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $meta.lastTrimKind | Should -Be 'manual'
    $meta.trimCount | Should -Be 1
    [double]$meta.lastTrimBytes | Should -BeGreaterThan 0

    for ($i = 0; $i -lt 5000; $i++) {
      Add-Content -LiteralPath $logPath -Value ("LineB {0:D4} {1}" -f $i, $payload) -Encoding utf8
    }

    ((Get-Item -LiteralPath $logPath).Length) | Should -BeGreaterThan 5MB

    $statusAfterManual = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Status -ResultsDir $resultsDir
    ($statusAfterManual | ConvertFrom-Json).autoTrim.eligible | Should -BeFalse

    Start-Sleep -Seconds 3
    $autoOutput = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -AutoTrim -ResultsDir $resultsDir -AutoTrimCooldownSeconds 2

    $metaAfter = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $metaAfter.lastTrimKind | Should -Be 'auto'
    $metaAfter.autoTrimCount | Should -Be 1
    $metaAfter.trimCount | Should -Be 2
  }
}
