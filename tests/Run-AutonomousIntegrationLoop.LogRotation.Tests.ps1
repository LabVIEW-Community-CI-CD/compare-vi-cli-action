Set-StrictMode -Version Latest

Describe 'Run-AutonomousIntegrationLoop JSON log rotation (size-based)' -Tag 'Unit' {
  BeforeAll {
    $root = Split-Path -Parent $PSCommandPath | Split-Path -Parent
  $scriptPath = Join-Path $root 'scripts' 'Run-AutonomousIntegrationLoop.ps1'
  Test-Path $scriptPath | Should -BeTrue
  . "$PSScriptRoot/TestHelpers.Schema.ps1"
  $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $script:tmpDir | Out-Null
  }

  AfterAll {
  if (Test-Path $script:tmpDir) { Remove-Item -Recurse -Force $script:tmpDir }
  }

  It 'rotates when JsonLogMaxBytes threshold small (multi-run accumulation)' {
    $jsonLog = Join-Path $script:tmpDir 'loop.log.json'
    $final   = Join-Path $script:tmpDir 'final-status.json'
    $base = Join-Path $script:tmpDir 'VI1.vi'; New-Item -ItemType File -Path $base -Force | Out-Null
    $head = Join-Path $script:tmpDir 'VI2.vi'; New-Item -ItemType File -Path $head -Force | Out-Null

    $runner = Join-Path $script:tmpDir 'rotation-runner.ps1'
  $runnerContent = @"
function Invoke-LoopOnce {
  & '$scriptPath' -Base '$base' -Head '$head' -MaxIterations 20 -IntervalSeconds 0 -JsonLogPath '$jsonLog' -JsonLogMaxBytes 250 -FinalStatusJsonPath '$final' -DiffSummaryFormat None -FailOnDiff:`$false -LogVerbosity Quiet -CustomExecutor { param(`$CliPath,`$Base,`$Head,`$ExecArgs) return 0 }
  if (
  $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Invoke-LoopOnce
Invoke-LoopOnce
exit 0
"@
    Set-Content -LiteralPath $runner -Value $runnerContent -Encoding UTF8
  pwsh -NoLogo -NoProfile -File $runner | Out-Null
  $exit = $LASTEXITCODE
  $exit | Should -Be 0 -Because 'both runs succeed (executor returns 0)'

    Test-Path $final | Should -BeTrue
    Assert-JsonShape -Path $final -Spec 'FinalStatus' | Should -BeTrue

    # Rotated files follow pattern <log>.N.roll (expect at least 1 after two runs with tiny max bytes)
    $rolls = @(Get-ChildItem -Path $script:tmpDir -Filter 'loop.log.json.*.roll' | Sort-Object Name)
    if ($rolls.Count -lt 1) {
      Write-Host "DEBUG: Active log size=$((Get-Item $jsonLog).Length) bytes. Contents:" -ForegroundColor Yellow
      Get-Content -LiteralPath $jsonLog | Write-Host
    }
    $rolls.Count | Should -BeGreaterThan 0 -Because 'multi-run accumulation should trigger at least one rotation'
    (Get-Item $jsonLog).Length | Should -BeLessThan 600 -Because 'active file should remain modest after rotations'
    foreach ($r in $rolls) { $r.Length | Should -BeLessThan 1500 }

    # Validate NDJSON integrity & LoopEvent schema across all segments (rotated + active)
    $allLogs = @($rolls.FullName + $jsonLog)
    foreach ($file in $allLogs) {
      Assert-NdjsonShapes -Path $file -Spec 'LoopEvent' | Should -BeTrue
    }

    # Confirm rotate meta events equal roll count
    $metaRotateEvents = foreach ($file in $allLogs) { Get-Content -LiteralPath $file | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.type -eq 'meta' -and $_.action -eq 'rotate' } }
    $metaRotateEvents.Count | Should -Be $rolls.Count

    # Verify iteration count in final status
    $status = Get-Content -LiteralPath $final -Raw | ConvertFrom-Json
  $status.iterations | Should -Be 20 -Because 'final run used 20 iterations'
    $status.succeeded  | Should -BeTrue
  }
}
