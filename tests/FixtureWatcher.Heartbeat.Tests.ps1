Describe 'FixtureWatcher Heartbeat' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path '.').ProviderPath
    $script:watcherScript = Join-Path $repoRoot 'tools' 'Start-FixtureWatcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) { throw 'Watcher script missing' }
  }

  It 'emits at least one Heartbeat event when -HeartbeatSeconds specified' {
    # Sandbox with copies of fixtures to avoid interference
    $sandbox = Join-Path $TestDrive 'hb'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'VI1.vi') -Destination (Join-Path $sandbox 'VI1.vi')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'VI2.vi') -Destination (Join-Path $sandbox 'VI2.vi')
    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList @('-NoLogo','-NoProfile','-File',$watcherScript,'-DurationSeconds','6','-HeartbeatSeconds','1','-Quiet','-LogPath',$log)
      # Wait for at least one heartbeat or timeout
      $deadline = (Get-Date).AddSeconds(7)
      $hb = @()
      while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
          $lines = Get-Content -LiteralPath $log -ErrorAction SilentlyContinue
          if ($lines) { $hb = @($lines | Where-Object { $_ -match '"event":"Heartbeat"' }) }
          if ($hb.Count -gt 0) { break }
        }
        Start-Sleep -Milliseconds 300
      }
      try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
      $hb.Count | Should -BeGreaterThan 0
      $first = ($hb | Select-Object -First 1) | ConvertFrom-Json
      $first.schema | Should -Be 'fixture-watch-log-v1'
      $first.event | Should -Be 'Heartbeat'
      $first.name | Should -Match 'VI[12]\.vi'
    } finally { Pop-Location }
  }
}
