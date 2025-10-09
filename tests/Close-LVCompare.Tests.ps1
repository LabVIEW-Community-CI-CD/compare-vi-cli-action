Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Close-LVCompare.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'Close-LVCompare.ps1'
    Test-Path -LiteralPath $scriptPath | Should -BeTrue
    $script:scriptPath = $scriptPath
  }

  It 'invokes LVCompare with explicit labview path and default flags' {
    $work = Join-Path $TestDrive 'invoke'
    New-Item -ItemType Directory -Path $work | Out-Null

    $stubCmd = Join-Path $work 'LVCompare.cmd'
    $capture = Join-Path $work 'args.txt'
    Set-Content -LiteralPath $stubCmd -Encoding ascii -Value @"
@echo off
setlocal
>"$capture" echo %*
exit /b 0
"@
    $labviewExe = Join-Path $work 'LabVIEW.exe'
    Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''

    $base = Join-Path $work 'Base.vi'
    $head = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $base -Encoding ascii -Value ''
    Set-Content -LiteralPath $head -Encoding ascii -Value ''

    & pwsh -NoLogo -NoProfile -File $script:scriptPath `
      -LVComparePath $stubCmd `
      -LabVIEWExePath $labviewExe `
      -BaseVi $base `
      -HeadVi $head `
      -TimeoutSeconds 5 *> $null

    $LASTEXITCODE | Should -Be 0
    Test-Path -LiteralPath $capture | Should -BeTrue
    $content = Get-Content -LiteralPath $capture -Raw
    ($content.Contains($base)) | Should -BeTrue
    ($content.Contains($head)) | Should -BeTrue
    ($content -match '-lvpath\s+"?' + [regex]::Escape($labviewExe)) | Should -BeTrue
    ($content.Contains('-nobdcosm')) | Should -BeTrue
    ($content.Contains('-nofppos')) | Should -BeTrue
    ($content.Contains('-noattr')) | Should -BeTrue
  }

  It 'fails when LabVIEW executable path is missing' {
    $work = Join-Path $TestDrive 'missing'
    New-Item -ItemType Directory -Path $work | Out-Null

    $stubCmd = Join-Path $work 'LVCompare.cmd'
    Set-Content -LiteralPath $stubCmd -Encoding ascii -Value "@echo off`nexit /b 0"
    $missingLabVIEW = Join-Path $work 'MissingLabVIEW.exe'

    $base = Join-Path $work 'Base.vi'
    $head = Join-Path $work 'Head.vi'
    Set-Content -LiteralPath $base -Encoding ascii -Value ''
    Set-Content -LiteralPath $head -Encoding ascii -Value ''

    & pwsh -NoLogo -NoProfile -File $script:scriptPath `
      -LVComparePath $stubCmd `
      -LabVIEWExePath $missingLabVIEW `
      -BaseVi $base `
      -HeadVi $head `
      -TimeoutSeconds 5 *> $null

    $LASTEXITCODE | Should -Not -Be 0
  }
}
