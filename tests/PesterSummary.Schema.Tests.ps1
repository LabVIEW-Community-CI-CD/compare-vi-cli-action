<#
  Validates pester summary JSON matches schema contract (basic structural & type checks)
  Strategy: Launch dispatcher in a separate PowerShell process so nested Pester runs do not interfere with the current Pester session.
  Path Resolution: Use $PSScriptRoot (stable in Pester context) instead of $MyInvocation which can be null in dynamic discovery.
#>

## Path resolution deferred to test execution block (handles environments where $PSScriptRoot may be null during discovery)

Describe 'Pester Summary Schema' {
  It 'emits JSON with required fields matching schema expectations' {
  # Resolve repository root (parent of this test file's directory) with multi-variable fallback
  $scriptDir = $PSScriptRoot
  if (-not $scriptDir -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
  if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
  if (-not $scriptDir) { throw 'Unable to resolve script directory for schema test.' }
  $root = Split-Path -Parent $scriptDir
  $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'

  # Create a tiny ephemeral test that always passes so we have non-zero totals
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $testsDir = Join-Path $tempDir 'tests'
    New-Item -ItemType Directory -Path $testsDir | Out-Null
    $mini = @(
      "Describe 'Mini' {",
      "  It 'passes' { 1 | Should -Be 1 }",
      "}"
    ) -join [Environment]::NewLine
    $miniPath = Join-Path $testsDir 'Mini.Tests.ps1'
    Set-Content -LiteralPath $miniPath -Value $mini -Encoding UTF8

  Push-Location $root
    try {
      $resDir = Join-Path $tempDir 'results'
  Write-Host "[schema-test] Dispatcher path: $dispatcher" -ForegroundColor Cyan
  (Test-Path -LiteralPath $dispatcher) | Should -BeTrue -Because 'Dispatcher script must exist'
  Write-Host "[schema-test] Using dispatcher at: $dispatcher" -ForegroundColor Cyan
  Write-Host "[schema-test] Mini test path: $miniPath" -ForegroundColor Cyan
  & pwsh -NoLogo -NoProfile -File $dispatcher -TestsPath $testsDir -ResultsPath $resDir | Out-Null
      $exitCode = $LASTEXITCODE
      Write-Host "[schema-test] Dispatcher exit code: $exitCode" -ForegroundColor Cyan
      $summaryPath = Join-Path $resDir 'pester-summary.json'
      if (-not (Test-Path $summaryPath)) {
        Write-Host "[schema-test] Contents of results directory:" -ForegroundColor Yellow
        if (Test-Path $resDir) { Get-ChildItem -Force $resDir | Format-List | Out-String | Write-Host }
      }
      Test-Path $summaryPath | Should -BeTrue -Because 'Dispatcher should emit JSON summary file'
      $json = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json

      $req = 'schemaVersion','total','passed','failed','errors','skipped','duration_s','timestamp','pesterVersion','includeIntegration','discoveryFailures'
      foreach ($k in $req) { ($json.PSObject.Properties.Name -contains $k) | Should -BeTrue -Because "Missing field $k" }

  $json.schemaVersion | Should -Be '1.5.0'
      $json.total | Should -BeGreaterThan 0
      $json.passed | Should -BeGreaterThan 0
      $json.failed | Should -Be 0
      $json.errors | Should -BeGreaterOrEqual 0
      $json.skipped | Should -BeGreaterOrEqual 0
      $json.duration_s | Should -BeGreaterThan 0
      [DateTime]::Parse($json.timestamp) | Out-Null
      $json.pesterVersion | Should -Match '^5\.'
      $json.includeIntegration | Should -BeFalse
  $json.discoveryFailures | Should -BeGreaterOrEqual 0
  # Context blocks should be absent by default (no -EmitContext)
  ($json.PSObject.Properties.Name -contains 'environment') | Should -BeFalse
  ($json.PSObject.Properties.Name -contains 'run') | Should -BeFalse
  ($json.PSObject.Properties.Name -contains 'selection') | Should -BeFalse
  ($json.PSObject.Properties.Name -contains 'stability') | Should -BeFalse
  ($json.PSObject.Properties.Name -contains 'discovery') | Should -BeFalse
    } finally {
      Pop-Location
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
}
