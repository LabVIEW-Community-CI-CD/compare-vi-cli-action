Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe "Run-HeadlessCompare.ps1" -Tag "Unit" {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $scriptPath = Join-Path $repoRoot "tools" "Run-HeadlessCompare.ps1"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
      throw "Run-HeadlessCompare.ps1 not found at $scriptPath"
    }
    $script:RunHeadlessScript = $scriptPath
    $script:StageScript = Join-Path $repoRoot "tools" "Stage-CompareInputs.ps1"
    if (-not (Test-Path -LiteralPath $script:StageScript -PathType Leaf)) {
      throw "Stage-CompareInputs.ps1 not found at $script:StageScript"
    }
  }

  It "defaults to cli-only policy, skips warmup, and forwards timeout" {
    $work = Join-Path $TestDrive "headless-default"
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    $fsRoot = (Resolve-Path ".").Path
    try {
      New-Item -ItemType Directory -Path "tools" | Out-Null
      Copy-Item -LiteralPath $script:RunHeadlessScript -Destination "tools/Run-HeadlessCompare.ps1"
      Copy-Item -LiteralPath $script:StageScript -Destination "tools/Stage-CompareInputs.ps1"

      $logPath = Join-Path $fsRoot "invoke-log.json"
      $stubLines = @(
        "param(",
        "  [string]`$BaseVi,",
        "  [string]`$HeadVi,",
        "  [Alias('LabVIEWPath')][string]`$LabVIEWExePath,",
        "  [Alias('LVCompareExePath')][string]`$LVComparePath,",
        "  [string]`$OutputRoot,",
        "  [ValidateSet('detect','spawn','skip')][string]`$Warmup,",
        "  [switch]`$RenderReport,",
        "  [switch]`$CloseLabVIEW,",
        "  [switch]`$CloseLVCompare,",
        "  [int]`$TimeoutSeconds,",
        "  [switch]`$DisableTimeout,",
        "  [string]`$StagingRoot,",
        "  [switch]`$SameNameHint,",
        "  [switch]`$AllowSameLeaf",
        ")",
        "`$logDir = Split-Path '$logPath'",
        "if (`$logDir -and -not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }",
        "`$payload = [ordered]@{",
          "  base = `$BaseVi",
          "  head = `$HeadVi",
        "  output = `$OutputRoot",
        "  warmup = `$Warmup",
        "  renderReport = `$RenderReport.IsPresent",
        "  closeLabVIEW = `$CloseLabVIEW.IsPresent",
        "  closeLVCompare = `$CloseLVCompare.IsPresent",
          "  timeout = `$TimeoutSeconds",
          "  disableTimeout = `$DisableTimeout.IsPresent",
          "  policy = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_POLICY')",
          "  mode = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_MODE')",
        "  stagingRoot = `$StagingRoot",
        "  sameNameHint = `$SameNameHint.IsPresent",
        "  allowSameLeaf = `$AllowSameLeaf.IsPresent",
      "}",
        "`$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '$logPath' -Encoding utf8",
        "exit 0"
      )
      $stubPath = [System.IO.Path]::Combine($fsRoot, "tools", "TestStand-CompareHarness.ps1")
      [System.IO.File]::WriteAllLines($stubPath, $stubLines)
      Test-Path -LiteralPath $stubPath | Should -BeTrue

      $baseLeaf = ('Bas' + 'e') + '.vi'
      $headLeaf = ('Hea' + 'd') + '.vi'
      $baseRegex = [regex]::Escape($baseLeaf)
      $headRegex = [regex]::Escape($headLeaf)
      $baseFs = Join-Path $fsRoot ("VI-{0}" -f $baseLeaf)
      $headFs = Join-Path $fsRoot ("VI-{0}" -f $headLeaf)
      Set-Content -LiteralPath $baseFs -Value "base" -Encoding UTF8
      Set-Content -LiteralPath $headFs -Value "head" -Encoding UTF8

      Remove-Item Env:LVCI_COMPARE_POLICY, Env:LVCI_COMPARE_MODE -ErrorAction SilentlyContinue

      $output = & pwsh -NoLogo -NoProfile -File "tools/Run-HeadlessCompare.ps1" `
        -BaseVi $baseFs `
        -HeadVi $headFs `
        -OutputRoot (Join-Path $fsRoot "results") 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      Test-Path -LiteralPath $logPath | Should -BeTrue
      $data = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $data.policy | Should -Be "cli-only"
      $data.mode | Should -Be "labview-cli"
      $data.warmup | Should -Be "skip"
      $data.timeout | Should -Be 600
      $data.disableTimeout | Should -BeFalse
      $data.closeLabVIEW | Should -BeTrue
      $data.closeLVCompare | Should -BeTrue
      $allowedLeaves = @($baseLeaf, $headLeaf, 'Base.vi', 'Head.vi') | Select-Object -Unique
      $leafPattern = '({0})$' -f (($allowedLeaves | ForEach-Object { [regex]::Escape($_) }) -join '|')
      $data.base | Should -Match $leafPattern
      $data.head | Should -Match $leafPattern
      $data.base | Should -Not -Be $baseFs
      $data.head | Should -Not -Be $headFs
      $data.stagingRoot | Should -Not -BeNullOrEmpty
      $data.sameNameHint | Should -BeFalse
      $data.allowSameLeaf | Should -BeFalse
      Test-Path -LiteralPath $data.stagingRoot | Should -BeFalse
    }
    finally {
      Pop-Location
    }
  }

  It "stages duplicate filenames so LVCompare does not throw" {
    $work = Join-Path $TestDrive "headless-duplicate"
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    $fsRoot = (Resolve-Path ".").Path
    try {
      New-Item -ItemType Directory -Path "tools" | Out-Null
      Copy-Item -LiteralPath $script:RunHeadlessScript -Destination "tools/Run-HeadlessCompare.ps1"
      Copy-Item -LiteralPath $script:StageScript -Destination "tools/Stage-CompareInputs.ps1"

      $logPath = Join-Path $fsRoot "invoke-log.json"
      $stubLines = @(
        "param(",
        "  [string]`$BaseVi,",
        "  [string]`$HeadVi,",
        "  [Alias('LabVIEWPath')][string]`$LabVIEWExePath,",
        "  [Alias('LVCompareExePath')][string]`$LVComparePath,",
        "  [string]`$OutputRoot,",
        "  [ValidateSet('detect','spawn','skip')][string]`$Warmup,",
        "  [switch]`$RenderReport,",
        "  [switch]`$CloseLabVIEW,",
        "  [switch]`$CloseLVCompare,",
        "  [int]`$TimeoutSeconds,",
        "  [switch]`$DisableTimeout,",
        "  [string]`$StagingRoot,",
        "  [switch]`$SameNameHint,",
        "  [switch]`$AllowSameLeaf",
        ")",
        "`$payload = [ordered]@{",
          "base = `$BaseVi",
          "head = `$HeadVi",
          "stagingRoot = `$StagingRoot",
          "warmup = `$Warmup",
          "policy = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_POLICY')",
          "mode = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_MODE')",
          "sameNameHint = `$SameNameHint.IsPresent",
          "allowSameLeaf = `$AllowSameLeaf.IsPresent",
        "}",
        "`$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '$logPath' -Encoding utf8",
        "exit 0"
      )
      $stubPath = [System.IO.Path]::Combine($fsRoot, "tools", "TestStand-CompareHarness.ps1")
      [System.IO.File]::WriteAllLines($stubPath, $stubLines)
      Test-Path -LiteralPath $stubPath | Should -BeTrue

      $baseDir = Join-Path $fsRoot "base"
      $headDir = Join-Path $fsRoot "head"
      New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null
      $baseFs = Join-Path $baseDir "Sample.vi"
      $headFs = Join-Path $headDir "Sample.vi"
      Set-Content -LiteralPath $baseFs -Value "base" -Encoding UTF8
      Set-Content -LiteralPath $headFs -Value "head" -Encoding UTF8

      Remove-Item Env:LVCI_COMPARE_POLICY, Env:LVCI_COMPARE_MODE -ErrorAction SilentlyContinue

      $output = & pwsh -NoLogo -NoProfile -File "tools/Run-HeadlessCompare.ps1" `
        -BaseVi $baseFs `
        -HeadVi $headFs `
        -OutputRoot (Join-Path $fsRoot "results") 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      $data = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $allowedLegacy = @((Split-Path -Leaf $baseFs), (Split-Path -Leaf $headFs), 'Base.vi', 'Head.vi') | Select-Object -Unique
      $legacyPattern = '({0})$' -f (($allowedLegacy | ForEach-Object { [regex]::Escape($_) }) -join '|')
      $data.base | Should -Match $legacyPattern
      $data.head | Should -Match $legacyPattern
      $data.policy | Should -Be "cli-only"
      $data.mode | Should -Be "labview-cli"
      $data.stagingRoot | Should -Not -BeNullOrEmpty
      $data.sameNameHint | Should -BeTrue
      $data.allowSameLeaf | Should -BeFalse
      Test-Path -LiteralPath $data.stagingRoot | Should -BeFalse
    }
    finally {
      Pop-Location
    }
  }

  It "propagates AllowSameLeaf when staging mirrors dependency trees" {
    $work = Join-Path $TestDrive "headless-allow-same-leaf"
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    $fsRoot = (Resolve-Path ".").Path
    try {
      New-Item -ItemType Directory -Path "tools" | Out-Null
      Copy-Item -LiteralPath $script:RunHeadlessScript -Destination "tools/Run-HeadlessCompare.ps1"
      Copy-Item -LiteralPath $script:StageScript -Destination "tools/Stage-CompareInputs.ps1"

      $logPath = Join-Path $fsRoot "invoke-log.json"
      $stubLines = @(
        "param(",
        "  [string]`$BaseVi,",
        "  [string]`$HeadVi,",
        "  [Alias('LabVIEWPath')][string]`$LabVIEWExePath,",
        "  [Alias('LVCompareExePath')][string]`$LVComparePath,",
        "  [string]`$OutputRoot,",
        "  [ValidateSet('detect','spawn','skip')][string]`$Warmup,",
        "  [switch]`$RenderReport,",
        "  [switch]`$CloseLabVIEW,",
        "  [switch]`$CloseLVCompare,",
        "  [int]`$TimeoutSeconds,",
        "  [switch]`$DisableTimeout,",
        "  [string]`$StagingRoot,",
        "  [switch]`$SameNameHint,",
        "  [switch]`$AllowSameLeaf",
        ")",
        "`$payload = [ordered]@{",
          "base = `$BaseVi",
          "head = `$HeadVi",
          "stagingRoot = `$StagingRoot",
          "policy = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_POLICY')",
          "mode = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_MODE')",
          "sameNameHint = `$SameNameHint.IsPresent",
          "allowSameLeaf = `$AllowSameLeaf.IsPresent",
        "}",
        "`$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '$logPath' -Encoding utf8",
        "exit 0"
      )
      $stubPath = [System.IO.Path]::Combine($fsRoot, "tools", "TestStand-CompareHarness.ps1")
      [System.IO.File]::WriteAllLines($stubPath, $stubLines)
      Test-Path -LiteralPath $stubPath | Should -BeTrue

      $baseDir = Join-Path $fsRoot "base-tree"
      $headDir = Join-Path $fsRoot "head-tree"
      New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null
      $baseFs = Join-Path $baseDir "Widget.vi"
      $headFs = Join-Path $headDir "Widget.vi"
      Set-Content -LiteralPath $baseFs -Value "base" -Encoding UTF8
      Set-Content -LiteralPath $headFs -Value "head" -Encoding UTF8
      New-Item -ItemType Directory -Path (Join-Path $baseDir "deps"), (Join-Path $headDir "deps") | Out-Null
      Set-Content -LiteralPath (Join-Path $baseDir "deps" "helper.vi") -Value "dep" -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $headDir "deps" "helper.vi") -Value "dep" -Encoding UTF8

      Remove-Item Env:LVCI_COMPARE_POLICY, Env:LVCI_COMPARE_MODE -ErrorAction SilentlyContinue

      $output = & pwsh -NoLogo -NoProfile -File "tools/Run-HeadlessCompare.ps1" `
        -BaseVi $baseFs `
        -HeadVi $headFs `
        -OutputRoot (Join-Path $fsRoot "results") 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      $data = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $data.sameNameHint | Should -BeTrue
      $data.allowSameLeaf | Should -BeTrue
      $data.stagingRoot | Should -Not -BeNullOrEmpty
      Test-Path -LiteralPath $data.stagingRoot | Should -BeFalse
    }
    finally {
      Pop-Location
    }
  }

  It "honours WarmupMode, DisableTimeout, and DisableCleanup options" {
    $work = Join-Path $TestDrive "headless-options"
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    $fsRoot = (Resolve-Path ".").Path
    try {
      New-Item -ItemType Directory -Path "tools" | Out-Null
      Copy-Item -LiteralPath $script:RunHeadlessScript -Destination "tools/Run-HeadlessCompare.ps1"
      Copy-Item -LiteralPath $script:StageScript -Destination "tools/Stage-CompareInputs.ps1"

      $logPath = Join-Path $fsRoot "invoke-log.json"
      $stubLines = @(
        "param(",
        "  [string]`$BaseVi,",
        "  [string]`$HeadVi,",
        "  [Alias('LabVIEWPath')][string]`$LabVIEWExePath,",
        "  [Alias('LVCompareExePath')][string]`$LVComparePath,",
        "  [string]`$OutputRoot,",
        "  [ValidateSet('detect','spawn','skip')][string]`$Warmup,",
        "  [switch]`$RenderReport,",
        "  [switch]`$CloseLabVIEW,",
        "  [switch]`$CloseLVCompare,",
        "  [int]`$TimeoutSeconds,",
        "  [switch]`$DisableTimeout,",
        "  [string]`$StagingRoot,",
        "  [switch]`$SameNameHint,",
        "  [switch]`$AllowSameLeaf",
        ")",
        "`$logDir = Split-Path '$logPath'",
        "if (`$logDir -and -not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }",
        "`$payload = [ordered]@{",
          "  warmup = `$Warmup",
        "  renderReport = `$RenderReport.IsPresent",
        "  closeLabVIEW = `$CloseLabVIEW.IsPresent",
        "  closeLVCompare = `$CloseLVCompare.IsPresent",
          "  timeout = `$TimeoutSeconds",
          "  disableTimeout = `$DisableTimeout.IsPresent",
          "  policy = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_POLICY')",
          "  mode = [System.Environment]::GetEnvironmentVariable('LVCI_COMPARE_MODE')",
          "  stagingRoot = `$StagingRoot",
          "  sameNameHint = `$SameNameHint.IsPresent",
        "}",
        "`$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '$logPath' -Encoding utf8",
        "exit 0"
      )
      $stubPath = [System.IO.Path]::Combine($fsRoot, "tools", "TestStand-CompareHarness.ps1")
      [System.IO.File]::WriteAllLines($stubPath, $stubLines)
      Test-Path -LiteralPath $stubPath | Should -BeTrue

      $baseLeaf = ('Bas' + 'e') + '.vi'
      $headLeaf = ('Hea' + 'd') + '.vi'
      $baseFs = Join-Path $fsRoot $baseLeaf
      $headFs = Join-Path $fsRoot $headLeaf
      Set-Content -LiteralPath $baseFs -Value "base" -Encoding UTF8
      Set-Content -LiteralPath $headFs -Value "head" -Encoding UTF8

      $env:LVCI_COMPARE_POLICY = "cli-first"
      $env:LVCI_COMPARE_MODE = "labview-cli"

      $output = & pwsh -NoLogo -NoProfile -File "tools/Run-HeadlessCompare.ps1" `
        -BaseVi $baseFs `
        -HeadVi $headFs `
        -OutputRoot (Join-Path $fsRoot "results") `
        -WarmupMode detect `
        -RenderReport `
        -TimeoutSeconds 45 `
        -DisableTimeout `
        -DisableCleanup `
        -UseRawPaths 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      Test-Path -LiteralPath $logPath | Should -BeTrue
      $data = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
      $data.policy | Should -Be "cli-first"
      $data.mode | Should -Be "labview-cli"
      $data.warmup | Should -Be "detect"
      $data.renderReport | Should -BeTrue
      $data.timeout | Should -Be 45
      $data.disableTimeout | Should -BeTrue
      $data.closeLabVIEW | Should -BeFalse
      $data.closeLVCompare | Should -BeFalse
      $data.stagingRoot | Should -BeNullOrEmpty
      $data.sameNameHint | Should -BeFalse
    }
    finally {
      Remove-Item Env:LVCI_COMPARE_POLICY, Env:LVCI_COMPARE_MODE -ErrorAction SilentlyContinue
      Pop-Location
    }
  }
}
