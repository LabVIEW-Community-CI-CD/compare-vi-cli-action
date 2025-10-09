Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Prime-LVCompare.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:primePath = Join-Path $repoRoot 'tools' 'Prime-LVCompare.ps1'
    Test-Path -LiteralPath $script:primePath | Should -BeTrue
  }

  It 'runs LVCompare with expected arguments and returns exit code' {
    $workDir = Join-Path $TestDrive 'prime'
    New-Item -ItemType Directory -Path $workDir | Out-Null

    $stub = Join-Path $workDir 'LVCompare.cmd'
    Set-Content -LiteralPath $stub -Encoding ascii -Value "@echo off`nexit /b 1"

    $base = Join-Path $workDir 'Base.vi'
    $head = Join-Path $workDir 'Head.vi'
    Set-Content -LiteralPath $base -Encoding ascii -Value ''
    Set-Content -LiteralPath $head -Encoding ascii -Value ''

    & pwsh -NoLogo -NoProfile -File $script:primePath `
      -LVCompareExePath $stub `
      -BaseVi $base `
      -HeadVi $head `
      -LabVIEWExePath (Join-Path $workDir 'LabVIEW.exe') `
      -TimeoutSeconds 5 *> $null

    $LASTEXITCODE | Should -Be 1
  }

  It 'fails when ExpectNoDiff is violated' {
    $workDir = Join-Path $TestDrive 'prime-failure'
    New-Item -ItemType Directory -Path $workDir | Out-Null

    $stub = Join-Path $workDir 'LVCompare.cmd'
    Set-Content -LiteralPath $stub -Encoding ascii -Value "@echo off`nexit /b 1"

    $base = Join-Path $workDir 'Base.vi'
    $head = Join-Path $workDir 'Head.vi'
    Set-Content -LiteralPath $base -Encoding ascii -Value ''
    Set-Content -LiteralPath $head -Encoding ascii -Value ''

    & pwsh -NoLogo -NoProfile -File $script:primePath `
      -LVCompareExePath $stub `
      -BaseVi $base `
      -HeadVi $head `
      -ExpectNoDiff `
      -TimeoutSeconds 5 *> $null

    $LASTEXITCODE | Should -Not -Be 0
  }
}
