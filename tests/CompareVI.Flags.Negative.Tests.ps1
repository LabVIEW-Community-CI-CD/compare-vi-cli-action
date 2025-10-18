Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LVCompare flags (negative cases)' -Tag 'Unit' {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    Import-Module (Join-Path $root 'scripts' 'CompareVI.psm1') -Force
    Mock -CommandName Resolve-Cli -ModuleName CompareVI -MockWith { param($Explicit,$PreferredBitness) 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe' }

    function New-TestVis {
      $vis = Join-Path $TestDrive ('vis-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $vis -Force | Out-Null
      $base = Join-Path $vis 'a.vi'
      $head = Join-Path $vis 'b.vi'
      Set-Content -LiteralPath $base -Value '' -Encoding utf8
      Set-Content -LiteralPath $head -Value 'x' -Encoding utf8
      @{ base = $base; head = $head }
    }
  }

  It 'fails early on unknown LVCompare flag (no executor invocation)' {
    $paths = New-TestVis
    $script:called = $false
    $exec = { param($cli,$b,$h,$argv) $script:called = $true; return 0 }
    { Invoke-CompareVI -Base $paths.base -Head $paths.head -LvCompareArgs '--bogusflag' -FailOnDiff:$false -Executor $exec } | Should -Throw -ExpectedMessage '*Invalid LVCompare flag*'
    $script:called | Should -BeFalse
  }

  It 'fails early when -lvpath is missing a value (no executor invocation)' {
    $paths = New-TestVis
    $script:called2 = $false
    $exec = { param($cli,$b,$h,$argv) $script:called2 = $true; return 0 }
    { Invoke-CompareVI -Base $paths.base -Head $paths.head -LvCompareArgs '-lvpath' -FailOnDiff:$false -Executor $exec } | Should -Throw -ExpectedMessage '*-lvpath requires a following path value*'
    $script:called2 | Should -BeFalse
    $script:called2 = $false
    { Invoke-CompareVI -Base $paths.base -Head $paths.head -LvCompareArgs '-lvpath -noattr' -FailOnDiff:$false -Executor $exec } | Should -Throw -ExpectedMessage '*-lvpath must be followed by a path value*'
    $script:called2 | Should -BeFalse
  }
}
