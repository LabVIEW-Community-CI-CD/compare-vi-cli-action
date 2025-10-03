<#
  Tests for LOOP_CLOSE_LABVIEW executor wrapping.
  Strategy:
    * Mock Get-Process locally by defining a function in script scope (per repository pattern: shadow then remove).
    * Use simulation mode (LOOP_SIMULATE=1) so no real LVCompare.exe call is needed.
    * Provide LOOP_CLOSE_LABVIEW=1 and a JSON log path.
    * After run, parse JSON log lines and assert presence of labviewCloseAttempt event with expected counters.
    * Provide two fake LabVIEW processes, one that reports successful CloseMainWindow and one that fails triggering Kill path.
  Invariants:
    * labviewCloseAttempt event emitted exactly once for a single iteration run.
    * attempted == 2, closed == 1, killed == 1
    * graceMs reflects provided or default value (we rely on default 5000 unless overridden).
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../module/CompareLoop/CompareLoop.psd1') -Force

Describe 'Run-AutonomousIntegrationLoop LOOP_CLOSE_LABVIEW' -Tag 'Unit' {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  $root = Resolve-Path (Join-Path $scriptDir '..')
  $loopScript = Join-Path $root 'scripts/Run-AutonomousIntegrationLoop.ps1'
  It 'emits labviewCloseAttempt event with expected counters' {
    # Arrange environment
  # Use real VI artifacts per migration directive
  $env:LV_BASE_VI = 'VI1.vi'
  $env:LV_HEAD_VI = 'VI2.vi'
    $env:LOOP_SIMULATE = '1'
    $env:LOOP_MAX_ITERATIONS = '1'
    $env:LOOP_CLOSE_LABVIEW = '1'
    $logPath = Join-Path $TestDrive 'loop-events.ndjson'
    $env:LOOP_JSON_LOG = $logPath
    Remove-Item -Path $logPath -ErrorAction SilentlyContinue

    # Fake process objects
    class FakeLabVIEWProcSuccess {
      [bool]CloseMainWindow() { return $true }
      [bool]WaitForExit([int]$ms) { return $true }
      Kill() { throw 'ShouldNotKillSuccess' }
      Close() { }
      Dispose() { }
    }
    class FakeLabVIEWProcFailClose {
      [bool]CloseMainWindow() { return $false }
      [bool]WaitForExit([int]$ms) { return $false }
      Kill() { $script:KillCount++ }
      Close() { }
      Dispose() { }
    }
    $script:KillCount = 0

    function Get-Process { param([string]$Name)
      if ($Name -eq 'LabVIEW') { return [object[]]@([FakeLabVIEWProcSuccess]::new(), [FakeLabVIEWProcFailClose]::new()) }
      return @()
    }

    try {
      pwsh -NoLogo -NoProfile -File $loopScript | Out-Null
    } finally {
      Remove-Item Function:Get-Process -ErrorAction SilentlyContinue
    }

    Test-Path $logPath | Should -BeTrue
    $lines = Get-Content $logPath | Where-Object { $_ -match 'labviewCloseAttempt' }
    $lines.Count | Should -Be 1
    $evt = $lines | ForEach-Object { $_ | ConvertFrom-Json }
    $evt.attempted | Should -Be 2
    $evt.closed | Should -Be 1
    $evt.killed | Should -Be 1
    $evt.graceMs | Should -Be 5000
    $script:KillCount | Should -Be 1
  }

  It 'emits forceKill flag and success when LOOP_CLOSE_LABVIEW_FORCE=1' {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $root = Resolve-Path (Join-Path $scriptDir '..')
    $loopScript = Join-Path $root 'scripts/Run-AutonomousIntegrationLoop.ps1'
  # Use real VI artifacts per migration directive
  $env:LV_BASE_VI = 'VI1.vi'
  $env:LV_HEAD_VI = 'VI2.vi'
    $env:LOOP_SIMULATE = '1'
    $env:LOOP_MAX_ITERATIONS = '1'
    $env:LOOP_CLOSE_LABVIEW = '1'
    $env:LOOP_CLOSE_LABVIEW_FORCE = '1'
    $logPath = Join-Path $TestDrive 'loop-events-force.ndjson'
    $env:LOOP_JSON_LOG = $logPath
    Remove-Item -Path $logPath -ErrorAction SilentlyContinue

    class FakeLabVIEWProcHang {
      [bool]CloseMainWindow() { return $true }
      [bool]WaitForExit([int]$ms) { Start-Sleep -Milliseconds 5; return $false }
      Kill() { }
      Close() { }
      Dispose() { }
    }

    function Get-Process { param([string]$Name) if ($Name -eq 'LabVIEW') { return ,([FakeLabVIEWProcHang]::new()) } }
    function Start-Process { param([string]$FilePath,[string[]]$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru,[Parameter(ValueFromRemainingArguments=$true)]$Rest)
      if ($FilePath -match 'taskkill') {
        # Simulate successful taskkill
        $ps = New-Object PSObject -Property @{ ExitCode = 0 }
        $ps | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param(); return }
        return $ps
      }
      throw 'Unexpected Start-Process usage in test'
    }
    try {
      pwsh -NoLogo -NoProfile -File $loopScript | Out-Null
    } finally {
      Remove-Item Function:Get-Process -ErrorAction SilentlyContinue
      Remove-Item Function:Start-Process -ErrorAction SilentlyContinue
    }
    $forceLine = Get-Content $logPath | Where-Object { $_ -match 'labviewCloseAttempt' }
    $evt = $forceLine | ForEach-Object { $_ | ConvertFrom-Json }
    $evt.forceKill | Should -BeTrue
    $evt.forceKillSuccess | Should -Be 1
    $evt.attempted | Should -Be 1
  }
}
