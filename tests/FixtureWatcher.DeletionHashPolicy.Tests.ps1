Describe 'FixtureWatcher Deleted Event Hash Policy' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path '.').ProviderPath
    $script:watcherScript = Join-Path $repoRoot 'tools' 'Start-FixtureWatcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) { throw 'Watcher script missing' }

    function Invoke-WatcherScenario {
      param([switch]$DisablePollOptimization)
      $sandbox = Join-Path $TestDrive ('del-' + [guid]::NewGuid().ToString('n'))
      New-Item -ItemType Directory -Path $sandbox | Out-Null
      Copy-Item (Join-Path $repoRoot 'VI1.vi') (Join-Path $sandbox 'VI1.vi')
      Push-Location $sandbox
      try {
        $log = Join-Path $sandbox 'watch.ndjson'
        $args = @('-NoLogo','-NoProfile','-File',$watcherScript,'-Targets','VI1.vi','-DurationSeconds','5','-Quiet','-LogPath',$log)
        if ($DisablePollOptimization) { $args += '-PollHashOnChangeOnly:$false' }
        $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList $args
        $deadline = (Get-Date).AddSeconds(6)
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath 'VI1.vi' -Force
        $deletedLines = @()
        while ((Get-Date) -lt $deadline) {
          if (Test-Path $log) {
            $lines = Get-Content $log -ErrorAction SilentlyContinue
            if ($lines) { $deletedLines = @($lines | Where-Object { $_ -match '"event":"Deleted"' }) }
            if ($deletedLines.Count -gt 0) { break }
          }
          Start-Sleep -Milliseconds 250
        }
        try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
        return $deletedLines
      } finally { Pop-Location }
    }
  }

  It 'omits sha256 on Deleted when PollHashOnChangeOnly default true' {
    $deleted = Invoke-WatcherScenario
    $deleted.Count | Should -BeGreaterThan 0
    $obj = ($deleted | Select-Object -Last 1) | ConvertFrom-Json
    $obj.sha256 | Should -BeNullOrEmpty
  }

  It 'includes sha256 on Deleted when PollHashOnChangeOnly disabled' {
    $deleted = Invoke-WatcherScenario -DisablePollOptimization
    $deleted.Count | Should -BeGreaterThan 0
    $obj = ($deleted | Select-Object -Last 1) | ConvertFrom-Json
    ($obj.PSObject.Properties.Name -contains 'sha256') | Should -BeTrue
  }
}
