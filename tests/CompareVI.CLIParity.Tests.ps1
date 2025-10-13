#Requires -Version 7.0
# Pester v5 parity harness for CLI vs LVCompare

BeforeAll {
  $here = Split-Path -Parent $PSCommandPath
  $repoRoot = (Resolve-Path (Join-Path $here '..')).Path
  . (Join-Path $repoRoot 'scripts' 'CompareVI.ps1')

  $script:baseVi = Join-Path $repoRoot 'VI1.vi'
  $script:headVi = Join-Path $repoRoot 'VI2.vi'

  $script:cliAvailable = $false
  $script:cliSkipReason = $null

  $cliPath = $env:LABVIEW_CLI_PATH
  $labviewExe = $env:LABVIEW_EXE

  if (-not $cliPath -or -not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    $script:cliSkipReason = 'LABVIEW_CLI_PATH not configured'
  } elseif (-not $labviewExe -or -not (Test-Path -LiteralPath $labviewExe -PathType Leaf)) {
    $script:cliSkipReason = 'LABVIEW_EXE not configured'
  } else {
    $script:cliAvailable = $true
  }

  $script:originalPolicy = $env:LVCI_COMPARE_POLICY
}

AfterAll {
  if ($null -ne $script:originalPolicy) {
    $env:LVCI_COMPARE_POLICY = $script:originalPolicy
  } else {
    Remove-Item Env:LVCI_COMPARE_POLICY -ErrorAction SilentlyContinue
  }
}

Describe 'CompareVI CLI parity' -Tag 'Parity' {
  BeforeEach {
    $env:LVCI_CLI_NUNIT_PATH = Join-Path $TestDrive 'cli-results.xml'
    $env:LVCI_CLI_FORMAT = 'XML'
  }

  AfterEach {
    Remove-Item Env:LVCI_CLI_NUNIT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:LVCI_CLI_FORMAT -ErrorAction SilentlyContinue
  }

  It 'matches diff result for VI1 vs VI2' {
    if (-not $script:cliAvailable) {
      Write-Warning ('[cli-parity] Skipping: {0}' -f $script:cliSkipReason)
      return
    }
    Push-Location $TestDrive
    try {
      $env:LVCI_COMPARE_POLICY = 'cli-only'
      $cliResult = Invoke-CompareVI -Base $script:baseVi -Head $script:headVi -FailOnDiff:$false -CompareExecJsonPath (Join-Path $TestDrive 'cli-exec.json')
    } finally {
      Pop-Location
    }

    $env:LVCI_COMPARE_POLICY = 'lv-only'
    $lvResult = Invoke-CompareVI -Base $script:baseVi -Head $script:headVi -FailOnDiff:$false

    $cliResult.Diff | Should -Be $lvResult.Diff
    $cliResult.ExitCode | Should -Be $lvResult.ExitCode
    $cliResult.DiffUnknown | Should -BeFalse
  }

  It 'reports no diff for identical VI' {
    if (-not $script:cliAvailable) {
      Write-Warning ('[cli-parity] Skipping: {0}' -f $script:cliSkipReason)
      return
    }
    Push-Location $TestDrive
    try {
      $env:LVCI_COMPARE_POLICY = 'cli-only'
      $cliResult = Invoke-CompareVI -Base $script:baseVi -Head $script:baseVi -FailOnDiff:$false -CompareExecJsonPath (Join-Path $TestDrive 'cli-identical.json')
    } finally {
      Pop-Location
    }

    $env:LVCI_COMPARE_POLICY = 'lv-only'
    $lvResult = Invoke-CompareVI -Base $script:baseVi -Head $script:baseVi -FailOnDiff:$false

    $cliResult.Diff | Should -BeFalse
    $lvResult.Diff | Should -BeFalse
    $cliResult.ExitCode | Should -Be $lvResult.ExitCode
    $cliResult.DiffUnknown | Should -BeFalse
  }
}
