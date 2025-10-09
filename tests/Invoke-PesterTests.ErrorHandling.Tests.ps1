Describe 'Invoke-PesterTests failure handling' -Tag 'Unit' {
  BeforeAll {
    $testDir = Split-Path -Parent $PSCommandPath
    if (-not $testDir) { $testDir = (Resolve-Path '.').Path }
    $script:repoRoot = (Resolve-Path (Join-Path $testDir '..')).Path
    $script:dispatcherPath = Join-Path $script:repoRoot 'Invoke-PesterTests.ps1'
    Test-Path -LiteralPath $script:dispatcherPath | Should -BeTrue
    $script:skipDueToLV = $false
    try {
      $lv = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue)
      if ($lv.Count -gt 0) {
        $script:skipDueToLV = $true
        Write-Host ("[warn] Skipping failure-handling tests because LVCompare is running (PID(s): {0})" -f ($lv.Id -join ',')) -ForegroundColor Yellow
      }
    } catch {}
    $script:InvokeDispatcher = {
      param(
        [string]$DispatcherPath,
        [string]$ResultsPath
      )
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = 'pwsh'
      $psi.Arguments = "-NoLogo -NoProfile -File `"$DispatcherPath`" -TestsPath tests -ResultsPath `"$ResultsPath`" -IncludePatterns Invoke-PesterTests.ErrorHandling.Tests.ps1"
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.UseShellExecute = $false
      $proc = [System.Diagnostics.Process]::Start($psi)
      $stdout = $proc.StandardOutput.ReadToEnd()
      $stderr = $proc.StandardError.ReadToEnd()
      $proc.WaitForExit()
      return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
      }
    }
  }

  It 'emits an error when ResultsPath is an existing file' -Skip:$script:skipDueToLV {
    $resultsFile = Join-Path $TestDrive 'blocked-results.txt'
    Set-Content -LiteralPath $resultsFile -Value 'blocked' -Encoding ascii
    $crumbPath = Join-Path $script:repoRoot 'tests/results/_diagnostics/guard.json'
    if (Test-Path -LiteralPath $crumbPath) { Remove-Item -LiteralPath $crumbPath -Force }
    $invokerDir = Join-Path $script:repoRoot 'tests/results/_invoker'
    $invokerExisted = Test-Path -LiteralPath $invokerDir

    $res = & $script:InvokeDispatcher $script:dispatcherPath $resultsFile
    $res.ExitCode | Should -Not -Be 0

    $combined = ($res.StdOut + "`n" + $res.StdErr)
    $combined | Should -Match 'Results path points to a file'

    Test-Path -LiteralPath (Join-Path (Split-Path -Parent $resultsFile) 'pester-results.xml') | Should -BeFalse

    Test-Path -LiteralPath $crumbPath | Should -BeTrue
    $crumb = Get-Content -LiteralPath $crumbPath -Raw | ConvertFrom-Json
    $crumb.schema | Should -Be 'dispatcher-results-guard/v1'
    $crumb.path   | Should -Be $resultsFile
    $crumb.message | Should -Match [regex]::Escape($resultsFile)

    if (-not $invokerExisted) {
      Test-Path -LiteralPath $invokerDir | Should -BeFalse
    } else {
      Write-Host '[note] tests/results/_invoker pre-existed; skipping post-assert.' -ForegroundColor DarkGray
    }
  }

  It 'emits an error when ResultsPath is a read-only directory' -Skip:$script:skipDueToLV {
    $resultsDir = Join-Path $TestDrive 'blocked-dir'
    New-Item -ItemType Directory -Path $resultsDir | Out-Null
    (Get-Item -LiteralPath $resultsDir).Attributes = 'ReadOnly'
    $crumbPath = Join-Path $script:repoRoot 'tests/results/_diagnostics/guard.json'
    if (Test-Path -LiteralPath $crumbPath) { Remove-Item -LiteralPath $crumbPath -Force }
    $invokerDir = Join-Path $script:repoRoot 'tests/results/_invoker'
    $invokerExisted = Test-Path -LiteralPath $invokerDir

    try {
      $res = & $script:InvokeDispatcher $script:dispatcherPath $resultsDir
      $res.ExitCode | Should -Not -Be 0
      $combined = ($res.StdOut + "`n" + $res.StdErr)
      $combined | Should -Match 'Results directory is not writable'
      Test-Path -LiteralPath (Join-Path $resultsDir 'pester-results.xml') | Should -BeFalse
      Test-Path -LiteralPath $crumbPath | Should -BeTrue
      $crumb = Get-Content -LiteralPath $crumbPath -Raw | ConvertFrom-Json
      $crumb.path | Should -Be $resultsDir
      $crumb.message | Should -Match [regex]::Escape($resultsDir)

      if (-not $invokerExisted) {
        Test-Path -LiteralPath $invokerDir | Should -BeFalse
      } else {
        Write-Host '[note] tests/results/_invoker pre-existed; skipping post-assert.' -ForegroundColor DarkGray
      }
    } finally {
      (Get-Item -LiteralPath $resultsDir).Attributes = 'Normal'
    }
  }
}
