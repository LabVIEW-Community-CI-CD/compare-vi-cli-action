Describe 'CompareVI directory guard' -Tag 'Unit' {
  BeforeAll {
    $ErrorActionPreference = 'Stop'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'scripts' 'CompareVI.psm1'
    Import-Module $modulePath -Force
  }

  It 'throws when Base is a directory' {
    $baseDir = Join-Path $TestDrive 'bad.vi'
    $headFile = Join-Path $TestDrive 'good.vi'
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    Set-Content -LiteralPath $headFile -Value 'dummy' -Encoding ascii
  { Invoke-CompareVI -Base $baseDir -Head $headFile } | Should -Throw
  }

  It 'throws when Head is a directory' {
    $baseFile = Join-Path $TestDrive 'good.vi'
    $headDir = Join-Path $TestDrive 'bad.vi'
    Set-Content -LiteralPath $baseFile -Value 'dummy' -Encoding ascii
    New-Item -ItemType Directory -Path $headDir -Force | Out-Null
  { Invoke-CompareVI -Base $baseFile -Head $headDir } | Should -Throw
  }
}

Describe 'Capture-LVCompare directory guard' -Tag 'Unit' {
  It 'throws when Base is a directory (script preflight)' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot 'scripts' 'Capture-LVCompare.ps1'
    $baseDir = Join-Path $TestDrive 'bad.vi'
    $headFile = Join-Path $TestDrive 'good.vi'
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    Set-Content -LiteralPath $headFile -Value 'dummy' -Encoding ascii
  { & $scriptPath -Base $baseDir -Head $headFile -OutputDir (Join-Path $TestDrive 'out') } | Should -Throw
  }
}

