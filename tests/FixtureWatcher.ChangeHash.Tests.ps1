Describe 'FixtureWatcher Changed Event Hash Behavior' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path '.').ProviderPath
    . (Join-Path $script:repoRoot 'tests' '_WatcherTestPrereq.ps1')
    $script:watcherScript = Join-Path $repoRoot 'tools' 'Start-FixtureWatcher.ps1'
    if (-not (Test-Path -LiteralPath $watcherScript)) { throw 'Watcher script missing' }
  }

  It 'detects hash/length change after atomic swap' {
    $sandbox = Join-Path $TestDrive 'chg'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    $fixtureName = 'VI1.vi'
    $sourceFixture = Join-Path $repoRoot $fixtureName
    $sandboxTarget = Join-Path $sandbox $fixtureName
  Copy-Item $sourceFixture $sandboxTarget
  # Ensure sandbox target is writable (prereq script may have marked source read-only)
  try { (Get-Item $sandboxTarget).IsReadOnly = $false } catch {}

    # Phase 1: pre-grow before watcher start
    $baselineLen = (Get-Item $sourceFixture).Length
    $firstGrowth = 2048
  $fs1 = [System.IO.File]::Open($sandboxTarget,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
    try { $fs1.SetLength($baselineLen + $firstGrowth) } finally { $fs1.Dispose() }
    $preStartLen = (Get-Item $sandboxTarget).Length
    $preStartLen | Should -Be ($baselineLen + $firstGrowth)

    Remove-Item Env:WATCHER_DEBUG -ErrorAction SilentlyContinue
    Remove-Item Env:WATCHER_FORCE_CHANGED -ErrorAction SilentlyContinue
    Remove-Item Env:WATCHER_STARTUP_POLL_DELAY_MS -ErrorAction SilentlyContinue

    Push-Location $sandbox
    try {
      $log = Join-Path $sandbox 'watch.ndjson'
      $procArgs = @('-NoLogo','-NoProfile','-File',$watcherScript,'-Targets',$fixtureName,'-DurationSeconds','12','-Quiet','-LogPath',$log)
      $proc = Start-Process pwsh -NoNewWindow -PassThru -ArgumentList $procArgs

      # Wait for Initial
      $haveInitial=$false; $waitInitialDeadline=(Get-Date).AddSeconds(3)
      while(-not $haveInitial -and (Get-Date) -lt $waitInitialDeadline){
        if(Test-Path $log){ $haveInitial = (Select-String -Path $log -SimpleMatch '"event":"Initial"') -ne $null }
        if(-not $haveInitial){ Start-Sleep -Milliseconds 120 }
      }
      if(-not $haveInitial){ throw 'Initial event not observed within 3s' }

      # Phase 2: build enlarged temp and atomic swap
      $secondGrowth = 3072
      $tempFile = Join-Path $sandbox (New-Guid).Guid
  Copy-Item $sandboxTarget $tempFile
  try { (Get-Item $tempFile).IsReadOnly = $false } catch {}
      $fs2 = [System.IO.File]::Open($tempFile,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
      try { $fs2.SetLength($preStartLen + $secondGrowth) } finally { $fs2.Dispose() }
      $targetFinalLen = $preStartLen + $secondGrowth
      $swapSucceeded=$false; $swapDeadline=(Get-Date).AddSeconds(4)
      while(-not $swapSucceeded -and (Get-Date) -lt $swapDeadline){
        try { Move-Item -LiteralPath $tempFile -Destination $sandboxTarget -Force; $swapSucceeded=$true } catch { Start-Sleep -Milliseconds 100 }
      }
      if(-not $swapSucceeded){
        try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
        Set-ItResult -Inconclusive -Because 'Atomic swap could not complete under contention'
        return
      }

      # Poll for Changed with new length
      $deadline = (Get-Date).AddSeconds(8)
      $changedEvents = @(); $finalEvents=@()
      while ((Get-Date) -lt $deadline) {
        if (Test-Path $log) {
          $lines = Get-Content $log -ErrorAction SilentlyContinue
          if ($lines) {
            $changedEvents = @($lines | Where-Object { $_ -match '"event":"Changed"' -and $_ -notmatch '"length":0' })
            if ($changedEvents) {
              $finalEvents = $changedEvents | Where-Object { $_ -match '"length":'+$targetFinalLen }
              if ($finalEvents) { break }
            }
          }
        }
        Start-Sleep -Milliseconds 200
      }
      try { $proc | Stop-Process -ErrorAction SilentlyContinue } catch {}
      if(-not $changedEvents){
        if(Test-Path $log){ Write-Host '[diag] Log contents (no Changed events):' -ForegroundColor DarkYellow; Get-Content $log }
      }
      ($changedEvents.Count) | Should -BeGreaterThan 0
      $obj = if($finalEvents){ ($finalEvents | Select-Object -Last 1) | ConvertFrom-Json } else { ($changedEvents | Select-Object -Last 1) | ConvertFrom-Json }
      $obj.sha256 | Should -Not -BeNullOrEmpty
      $obj.length | Should -Be $targetFinalLen
      $obj.length | Should -BeGreaterThan $preStartLen
      $obj.name | Should -Be $fixtureName
    } finally { Pop-Location }
  }
}
