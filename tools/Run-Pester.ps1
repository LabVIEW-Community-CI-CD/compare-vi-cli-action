param(
  [switch]$IncludeIntegration,
  # Optional: run only a specific test file or directory
  [string]$Path,
  # Optional: set Pester output verbosity (Quiet|Normal|Detailed|Diagnostic)
  [ValidateSet('Quiet','Normal','Detailed','Diagnostic')]
  [string]$Output = 'Detailed'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resultsDir = Join-Path $root 'tests' 'results'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

# Check for Pester v5+ availability and import accordingly (should be pre-installed in CI or available locally)
$pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge '5.0.0' } | Select-Object -First 1
if (-not $pesterModule) {
  Write-Host 'Pester v5+ not found. Attempting to install locally under tools/modules...'
  $toolsModules = Join-Path $root 'tools' 'modules'
  $pesterPath = Join-Path $toolsModules 'Pester'
  if (-not (Test-Path -LiteralPath $pesterPath)) {
    New-Item -ItemType Directory -Force -Path $toolsModules | Out-Null
    Save-Module -Name Pester -RequiredVersion 5.4.0 -Path $toolsModules -Force
  }
  $importTarget = Get-ChildItem -Path $pesterPath -Directory | Sort-Object Name -Descending | Select-Object -First 1
  Import-Module (Join-Path $importTarget.FullName 'Pester.psd1') -Force
} else {
  Import-Module Pester -MinimumVersion 5.0.0 -Force
}
Write-Host ("Using Pester {0}" -f (Get-Module Pester).Version)

# Build configuration
${script:startTime} = Get-Date
$conf = New-PesterConfiguration

# Resolve target path
if ($Path) {
  $target = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $root $Path }
  $conf.Run.Path = $target
} else {
  $conf.Run.Path = (Join-Path $root 'tests')
}
if (-not $IncludeIntegration) {
  $conf.Filter.ExcludeTag = @('Integration')
}
$conf.Output.Verbosity = $Output
$conf.TestResult.Enabled = $true
$conf.TestResult.OutputFormat = 'NUnitXml'
$conf.TestResult.OutputPath = 'pester-results.xml'  # filename relative to CWD per Pester 5

# Run from results directory so XML lands there
Push-Location -LiteralPath $resultsDir
try {
  Invoke-Pester -Configuration $conf
}
finally {
  Pop-Location
}

# Derive summary from NUnit XML
$xmlPath = Join-Path $resultsDir 'pester-results.xml'
if (-not (Test-Path -LiteralPath $xmlPath)) {
  Write-Error "Pester result XML not found at: $xmlPath"
  exit 1
}
[xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
$rootNode = $doc.'test-results'
[int]$total = $rootNode.total
[int]$failed = $rootNode.failures
[int]$errors = $rootNode.errors
[int]$notRun = $rootNode.'not-run'
[int]$inconclusive = $rootNode.inconclusive
[int]$ignored = $rootNode.ignored
[int]$invalid = $rootNode.invalid
# Treat not-run as skipped for summary purposes
$skipped = $notRun
# Passed excludes failures, errors, and not-run categories
$passed = $total - $failed - $errors - $skipped
if ($passed -lt 0) { $passed = 0 }

$duration = ((Get-Date) - $script:startTime).TotalSeconds
$summary = @(
  "Tests completed in {0:N2}s" -f $duration,
  "Tests Passed: $passed, Failed: $failed, Skipped: $skipped, Inconclusive: $inconclusive, NotRun: $notRun"
) -join [Environment]::NewLine
$summary | Tee-Object -FilePath (Join-Path $resultsDir 'pester-summary.txt')

if ($failed -gt 0 -or $errors -gt 0) { exit 1 }