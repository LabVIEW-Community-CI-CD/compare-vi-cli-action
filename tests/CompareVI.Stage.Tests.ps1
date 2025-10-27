Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-CompareVI staging' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $repoRoot 'scripts' 'CompareVI.psm1') -Force
  }

  AfterAll {
    Remove-Module CompareVI -ErrorAction SilentlyContinue
  }

  It 'stages duplicate filenames before invoking LVCompare' {
    $work = Join-Path $TestDrive 'comparevi-stage'
    New-Item -ItemType Directory -Path $work | Out-Null
    Push-Location $work
    try {
      $baseDir = Join-Path $work 'base'
      $headDir = Join-Path $work 'head'
      New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null
      $baseVi = Join-Path $baseDir 'Sample.vi'
      $headVi = Join-Path $headDir 'Sample.vi'
      Set-Content -LiteralPath $baseVi -Value 'base' -Encoding UTF8
      Set-Content -LiteralPath $headVi -Value 'head' -Encoding UTF8

      $command = Invoke-CompareVI -Base $baseVi -Head $headVi -PreviewArgs
      $parts = $command -split '"'
      $pathsSection = $parts[-1].Trim()
      $tokens = $pathsSection -split '\s+'
      $stagedBase = $tokens[0]
      $stagedHead = $tokens[1]

      $stagedBase | Should -Not -Be $baseVi
      $stagedHead | Should -Not -Be $headVi
      $baseLeafName = ('Bas' + 'e') + '.vi'
      $headLeafName = ('Hea' + 'd') + '.vi'
      (Split-Path -Leaf $stagedBase) | Should -Be $baseLeafName
      (Split-Path -Leaf $stagedHead) | Should -Be $headLeafName
      $stageRoot = Split-Path -Parent $stagedBase
      Test-Path -LiteralPath $stageRoot | Should -BeFalse
    }
    finally {
      Pop-Location
    }
  }
}

Describe 'Stage-CompareInputs.ps1' -Tag 'Unit' {
It 'mirrors dependency trees and allows duplicate leaf names when required' {
  $stageScript = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'tools/Stage-CompareInputs.ps1'
  Test-Path -LiteralPath $stageScript | Should -BeTrue

  $workDir = Join-Path $TestDrive 'stage-mirror'
  New-Item -ItemType Directory -Path $workDir | Out-Null

  $baseDir = Join-Path $workDir 'base-tree'
  $headDir = Join-Path $workDir 'head-tree'
  New-Item -ItemType Directory -Path $baseDir, $headDir | Out-Null

  $baseVi = Join-Path $baseDir 'Widget.vi'
  $headVi = Join-Path $headDir 'Widget.vi'
  Set-Content -LiteralPath $baseVi -Value 'base' -Encoding utf8
  Set-Content -LiteralPath $headVi -Value 'head' -Encoding utf8
  New-Item -ItemType Directory -Path (Join-Path $baseDir 'deps'), (Join-Path $headDir 'deps') | Out-Null
  Set-Content -LiteralPath (Join-Path $baseDir 'deps/helper.vi') -Value 'dep' -Encoding utf8
  Set-Content -LiteralPath (Join-Path $headDir 'deps/helper.vi') -Value 'dep' -Encoding utf8

  $result = & $stageScript -BaseVi $baseVi -HeadVi $headVi
  $result | Should -Not -BeNullOrEmpty
  $result.AllowSameLeaf | Should -BeTrue
  $result.Mode | Should -Be 'mirror'
  $widgetLeaf = ('Widg' + 'et') + '.vi'
  (Split-Path -Leaf $result.Base) | Should -Be $widgetLeaf
  (Split-Path -Leaf $result.Head) | Should -Be $widgetLeaf
  Test-Path -LiteralPath $result.Root | Should -BeTrue
  try {
    (Split-Path -Leaf (Split-Path -Parent $result.Base)) | Should -Be 'base-tree'
    (Split-Path -Leaf (Split-Path -Parent $result.Head)) | Should -Be 'head-tree'
  } finally {
    if (Test-Path -LiteralPath $result.Root) {
      Remove-Item -LiteralPath $result.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
}
