Describe 'FixtureWatcher JSON Field Ordering' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path '.').ProviderPath
    $script:watcherScript = Join-Path $repoRoot 'tools' 'Start-FixtureWatcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) { throw 'Watcher script missing' }
  }

  It 'emits schema as first property in JSON lines' {
    $sandbox = Join-Path $TestDrive 'order'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    Copy-Item (Join-Path $repoRoot 'VI1.vi') (Join-Path $sandbox 'VI1.vi')
    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList @('-NoLogo','-NoProfile','-File',$watcherScript,'-Once','-Quiet','-LogPath',$log)
      $proc.WaitForExit()
      $lines = if (Test-Path $log) { Get-Content $log } else { @() }
      $lines.Count | Should -BeGreaterThan 0
      foreach ($line in $lines) {
        $trim = $line.TrimStart()
        $trim.StartsWith('{"schema"') | Should -BeTrue
      }
    } finally { Pop-Location }
  }
}
