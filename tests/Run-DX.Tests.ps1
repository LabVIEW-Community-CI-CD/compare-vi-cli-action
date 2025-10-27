Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Run-DX.ps1 (TestStand staging)' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunDxPath = Join-Path $repoRoot 'tools' 'Run-DX.ps1'
    $script:StageScriptPath = Join-Path $repoRoot 'tools' 'Stage-CompareInputs.ps1'
    Test-Path -LiteralPath $script:RunDxPath | Should -BeTrue
    Test-Path -LiteralPath $script:StageScriptPath | Should -BeTrue
  }

  It 'stages duplicate filenames by default and cleans up temp directory' {
    $work = Join-Path $TestDrive 'dx-stage-default'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      New-Item -ItemType Directory -Path 'tools' | Out-Null
      Copy-Item -LiteralPath $script:RunDxPath -Destination 'tools/Run-DX.ps1'
      Copy-Item -LiteralPath $script:StageScriptPath -Destination 'tools/Stage-CompareInputs.ps1'
      $harnessStub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$OutputRoot,
  [string]$StagingRoot,
  [switch]$SameNameHint,
  [switch]$AllowSameLeaf,
  [string]$Warmup
)
if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
$log = [ordered]@{
  base          = $BaseVi
  head          = $HeadVi
  stagingRoot   = $StagingRoot
  sameNameHint  = $SameNameHint.IsPresent
  allowSameLeaf = $AllowSameLeaf.IsPresent
  warmup        = $Warmup
}
$log | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'harness-log.json') -Encoding utf8
$session = [ordered]@{
  schema = 'teststand-compare-session/v1'
  warmup = @{
    mode   = $Warmup
    events = $null
  }
  compare = @{
    events  = $null
    capture = $null
    report  = $false
    staging = @{
      enabled = (-not [string]::IsNullOrWhiteSpace($StagingRoot))
      root    = $StagingRoot
    }
    allowSameLeaf = $AllowSameLeaf.IsPresent
    mode    = 'labview-cli'
    autoCli = $SameNameHint.IsPresent
  }
  outcome = $null
  error   = $null
}
$session | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputRoot 'session-index.json') -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath (Join-Path $work 'tools/TestStand-CompareHarness.ps1') -Value $harnessStub -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $work 'tools/Debug-ChildProcesses.ps1') -Encoding UTF8 -Value "param() exit 0"
      Set-Content -LiteralPath (Join-Path $work 'tools/Detect-RogueLV.ps1') -Encoding UTF8 -Value "param() exit 0"

      $baseDir = Join-Path $work 'base'
      $headDir = Join-Path $work 'head'
      New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null
      $baseVi = Join-Path $baseDir 'Sample.vi'
      $headVi = Join-Path $headDir 'Sample.vi'
      Set-Content -LiteralPath $baseVi -Value 'base' -Encoding UTF8
      Set-Content -LiteralPath $headVi -Value 'head' -Encoding UTF8

      $outputRoot = Join-Path $work 'results'
      $runDx = Join-Path $work 'tools/Run-DX.ps1'
      & pwsh -NoLogo -NoProfile -File $runDx `
        -Suite TestStand `
        -BaseVi $baseVi `
        -HeadVi $headVi `
        -OutputRoot $outputRoot `
        -Warmup skip *> $null
      $LASTEXITCODE | Should -Be 0

      $logPath = Join-Path $outputRoot 'harness-log.json'
      Test-Path -LiteralPath $logPath | Should -BeTrue
      $log = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $allowedLegacy = @((Split-Path -Leaf $baseVi), (Split-Path -Leaf $headVi), 'Base.vi', 'Head.vi') | Select-Object -Unique
      $legacyPattern = '({0})$' -f (($allowedLegacy | ForEach-Object { [regex]::Escape($_) }) -join '|')
      $log.base | Should -Match $legacyPattern
      $log.head | Should -Match $legacyPattern
      $log.sameNameHint | Should -BeTrue
      $log.allowSameLeaf | Should -BeFalse
      $log.stagingRoot | Should -Not -BeNullOrEmpty
      Test-Path -LiteralPath $log.stagingRoot | Should -BeFalse

      $sessionPath = Join-Path $outputRoot 'session-index.json'
      $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
      $session.compare.staging.enabled | Should -BeTrue
      $session.compare.staging.root | Should -Be $log.stagingRoot
      $session.compare.allowSameLeaf | Should -BeFalse
    }
    finally { Pop-Location }
  }

  It 'respects -UseRawPaths and skips staging' {
    $work = Join-Path $TestDrive 'dx-raw-paths'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      New-Item -ItemType Directory -Path 'tools' | Out-Null
      Copy-Item -LiteralPath $script:RunDxPath -Destination 'tools/Run-DX.ps1'
      Copy-Item -LiteralPath $script:StageScriptPath -Destination 'tools/Stage-CompareInputs.ps1'
      $harnessStub = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$OutputRoot,
  [string]$StagingRoot,
  [switch]$SameNameHint,
  [switch]$AllowSameLeaf,
  [string]$Warmup
)
if (-not (Test-Path -LiteralPath $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
$log = [ordered]@{
  base          = $BaseVi
  head          = $HeadVi
  stagingRoot   = $StagingRoot
  sameNameHint  = $SameNameHint.IsPresent
  allowSameLeaf = $AllowSameLeaf.IsPresent
  warmup        = $Warmup
}
$log | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'harness-log.json') -Encoding utf8
$session = [ordered]@{
  schema = 'teststand-compare-session/v1'
  warmup = @{
    mode   = $Warmup
    events = $null
  }
  compare = @{
    events  = $null
    capture = $null
    report  = $false
    staging = @{
      enabled = (-not [string]::IsNullOrWhiteSpace($StagingRoot))
      root    = $StagingRoot
    }
    allowSameLeaf = $AllowSameLeaf.IsPresent
    mode    = 'labview-cli'
    autoCli = $SameNameHint.IsPresent
  }
  outcome = $null
  error   = $null
}
$session | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputRoot 'session-index.json') -Encoding utf8
exit 0
'@
      Set-Content -LiteralPath (Join-Path $work 'tools/TestStand-CompareHarness.ps1') -Value $harnessStub -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $work 'tools/Debug-ChildProcesses.ps1') -Encoding UTF8 -Value "param() exit 0"
      Set-Content -LiteralPath (Join-Path $work 'tools/Detect-RogueLV.ps1') -Encoding UTF8 -Value "param() exit 0"

      $baseLeaf = ('Bas' + 'e') + '.vi'
      $baseVi = Join-Path $work $baseLeaf
      $headVi = Join-Path $work 'HeadDifferent.vi'
      Set-Content -LiteralPath $baseVi -Value 'base' -Encoding UTF8
      Set-Content -LiteralPath $headVi -Value 'head' -Encoding UTF8

      $outputRoot = Join-Path $work 'results'
      $runDx = Join-Path $work 'tools/Run-DX.ps1'
      & pwsh -NoLogo -NoProfile -File $runDx `
        -Suite TestStand `
        -BaseVi $baseVi `
        -HeadVi $headVi `
        -OutputRoot $outputRoot `
        -Warmup detect `
        -UseRawPaths *> $null
      $LASTEXITCODE | Should -Be 0

      $logPath = Join-Path $outputRoot 'harness-log.json'
      Test-Path -LiteralPath $logPath | Should -BeTrue
      $log = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $log.base | Should -Be (Resolve-Path $baseVi).Path
      $log.head | Should -Be (Resolve-Path $headVi).Path
      $log.stagingRoot | Should -BeNullOrEmpty
      $log.sameNameHint | Should -BeFalse
      $log.allowSameLeaf | Should -BeFalse

      $sessionPath = Join-Path $outputRoot 'session-index.json'
      $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
      $session.compare.staging.enabled | Should -BeFalse
      $session.compare.autoCli | Should -BeFalse
      $session.compare.allowSameLeaf | Should -BeFalse
    }
    finally { Pop-Location }
  }
}
