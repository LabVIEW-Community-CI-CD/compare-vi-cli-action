<#
  Test: Stray 32-bit LVCompare detection and kill in Run-AutonomousIntegrationLoop.
  Approach:
    * Shadow Get-Process to return a fake 32-bit LVCompare process exposing MainModule.FileName and Kill().
    * Provide LOOP_CLOSE_LABVIEW=1 (auto-close required for detection path) and LOOP_SIMULATE=1 to avoid real CLI usage.
    * Provide a synthetic binary file representing 32-bit (Machine=0x014C) for MainModule.FileName.
    * Capture JSON log and assert lvcompareStrayKill event fields.
  Notes:
    * We don't assert labviewCloseAttempt here; that is covered elsewhere.
    * We ensure at least one LabVIEW process (can be empty) – detection only hinges on LVCompare enumeration.
#>
Set-StrictMode -Version Latest

Describe 'Run-AutonomousIntegrationLoop stray LVCompare kill' -Tag 'Unit' {
  $root = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')
  $loopScript = Join-Path $root 'scripts/Run-AutonomousIntegrationLoop.ps1'

  It 'emits lvcompareStrayKill event with detected/killed counts' {
  # Use real artifact names per migration (Base/Head deprecated)
  $env:LV_BASE_VI = 'VI1.vi'
  $env:LV_HEAD_VI = 'VI2.vi'
    $env:LOOP_SIMULATE = '1'
    $env:LOOP_MAX_ITERATIONS = '1'
    $env:LOOP_CLOSE_LABVIEW = '1'
    $env:LOOP_JSON_LOG = Join-Path $TestDrive 'events.ndjson'
    Remove-Item $env:LOOP_JSON_LOG -ErrorAction SilentlyContinue

    # Synthetic 32-bit binary for LVCompare path
    $fakeDir = Join-Path $TestDrive 'fake'
    New-Item -ItemType Directory -Path $fakeDir | Out-Null
    $fakeExe = Join-Path $fakeDir 'LVCompare.exe'
    $bytes = New-Object byte[] 256
    $bytes[0] = 0x4D; $bytes[1] = 0x5A  # MZ
  $e = [BitConverter]::GetBytes(0x80)
  for ($i=0; $i -lt $e.Length; $i++) { $bytes[0x3C + $i] = $e[$i] }
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45; $bytes[0x82] = 0x00; $bytes[0x83] = 0x00 # PE\0\0
    $bytes[0x84] = 0x4C; $bytes[0x85] = 0x01 # Machine I386
    [IO.File]::WriteAllBytes($fakeExe, $bytes)

    # Fake process classes
    class FakeModule { [string]$FileName; FakeModule([string]$f){$this.FileName=$f} }
    class FakeProcLVCompare {
      [int]$KillCount = 0
      [object] get_MainModule(){ return [FakeModule]::new($script:FakePath) }
      Kill(){ $this.KillCount++ }
      Close(){}
      Dispose(){}
    }
    class FakeProcLabVIEW { Close(){} Dispose(){} Kill(){} }
    $script:FakePath = $fakeExe
    $lvCompareInstance = [FakeProcLVCompare]::new()

    function Get-Process { param([string]$Name)
      switch ($Name) {
        'LVCompare' { return ,$lvCompareInstance }
        'LabVIEW'   { return @() }
      }
    }

    try {
      pwsh -NoLogo -NoProfile -File $loopScript | Out-Null
    } finally {
      Remove-Item Function:Get-Process -ErrorAction SilentlyContinue
    }

    Test-Path $env:LOOP_JSON_LOG | Should -BeTrue
    $lines = Get-Content $env:LOOP_JSON_LOG | Where-Object { $_ -match 'lvcompareStrayKill' }
    $lines.Count | Should -Be 1
    $evt = $lines | ForEach-Object { $_ | ConvertFrom-Json }
    $evt.detected | Should -Be 1
    $evt.killed   | Should -Be 1
    # Confirm Kill was invoked on fake process
    $lvCompareInstance.KillCount | Should -Be 1
  }
}
