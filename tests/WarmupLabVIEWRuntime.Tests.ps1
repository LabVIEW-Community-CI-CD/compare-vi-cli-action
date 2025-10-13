Describe 'Warmup-LabVIEWRuntime.ps1' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:warmupPath = Join-Path $repoRoot 'tools/Warmup-LabVIEWRuntime.ps1'
  }

  AfterEach {
    Remove-Item Env:LABVIEW_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:LV_BASE_VI -ErrorAction SilentlyContinue
    Remove-Item Env:LV_HEAD_VI -ErrorAction SilentlyContinue
    Remove-Item Env:WARMUP_PRIME_SCRIPT -ErrorAction SilentlyContinue
    Remove-Item Env:WARMUP_NO_JSON -ErrorAction SilentlyContinue
  }

  It 'honours dry run without invoking LVCompare' {
    $logPath = Join-Path $TestDrive 'warmup.ndjson'
    $labviewExe = Join-Path $TestDrive 'LabVIEW.exe'
    Set-Content -LiteralPath $labviewExe -Value '' -Encoding ascii
    $env:LABVIEW_PATH = $labviewExe

    Push-Location $repoRoot
    try {
      $output = & $warmupPath -DryRun -JsonLogPath $logPath 2>&1
    } finally {
      Pop-Location
    }

    Test-Path $logPath | Should -BeTrue
    $events = Get-Content -LiteralPath $logPath
    ($events | Select-String -SimpleMatch '"strategy":"lvcompare-prime"') | Should -Not -BeNullOrEmpty
    ($events | Select-String -SimpleMatch '"reason":"dry-run"') | Should -Not -BeNullOrEmpty
  }

  It 'invokes prime script with expected arguments' {
    $labviewExe = Join-Path $TestDrive 'LabVIEW.exe'
    Set-Content -LiteralPath $labviewExe -Value '' -Encoding ascii
    $env:LABVIEW_PATH = $labviewExe

    $baseVi = Join-Path $TestDrive 'base.vi'
    $headVi = Join-Path $TestDrive 'head.vi'
    New-Item -ItemType File -Path $baseVi -Force | Out-Null
    New-Item -ItemType File -Path $headVi -Force | Out-Null
    $env:LV_BASE_VI = $baseVi
    $env:LV_HEAD_VI = $headVi

    $primeLog = Join-Path $TestDrive 'prime-log.json'
    $stubPrime = Join-Path $TestDrive 'Prime-LVCompare.ps1'
    $stubContent = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$LabVIEWExePath,
  [string]$LabVIEWBitness,
  [switch]$ExpectNoDiff,
  [switch]$LeakCheck,
  [switch]$KillOnTimeout
)
$logPath = Join-Path $PSScriptRoot 'prime-log.json'
$payload = [ordered]@{
  baseVi        = $BaseVi
  headVi        = $HeadVi
  labviewExe    = $LabVIEWExePath
  bitness       = $LabVIEWBitness
  expectNoDiff  = $ExpectNoDiff.IsPresent
  leakCheck     = $LeakCheck.IsPresent
  killOnTimeout = $KillOnTimeout.IsPresent
}
$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $logPath -Encoding utf8
exit 0
'@
    Set-Content -LiteralPath $stubPrime -Encoding utf8 -Value $stubContent
    $env:WARMUP_PRIME_SCRIPT = $stubPrime

    $jsonLog = Join-Path $TestDrive 'warmup.ndjson'
    Push-Location $repoRoot
    try {
      & $warmupPath -JsonLogPath $jsonLog | Out-Null
    } finally {
      Pop-Location
    }

    Test-Path $primeLog | Should -BeTrue
    $record = Get-Content -LiteralPath $primeLog -Raw | ConvertFrom-Json
    $record.baseVi | Should -Be $baseVi
    $record.headVi | Should -Be $headVi
    $record.labviewExe | Should -Be $labviewExe
    $record.bitness | Should -Be '64'
    $record.expectNoDiff | Should -BeTrue
    $record.leakCheck | Should -BeTrue

    $events = Get-Content -LiteralPath $jsonLog
    ($events | Select-String -SimpleMatch '"prime-start"') | Should -Not -BeNullOrEmpty
    ($events | Select-String -SimpleMatch '"warmup-complete"') | Should -Not -BeNullOrEmpty
  }
}
