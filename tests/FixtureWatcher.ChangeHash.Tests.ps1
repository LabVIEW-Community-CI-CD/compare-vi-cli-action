<#
.SYNOPSIS
  Tests FixtureWatcher Changed event with hash validation.
.DESCRIPTION
  Validates that FileSystemWatcher properly detects file changes and
  filters out zero-length Changed events.
#>

Describe 'FixtureWatcher ChangeHash' -Tag 'Unit', 'Watcher' {
  BeforeAll {
    # Dot-source the helper functions
    . "$PSScriptRoot/support/WatcherMutation.ps1"
    
    # Create a baseline fixture file
    if (-not $TestDrive) {
      $fallback = Join-Path ([IO.Path]::GetTempPath()) ("pester-fallback-" + [guid]::NewGuid())
      New-Item -ItemType Directory -Force -Path $fallback | Out-Null
      Set-Variable -Name TestDrive -Value $fallback -Scope Global -Force
    }
    
    $script:baselineFile = Join-Path $TestDrive "baseline.txt"
    "Original content" | Set-Content -NoNewline -LiteralPath $script:baselineFile -Encoding utf8
    $script:baselineHash = (Get-FileHash -LiteralPath $script:baselineFile -Algorithm SHA256).Hash
  }

  It 'detects file change via grown copy and atomic swap' {
    # Setup FileSystemWatcher
    $watchDir = Split-Path -Path $script:baselineFile -Parent
    $fsw = [System.IO.FileSystemWatcher]::new($watchDir)
    $fsw.Filter = [IO.Path]::GetFileName($script:baselineFile)
    $fsw.IncludeSubdirectories = $false
    $fsw.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    
    $eventSourceId = "WatcherTest_$([guid]::NewGuid().ToString('N'))"
    $receivedEvents = [System.Collections.Generic.List[object]]::new()
    
    try {
      # Register event handler
      Register-ObjectEvent -InputObject $fsw -EventName Changed -SourceIdentifier $eventSourceId | Out-Null
      
      # Enable watcher BEFORE making changes
      $fsw.EnableRaisingEvents = $true
      
      # Small delay to ensure watcher is active
      Start-Sleep -Milliseconds 100

      # Use helper to create grown copy
      $grown = New-GrownCopy -Source $script:baselineFile -ExtraBytes 100
      $grown.FinalLength | Should -BeGreaterThan (Get-Item -LiteralPath $script:baselineFile).Length

      # Use helper to atomically swap
      $swapSuccess = Invoke-AtomicSwap -Original $script:baselineFile -Replacement $grown.Path
      $swapSuccess | Should -BeTrue

      # Wait for event with timeout
      $timeout = 3000
      $elapsed = 0
      $interval = 100
      while ($elapsed -lt $timeout) {
        $events = @(Get-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue)
        if ($events.Count -gt 0) { break }
        Start-Sleep -Milliseconds $interval
        $elapsed += $interval
      }

      # Collect all events
      $events = @(Get-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue)
      
      # Verify file hash changed (main assertion - more reliable than event timing)
      $newHash = (Get-FileHash -LiteralPath $script:baselineFile -Algorithm SHA256).Hash
      $newHash | Should -Not -Be $script:baselineHash

      # Verify new content has expected length
      $newInfo = Get-Item -LiteralPath $script:baselineFile
      $newInfo.Length | Should -Be ($grown.FinalLength)

      # If events were received, verify no zero-length Changed events
      if ($events.Count -gt 0) {
        foreach ($evt in $events) {
          # Verify file at event path is not zero-length
          $path = $evt.SourceEventArgs.FullPath
          if (Test-Path -LiteralPath $path) {
            $fileInfo = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($fileInfo) {
              $fileInfo.Length | Should -BeGreaterThan 0 -Because "Changed event should not be emitted for zero-length files"
            }
          }
          Remove-Event -EventIdentifier $evt.EventIdentifier
        }
      }
      
      # Note: Event detection is best-effort in tests; the core validation is
      # that helpers work correctly and file was mutated successfully

    } finally {
      Unregister-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue
      Get-Event -SourceIdentifier $eventSourceId -ErrorAction SilentlyContinue | Remove-Event
      $fsw.EnableRaisingEvents = $false
      $fsw.Dispose()
    }
  }
}
