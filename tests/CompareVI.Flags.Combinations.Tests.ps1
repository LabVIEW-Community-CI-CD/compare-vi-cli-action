Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LVCompare flags (knowledgebase combinations)' -Tag 'Unit' {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    Import-Module (Join-Path $root 'scripts' 'CompareVI.psm1') -Force

    # Always mock Resolve-Cli to avoid environment coupling
    Mock -CommandName Resolve-Cli -ModuleName CompareVI -MockWith { param($Explicit,$PreferredBitness) 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe' }

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

  It 'accepts singleton flags: -nobdcosm, -nofppos, -noattr' -ForEach @(
    @{ args = '-nobdcosm' ; flag='-nobdcosm' },
    @{ args = '-nofppos'  ; flag='-nofppos'  },
    @{ args = '-noattr'   ; flag='-noattr'   }
  ) {
    param($argSpec, $flag)
    $exec = New-ExecWithArgs -argSpec $argSpec
    $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($flag))
    @($exec.args) | Should -Contain $flag
  }

  It 'accepts pair combinations of knowledgebase flags' -ForEach @(
    @{ args = '-nobdcosm -nofppos' ; a='-nobdcosm'; b='-nofppos' },
    @{ args = '-nobdcosm -noattr'  ; a='-nobdcosm'; b='-noattr'  },
    @{ args = '-nofppos -noattr'   ; a='-nofppos' ; b='-noattr'  }
  ) {
    param($argSpec,$a,$b)
    $exec = New-ExecWithArgs -argSpec $argSpec
    $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($a))
    $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($b))
    @($exec.args) | Should -Contain $a
    @($exec.args) | Should -Contain $b
  }

  It 'accepts triple combination: -nobdcosm -nofppos -noattr' {
    $exec = New-ExecWithArgs -argSpec '-nobdcosm -nofppos -noattr'
    foreach ($f in @('-nobdcosm','-nofppos','-noattr')) {
      $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($f))
      @($exec.args) | Should -Contain $f
    }
  }

  It 'allows mixing -lvpath with noise-filter flags' {
    $lv = 'C:\\Path With Space\\LabVIEW.exe'
    $exec = New-ExecWithArgs -argSpec ("-nobdcosm -nofppos -noattr -lvpath `"$lv`"")
    foreach ($f in @('-nobdcosm','-nofppos','-noattr','-lvpath')) {
      $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($f))
    }
    # Verify tokens preserve -lvpath value
    $tokens = @($exec.args)
    ($tokens -contains '-lvpath') | Should -BeTrue
    $idx = [array]::IndexOf($tokens,'-lvpath')
    $idx | Should -BeGreaterOrEqual 0
    $tokens[$idx+1] | Should -Be $lv
  }
}
