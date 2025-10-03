Describe 'FixtureWatcher Heartbeat Performance Metrics' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path '.').ProviderPath
    $script:watcherScript = Join-Path $repoRoot 'tools' 'Start-FixtureWatcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) { throw 'Watcher script missing' }
  }

  It 'adds cpuPercent and diskWriteBytesPerSec when -IncludePerfMetrics used' {
    $sandbox = Join-Path $TestDrive 'perf'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    Copy-Item (Join-Path $repoRoot 'VI1.vi') (Join-Path $sandbox 'VI1.vi')
    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $procArgs = @('-NoLogo','-NoProfile','-File',$watcherScript,'-DurationSeconds','7','-HeartbeatSeconds','1','-IncludePerfMetrics','-Quiet','-LogPath',$log)
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList $procArgs
      $deadline = (Get-Date).AddSeconds(8)
      $withPerf = @()
      while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
          $lines = Get-Content $log -ErrorAction SilentlyContinue
          if ($lines) {
            $hb = @($lines | Where-Object { $_ -match '"event":"Heartbeat"' })
            if ($hb.Count -gt 0) {
              $parsed = $hb | ForEach-Object { $_ | ConvertFrom-Json }
              $withPerf = @($parsed | Where-Object { $_.PSObject.Properties.Name -contains 'cpuPercent' -and $_.PSObject.Properties.Name -contains 'diskWriteBytesPerSec' })
              if ($withPerf.Count -gt 0) { break }
            }
          }
        }
        Start-Sleep -Milliseconds 300
      }
      try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
      $withPerf.Count | Should -BeGreaterThan 0
      foreach ($p in $withPerf) {
        ($p.PSObject.Properties.Name -contains 'cpuPercent') | Should -BeTrue
        ($p.PSObject.Properties.Name -contains 'diskWriteBytesPerSec') | Should -BeTrue
      }
    } finally { Pop-Location }
  }
}
