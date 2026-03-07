Describe 'Dev Watcher Manager' -Tag 'Unit' {
  BeforeAll {
    . (Join-Path $PSScriptRoot '_TestPathHelper.ps1')
    Get-Command node -ErrorAction Stop | Out-Null
  }

  It 'ensures watcher and reports enriched status' {
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Ensure -ResultsDir $resultsDir -WarnSeconds 1 -HangSeconds 2 -NoProgressSeconds 0 -PollMs 200 | Out-Null

    $status = $null
    $statusPath = $null
    $maxAttempts = Get-TestIterations -Default 15 -Fast 5
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
      $statusJson = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Status -ResultsDir $resultsDir
      $status = $statusJson | ConvertFrom-Json
      $statusPath = $status.files.status.path
      if ($status.files.status.exists -or (Test-Path -LiteralPath $statusPath)) {
        break
      }
      Invoke-TestSleep -Milliseconds 400 -FastMilliseconds 20
    }

    $status.schema | Should -Be 'dev-watcher/status-v2'
    $status.state | Should -Not -BeNullOrEmpty
    $status.files.status.path | Should -Not -BeNullOrEmpty
    $status.files.heartbeat.path | Should -Not -BeNullOrEmpty
    $status.files.events.path | Should -Not -BeNullOrEmpty
    $status.thresholds | Should -Not -BeNullOrEmpty

    pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Stop -ResultsDir $resultsDir | Out-Null
    Invoke-TestSleep -Milliseconds 200 -FastMilliseconds 20

    $afterStop = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Status -ResultsDir $resultsDir | ConvertFrom-Json
    $afterStop.alive | Should -BeFalse
    $afterStop.files.heartbeat.exists | Should -BeFalse
  }

  It 'records trim metadata and enforces cooldown for auto-trim' {
    $resultsDir = Join-Path $TestDrive 'trim-results'
    $watchDir = Join-Path $resultsDir '_agent' 'watcher'
    New-Item -ItemType Directory -Path $watchDir -Force | Out-Null

    $logPath = Join-Path $watchDir 'watch.out'
    $lineCountPrimary = if (Test-IsFastMode) { 4100 } else { 6000 }
    $payloadPrimary = if (Test-IsFastMode) { 'X' * 2048 } else { 'X' * 980 }
    $writer = [System.IO.StreamWriter]::new($logPath, $false, [System.Text.Encoding]::UTF8)
    try {
      for ($i = 0; $i -lt $lineCountPrimary; $i++) {
        $writer.WriteLine(("Line {0:D4} {1}" -f $i, $payloadPrimary))
      }
    } finally {
      $writer.Dispose()
    }

    $manualOutput = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Trim -ResultsDir $resultsDir
    $manualOutput | Should -Match 'Trimmed watcher logs'

    $metaPath = Join-Path $watchDir 'watcher-trim.json'
    Test-Path -LiteralPath $metaPath | Should -BeTrue
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $meta.lastTrimKind | Should -Be 'manual'
    $meta.trimCount | Should -Be 1
    [double]$meta.lastTrimBytes | Should -BeGreaterThan 0

    $payloadSecondary = if (Test-IsFastMode) { 'Y' * 2048 } else { 'X' * 980 }
    $lineCountSecondary = if (Test-IsFastMode) { 3200 } else { 5000 }
    $appendWriter = [System.IO.StreamWriter]::new($logPath, $true, [System.Text.Encoding]::UTF8)
    try {
      for ($i = 0; $i -lt $lineCountSecondary; $i++) {
        $appendWriter.WriteLine(("LineB {0:D4} {1}" -f $i, $payloadSecondary))
      }
    } finally {
      $appendWriter.Dispose()
    }

    ((Get-Item -LiteralPath $logPath).Length) | Should -BeGreaterThan 5MB

    $statusAfterManual = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -Status -ResultsDir $resultsDir
    ($statusAfterManual | ConvertFrom-Json).autoTrim.eligible | Should -BeFalse

    Invoke-TestSleep -Seconds 3 -FastSeconds 0.2
    $autoOutput = pwsh -NoLogo -NoProfile -File tools/Dev-WatcherManager.ps1 -AutoTrim -ResultsDir $resultsDir -AutoTrimCooldownSeconds 2

    $metaAfter = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $metaAfter.lastTrimKind | Should -Be 'auto'
    $metaAfter.autoTrimCount | Should -Be 1
    $metaAfter.trimCount | Should -Be 2
  }
}
