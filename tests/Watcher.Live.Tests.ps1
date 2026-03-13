Describe 'Pester Watcher Live Feed' -Tag 'Unit','REQ:WATCHER_LIVE_FEED' {
  BeforeAll {
    . (Join-Path $PSScriptRoot '_TestPathHelper.ps1')
    $nodeCmd = Get-Command node -ErrorAction Stop
    $scriptRoot = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent $scriptRoot
    $script:WatcherScript = Join-Path $repoRoot 'tools' 'follow-pester-artifacts.mjs'
    $script:NodePath = $nodeCmd.Source
  }

  It 'streams log and summary updates while the dispatcher runs' {
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $logPath = Join-Path $resultsDir 'pester-dispatcher.log'
    $summaryPath = Join-Path $resultsDir 'pester-summary.json'
    $stdoutPath = Join-Path $TestDrive 'watcher.out'
    $stderrPath = Join-Path $TestDrive 'watcher.err'
    $statusPath = Join-Path $TestDrive 'watcher-status.json'
    $heartbeatPath = Join-Path $TestDrive 'watcher-heartbeat.json'
    $eventsPath = Join-Path $TestDrive 'watcher-events.ndjson'

    $arguments = @(
      $script:WatcherScript,
      '--results', $resultsDir,
      '--tail', '0',
      '--warn-seconds', '4',
      '--hang-seconds', '6',
      '--poll-ms', '500',
      '--status-file', $statusPath,
      '--heartbeat-file', $heartbeatPath,
      '--events-file', $eventsPath
    )

    $proc = Start-Process -FilePath $script:NodePath -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden
    try {
      Invoke-TestSleep -Milliseconds 250 -FastMilliseconds 120
      Set-Content -LiteralPath $logPath -Value 'Context A' -Encoding utf8
      Invoke-TestSleep -Milliseconds 200 -FastMilliseconds 100
      Set-Content -LiteralPath $summaryPath -Value '{"result":"Running","totals":{"tests":1,"passed":1,"failed":0},"durationSeconds":1}' -Encoding utf8
      Invoke-TestSleep -Milliseconds 200 -FastMilliseconds 100
      Add-Content -LiteralPath $logPath -Value "`nIt done" -Encoding utf8
      $deadline = (Get-Date).AddMilliseconds(2000)
      do {
        Invoke-TestSleep -Milliseconds 150 -FastMilliseconds 80
        $stdoutSnapshot = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
        if ($stdoutSnapshot -match '\[summary\].*Result=') { break }
      } while ((Get-Date) -lt $deadline)
      if (-not (Test-IsFastMode)) {
        $logDeadline = (Get-Date).AddMilliseconds(2000)
        do {
          Invoke-TestSleep -Milliseconds 150 -FastMilliseconds 80
          $stdoutSnapshot = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
          if ($stdoutSnapshot -match '\[log\].*It done') { break }
        } while ((Get-Date) -lt $logDeadline)
      }
    }
    finally {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
      $proc.WaitForExit()
    }

    $stdout = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }

    $stdout | Should -Match '\[watch\] Results directory:'
    $stdout | Should -Match '\[summary\].*Result=Running'
    if (-not (Test-IsFastMode)) {
      $stdout | Should -Match '\[log\].*It done'
    }
    $stderr | Should -BeNullOrEmpty

    Test-Path -LiteralPath $eventsPath | Should -BeTrue
    $events = @(Get-Content -LiteralPath $eventsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    $events.Count | Should -BeGreaterThan 0
    ($events | Where-Object { $_.source -eq 'pester-artifact-watcher' }).Count | Should -BeGreaterThan 0
    ($events | Where-Object { $_.phase -eq 'summary-update' }).Count | Should -BeGreaterThan 0

    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    $status.events.schema | Should -Be 'comparevi/runtime-event/v1'
    $status.events.source | Should -Be 'pester-artifact-watcher'
    $status.events.path | Should -Be $eventsPath
    [int]$status.events.count | Should -BeGreaterThan 0
  }

  It 'exits with code 2 when fail-fast hang detection triggers' {
    $resultsDir = Join-Path $TestDrive 'results-hang'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $logPath = Join-Path $resultsDir 'pester-dispatcher.log'
    $stdoutPath = Join-Path $TestDrive 'watcher-hang.out'
    $stderrPath = Join-Path $TestDrive 'watcher-hang.err'

    $arguments = @(
      $script:WatcherScript,
      '--results', $resultsDir,
      '--tail', '0',
      '--warn-seconds', '1',
      '--hang-seconds', '2',
      '--poll-ms', '200',
      '--exit-on-hang'
    )

    $proc = Start-Process -FilePath $script:NodePath -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden

    Set-Content -LiteralPath $logPath -Value 'Context B' -Encoding utf8
    Invoke-TestSleep -Milliseconds 300 -FastMilliseconds 20
    Add-Content -LiteralPath $logPath -Value "`nStill running" -Encoding utf8

    $exited = $proc.WaitForExit(5000)
    if (-not $exited) {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
      $proc.WaitForExit()
      throw 'Watcher did not exit after hang detection window.'
    }

    $proc.ExitCode | Should -Be 2
    $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    $stderr | Should -Match '\[hang-suspect\]'
  }
}
