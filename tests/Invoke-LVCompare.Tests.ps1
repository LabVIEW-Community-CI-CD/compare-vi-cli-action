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
      $stub = @'
param(
  [string]$Base,
  [string]$Head,
  [object]$LvArgs,
  [string]$LvComparePath,
  [switch]$RenderReport,
  [string]$OutputDir,
  [switch]$Quiet
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if ($LvArgs -is [System.Array]) { $args = @($LvArgs) } elseif ($LvArgs) { $args = @([string]$LvArgs) } else { $args = @() }
$cap = [ordered]@{ schema='lvcompare-capture-v1'; exitCode=1; seconds=0.5; command='stub'; args=$args }
$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-capture.json') -Encoding utf8
exit 1
'@
      Set-Content -LiteralPath $captureStub -Value $stub -Encoding UTF8

      $labviewExe = Join-Path $work 'LabVIEW.exe'; Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''
      $base = Join-Path $work 'Base.vi'; Set-Content -LiteralPath $base -Encoding ascii -Value ''
      $head = Join-Path $work 'Head.vi'; Set-Content -LiteralPath $head -Encoding ascii -Value ''
      $outDir = Join-Path $work 'out'
      $logPath = Join-Path $outDir 'events.ndjson'

      $driverQuoted = $script:driverPath.Replace("'", "''")
      $baseQuoted = $base.Replace("'", "''")
      $headQuoted = $head.Replace("'", "''")
      $labviewQuoted = $labviewExe.Replace("'", "''")
      $outQuoted = $outDir.Replace("'", "''")
      $logQuoted = $logPath.Replace("'", "''")
      $stubQuoted = $captureStub.Replace("'", "''")
      $command = "& { & '$driverQuoted' -BaseVi '$baseQuoted' -HeadVi '$headQuoted' -LabVIEWExePath '$labviewQuoted' -OutputDir '$outQuoted' -JsonLogPath '$logQuoted' -LeakCheck -CaptureScriptPath '$stubQuoted'; exit `$LASTEXITCODE }"
      & pwsh -NoLogo -NoProfile -Command $command *> $null

      $LASTEXITCODE | Should -Be 1
      $capturePath = Join-Path $outDir 'lvcompare-capture.json'
      Test-Path -LiteralPath $capturePath | Should -BeTrue
      $cap = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
      $cap.args | Should -Contain '-nobdcosm'
      $cap.args | Should -Contain '-nofppos'
      $cap.args | Should -Contain '-noattr'

      $trackerPath = Join-Path $outDir '_agent' 'labview-pid.json'
      Test-Path -LiteralPath $trackerPath | Should -BeTrue
      $tracker = Get-Content -LiteralPath $trackerPath -Raw | ConvertFrom-Json
      $tracker.context.stage | Should -Be 'lvcompare:summary'
      $tracker.context.status | Should -Be 'diff'
      $tracker.context.compareExitCode | Should -Be 1
      $tracker.context.reportGenerated | Should -BeFalse
    }
    finally { Pop-Location }
  }

  It 'aborts before launch when LabVIEW source control is enabled' {
    $work = Join-Path $TestDrive 'driver-scc-guard'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      $captureStub = Join-Path $work 'CaptureStub.ps1'
      $stub = @'
param(
  [string]$Base,
  [string]$Head,
  [object]$LvArgs,
  [string]$LvComparePath,
  [switch]$RenderReport,
  [string]$OutputDir,
  [switch]$Quiet
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
Set-Content -LiteralPath (Join-Path $OutputDir 'stub-invoked.txt') -Value 'called' -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath $captureStub -Value $stub -Encoding UTF8

      $labviewExe = Join-Path $work 'LabVIEW.exe'; Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''
      $labviewIni = Join-Path $work 'LabVIEW.ini'; Set-Content -LiteralPath $labviewIni -Value "SCCUseInLabVIEW=True`nSCCProviderIsActive=True`n" -Encoding utf8
      $base = Join-Path $work 'Base.vi'; Set-Content -LiteralPath $base -Encoding ascii -Value ''
      $head = Join-Path $work 'Head.vi'; Set-Content -LiteralPath $head -Encoding ascii -Value ''
      $outDir = Join-Path $work 'out'

      $driverQuoted = $script:driverPath.Replace("'", "''")
      $baseQuoted = $base.Replace("'", "''")
      $headQuoted = $head.Replace("'", "''")
      $labviewQuoted = $labviewExe.Replace("'", "''")
      $outQuoted = $outDir.Replace("'", "''")
      $stubQuoted = $captureStub.Replace("'", "''")
      $command = "& { \$WarningPreference = 'Continue'; & '$driverQuoted' -BaseVi '$baseQuoted' -HeadVi '$headQuoted' -LabVIEWExePath '$labviewQuoted' -OutputDir '$outQuoted' -CaptureScriptPath '$stubQuoted' 3>&1; exit `$LASTEXITCODE }"
      $output = & pwsh -NoLogo -NoProfile -Command $command
      $exitCode = $LASTEXITCODE

      $exitCode | Should -Be 2
      $warningLines = @(
        $output | ForEach-Object {
          if ($_ -is [System.Management.Automation.WarningRecord]) { $_ }
          elseif ([string]$_ -match 'WARNING:') { $_ }
        }
      ) | Where-Object { $_ }
      $warningText = $warningLines | ForEach-Object {
        if ($_ -is [System.Management.Automation.WarningRecord]) { $_.Message }
        else { [string]$_ }
      }
      $warningText | Should -Not -BeNullOrEmpty
      ($warningText | Where-Object { $_ -match 'LabVIEW source control is enabled' }) | Should -Not -BeNullOrEmpty
      ($warningText | Where-Object { $_ -match 'Likely cause: LabVIEW Source Control bootstrap dialog' }) | Should -Not -BeNullOrEmpty

      $capturePath = Join-Path $outDir 'lvcompare-capture.json'
      Test-Path -LiteralPath $capturePath | Should -BeFalse
      $stubMarker = Join-Path $outDir 'stub-invoked.txt'
      Test-Path -LiteralPath $stubMarker | Should -BeFalse
    }
    finally { Pop-Location }
  }

  It 'stages duplicate filenames by default' {
    $work = Join-Path $TestDrive 'driver-stage'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      $captureStub = Join-Path $work 'CaptureStub.ps1'
      $stub = @'
param(
  [string]$Base,
  [string]$Head,
  [object]$LvArgs,
  [string]$LvComparePath,
  [switch]$RenderReport,
  [string]$OutputDir,
  [switch]$Quiet
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$log = [ordered]@{ base = $Base; head = $Head }
$log | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'stage-log.json') -Encoding utf8
$cap = [ordered]@{ schema='lvcompare-capture-v1'; exitCode=0; seconds=0.25; command='stub'; args=@() }
$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-capture.json') -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath $captureStub -Value $stub -Encoding UTF8

      $labviewExe = Join-Path $work 'LabVIEW.exe'
      Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''
      $baseDir = Join-Path $work 'base'
      $headDir = Join-Path $work 'head'
      New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null
      $baseVi = Join-Path $baseDir 'Sample.vi'; Set-Content -LiteralPath $baseVi -Encoding ascii -Value ''
      $headVi = Join-Path $headDir 'Sample.vi'; Set-Content -LiteralPath $headVi -Encoding ascii -Value ''
      $outDir = Join-Path $work 'out'

      $driverQuoted = $script:driverPath.Replace("'", "''")
      $baseQuoted = $baseVi.Replace("'", "''")
      $headQuoted = $headVi.Replace("'", "''")
      $labviewQuoted = $labviewExe.Replace("'", "''")
      $outQuoted = $outDir.Replace("'", "''")
      $stubQuoted = $captureStub.Replace("'", "''")
      $command = "& { & '$driverQuoted' -BaseVi '$baseQuoted' -HeadVi '$headQuoted' -LabVIEWExePath '$labviewQuoted' -OutputDir '$outQuoted' -CaptureScriptPath '$stubQuoted'; exit `$LASTEXITCODE }"
      & pwsh -NoLogo -NoProfile -Command $command *> $null

      $LASTEXITCODE | Should -Be 0
      $logPath = Join-Path $outDir 'stage-log.json'
      Test-Path -LiteralPath $logPath | Should -BeTrue
      $stageLog = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $stageLog.base | Should -Not -Be $baseVi
      $stageLog.head | Should -Not -Be $headVi
      (Split-Path -Leaf $stageLog.base) | Should -Be 'Base.vi'
      (Split-Path -Leaf $stageLog.head) | Should -Be 'Head.vi'
      $stageRoot = Split-Path -Parent $stageLog.base
      Test-Path -LiteralPath $stageRoot | Should -BeFalse
    }
    finally { Pop-Location }
  }

  It 'supports ReplaceFlags to override defaults' {
    $work = Join-Path $TestDrive 'driver-custom'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      $captureStub = Join-Path $work 'CaptureStub.ps1'
      $stub = @'
param(
  [string]$Base,
  [string]$Head,
  [object]$LvArgs,
  [string]$LvComparePath,
  [switch]$RenderReport,
  [string]$OutputDir,
  [switch]$Quiet
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if ($LvArgs -is [System.Array]) { $args = @($LvArgs) } elseif ($LvArgs) { $args = @([string]$LvArgs) } else { $args = @() }
$cap = [ordered]@{ schema='lvcompare-capture-v1'; exitCode=0; seconds=0.25; command='stub'; args=$args }
$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-capture.json') -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath $captureStub -Value $stub -Encoding UTF8

      $labviewExe = Join-Path $work 'LabVIEW.exe'; Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''
      $base = Join-Path $work 'Base.vi'; Set-Content -LiteralPath $base -Encoding ascii -Value ''
$head = Join-Path $work 'Head.vi'; Set-Content -LiteralPath $head -Encoding ascii -Value ''
      $outDir = Join-Path $work 'out'

      $logPath = Join-Path $outDir 'events.ndjson'
      $driverQuoted = $script:driverPath.Replace("'", "''")
      $baseQuoted = $base.Replace("'", "''")
      $headQuoted = $head.Replace("'", "''")
      $labviewQuoted = $labviewExe.Replace("'", "''")
      $outQuoted = $outDir.Replace("'", "''")
      $logQuoted = $logPath.Replace("'", "''")
      $stubQuoted = $captureStub.Replace("'", "''")
      $flagsCommand = "-Flags @('alpha','beta','gamma')"
      $command = "& { & '$driverQuoted' -BaseVi '$baseQuoted' -HeadVi '$headQuoted' -LabVIEWExePath '$labviewQuoted' -OutputDir '$outQuoted' $flagsCommand -ReplaceFlags -JsonLogPath '$logQuoted' -CaptureScriptPath '$stubQuoted'; exit `$LASTEXITCODE }"
      & pwsh -NoLogo -NoProfile -Command $command *> $null

      $exitCode = $LASTEXITCODE
      $exitCode | Should -Be 0
      $cap = Get-Content -LiteralPath (Join-Path $outDir 'lvcompare-capture.json') -Raw | ConvertFrom-Json
      ($cap.args -contains '-nobdcosm') | Should -BeFalse
      ($cap.args -contains '-nofppos') | Should -BeFalse
      ($cap.args -contains '-noattr') | Should -BeFalse
      $cap.args | Should -Contain 'alpha'
      $cap.args | Should -Contain 'beta'
      $cap.args | Should -Contain 'gamma'

      $trackerPath = Join-Path $outDir '_agent' 'labview-pid.json'
      Test-Path -LiteralPath $trackerPath | Should -BeTrue
      $tracker = Get-Content -LiteralPath $trackerPath -Raw | ConvertFrom-Json
      $tracker.context.stage | Should -Be 'lvcompare:summary'
      $tracker.context.status | Should -Be 'ok'
      $tracker.context.compareExitCode | Should -Be 0
    }
    finally { Pop-Location }
  }

  It 'forwards TimeoutSeconds to the capture script' {
    $work = Join-Path $TestDrive 'driver-timeout'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      $captureStub = Join-Path $work 'CaptureStub.ps1'
      $stub = @'
param(
  [string]$Base,
  [string]$Head,
  [object]$LvArgs,
  [string]$LvComparePath,
  [switch]$RenderReport,
  [string]$OutputDir,
  [switch]$Quiet,
  [Nullable[int]]$TimeoutSeconds
)
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$log = [ordered]@{
  timeoutProvided = $PSBoundParameters.ContainsKey('TimeoutSeconds')
  timeoutSeconds  = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
}
$log | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'timeout-log.json') -Encoding utf8
$cap = [ordered]@{ schema='lvcompare-capture-v1'; exitCode=0; seconds=0.1; command='stub'; args=@() }
$cap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'lvcompare-capture.json') -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath $captureStub -Value $stub -Encoding UTF8

      $labviewExe = Join-Path $work 'LabVIEW.exe'
      Set-Content -LiteralPath $labviewExe -Encoding ascii -Value ''
      $base = Join-Path $work 'Base.vi'; Set-Content -LiteralPath $base -Encoding ascii -Value ''
      $head = Join-Path $work 'Head.vi'; Set-Content -LiteralPath $head -Encoding ascii -Value ''
      $outDir = Join-Path $work 'out'

      $driverQuoted = $script:driverPath.Replace("'", "''")
      $baseQuoted = $base.Replace("'", "''")
      $headQuoted = $head.Replace("'", "''")
      $labviewQuoted = $labviewExe.Replace("'", "''")
      $outQuoted = $outDir.Replace("'", "''")
      $stubQuoted = $captureStub.Replace("'", "''")
      $command = "& { & '$driverQuoted' -BaseVi '$baseQuoted' -HeadVi '$headQuoted' -LabVIEWExePath '$labviewQuoted' -OutputDir '$outQuoted' -CaptureScriptPath '$stubQuoted' -TimeoutSeconds 12; exit `$LASTEXITCODE }"
      & pwsh -NoLogo -NoProfile -Command $command *> $null

      $LASTEXITCODE | Should -Be 0
      $logPath = Join-Path $outDir 'timeout-log.json'
      Test-Path -LiteralPath $logPath | Should -BeTrue
      $log = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $log.timeoutProvided | Should -BeTrue
      $log.timeoutSeconds | Should -Be 12
    }
    finally { Pop-Location }
  }

}
