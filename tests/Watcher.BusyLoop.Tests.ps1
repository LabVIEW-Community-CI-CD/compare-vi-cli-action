Describe 'Pester Watcher Busy Loop Detection' -Tag 'Unit' {
  BeforeAll {
    $nodeCmd = Get-Command node -ErrorAction Stop
    $scriptRoot = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent $scriptRoot
    $script:WatcherScript = Join-Path $repoRoot 'tools' 'follow-pester-artifacts.mjs'
    $script:NodePath = $nodeCmd.Source
  }

  It 'exits with code 3 when log grows without progress' {
    $resultsDir = Join-Path $TestDrive 'busy-results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $logPath = Join-Path $resultsDir 'pester-dispatcher.log'
    $stdoutPath = Join-Path $TestDrive 'busy.out'
    $stderrPath = Join-Path $TestDrive 'busy.err'

    $arguments = @(
      $script:WatcherScript,
      '--results', $resultsDir,
      '--tail', '0',
      '--warn-seconds', '30',
      '--hang-seconds', '60',
      '--poll-ms', '200',
      '--no-progress-seconds', '2',
      '--exit-on-no-progress'
    )

    $proc = Start-Process -FilePath $script:NodePath -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden

    try {
      Start-Sleep -Milliseconds 200
      for ($i = 0; $i -lt 6; $i++) {
        Add-Content -LiteralPath $logPath -Value "Tick $i" -Encoding utf8
        Start-Sleep -Milliseconds 400
      }
      $exited = $proc.WaitForExit(4000)
      if (-not $exited) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        $proc.WaitForExit()
        throw 'Watcher did not exit on busy loop detection.'
      }
      $proc.ExitCode | Should -Be 3
      $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
      $stderr | Should -Match '\[busy-suspect\]'
    } finally {
      if (-not $proc.HasExited) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        $proc.WaitForExit()
      }
    }
  }

  It 'continues when progress markers are present' {
    $resultsDir = Join-Path $TestDrive 'progress-results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $logPath = Join-Path $resultsDir 'pester-dispatcher.log'
    $stdoutPath = Join-Path $TestDrive 'progress.out'
    $stderrPath = Join-Path $TestDrive 'progress.err'

    $arguments = @(
      $script:WatcherScript,
      '--results', $resultsDir,
      '--tail', '0',
      '--warn-seconds', '30',
      '--hang-seconds', '60',
      '--poll-ms', '200',
      '--no-progress-seconds', '2',
      '--exit-on-no-progress'
    )

    $proc = Start-Process -FilePath $script:NodePath -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden
    try {
      Start-Sleep -Milliseconds 200
      for ($i = 0; $i -lt 4; $i++) {
        Add-Content -LiteralPath $logPath -Value "[-] It progresses $i" -Encoding utf8
        Start-Sleep -Milliseconds 600
      }
      Start-Sleep -Milliseconds 800
    }
    finally {
      if (-not $proc.HasExited) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        $proc.WaitForExit()
      }
    }

    $stderr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    $stderr | Should -Not -Match '\[busy-suspect\]'
  }
}
