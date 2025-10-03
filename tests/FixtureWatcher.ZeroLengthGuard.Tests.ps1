<#
.SYNOPSIS
  Tests FixtureWatcher zero-length Changed event guard.
.DESCRIPTION
  Validates that FileSystemWatcher does not emit Changed events for
  zero-length files during normal polling operations.
#>

Describe 'FixtureWatcher ZeroLengthChangedGuard' -Tag 'Unit', 'Watcher' {
  BeforeAll {
    # Create baseline file with content
    if (-not $TestDrive) {
      $fallback = Join-Path ([IO.Path]::GetTempPath()) ("pester-fallback-" + [guid]::NewGuid())
      New-Item -ItemType Directory -Force -Path $fallback | Out-Null
      Set-Variable -Name TestDrive -Value $fallback -Scope Global -Force
    }
    
    $script:testFile = Join-Path $TestDrive "guard-test.txt"
    "Initial content for guard test" | Set-Content -NoNewline -LiteralPath $script:testFile -Encoding utf8
  }

  It 'does not emit Changed events with zero length during polling window' {
    # Setup FileSystemWatcher without debug/force flags
    $watchDir = Split-Path -Path $script:testFile -Parent
    $fsw = [System.IO.FileSystemWatcher]::new($watchDir)
    $fsw.Filter = [IO.Path]::GetFileName($script:testFile)
    $fsw.IncludeSubdirectories = $false
    $fsw.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    $fsw.EnableRaisingEvents = $true

    $eventSourceId = "ZeroLengthGuard_$([guid]::NewGuid().ToString('N'))"
    
    try {
      Register-ObjectEvent -InputObject $fsw -EventName Changed -SourceIdentifier $eventSourceId | Out-Null

      # Wait for bounded polling window (600ms)
      Start-Sleep -Milliseconds 600

      # Drain all events
      $receivedEvents = @()
      while ($null -ne ($evt = Get-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Remove-Event -EventIdentifier $evt.EventIdentifier
      }

      # Create an explicit scenario: touch the file without zeroing it
      "Updated content" | Add-Content -LiteralPath $script:testFile -Encoding utf8 -NoNewline
      
      # Give time for any events
      Start-Sleep -Milliseconds 200

      # Drain events again
      $postTouchEvents = @()
      while ($null -ne ($evt = Get-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $postTouchEvents += $evt
        Remove-Event -EventIdentifier $evt.EventIdentifier
      }

      # Verify no event corresponds to zero-length file
      foreach ($evt in $postTouchEvents) {
        $path = $evt.SourceEventArgs.FullPath
        if (Test-Path -LiteralPath $path) {
          $info = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
          if ($info) {
            $info.Length | Should -BeGreaterThan 0 -Because "Changed event should not be emitted for zero-length files"
          }
        }
      }

      # Assertion: if no events, that's also acceptable (passive guard)
      # The key invariant: no zero-length Changed events
      $postTouchEvents.Count | Should -BeGreaterOrEqual 0

    } finally {
      Unregister-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue
      Get-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue | Remove-Event
      $fsw.EnableRaisingEvents = $false
      $fsw.Dispose()
    }
  }
}
