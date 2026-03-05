Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LVCompare flags (canonical combinations)' -Tag 'CompareVI','Unit' {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    Import-Module (Join-Path $root 'scripts' 'CompareVI.psm1') -Force

    # Always mock Resolve-Cli to avoid environment coupling
    Mock -CommandName Resolve-Cli -ModuleName CompareVI -MockWith { param($Explicit,$PreferredBitness) 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe' }

    Set-Variable -Name CanonicalFlags -Scope Script -Value @('-noattr','-nofp','-nofppos','-nobd','-nobdcosm') -Force

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

  It 'accepts singleton canonical flags' {
    foreach ($flag in $script:CanonicalFlags) {
      $exec = New-ExecWithArgs -argSpec $flag
      $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($flag))
      @($exec.args) | Should -Contain $flag
    }
  }

  It 'accepts pair combinations of canonical flags' {
    $cases = @(
      @{ args = '-noattr -nofp'      ; a='-noattr'  ; b='-nofp' },
      @{ args = '-noattr -nofppos'   ; a='-noattr'  ; b='-nofppos' },
      @{ args = '-noattr -nobd'      ; a='-noattr'  ; b='-nobd' },
      @{ args = '-noattr -nobdcosm'  ; a='-noattr'  ; b='-nobdcosm' },
      @{ args = '-nofp -nobd'        ; a='-nofp'    ; b='-nobd' },
      @{ args = '-nofppos -nobdcosm' ; a='-nofppos' ; b='-nobdcosm' }
    )
    foreach ($case in $cases) {
      $exec = New-ExecWithArgs -argSpec $case.args
      $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($case.a))
      $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($case.b))
      @($exec.args) | Should -Contain $case.a
      @($exec.args) | Should -Contain $case.b
    }
  }

  It 'accepts canonical combination: -noattr -nofp -nofppos -nobd -nobdcosm' {
    $combo = $script:CanonicalFlags -join ' '
    $exec = New-ExecWithArgs -argSpec $combo
    foreach ($f in $script:CanonicalFlags) {
      $exec.command | Should -Match ("(^|\s){0}(\s|$)" -f [regex]::Escape($f))
      @($exec.args) | Should -Contain $f
    }
  }

  It 'allows mixing -lvpath with canonical flags' {
    $lv = 'C:\Path With Space\LabVIEW.exe'
    $exec = New-ExecWithArgs -argSpec (("{0} -lvpath `"{1}`"" -f ($script:CanonicalFlags -join ' '), $lv))
    foreach ($f in ($script:CanonicalFlags + @('-lvpath'))) {
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
