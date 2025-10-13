Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LVCompare flags (nobdpos extensions)' -Tag 'Unit' {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    Import-Module (Join-Path $root 'scripts' 'CompareVI.psm1') -Force

    Mock -CommandName Resolve-Cli -ModuleName CompareVI -MockWith { 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe' }

    function New-ExecWithArgs([string]$argSpec) {
      $work = Join-Path $TestDrive ('flags-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $work -Force | Out-Null
      $base = Join-Path $work 'Base.vi'
      $head = Join-Path $work 'Head.vi'
      Set-Content -LiteralPath $base -Value '' -Encoding ascii
      Set-Content -LiteralPath $head -Value 'x' -Encoding ascii
      $execPath = Join-Path $work 'compare-exec.json'
      $null = Invoke-CompareVI -Base $base -Head $head -LvCompareArgs $argSpec -FailOnDiff:$false -Executor { 0 } -CompareExecJsonPath $execPath
      if (-not (Test-Path -LiteralPath $execPath)) { throw "compare-exec.json missing: $execPath" }
      return (Get-Content -LiteralPath $execPath -Raw | ConvertFrom-Json -ErrorAction Stop)
    }
  }

  It 'accepts -nobdpos alone' {
    $exec = New-ExecWithArgs -argSpec '-nobdpos'
    @($exec.args) | Should -Contain '-nobdpos'
  }

  It 'accepts -nobdpos in pair combinations' {
    $pairs = @(
      @{ args = '-nobdpos -nobdcosm'; flags = @('-nobdpos','-nobdcosm') },
      @{ args = '-nobdpos -nofppos'; flags = @('-nobdpos','-nofppos') },
      @{ args = '-nobdpos -noattr' ; flags = @('-nobdpos','-noattr') }
    )
    foreach ($case in $pairs) {
      $exec = New-ExecWithArgs -argSpec $case.args
      foreach ($flag in $case.flags) {
        @($exec.args) | Should -Contain $flag -Because ("pair {0} retains {1}" -f $case.args, $flag)
      }
    }
  }

  It 'accepts triple combinations including -nobdpos' {
    $triples = @(
      @{ args = '-nobdpos -nobdcosm -nofppos'; flags = @('-nobdpos','-nobdcosm','-nofppos') },
      @{ args = '-nobdpos -nobdcosm -noattr' ; flags = @('-nobdpos','-nobdcosm','-noattr') },
      @{ args = '-nobdpos -nofppos -noattr'  ; flags = @('-nobdpos','-nofppos','-noattr') }
    )
    foreach ($case in $triples) {
      $exec = New-ExecWithArgs -argSpec $case.args
      foreach ($flag in $case.flags) {
        @($exec.args) | Should -Contain $flag -Because ("triple {0} retains {1}" -f $case.args, $flag)
      }
    }
  }

  It 'accepts -nobd alongside layout/cosmetic filters (redundant but valid)' {
    $exec = New-ExecWithArgs -argSpec '-nobd -nobdpos -nobdcosm'
    foreach ($flag in @('-nobd','-nobdpos','-nobdcosm')) {
      @($exec.args) | Should -Contain $flag -Because 'driver should pass through all supplied flags'
    }
  }
}
