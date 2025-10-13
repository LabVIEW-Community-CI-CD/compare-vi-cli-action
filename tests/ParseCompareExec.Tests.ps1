Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Parse-CompareExec.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:parseScript = Join-Path $repoRoot 'tools' 'Parse-CompareExec.ps1'
    Test-Path -LiteralPath $script:parseScript | Should -BeTrue
  }

  It 'prefers lvcompare-capture.json when available' {
    $work = Join-Path $TestDrive 'with-capture'
    New-Item -ItemType Directory -Path $work | Out-Null
    $results = Join-Path $work 'results'
    New-Item -ItemType Directory -Path $results | Out-Null

    $captureDir = Join-Path $results 'compare'
    New-Item -ItemType Directory -Path $captureDir | Out-Null

    $stdoutContent = "diff detected`nline2"
    $capture = [ordered]@{
      schema    = 'lvcompare-capture-v1'
      timestamp = '2025-01-02T03:04:05.0000000Z'
      base      = 'C:\base.vi'
      head      = 'C:\head.vi'
      cliPath   = 'C:\Program Files\NI\LVCompare.exe'
      args      = @('-foo','-bar')
      lvPath    = 'C:\Program Files\NI\LabVIEW.exe'
      flags     = @('-foo','-bar')
      exitCode  = 1
      seconds   = 0.42
      stdoutLen = $stdoutContent.Length
      stderrLen = 0
      command   = 'LVCompare.exe "C:\base.vi" "C:\head.vi" -foo -bar'
      stdout    = $stdoutContent
      stderr    = $null
      diffDetected = $true
    }
    $capturePath = Join-Path $captureDir 'lvcompare-capture.json'
    $capture | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $capturePath -Encoding utf8

    $stdoutPath = Join-Path $captureDir 'lvcompare-stdout.txt'
    $stdoutContent | Set-Content -LiteralPath $stdoutPath -Encoding utf8
    $stderrPath = Join-Path $captureDir 'lvcompare-stderr.txt'
    Set-Content -LiteralPath $stderrPath -Value '' -Encoding utf8
    $reportPath = Join-Path $captureDir 'compare-report.html'
    Set-Content -LiteralPath $reportPath -Value '<html></html>' -Encoding utf8

    $execData = [ordered]@{
      diff        = $true
      exitCode    = 1
      duration_s  = 0.50
      duration_ns = 0
      cliPath     = 'C:\Program Files\NI\LVCompare.exe'
      command     = 'LVCompare.exe "C:\base.vi" "C:\head.vi" -foo -bar'
    }
    $execPath = Join-Path $captureDir 'compare-exec.json'
    $execData | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $execPath -Encoding utf8

    $outPath = Join-Path $results 'compare-outcome.json'
    & pwsh -NoLogo -NoProfile -File $script:parseScript -SearchDir $results -OutJson $outPath
    $LASTEXITCODE | Should -Be 0

    Test-Path -LiteralPath $outPath | Should -BeTrue
    $out = Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json -Depth 6

    $out.source | Should -Be 'capture'
    $out.captureJson | Should -Be $capturePath
    $out.capture.status | Should -Be 'ok'
    $out.exitCode | Should -Be 1
    $out.diff | Should -BeTrue
    $out.durationMs | Should -Be 420
    $out.stdoutLen | Should -Be ($capture.stdoutLen)
    $out.stdoutPath | Should -Be $stdoutPath
    $out.stderrLen | Should -Be ($capture.stderrLen)
    $out.reportPath | Should -Be $reportPath
    $out.compareExec.status | Should -Be 'ok'
    $out.compareExec.path | Should -Be $execPath
  }

  It 'falls back to compare-exec when capture is missing' {
    $work = Join-Path $TestDrive 'exec-only'
    New-Item -ItemType Directory -Path $work | Out-Null

    $execDir = Join-Path $work 'drift'
    New-Item -ItemType Directory -Path $execDir | Out-Null

    $execData = [ordered]@{
      diff        = $false
      exitCode    = 0
      duration_s  = 1.25
      cliPath     = 'D:\LVCompare.exe'
      command     = 'LVCompare.exe base.vi head.vi'
    }
    $execPath = Join-Path $execDir 'compare-exec.json'
    $execData | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $execPath -Encoding utf8

    $outPath = Join-Path $work 'compare-outcome.json'
    & pwsh -NoLogo -NoProfile -File $script:parseScript -SearchDir $work -OutJson $outPath
    $LASTEXITCODE | Should -Be 0

    $out = Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json -Depth 6

    $out.source | Should -Be 'compare-exec'
    $out.capture.status | Should -Be 'missing'
    $out.capture.reason | Should -Be 'no_capture_json'
    $out.exitCode | Should -Be 0
    $out.diff | Should -BeFalse
    $out.durationMs | Should -Be 1250
    $out.compareExec.status | Should -Be 'ok'
    $out.compareExec.path | Should -Be $execPath
    $out.compareExec.exitCode | Should -Be 0
    $out.compareExec.diff | Should -BeFalse
  }

  It 'emits missing outcome when no artifacts exist' {
    $work = Join-Path $TestDrive 'no-artifacts'
    New-Item -ItemType Directory -Path $work | Out-Null
    $outPath = Join-Path $work 'compare-outcome.json'

    & pwsh -NoLogo -NoProfile -File $script:parseScript -SearchDir $work -OutJson $outPath
    $LASTEXITCODE | Should -Be 0

    Test-Path -LiteralPath $outPath | Should -BeTrue
    $out = Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json -Depth 6

    $out.source | Should -Be 'missing'
    $out.file | Should -BeNullOrEmpty
    $out.capture.status | Should -Be 'missing'
    $out.capture.reason | Should -Be 'no_capture_json'
    $out.compareExec.status | Should -Be 'missing'
    $out.compareExec.reason | Should -Be 'no_exec_json'
  }
}
