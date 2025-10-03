Describe 'FixtureWatcher Initial State Emission' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path '.').ProviderPath
    $script:watcherScript = Join-Path $repoRoot 'tools' 'Start-FixtureWatcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) { throw 'Watcher script missing' }
  }

  It 'emits Initial events for each target by default' {
    $sandbox = Join-Path $TestDrive 'init-default'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    Copy-Item (Join-Path $repoRoot 'VI1.vi') (Join-Path $sandbox 'VI1.vi')
    Copy-Item (Join-Path $repoRoot 'VI2.vi') (Join-Path $sandbox 'VI2.vi')
    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList @('-NoLogo','-NoProfile','-File',$watcherScript,'-DurationSeconds','2','-Quiet','-LogPath',$log)
      $deadline = (Get-Date).AddSeconds(3)
      $initial = @()
      while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
          $lines = Get-Content $log -ErrorAction SilentlyContinue
          if ($lines) { $initial = @($lines | Where-Object { $_ -match '"event":"Initial"' }) }
          if ($initial.Count -ge 2) { break }
        }
        Start-Sleep -Milliseconds 200
      }
      try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
      $initial.Count | Should -BeGreaterOrEqual 2
    } finally { Pop-Location }
  }

  It 'suppresses Initial events when -IncludeInitialState:false specified' {
    $sandbox = Join-Path $TestDrive 'init-disabled'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    Copy-Item (Join-Path $repoRoot 'VI1.vi') (Join-Path $sandbox 'VI1.vi')
    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList @('-NoLogo','-NoProfile','-File',$watcherScript,'-IncludeInitialState:$false','-DurationSeconds','2','-Quiet','-LogPath',$log)
      Start-Sleep -Seconds 3
      try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
      $lines = if (Test-Path $log) { Get-Content $log } else { @() }
      ($lines | Where-Object { $_ -match '"event":"Initial"' }).Count | Should -Be 0
    } finally { Pop-Location }
  }

  It 'emits Initial then exits immediately with -Once' {
    $sandbox = Join-Path $TestDrive 'init-once'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    Copy-Item (Join-Path $repoRoot 'VI1.vi') (Join-Path $sandbox 'VI1.vi')
    Copy-Item (Join-Path $repoRoot 'VI2.vi') (Join-Path $sandbox 'VI2.vi')
    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $start = Get-Date
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList @('-NoLogo','-NoProfile','-File',$watcherScript,'-Once','-Quiet','-LogPath',$log)
      $proc.WaitForExit()
      $elapsed = (Get-Date) - $start
      $elapsed.TotalSeconds | Should -BeLessThan 5
      $lines = if (Test-Path $log) { Get-Content $log } else { @() }
      ($lines | Where-Object { $_ -match '"event":"Initial"' }).Count | Should -BeGreaterOrEqual 2
      ($lines | Where-Object { $_ -match '"event":"Heartbeat"' }).Count | Should -Be 0
    } finally { Pop-Location }
  }
}
