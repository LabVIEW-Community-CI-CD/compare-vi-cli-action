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
  [switch]`$Quiet,
  [string]`$ReportStagingDir
)
if (-not (Test-Path `$OutputDir)) { New-Item -ItemType Directory -Path `$OutputDir -Force | Out-Null }
if (`$LvArgs -is [System.Array]) { `$args = @(`$LvArgs) } elseif (`$LvArgs) { `$args = @([string]`$LvArgs) } else { `$args = @() }
`$timestamp = (Get-Date).ToUniversalTime().ToString('o')
`$basePath = (Resolve-Path -LiteralPath `$Base).Path
`$headPath = (Resolve-Path -LiteralPath `$Head).Path
if (`$LvComparePath) {
  `$cliPath = try { (Resolve-Path -LiteralPath `$LvComparePath).Path } catch { `$LvComparePath }
} else {
  `$cliPath = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
}
`$lvPathValue = `$null
`$flagsOnly = @()
for (`$i = 0; `$i -lt `$args.Count; `$i++) {
  `$tok = `$args[`$i]
  if (`$null -eq `$tok) { continue }
  if (`$tok -ieq '-lvpath' -and (`$i + 1) -lt `$args.Count) {
    `$lvPathValue = `$args[`$i + 1]
    `$i++
    continue
  }
  if (`$tok.StartsWith('-')) { `$flagsOnly += `$tok }
}
if (-not `$lvPathValue) { `$lvPathValue = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe' }
`$stdout = 'stub-run'
`$cap = [ordered]@{
  schema    = 'lvcompare-capture-v1'
  timestamp = `$timestamp
  base      = `$basePath
  head      = `$headPath
  cliPath   = `$cliPath
  args      = @(`$args)
  lvPath    = `$lvPathValue
  flags     = @(`$flagsOnly)
  exitCode  = 1
  seconds   = 0.5
  stdoutLen = `$stdout.Length
  stderrLen = 0
  command   = 'stub lvcompare'
  stdout    = `$stdout
  stderr    = `$null
  diffDetected = `$true
}
`$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path `$OutputDir 'lvcompare-capture.json') -Encoding utf8
if (`$LvComparePath) { `$resolved = try { (Resolve-Path -LiteralPath `$LvComparePath).Path } catch { `$LvComparePath } } else { `$resolved = '' }
Set-Content -LiteralPath (Join-Path `$OutputDir 'lvcompare-path.txt') -Value `$resolved -Encoding utf8
if (`$ReportStagingDir) {
  if (-not (Test-Path `$ReportStagingDir)) { New-Item -ItemType Directory -Path `$ReportStagingDir -Force | Out-Null }
  Set-Content -LiteralPath (Join-Path `$ReportStagingDir 'compare-report.html') -Value 'stub-report' -Encoding utf8
}
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
      $cap.flags | Should -Contain '-nobdcosm'
      $cap.flags | Should -Contain '-nofppos'
      $cap.flags | Should -Contain '-noattr'
      ($cap.flags -contains '-lvpath') | Should -BeFalse
      $cap.lvPath | Should -Be ((Resolve-Path -LiteralPath $labviewExe).Path)
      $cap.cliPath | Should -Be ((Resolve-Path -LiteralPath $lvcompareExe).Path)
      $cap.diffDetected | Should -BeTrue
      $ts = $cap.timestamp
      if ($ts -isnot [string]) { $ts = $ts.ToString('o') }
      [regex]::IsMatch($ts, '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') | Should -BeTrue
      $pathRecord = Join-Path $outDir 'lvcompare-path.txt'
      Test-Path -LiteralPath $pathRecord | Should -BeTrue
      $recorded = (Get-Content -LiteralPath $pathRecord -Raw).Trim()
      $recorded | Should -Be ((Resolve-Path -LiteralPath $lvcompareExe).Path)
      $stagingReport = Join-Path (Join-Path (Join-Path $outDir '_staging') 'compare') 'compare-report.html'
      Test-Path -LiteralPath $stagingReport | Should -BeTrue
    }
    finally { Pop-Location }
  }

  It 'merges additional flags (e.g. -nobdpos) with defaults' {
    $work = Join-Path $TestDrive 'driver-with-extra-flag'
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
  [switch]`$Quiet,
  [string]`$ReportStagingDir
)
if (-not (Test-Path `$OutputDir)) { New-Item -ItemType Directory -Path `$OutputDir -Force | Out-Null }
if (`$LvArgs -is [System.Array]) { `$args = @(`$LvArgs) } elseif (`$LvArgs) { `$args = @([string]`$LvArgs) } else { `$args = @() }
`$timestamp = (Get-Date).ToUniversalTime().ToString('o')
`$basePath = (Resolve-Path -LiteralPath `$Base).Path
`$headPath = (Resolve-Path -LiteralPath `$Head).Path
if (`$LvComparePath) {
  `$cliPath = try { (Resolve-Path -LiteralPath `$LvComparePath).Path } catch { `$LvComparePath }
} else {
  `$cliPath = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
}
`$lvPathValue = `$null
`$flagsOnly = @()
for (`$i = 0; `$i -lt `$args.Count; `$i++) {
  `$tok = `$args[`$i]
  if (`$null -eq `$tok) { continue }
  if (`$tok -ieq '-lvpath' -and (`$i + 1) -lt `$args.Count) {
    `$lvPathValue = `$args[`$i + 1]
    `$i++
    continue
  }
  if (`$tok.StartsWith('-')) { `$flagsOnly += `$tok }
}
if (-not `$lvPathValue) { `$lvPathValue = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe' }
`$cap = [ordered]@{
  schema    = 'lvcompare-capture-v1'
  timestamp = `$timestamp
  base      = `$basePath
  head      = `$headPath
  cliPath   = `$cliPath
  args      = @(`$args)
  lvPath    = `$lvPathValue
  flags     = @(`$flagsOnly)
  exitCode  = 0
  seconds   = 0.25
  stdoutLen = 0
  stderrLen = 0
  command   = 'stub lvcompare'
  stdout    = `$null
  stderr    = `$null
  diffDetected = `$false
}
`$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path `$OutputDir 'lvcompare-capture.json') -Encoding utf8
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
        -Flags @('-nobdpos') `
        -CaptureScriptPath $captureStub *> $null

      $LASTEXITCODE | Should -Be 0
      $cap = Get-Content -LiteralPath (Join-Path $outDir 'lvcompare-capture.json') -Raw | ConvertFrom-Json
      foreach ($expected in @('-nobdcosm','-nofppos','-noattr','-nobdpos')) {
        $cap.args | Should -Contain $expected
        $cap.flags | Should -Contain $expected
      }
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
  [switch]`$Quiet,
  [string]`$ReportStagingDir
)
if (-not (Test-Path `$OutputDir)) { New-Item -ItemType Directory -Path `$OutputDir -Force | Out-Null }
if (`$LvArgs -is [System.Array]) { `$args = @(`$LvArgs) } elseif (`$LvArgs) { `$args = @([string]`$LvArgs) } else { `$args = @() }
`$timestamp = (Get-Date).ToUniversalTime().ToString('o')
`$basePath = (Resolve-Path -LiteralPath `$Base).Path
`$headPath = (Resolve-Path -LiteralPath `$Head).Path
`$lvPathValue = `$null
`$flagsOnly = @()
for (`$i = 0; `$i -lt `$args.Count; `$i++) {
  `$tok = `$args[`$i]
  if (`$null -eq `$tok) { continue }
  if (`$tok -ieq '-lvpath' -and (`$i + 1) -lt `$args.Count) {
    `$lvPathValue = `$args[`$i + 1]
    `$i++
    continue
  }
  if (`$tok.StartsWith('-')) { `$flagsOnly += `$tok }
}
if (-not `$lvPathValue) { `$lvPathValue = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe' }
`$cap = [ordered]@{
  schema    = 'lvcompare-capture-v1'
  timestamp = `$timestamp
  base      = `$basePath
  head      = `$headPath
  cliPath   = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  args      = @(`$args)
  lvPath    = `$lvPathValue
  flags     = @(`$flagsOnly)
  exitCode  = 0
  seconds   = 0.25
  stdoutLen = 0
  stderrLen = 0
  command   = 'stub lvcompare'
  stdout    = `$null
  stderr    = `$null
  diffDetected = `$false
}
`$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path `$OutputDir 'lvcompare-capture.json') -Encoding utf8
if (`$ReportStagingDir) {
  if (-not (Test-Path `$ReportStagingDir)) { New-Item -ItemType Directory -Path `$ReportStagingDir -Force | Out-Null }
  Set-Content -LiteralPath (Join-Path `$ReportStagingDir 'compare-report.html') -Value 'stub-report' -Encoding utf8
}
exit 0
"@
      Set-Content -LiteralPath $captureStub -Value $stub -Encoding UTF8

      $labviewExe = Join-Path $work 'LabVIEW.exe'; Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''
      $base = Join-Path $work 'Base.vi'; Set-Content -LiteralPath $base -Encoding ascii -Value ''
      $head = Join-Path $work 'Head.vi'; Set-Content -LiteralPath $head -Encoding ascii -Value ''
      $outDir = Join-Path $work 'out'

      $driverResolved = (Resolve-Path -LiteralPath $script:driverPath).Path
      $command = "& `"$driverResolved`" -BaseVi `"$base`" -HeadVi `"$head`" -LabVIEWExePath `"$labviewExe`" -OutputDir `"$outDir`" -Flags @('-foo','-bar','baz') -ReplaceFlags -CaptureScriptPath `"$captureStub`""
      & pwsh -NoLogo -NoProfile -Command $command *> $null

      $LASTEXITCODE | Should -Be 0
      $cap = Get-Content -LiteralPath (Join-Path $outDir 'lvcompare-capture.json') -Raw | ConvertFrom-Json
      ($cap.args -contains '-nobdcosm') | Should -BeFalse
      ($cap.args -contains '-nofppos') | Should -BeFalse
      ($cap.args -contains '-noattr') | Should -BeFalse
      $cap.args | Should -Contain '-foo'
      $cap.args | Should -Contain '-bar'
      $cap.args | Should -Contain 'baz'
      $cap.flags | Should -Contain '-foo'
      $cap.flags | Should -Contain '-bar'
      ($cap.flags -contains 'baz') | Should -BeFalse
      $cap.lvPath | Should -Be ((Resolve-Path -LiteralPath $labviewExe).Path)
      $cap.diffDetected | Should -BeFalse
      $stagingReport = Join-Path (Join-Path (Join-Path $outDir '_staging') 'compare') 'compare-report.html'
      Test-Path -LiteralPath $stagingReport | Should -BeTrue
    }
    finally { Pop-Location }
  }
}
