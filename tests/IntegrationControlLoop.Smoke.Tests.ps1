Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Integration Control Loop smoke' -Tag 'Unit' {
  Context 'Preflight guard (same leaf filename)' {
    It 'fails fast with InvalidInput and no CLI invocation' {
      Import-Module (Join-Path $PSScriptRoot '..' 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
      $dirA = Join-Path $TestDrive 'a'
      $dirB = Join-Path $TestDrive 'b'
      New-Item -ItemType Directory -Path $dirA | Out-Null
      New-Item -ItemType Directory -Path $dirB | Out-Null
      $p1 = Join-Path $dirA 'Same.vi'
      $p2 = Join-Path $dirB 'Same.vi'
  # create tiny placeholder files
  Set-Content -LiteralPath $p1 -Value '' -Encoding utf8
  Set-Content -LiteralPath $p2 -Value '' -Encoding utf8

      $r = Invoke-IntegrationCompareLoop -Base $p1 -Head $p2 -BypassCliValidation -Quiet
      $r | Should -Not -BeNullOrEmpty
      $r.Succeeded | Should -BeFalse
      $r.Reason | Should -Be 'InvalidInput'
      $r.Error | Should -Match 'same filename'
    }
  }

  Context 'Pre-clean path (LOOP_PRE_CLEAN=1)' {
    It 'invokes Stop-LVCompareProcesses and Stop-LabVIEWProcesses via stub' {
      # Mirror the runner and inject a stub cleanup script next to it
      $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
      $runnerSrc = Join-Path $repoRoot 'scripts' 'Run-AutonomousIntegrationLoop.ps1'
      Test-Path $runnerSrc | Should -BeTrue

      $shimScripts = Join-Path $TestDrive 'scripts'
      New-Item -ItemType Directory -Path $shimScripts | Out-Null
      $runnerDst = Join-Path $shimScripts 'Run-AutonomousIntegrationLoop.ps1'
      Copy-Item -LiteralPath $runnerSrc -Destination $runnerDst -Force

      # Write stub Ensure-LVCompareClean.ps1 that records calls
      $marker = Join-Path $TestDrive 'preclean-called.json'
      $stub = @"
Set-StrictMode -Version Latest
function Stop-LVCompareProcesses { param([switch]`$Quiet) '{"lvcompare":1}' | Set-Content -LiteralPath '$marker' -Encoding utf8; return 1 }
function Stop-LabVIEWProcesses  { param([switch]`$Quiet) '{"labview":1}'   | Add-Content -LiteralPath '$marker' -Encoding utf8; return 1 }
"@
      Set-Content -LiteralPath (Join-Path $shimScripts 'Ensure-LVCompareClean.ps1') -Value $stub -Encoding UTF8

      # Create dummy base/head files to satisfy early validation
      $base = Join-Path $TestDrive 'A.vi'
      $head = Join-Path $TestDrive 'B.vi'
  Set-Content -LiteralPath $base -Value '' -Encoding utf8
  Set-Content -LiteralPath $head -Value '' -Encoding utf8

      # Run the shimmed runner with pre-clean and dry-run (so it won’t invoke the real loop)
      $env:LOOP_PRE_CLEAN = '1'
      try {
        & pwsh -NoLogo -NoProfile -File $runnerDst -Base $base -Head $head -MaxIterations 1 -IntervalSeconds 0 -DryRun | Out-Null
      } finally {
        Remove-Item Env:LOOP_PRE_CLEAN -ErrorAction SilentlyContinue
      }

      # Validate that our stub recorded invocations
      Test-Path -LiteralPath $marker | Should -BeTrue
      $content = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop
      $content | Should -Match 'lvcompare'
      $content | Should -Match 'labview'
    }
  }
}
