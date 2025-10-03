<#[
  Test: multi-instance 64-bit LVCompare detection emits lvcompareMultiInstance event.
  Approach:
    * Shadow Get-Process to return two fake 64-bit LVCompare processes (Machine=0x8664) and no LabVIEW processes.
    * LOOP_CLOSE_LABVIEW=1 and LOOP_SIMULATE=1 so the loop wrapper executes the detection block once.
    * Provide synthetic 64-bit PE bytes for each fake MainModule path.
    * Assert: JSON log contains one lvcompareMultiInstance event line; no lvcompareStrayKill event (since all are 64-bit and not killed).
    * Assert: summary lines include Multiple LVCompare instances observed with expected counters (Occurrences=1 MaxConcurrent=2).
#>]
Set-StrictMode -Version Latest

Describe 'Run-AutonomousIntegrationLoop multi-instance LVCompare detection' -Tag 'Unit' {
  $root = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')
  $loopScript = Join-Path $root 'scripts/Run-AutonomousIntegrationLoop.ps1'

  It 'emits lvcompareMultiInstance event (two 64-bit survivors) and no stray kill event' {
  # Use real artifact names per migration (Base/Head deprecated)
  $env:LV_BASE_VI = 'VI1.vi'
  $env:LV_HEAD_VI = 'VI2.vi'
    $env:LOOP_SIMULATE = '1'
    $env:LOOP_MAX_ITERATIONS = '1'
    $env:LOOP_CLOSE_LABVIEW = '1'
    $env:LOOP_JSON_LOG = Join-Path $TestDrive 'events-multi.ndjson'
    Remove-Item $env:LOOP_JSON_LOG -ErrorAction SilentlyContinue

    # Create two synthetic 64-bit binaries
    function New-Stub64Exe([string]$Path) {
      $bytes = New-Object byte[] 256
      $bytes[0] = 0x4D; $bytes[1] = 0x5A
      $e = [BitConverter]::GetBytes(0x80)
      for ($i=0; $i -lt $e.Length; $i++) { $bytes[0x3C + $i] = $e[$i] }
      $bytes[0x80] = 0x50; $bytes[0x81] = 0x45; $bytes[0x82] = 0x00; $bytes[0x83] = 0x00
      $bytes[0x84] = 0x64; $bytes[0x85] = 0x86 # 0x8664
      [IO.File]::WriteAllBytes($Path, $bytes)
    }

    $fakeDir = Join-Path $TestDrive 'fake'
    New-Item -ItemType Directory -Path $fakeDir | Out-Null
    $exe1 = Join-Path $fakeDir 'LVCompare1.exe'
    $exe2 = Join-Path $fakeDir 'LVCompare2.exe'
    New-Stub64Exe $exe1
    New-Stub64Exe $exe2

    # Fake process classes
    class FakeModule64A { [string]$FileName; FakeModule64A([string]$f){$this.FileName=$f} }
    class FakeModule64B { [string]$FileName; FakeModule64B([string]$f){$this.FileName=$f} }
    class FakeProcLVCompareA { [object] get_MainModule(){ return [FakeModule64A]::new($script:PathA) } Kill(){} Close(){} Dispose(){} }
    class FakeProcLVCompareB { [object] get_MainModule(){ return [FakeModule64B]::new($script:PathB) } Kill(){} Close(){} Dispose(){} }
    class FakeProcLabVIEW { Close(){} Dispose(){} Kill(){} }
    $script:PathA = $exe1
    $script:PathB = $exe2
    $instA = [FakeProcLVCompareA]::new()
    $instB = [FakeProcLVCompareB]::new()

    function Get-Process { param([string]$Name)
      switch ($Name) {
        'LVCompare' { return @($instA,$instB) }
        'LabVIEW'   { return @() }
      }
    }

    try {
      $output = pwsh -NoLogo -NoProfile -File $loopScript 2>&1
    } finally {
      Remove-Item Function:Get-Process -ErrorAction SilentlyContinue
    }

    Test-Path $env:LOOP_JSON_LOG | Should -BeTrue
    $multi = Get-Content $env:LOOP_JSON_LOG | Where-Object { $_ -match 'lvcompareMultiInstance' }
    $multi.Count | Should -Be 1
    ($multi | ConvertFrom-Json).concurrent | Should -Be 2
    $stray = Get-Content $env:LOOP_JSON_LOG | Where-Object { $_ -match 'lvcompareStrayKill' }
    $stray.Count | Should -Be 0

    # Console summary line check (Occurrences=1 MaxConcurrent=2)
    ($output -join "`n") | Should -Match 'Occurrences=1 MaxConcurrent=2'
  }
}
