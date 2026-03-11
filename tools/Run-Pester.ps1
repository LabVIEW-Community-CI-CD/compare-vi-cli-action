param(
  [switch]$IncludeIntegration,
  [string[]]$Path,
  [string[]]$FullName,
  [string[]]$Tag,
  [string[]]$ExcludeTag,
  [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
  [string]$OutputVerbosity = 'Detailed',
  [string]$ResultsDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resultsDir = if ($ResultsDir) {
  if ([System.IO.Path]::IsPathRooted($ResultsDir)) {
    $ResultsDir
  } else {
    Join-Path $root $ResultsDir
  }
} else {
  Join-Path $root 'tests' 'results'
}
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

$pesterVersion = '5.7.1'
$resolverPath = Join-Path $PSScriptRoot 'Get-PesterVersion.ps1'
if (Test-Path -LiteralPath $resolverPath) {
  try {
    $resolved = & $resolverPath
    if ($resolved -and -not [string]::IsNullOrWhiteSpace($resolved)) {
      $pesterVersion = $resolved
    }
  } catch {
    Write-Verbose ("Falling back to default Pester version ({0}) because resolver failed: {1}" -f $pesterVersion, $_.Exception.Message)
  }
}
if (-not $env:PESTER_VERSION -or [string]::IsNullOrWhiteSpace($env:PESTER_VERSION)) {
  $env:PESTER_VERSION = $pesterVersion
}

# Ensure the required Pester version is available locally
$pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [version]$pesterVersion } | Select-Object -First 1
if (-not $pesterModule) {
  Write-Host ("Pester {0} not found. Installing locally under tools/modules..." -f $pesterVersion)
  $toolsModules = Join-Path $root 'tools' 'modules'
  $pesterPath = Join-Path $toolsModules 'Pester'
  if (-not (Test-Path -LiteralPath $pesterPath)) {
    New-Item -ItemType Directory -Force -Path $toolsModules | Out-Null
  }
  Save-Module -Name Pester -RequiredVersion $pesterVersion -Path $toolsModules -Force
  $importTarget = Get-ChildItem -Path $pesterPath -Directory | Where-Object { $_.Name -eq $pesterVersion } | Select-Object -First 1
  if (-not $importTarget) {
    $importTarget = Get-ChildItem -Path $pesterPath -Directory | Sort-Object Name -Descending | Select-Object -First 1
  }
  Import-Module (Join-Path $importTarget.FullName 'Pester.psd1') -Force
} else {
  Import-Module Pester -RequiredVersion $pesterVersion -Force
}
Write-Host ("Using Pester {0}" -f (Get-Module Pester).Version)

# Build configuration
$conf = New-PesterConfiguration
$resolvedPaths = if ($Path -and $Path.Count -gt 0) {
  @($Path | ForEach-Object {
    if ([System.IO.Path]::IsPathRooted($_)) {
      $_
    } else {
      Join-Path $root $_
    }
  })
} else {
  @(Join-Path $root 'tests')
}
$conf.Run.Path = $resolvedPaths
$effectiveExcludeTag = New-Object System.Collections.Generic.List[string]
if ($ExcludeTag) {
  foreach ($entry in $ExcludeTag) {
    if (-not [string]::IsNullOrWhiteSpace($entry)) {
      $effectiveExcludeTag.Add($entry.Trim())
    }
  }
}
if (-not $IncludeIntegration -and -not ($Tag -contains 'Integration')) {
  $effectiveExcludeTag.Add('Integration')
}
if ($Tag -and $Tag.Count -gt 0) {
  $conf.Filter.Tag = @($Tag)
}
if ($effectiveExcludeTag.Count -gt 0) {
  $conf.Filter.ExcludeTag = @($effectiveExcludeTag | Select-Object -Unique)
}
if ($FullName -and $FullName.Count -gt 0) {
  $conf.Filter.FullName = @($FullName)
}
$conf.Output.Verbosity = $OutputVerbosity
$conf.Run.PassThru = $true
$conf.TestResult.Enabled = $true
$conf.TestResult.OutputFormat = 'NUnitXml'
$conf.TestResult.OutputPath = 'pester-results.xml'  # filename relative to CWD per Pester 5

# Run from results directory so XML lands there
Push-Location -LiteralPath $resultsDir
try {
  $pesterResult = Invoke-Pester -Configuration $conf
}
finally {
  Pop-Location
}

# Derive summary from NUnit XML
$xmlPath = Join-Path $resultsDir 'pester-results.xml'
$summaryPath = Join-Path $resultsDir 'pester-summary.txt'
if (-not (Test-Path -LiteralPath $xmlPath)) {
  $fallbackSummary = @(
    ("Tests Passed: {0}" -f $(if ($null -ne $pesterResult) { [int]$pesterResult.PassedCount } else { 0 }))
    ("Tests Failed: {0}" -f $(if ($null -ne $pesterResult) { [int]$pesterResult.FailedCount } else { 0 }))
    ("Tests Skipped: {0}" -f $(if ($null -ne $pesterResult) { [int]$pesterResult.SkippedCount } else { 0 }))
    'Summary source: in-memory fallback'
    ("Result XML missing: {0}" -f $xmlPath)
  ) -join [Environment]::NewLine
  $fallbackSummary | Tee-Object -FilePath $summaryPath
  Write-Error "Pester result XML not found at: $xmlPath"
  exit 1
}

try {
  [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
  $rootNode = $doc.'test-results'
  [int]$total = $rootNode.total
  [int]$failed = $rootNode.failures
  [int]$errors = $rootNode.errors
  $passed = $total - $failed - $errors
  $skipped = 0
  $summary = @(
    "Tests Passed: $passed",
    "Tests Failed: $failed",
    "Tests Skipped: $skipped"
  ) -join [Environment]::NewLine
  $summary | Tee-Object -FilePath $summaryPath
}
catch {
  $fallbackSummary = @(
    ("Tests Passed: {0}" -f $(if ($null -ne $pesterResult) { [int]$pesterResult.PassedCount } else { 0 }))
    ("Tests Failed: {0}" -f $(if ($null -ne $pesterResult) { [int]$pesterResult.FailedCount } else { 0 }))
    ("Tests Skipped: {0}" -f $(if ($null -ne $pesterResult) { [int]$pesterResult.SkippedCount } else { 0 }))
    'Summary source: in-memory fallback'
    ("XML parse error: {0}" -f $_.Exception.Message)
    ("Result XML: {0}" -f $xmlPath)
  ) -join [Environment]::NewLine
  $fallbackSummary | Tee-Object -FilePath $summaryPath
  Write-Warning ("Failed to parse NUnit XML at {0}: {1}" -f $xmlPath, $_.Exception.Message)
  exit 1
}

if ($failed -gt 0 -or $errors -gt 0) { exit 1 }
