Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LVCompare flags (knowledgebase baseline)' -Tag 'Unit' {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    $script:CompareModule = Import-Module (Join-Path $root 'scripts' 'CompareVI.psm1') -Force -PassThru
    $script:ArgModule = Import-Module (Join-Path $root 'scripts' 'ArgTokenization.psm1') -Force -PassThru

    Mock -CommandName Resolve-Cli -ModuleName CompareVI -MockWith { 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe' }

    function New-ExecWithArgs([object]$argSpec) {
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

    function Invoke-GetTokens([object]$spec) {
      & $script:ArgModule { param($value) Get-LVCompareArgTokens -Spec $value } $spec
    }

    function Invoke-NormalizeTokens([string[]]$tokens) {
      & $script:CompareModule { param($innerTokens) Convert-ArgTokenList -tokens $innerTokens } $tokens
    }
  }

  It 'accepts singleton knowledgebase flags' {
    foreach ($flag in @('-nobdcosm','-nofppos','-noattr')) {
      $exec = New-ExecWithArgs -argSpec $flag
      @($exec.args) | Should -Contain $flag -Because ("singleton flag {0} should be preserved" -f $flag)
    }
  }

  It 'accepts pair combinations of knowledgebase flags' {
    $cases = @(
      @{ args = '-nobdcosm -nofppos' ; flags = @('-nobdcosm','-nofppos') },
      @{ args = '-nobdcosm -noattr'  ; flags = @('-nobdcosm','-noattr')  },
      @{ args = '-nofppos -noattr'   ; flags = @('-nofppos','-noattr')   }
    )
    foreach ($case in $cases) {
      $exec = New-ExecWithArgs -argSpec $case.args
      foreach ($flag in $case.flags) {
        @($exec.args) | Should -Contain $flag -Because ("pair {0} should retain {1}" -f $case.args, $flag)
      }
    }
  }

  It 'accepts the canonical triple combination' {
    $exec = New-ExecWithArgs -argSpec '-nobdcosm -nofppos -noattr'
    foreach ($flag in @('-nobdcosm','-nofppos','-noattr')) {
      @($exec.args) | Should -Contain $flag -Because ("triple set should include {0}" -f $flag)
    }
  }

  It 'normalizes knowledgebase specs via token helpers' {
    $cases = @(
      @{ spec = '-nobdcosm'; expected = @('-nobdcosm') },
      @{ spec = '-nofppos'; expected = @('-nofppos') },
      @{ spec = '-noattr'; expected = @('-noattr') },
      @{ spec = '-nobdcosm -nofppos'; expected = @('-nobdcosm','-nofppos') },
      @{ spec = '-nobdcosm -noattr'; expected = @('-nobdcosm','-noattr') },
      @{ spec = '-nofppos -noattr'; expected = @('-nofppos','-noattr') },
      @{ spec = '-nobdcosm -nofppos -noattr'; expected = @('-nobdcosm','-nofppos','-noattr') }
    )

    foreach ($case in $cases) {
      $tokens = Invoke-GetTokens $case.spec
      $normalized = Invoke-NormalizeTokens $tokens

      @($normalized).Count | Should -Be $case.expected.Count
      foreach ($flag in $case.expected) {
        @($normalized) | Should -Contain $flag -Because ("spec {0} retains {1}" -f $case.spec, $flag)
      }
      foreach ($flag in $normalized) {
        @($case.expected) | Should -Contain $flag -Because ("spec {0} should not introduce {1}" -f $case.spec, $flag)
      }
    }
  }
}
