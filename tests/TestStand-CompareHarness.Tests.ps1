Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'TestStand-CompareHarness.ps1 (VI2 baseline pair)' -Tag 'Unit' {
  It 'passes repo VI2 artefacts to Invoke-LVCompare' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $baseReal = Join-Path $repoRoot 'VI2.vi'
    $headReal = Join-Path $repoRoot 'tmp-commit-236ffab\VI2.vi'
    if (-not (Test-Path -LiteralPath $baseReal -PathType Leaf) -or -not (Test-Path -LiteralPath $headReal -PathType Leaf)) {
      Set-ItResult -Skipped -Because 'Required VI fixtures not present'
      return
    }

    $work = Join-Path $TestDrive 'harness-vi2-specific'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      New-Item -ItemType Directory -Path 'tools' | Out-Null
      Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\TestStand-CompareHarness.ps1') -Destination 'tools\TestStand-CompareHarness.ps1'

      Set-Content -LiteralPath 'tools/Warmup-LabVIEWRuntime.ps1' -Encoding UTF8 -Value @'
param(
  [string]$LabVIEWPath,
  [string]$JsonLogPath
)
if ($JsonLogPath) {
  $dir = Split-Path -Parent $JsonLogPath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  '{"type":"warmup","schema":"stub"}' | Set-Content -LiteralPath $JsonLogPath -Encoding utf8
}
exit 0
'@

      $invokeStub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [Alias('LabVIEWPath')]
  [string]$LabVIEWExePath,
  [Alias('LVCompareExePath')]
  [string]$LVComparePath,
  [string]$OutputDir,
  [switch]$RenderReport,
  [string]$JsonLogPath,
  [object]$Flags,
  [string]$NoiseProfile
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$argsArray = @()
if ($Flags -is [System.Array]) { $argsArray = @($Flags) }
elseif ($Flags) { $argsArray = @([string]$Flags) }
$log = [pscustomobject]@{
  base = $BaseVi
  head = $HeadVi
  lvExe = $LabVIEWExePath
  lvCompare = $LVComparePath
  noiseProfile = $NoiseProfile
}
$log | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'invoke-args.json') -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath 'tools/Invoke-LVCompare.ps1' -Value $invokeStub -Encoding UTF8

      Set-Content -LiteralPath 'tools/Close-LVCompare.ps1' -Value "param() exit 0" -Encoding UTF8
      Set-Content -LiteralPath 'tools/Close-LabVIEW.ps1' -Value "param() exit 0" -Encoding UTF8

      $outputRoot = Join-Path $work 'results'
      $harness = Join-Path $work 'tools\TestStand-CompareHarness.ps1'
      $stageDir = Join-Path $work 'stage'
      New-Item -ItemType Directory -Path $stageDir | Out-Null
      $stagedBase = Join-Path $stageDir 'Base.vi'
      $stagedHead = Join-Path $stageDir 'Head.vi'
      Copy-Item -LiteralPath $baseReal -Destination $stagedBase -Force
      Copy-Item -LiteralPath $headReal -Destination $stagedHead -Force

      & pwsh -NoLogo -NoProfile -File $harness `
        -BaseVi $stagedBase `
        -HeadVi $stagedHead `
        -LabVIEWPath 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe' `
        -OutputRoot $outputRoot `
        -Warmup skip `
        -RenderReport:$false `
        -CloseLabVIEW `
        -CloseLVCompare `
        -StagingRoot $stageDir `
        -SameNameHint *> $null

      $invokeLogPath = Get-ChildItem -Path $outputRoot -Recurse -Filter 'invoke-args.json' | Select-Object -First 1
      $invokeLogPath | Should -Not -BeNullOrEmpty
      $invokeData = Get-Content -LiteralPath $invokeLogPath.FullName -Raw | ConvertFrom-Json
      $invokeData.base | Should -Be $stagedBase
      $invokeData.head | Should -Be $stagedHead
      $invokeData.lvExe | Should -Be 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
      $invokeData.lvCompare | Should -BeNullOrEmpty
      $invokeData.noiseProfile | Should -Be 'full'

      $sessionIndex = Join-Path $outputRoot 'session-index.json'
      Test-Path -LiteralPath $sessionIndex | Should -BeTrue
      $indexData = Get-Content -LiteralPath $sessionIndex -Raw | ConvertFrom-Json
      $indexData.compare.sameName | Should -BeTrue
      $indexData.compare.staging.enabled | Should -BeTrue
      $indexData.compare.staging.root | Should -Be $stageDir
    }
    finally { Pop-Location }
  }
}

Describe 'TestStand-CompareHarness.ps1 (auto CLI fallback)' -Tag 'Unit' {
  It 'skips warmup and records autoCli when comparing same-name VIs' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $baseDir = Join-Path $TestDrive 'base'
    $headDir = Join-Path $TestDrive 'head'
    New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null
    $baseVi = Join-Path $baseDir 'Sample.vi'
    $headVi = Join-Path $headDir 'Sample.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding UTF8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding UTF8

    $work = Join-Path $TestDrive 'harness-auto-cli'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      New-Item -ItemType Directory -Path 'tools' | Out-Null
      Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\TestStand-CompareHarness.ps1') -Destination 'tools\TestStand-CompareHarness.ps1'

      $sentinel = Join-Path $work 'warmup-called.txt'
      $sentinelLiteral = $sentinel -replace "'", "''"
      Set-Content -LiteralPath 'tools/Warmup-LabVIEWRuntime.ps1' -Encoding UTF8 -Value @"
param()
Set-Content -LiteralPath '$sentinelLiteral' -Value 'warmup' -Encoding utf8
exit 0
"@

      $invokeStub = @"
param(
  [string]`$BaseVi,
  [string]`$HeadVi,
  [Alias('LabVIEWPath')][string]`$LabVIEWExePath,
  [Alias('LVCompareExePath')][string]`$LVComparePath,
  [string]`$OutputDir,
  [switch]`$RenderReport,
  [string]`$JsonLogPath,
  [object]`$Flags
  [string]`$NoiseProfile
)
if (-not (Test-Path `$OutputDir)) { New-Item -ItemType Directory -Path `$OutputDir -Force | Out-Null }
if (`$JsonLogPath) { '{}' | Set-Content -LiteralPath `$JsonLogPath -Encoding utf8 }
`$capture = @{ exitCode = 0; seconds = 0.5; command = 'stub-cli' } | ConvertTo-Json
Set-Content -LiteralPath (Join-Path `$OutputDir 'lvcompare-capture.json') -Value `$capture -Encoding utf8
if (`$RenderReport) { Set-Content -LiteralPath (Join-Path `$OutputDir 'compare-report.html') -Value '<html/>' -Encoding utf8 }
exit 0
"@
      Set-Content -LiteralPath 'tools/Invoke-LVCompare.ps1' -Value $invokeStub -Encoding UTF8
      Set-Content -LiteralPath 'tools/Close-LVCompare.ps1' -Value "param() exit 0" -Encoding UTF8
      Set-Content -LiteralPath 'tools/Close-LabVIEW.ps1' -Value "param() exit 0" -Encoding UTF8

      $harness = Join-Path $work 'tools\TestStand-CompareHarness.ps1'
      $outputRoot = Join-Path $work 'results'
      $stageDir = Join-Path $work 'stage'
      New-Item -ItemType Directory -Path $stageDir | Out-Null
      $stagedBase = Join-Path $stageDir 'Base.vi'
      $stagedHead = Join-Path $stageDir 'Head.vi'
      Copy-Item -LiteralPath $baseVi -Destination $stagedBase -Force
      Copy-Item -LiteralPath $headVi -Destination $stagedHead -Force
      $previousPolicy = $env:LVCI_COMPARE_POLICY
      try {
        Remove-Item Env:LVCI_COMPARE_POLICY -ErrorAction SilentlyContinue
        & pwsh -NoLogo -NoProfile -File $harness `
          -BaseVi $stagedBase `
          -HeadVi $stagedHead `
          -OutputRoot $outputRoot `
          -Warmup detect `
          -RenderReport `
          -CloseLabVIEW `
          -StagingRoot $stageDir `
          -SameNameHint *> $null
      } finally {
        if ($null -ne $previousPolicy) { $env:LVCI_COMPARE_POLICY = $previousPolicy } else { Remove-Item Env:LVCI_COMPARE_POLICY -ErrorAction SilentlyContinue }
      }

      Test-Path -LiteralPath $sentinel | Should -BeFalse
      $sessionIndex = Join-Path $outputRoot 'session-index.json'
      Test-Path -LiteralPath $sessionIndex | Should -BeTrue
      $indexData = Get-Content -LiteralPath $sessionIndex -Raw | ConvertFrom-Json
      $indexData.compare.policy | Should -Be 'cli-only'
      $indexData.compare.mode | Should -Be 'labview-cli'
      $indexData.compare.autoCli | Should -BeTrue
      $indexData.compare.sameName | Should -BeTrue
      $indexData.compare.timeoutSeconds | Should -Be 600
      $indexData.compare.staging.enabled | Should -BeTrue
      $indexData.compare.staging.root | Should -Be $stageDir
    }
    finally { Pop-Location }
  }
}

Describe 'TestStand-CompareHarness.ps1 (dual-plane parity)' -Tag 'Unit' {
  It 'runs LabVIEW 2026 x64 and x32 sessions simultaneously and emits a parity session index' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $baseDir = Join-Path $TestDrive 'dual-base'
    $headDir = Join-Path $TestDrive 'dual-head'
    New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null
    $baseVi = Join-Path $baseDir 'Base.vi'
    $headVi = Join-Path $headDir 'Head.vi'
    Set-Content -LiteralPath $baseVi -Value 'base' -Encoding UTF8
    Set-Content -LiteralPath $headVi -Value 'head' -Encoding UTF8

    $work = Join-Path $TestDrive 'harness-dual-plane'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      New-Item -ItemType Directory -Path 'tools' | Out-Null
      Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\TestStand-CompareHarness.ps1') -Destination 'tools\TestStand-CompareHarness.ps1'

      Set-Content -LiteralPath 'tools/Warmup-LabVIEWRuntime.ps1' -Encoding UTF8 -Value @'
param(
  [string]$LabVIEWPath,
  [string]$JsonLogPath,
  [string]$SupportedBitness
)
if ($JsonLogPath) {
  $dir = Split-Path -Parent $JsonLogPath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  (@{ type = 'warmup'; bitness = $SupportedBitness; labview = $LabVIEWPath } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $JsonLogPath -Encoding utf8
}
exit 0
'@

      $invokeStub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [Alias('LabVIEWPath')]
  [string]$LabVIEWExePath,
  [Alias('LVCompareExePath')]
  [string]$LVComparePath,
  [string]$OutputDir,
  [switch]$RenderReport,
  [string]$JsonLogPath,
  [object]$Flags,
  [string]$NoiseProfile,
  [string]$LabVIEWBitness
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if ($JsonLogPath) {
  '{}' | Set-Content -LiteralPath $JsonLogPath -Encoding utf8
}
$capture = [ordered]@{
  exitCode = 0
  seconds = if ($LabVIEWBitness -eq '32') { 1.32 } else { 1.64 }
  command = "stub-$LabVIEWBitness"
  cliPath = "C:\Program Files\National Instruments\Shared\LabVIEW CLI\$LabVIEWBitness\LabVIEWCLI.exe"
  environment = @{
    cli = @{
      path = "C:\Program Files\National Instruments\Shared\LabVIEW CLI\$LabVIEWBitness\LabVIEWCLI.exe"
      version = '26.0.0f0'
      reportType = 'html'
      reportPath = 'compare-report.html'
      status = 'ok'
      message = "compare completed for $LabVIEWBitness"
    }
  }
}
$capture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-capture.json') -Encoding utf8
if ($RenderReport) {
  Set-Content -LiteralPath (Join-Path $OutputDir 'compare-report.html') -Value "<html data-bitness='$LabVIEWBitness'/>" -Encoding utf8
}
exit 0
'@
      Set-Content -LiteralPath 'tools/Invoke-LVCompare.ps1' -Value $invokeStub -Encoding UTF8
      Set-Content -LiteralPath 'tools/Close-LVCompare.ps1' -Value "param() exit 0" -Encoding UTF8
      Set-Content -LiteralPath 'tools/Close-LabVIEW.ps1' -Value "param() exit 0" -Encoding UTF8

      $outputRoot = Join-Path $work 'results'
      $harness = Join-Path $work 'tools\TestStand-CompareHarness.ps1'
      & pwsh -NoLogo -NoProfile -File $harness `
        -BaseVi $baseVi `
        -HeadVi $headVi `
        -OutputRoot $outputRoot `
        -SuiteClass dual-plane-parity `
        -LabVIEW64ExePath 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe' `
        -LabVIEW32ExePath 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe' `
        -Warmup detect `
        -RenderReport *> $null

      $LASTEXITCODE | Should -Be 0

      $sessionIndex = Join-Path $outputRoot 'session-index.json'
      Test-Path -LiteralPath $sessionIndex | Should -BeTrue
      $indexData = Get-Content -LiteralPath $sessionIndex -Raw | ConvertFrom-Json -Depth 12
      $indexData.schema | Should -Be 'teststand-compare-session/v2'
      $indexData.suiteClass | Should -Be 'dual-plane-parity'
      $indexData.primaryPlane | Should -Be 'native-labview-2026-64'
      $indexData.requestedSimultaneous | Should -BeTrue
      $indexData.parity.status | Should -Be 'match'
      $indexData.parity.mismatchCount | Should -Be 0
      $indexData.planes.x64.plane | Should -Be 'native-labview-2026-64'
      $indexData.planes.x32.plane | Should -Be 'native-labview-2026-32'
      $indexData.planes.x64.architecture | Should -Be '64-bit'
      $indexData.planes.x32.architecture | Should -Be '32-bit'
      $indexData.planes.x64.labviewExePath | Should -Be 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
      $indexData.planes.x32.labviewExePath | Should -Be 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
      $indexData.planes.x64.outcome.exitCode | Should -Be 0
      $indexData.planes.x32.outcome.exitCode | Should -Be 0
      $indexData.planes.x64.compare.report | Should -BeTrue
      $indexData.planes.x32.compare.report | Should -BeTrue
      $indexData.planes.x64.compare.policy | Should -Be 'cli-only'
      $indexData.planes.x32.compare.policy | Should -Be 'cli-only'
      $indexData.planes.x64.compare.mode | Should -Be 'labview-cli'
      $indexData.planes.x32.compare.mode | Should -Be 'labview-cli'
      Test-Path -LiteralPath (Join-Path $outputRoot 'planes\x64\session-index.json') | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $outputRoot 'planes\x32\session-index.json') | Should -BeTrue
    }
    finally { Pop-Location }
  }
}
