#Requires -Version 7.0
# Tag: Integration (executes the real CLI on self-hosted)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $here = Split-Path -Parent $PSCommandPath
  $repoRoot = Resolve-Path (Join-Path $here '..')
  . (Join-Path $repoRoot 'scripts' 'CompareVI.ps1')

  $Canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  $BaseVi = $env:LV_BASE_VI
  $HeadVi = $env:LV_HEAD_VI
  $script:Canonical = $Canonical
  $script:BaseVi = $BaseVi
  $script:HeadVi = $HeadVi
}

Describe 'Invoke-CompareVI (real CLI on self-hosted)' -Tag Integration {
  It 'has required files present' {
    Test-Path -LiteralPath $Canonical -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $BaseVi -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $HeadVi -PathType Leaf | Should -BeTrue
  }

  It 'exit 0 => diff=false when base=head' {
    $res = Invoke-CompareVI -Base $BaseVi -Head $BaseVi -LvComparePath $Canonical -FailOnDiff:$false
    $res.ExitCode | Should -Be 0
    $res.Diff | Should -BeFalse
    $res.CliPath | Should -Be (Resolve-Path $Canonical).Path
  }

  It 'exit 1 => diff=true when base!=head' {
    $res = Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -FailOnDiff:$false
    $res.ExitCode | Should -Be 1
    $res.Diff | Should -BeTrue
  }

  It 'fail-on-diff=true throws after outputs are written for diff' {
    $tmpOut = Join-Path $env:TEMP ("comparevi-outputs-{0}.txt" -f ([guid]::NewGuid()))
    { Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $Canonical -GitHubOutputPath $tmpOut -FailOnDiff:$true } | Should -Throw
    (Get-Content -LiteralPath $tmpOut -Raw) | Should -Match 'diff=true'
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
  }
}
