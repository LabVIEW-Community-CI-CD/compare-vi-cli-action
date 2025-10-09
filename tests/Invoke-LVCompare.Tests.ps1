Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-LVCompare.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:driverPath = Join-Path $repoRoot 'tools' 'Invoke-LVCompare.ps1'
    Test-Path -LiteralPath $script:driverPath | Should -BeTrue
  }

  It 'writes capture and includes default flags with leak summary' {
    $work = Join-Path $TestDrive 'driver-default'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      $captureStub = Join-Path $work 'CaptureStub.ps1'
      $stub = @"
param(
  [string]`$Base,
  [string]`$Head,
  [object]`$LvArgs,
  [string]`$LvComparePath,
  [switch]`$RenderReport,
  [string]`$OutputDir,
  [switch]`$Quiet
)
if (-not (Test-Path `$OutputDir)) { New-Item -ItemType Directory -Path `$OutputDir -Force | Out-Null }
if (`$LvArgs -is [System.Array]) { `$args = @(`$LvArgs) } elseif (`$LvArgs) { `$args = @([string]`$LvArgs) } else { `$args = @() }
$cap = [ordered]@{ schema='lvcompare-capture-v1'; exitCode=1; seconds=0.5; command='stub'; args=$args }
$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path `$OutputDir 'lvcompare-capture.json') -Encoding utf8
if (`$LvComparePath) { `$resolved = try { (Resolve-Path -LiteralPath `$LvComparePath).Path } catch { `$LvComparePath } } else { `$resolved = '' }
Set-Content -LiteralPath (Join-Path `$OutputDir 'lvcompare-path.txt') -Value `$resolved -Encoding utf8
exit 1
"@
      Set-Content -LiteralPath $captureStub -Value $stub -Encoding UTF8

      $labviewExe = Join-Path $work 'LabVIEW.exe'; Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''
      $lvcompareExe = Join-Path $work 'LVCompareOverride.exe'; Set-Content -LiteralPath $lvcompareExe -Encoding ascii -Value ''
      $base = Join-Path $work 'Base.vi'; Set-Content -LiteralPath $base -Encoding ascii -Value ''
      $head = Join-Path $work 'Head.vi'; Set-Content -LiteralPath $head -Encoding ascii -Value ''
      $outDir = Join-Path $work 'out'
      $logPath = Join-Path $outDir 'events.ndjson'

      & pwsh -NoLogo -NoProfile -File $script:driverPath `
        -BaseVi $base -HeadVi $head `
        -LabVIEWExePath $labviewExe `
        -LVComparePath $lvcompareExe `
        -OutputDir $outDir `
        -JsonLogPath $logPath `
        -LeakCheck `
        -CaptureScriptPath $captureStub *> $null

      $LASTEXITCODE | Should -Be 1
      $capturePath = Join-Path $outDir 'lvcompare-capture.json'
      Test-Path -LiteralPath $capturePath | Should -BeTrue
      $cap = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
      $cap.args | Should -Contain '-nobdcosm'
      $cap.args | Should -Contain '-nofppos'
      $cap.args | Should -Contain '-noattr'
      $pathRecord = Join-Path $outDir 'lvcompare-path.txt'
      Test-Path -LiteralPath $pathRecord | Should -BeTrue
      $recorded = (Get-Content -LiteralPath $pathRecord -Raw).Trim()
      $recorded | Should -Be ((Resolve-Path -LiteralPath $lvcompareExe).Path)
    }
    finally { Pop-Location }
  }

  It 'supports ReplaceFlags to override defaults' {
    $work = Join-Path $TestDrive 'driver-custom'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      $captureStub = Join-Path $work 'CaptureStub.ps1'
      $stub = @"
param(
  [string]`$Base,
  [string]`$Head,
  [object]`$LvArgs,
  [string]`$LvComparePath,
  [switch]`$RenderReport,
  [string]`$OutputDir,
  [switch]`$Quiet
)
if (-not (Test-Path `$OutputDir)) { New-Item -ItemType Directory -Path `$OutputDir -Force | Out-Null }
if (`$LvArgs -is [System.Array]) { `$args = @(`$LvArgs) } elseif (`$LvArgs) { `$args = @([string]`$LvArgs) } else { `$args = @() }
$cap = [ordered]@{ schema='lvcompare-capture-v1'; exitCode=0; seconds=0.25; command='stub'; args=$args }
$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path `$OutputDir 'lvcompare-capture.json') -Encoding utf8
exit 0
"@
      Set-Content -LiteralPath $captureStub -Value $stub -Encoding UTF8

      $labviewExe = Join-Path $work 'LabVIEW.exe'; Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''
      $base = Join-Path $work 'Base.vi'; Set-Content -LiteralPath $base -Encoding ascii -Value ''
      $head = Join-Path $work 'Head.vi'; Set-Content -LiteralPath $head -Encoding ascii -Value ''
      $outDir = Join-Path $work 'out'

      & pwsh -NoLogo -NoProfile -File $script:driverPath `
        -BaseVi $base -HeadVi $head `
        -LabVIEWExePath $labviewExe `
        -OutputDir $outDir `
        -Flags @('-foo','-bar','baz') `
        -ReplaceFlags `
        -CaptureScriptPath $captureStub *> $null

      $LASTEXITCODE | Should -Be 0
      $cap = Get-Content -LiteralPath (Join-Path $outDir 'lvcompare-capture.json') -Raw | ConvertFrom-Json
      ($cap.args -contains '-nobdcosm') | Should -BeFalse
      ($cap.args -contains '-nofppos') | Should -BeFalse
      ($cap.args -contains '-noattr') | Should -BeFalse
      $cap.args | Should -Contain '-foo'
      $cap.args | Should -Contain '-bar'
      $cap.args | Should -Contain 'baz'
    }
    finally { Pop-Location }
  }
}
