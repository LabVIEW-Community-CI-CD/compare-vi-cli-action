Describe 'FixtureWatcher Heartbeat Process Status' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path '.').ProviderPath
    $script:watcherScript = Join-Path $repoRoot 'tools' 'Start-FixtureWatcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) { throw 'Watcher script missing' }
  }

  It 'adds labviewRunning and lvcompareRunning when -IncludeProcessStatus used' {
    $sandbox = Join-Path $TestDrive 'proc-only'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    Copy-Item (Join-Path $repoRoot 'VI1.vi') (Join-Path $sandbox 'VI1.vi')
    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $procArgs = @('-NoLogo','-NoProfile','-File',$watcherScript,'-DurationSeconds','7','-HeartbeatSeconds','1','-IncludeProcessStatus','-Quiet','-LogPath',$log)
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList $procArgs
      $deadline = (Get-Date).AddSeconds(8)
      $withProc = @()
      while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
          $lines = Get-Content $log -ErrorAction SilentlyContinue
          if ($lines) {
            $hb = @($lines | Where-Object { $_ -match '"event":"Heartbeat"' })
            if ($hb.Count -gt 0) {
              $parsed = $hb | ForEach-Object { $_ | ConvertFrom-Json }
              $withProc = @($parsed | Where-Object { $_.PSObject.Properties.Name -contains 'labviewRunning' -and $_.PSObject.Properties.Name -contains 'lvcompareRunning' })
              if ($withProc.Count -gt 0) { break }
            }
          }
        }
        Start-Sleep -Milliseconds 300
      }
      try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
      $withProc.Count | Should -BeGreaterThan 0
      foreach ($p in $withProc) {
        ($p.PSObject.Properties.Name -contains 'labviewRunning') | Should -BeTrue
        ($p.PSObject.Properties.Name -contains 'lvcompareRunning') | Should -BeTrue
        $p.labviewRunning | Should -BeOfType 'System.Boolean'
        $p.lvcompareRunning | Should -BeOfType 'System.Boolean'
      }
    } finally { Pop-Location }
  }
}
