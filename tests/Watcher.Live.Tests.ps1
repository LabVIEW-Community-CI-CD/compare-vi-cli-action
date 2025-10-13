Describe 'Pester Watcher Live Feed' -Tag 'Unit' {
  BeforeAll {
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

    $arguments = @(
      $script:WatcherScript,
      '--results', $resultsDir,
      '--tail', '0',
      '--warn-seconds', '4',
      '--hang-seconds', '6',
      '--poll-ms', '500'
    )

    $proc = Start-Process -FilePath $script:NodePath -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden
    try {
      Start-Sleep -Milliseconds 250
      Set-Content -LiteralPath $logPath -Value 'Context A' -Encoding utf8
      Start-Sleep -Milliseconds 200
      Set-Content -LiteralPath $summaryPath -Value '{"result":"Running","totals":{"tests":1,"passed":1,"failed":0},"durationSeconds":1}' -Encoding utf8
      Start-Sleep -Milliseconds 200
      Add-Content -LiteralPath $logPath -Value "`nIt done" -Encoding utf8
      Start-Sleep -Milliseconds 500
    }
    finally {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
      $proc.WaitForExit()
    }

    $stdout = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }

    $stdout | Should -Match '\[watch\] Results directory:'
    $stdout | Should -Match '\[summary\].*Result=Running'
    $stdout | Should -Match '\[log\].*It done'
    $stderr | Should -BeNullOrEmpty
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
    Start-Sleep -Milliseconds 300
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
