# Regression test: Ensure Invoke-WithFunctionShadow works across a nested dispatcher invocation
# This guards against future changes that might reintroduce mock/command scope issues when the
# dispatcher launches an inner Pester run.

Describe 'Inline Shadowing (Nested Dispatcher)' -Tag 'Unit' {
  BeforeAll {
    if (-not (Get-Command Test-PesterAvailable -ErrorAction SilentlyContinue)) {
      function Test-PesterAvailable {
        $mods = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_ -and $_.Version -ge '5.0.0' })
        return ($mods.Count -gt 0)
      }
    }
  }

  It 'retains shadow effectiveness before and after nested dispatcher run' {
    # 1. Simulate older Pester (probe should be false)
    function Get-Module { param([switch]$ListAvailable,[string]$Name)
      if ($ListAvailable -and $Name -eq 'Pester') { return [pscustomobject]@{ Name='Pester'; Version=[version]'4.10.1' } }
      Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
    }
    Test-PesterAvailable | Should -BeFalse
    Remove-Item Function:Get-Module -ErrorAction SilentlyContinue

    # 2. Nested dispatcher run in isolated workspace
    $workspace = Join-Path $TestDrive 'shadow-nested'
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    $testsDir = Join-Path $workspace 'tests'
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null

    $innerTest = Join-Path $testsDir 'Inner.Tests.ps1'
@'
Describe "Inner Smoke" {
  It "passes" { 1 | Should -Be 1 }
}
'@ | Set-Content -Path $innerTest

    $dispatcherCopy = Join-Path $workspace 'Invoke-PesterTests.ps1'
    Copy-Item -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-PesterTests.ps1') -Destination $dispatcherCopy

    Push-Location $workspace
    try {
      # Invoke dispatcher in a separate pwsh process to prevent its Write-Error from failing this test.
      $cmd = "pwsh -NoLogo -NoProfile -File `"$dispatcherCopy`" -TestsPath tests -ResultsPath results -IncludeIntegration false"
      $innerOutput = & pwsh -NoLogo -NoProfile -Command $cmd 2>&1
      $nestedExit = $LASTEXITCODE
      $summaryJson = Join-Path $workspace 'results' 'pester-summary.json'
      Test-Path $summaryJson | Should -BeTrue -Because 'Nested dispatcher should emit summary JSON'
      $json = Get-Content -LiteralPath $summaryJson -Raw | ConvertFrom-Json
      # Strict expectations: nested dispatcher should succeed cleanly for shadow test
      if ($nestedExit -ne 0) {
        Write-Host '[nested-shadow] Nested dispatcher exit != 0. Output:' -ForegroundColor Yellow
        ($innerOutput | Out-String) | Write-Host
      }
      $nestedExit | Should -Be 0
      $json.failed | Should -Be 0
      $json.errors | Should -Be 0
      $json.discoveryFailures | Should -Be 0 -Because 'Shadowing smoke test should not introduce discovery failures'
      if ($json.failed -gt 0 -or $json.errors -gt 0 -or $json.discoveryFailures -gt 0) {
        Write-Host '[nested-shadow] DEBUG OUTPUT START' -ForegroundColor Yellow
        ($innerOutput | Out-String) | Write-Host
        Write-Host '[nested-shadow] DEBUG OUTPUT END' -ForegroundColor Yellow
      }

      # Known benign noise pattern from inner discovery (Pester attempting Import-Module Microsoft.PowerShell.Core)
  $noisePattern = "The module 'Microsoft.PowerShell.Core' could not be loaded"
  $filtered = $innerOutput | Where-Object { $_ -notmatch [regex]::Escape($noisePattern) }

      # (Optional) Uncomment to debug if pattern changes:
      # Write-Host "[nested-filter] Original: $($innerOutput.Count) lines; Filtered: $($filtered.Count) lines"

      # Assert that no unexpected severe errors slipped through (anything with CommandNotFound other than the known pattern)
      $unexpected = $filtered | Where-Object { $_ -match 'CommandNotFoundException' -and $_ -notmatch [regex]::Escape($noisePattern) }
  $unexpected | Should -BeNullOrEmpty
    } finally {
      Pop-Location
    }

    # 3. Simulate new Pester (probe should be true)
    function Get-Module { param([switch]$ListAvailable,[string]$Name)
      if ($ListAvailable -and $Name -eq 'Pester') { return [pscustomobject]@{ Name='Pester'; Version=[version]'5.7.1' } }
      Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
    }
    Test-PesterAvailable | Should -BeTrue
    Remove-Item Function:Get-Module -ErrorAction SilentlyContinue
  }
}
