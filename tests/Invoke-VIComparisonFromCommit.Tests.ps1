$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Invoke-VIComparisonFromCommit.ps1' -Tag 'Compare','Snapshot','Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:commitScript = Join-Path $repoRoot 'tools/icon-editor/Invoke-VIComparisonFromCommit.ps1'
    Test-Path -LiteralPath $script:commitScript | Should -BeTrue 'Invoke-VIComparisonFromCommit.ps1 not found.'
  }

  BeforeEach {
    $script:prevLabVIEWPath = $env:LABVIEW_PATH
    $script:prevLabVIEWCliPath = $env:LABVIEWCLI_PATH
    $script:prevLVComparePath = $env:LVCOMPARE_PATH
  }

  AfterEach {
    if ($script:prevLabVIEWPath) { Set-Item Env:LABVIEW_PATH $script:prevLabVIEWPath } else { Remove-Item Env:LABVIEW_PATH -ErrorAction SilentlyContinue }
    if ($script:prevLabVIEWCliPath) { Set-Item Env:LABVIEWCLI_PATH $script:prevLabVIEWCliPath } else { Remove-Item Env:LABVIEWCLI_PATH -ErrorAction SilentlyContinue }
    if ($script:prevLVComparePath) { Set-Item Env:LVCOMPARE_PATH $script:prevLVComparePath } else { Remove-Item Env:LVCOMPARE_PATH -ErrorAction SilentlyContinue }
  }

  It 'fails when LabVIEW 2025 executable cannot be found' {
    $testRepo = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $testRepo | Out-Null

    $missingPath = Join-Path $TestDrive 'missing' 'LabVIEW.exe'
    $errorRecord = $null
    try {
      & $script:commitScript `
        -Commit 'HEAD' `
        -RepoPath $testRepo `
        -SkipSync `
        -LabVIEWExePath $missingPath
    } catch {
      $errorRecord = $_
    }
    $errorRecord | Should -Not -BeNullOrEmpty
    $errorRecord.Exception.Message | Should -Match 'not found'
  }

  It 'rejects LabVIEW 2025 32-bit executable paths' {
    $testRepo = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $testRepo | Out-Null

    $x86Path = Join-Path $TestDrive 'Program Files (x86)\National Instruments\LabVIEW 2025\LabVIEW.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $x86Path) -Force | Out-Null
    Set-Content -LiteralPath $x86Path -Value '' -Encoding utf8

    $errorRecord = $null
    try {
      & $script:commitScript `
        -Commit 'HEAD' `
        -RepoPath $testRepo `
        -SkipSync `
        -LabVIEWExePath $x86Path
    } catch {
      $errorRecord = $_
    }
    $errorRecord | Should -Not -BeNullOrEmpty
    $errorRecord.Exception.Message | Should -Match '32-bit'
  }

  It 'returns metadata when LabVIEW 2025 64-bit executable is provided' {
    $repoPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $repoPath | Out-Null

    Push-Location $repoPath
    try {
      git init --quiet | Out-Null
      git config user.email 'tester@example.com' | Out-Null
      git config user.name 'Tester' | Out-Null
      Set-Content -LiteralPath 'README.md' -Value 'baseline' -Encoding utf8
      git add . | Out-Null
      git commit -m 'initial' --quiet | Out-Null
      $commitHash = (git rev-parse HEAD).Trim()
    } finally {
      Pop-Location
    }

    $lvPath = Join-Path $TestDrive 'Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $lvPath) -Force | Out-Null
    Set-Content -LiteralPath $lvPath -Value '' -Encoding utf8

    $result = & $script:commitScript `
      -Commit $commitHash `
      -RepoPath $repoPath `
      -SkipSync `
      -SkipValidate `
      -SkipLVCompare `
      -LabVIEWExePath $lvPath

    $result | Should -Not -BeNullOrEmpty
    $result.commit | Should -Be $commitHash
    $result.staged | Should -BeFalse
  }
}
