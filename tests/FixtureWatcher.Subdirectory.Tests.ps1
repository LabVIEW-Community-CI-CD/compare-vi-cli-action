Describe 'FixtureWatcher Subdirectory Inclusion' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path '.').ProviderPath
    $script:watcherScript = Join-Path $repoRoot 'tools' 'Start-FixtureWatcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) { throw 'Watcher script missing' }
  }

  It 'captures changes in nested directory when -IncludeSubdirectories set' {
    $sandbox = Join-Path $TestDrive 'subdir'
    $nested = Join-Path $sandbox 'nested'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    $fixtureName = 'VI1.vi'
    Copy-Item (Join-Path $repoRoot $fixtureName) (Join-Path $nested $fixtureName)
    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList @('-NoLogo','-NoProfile','-File',$watcherScript,'-Targets',$fixtureName,'-IncludeSubdirectories','-DurationSeconds','8','-Quiet','-LogPath',$log)
      Start-Sleep -Seconds 2
      [byte[]]$append = 1,2,3,4
      $filePath = Join-Path $nested $fixtureName
      [System.IO.File]::WriteAllBytes($filePath, ([System.IO.File]::ReadAllBytes($filePath) + $append))
      $deadline = (Get-Date).AddSeconds(5)
      $changed = @()
      while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
          $lines = Get-Content $log -ErrorAction SilentlyContinue
          if ($lines) { $changed = @($lines | Where-Object { $_ -match '"event":"Changed"' -and $_ -match 'nested' }) }
          if ($changed.Count -gt 0) { break }
        }
        Start-Sleep -Milliseconds 250
      }
      try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
      $changed.Count | Should -BeGreaterThan 0
    } finally { Pop-Location }
  }
}
