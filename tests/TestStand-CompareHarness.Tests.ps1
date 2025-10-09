Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'TestStand-CompareHarness.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:HarnessPath = Join-Path $repoRoot 'tools' 'TestStand-CompareHarness.ps1'
    Test-Path -LiteralPath $script:HarnessPath | Should -BeTrue
  }

  It 'produces session index using stubbed tooling' {
    $root = Join-Path $TestDrive 'harness'
    New-Item -ItemType Directory -Path $root | Out-Null
    Push-Location $root
    try {
      New-Item -ItemType Directory -Path 'tools' | Out-Null
      Copy-Item -LiteralPath $script:HarnessPath -Destination 'tools/TestStand-CompareHarness.ps1'

      $warmupStub = @'
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
      Set-Content -LiteralPath 'tools/Warmup-LabVIEWRuntime.ps1' -Value $warmupStub -Encoding UTF8

      $driverStub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [Alias('LabVIEWPath')]
  [string]$LabVIEWExePath,
  [Alias('LVCompareExePath')]
  [string]$LVComparePath,
  [string]$OutputDir,
  [switch]$RenderReport,
  [string]$JsonLogPath
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if ($JsonLogPath) {
  $dir = Split-Path -Parent $JsonLogPath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  '{"type":"compare","schema":"stub"}' | Set-Content -LiteralPath $JsonLogPath -Encoding utf8
}
$cap = [ordered]@{
  schema   = 'lvcompare-capture-v1'
  exitCode = 1
  seconds  = 0.42
  command  = 'stub lvcompare'
}
$cap | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-capture.json') -Encoding utf8
'report' | Set-Content -LiteralPath (Join-Path $OutputDir 'compare-report.html') -Encoding utf8
exit 1
'@
      Set-Content -LiteralPath 'tools/Invoke-LVCompare.ps1' -Value $driverStub -Encoding UTF8

      Set-Content -LiteralPath 'tools/Close-LVCompare.ps1' -Value "param() exit 0" -Encoding UTF8
      Set-Content -LiteralPath 'tools/Close-LabVIEW.ps1' -Value "param() exit 0" -Encoding UTF8

      Set-Content -LiteralPath 'VI1.vi' -Value '' -Encoding ascii
      Set-Content -LiteralPath 'VI2.vi' -Value '' -Encoding ascii
      Set-Content -LiteralPath 'LabVIEW.exe' -Value '' -Encoding ascii

      & pwsh -NoLogo -NoProfile -File 'tools/TestStand-CompareHarness.ps1' `
        -BaseVi ./VI1.vi `
        -HeadVi ./VI2.vi `
        -LabVIEWPath ./LabVIEW.exe `
        -RenderReport `
        -CloseLabVIEW `
        -CloseLVCompare *> $null

      $LASTEXITCODE | Should -Be 1
      $indexPath = Join-Path $root 'tests/results/teststand-session/session-index.json'
      Test-Path -LiteralPath $indexPath | Should -BeTrue
      $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
      $index.schema | Should -Be 'teststand-compare-session/v1'
      $index.warmup.events | Should -Match 'labview-runtime.ndjson'
      $index.compare.capture | Should -Match 'lvcompare-capture.json'
      $index.compare.report | Should -Not -BeNullOrEmpty
      $index.outcome | Should -Not -BeNullOrEmpty
    }
    finally {
      Pop-Location
    }
  }
}
