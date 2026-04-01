Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'git cat-file path quoting' -Tag 'Integration' {
  It 'handles repository paths containing spaces when working directory supplied' {
    $tempRepo = Join-Path $TestDrive 'space-path-catfile'
    New-Item -ItemType Directory -Path $tempRepo -Force | Out-Null

    Push-Location $tempRepo
    try {
      & git init | Out-Null
      & git config user.name 'CompareVI Tests' | Out-Null
      & git config user.email 'comparevi.tests@example.com' | Out-Null

      $targetRelPath = 'Tooling/deployment/VIP_Post-Install Custom Action.vi'
      New-Item -ItemType Directory -Path (Split-Path -Parent $targetRelPath) -Force | Out-Null

      'base version' | Set-Content -LiteralPath $targetRelPath -Encoding utf8
      & git add . | Out-Null
      & git commit -m 'feat: add VIP post-install action' | Out-Null

      'updated version' | Set-Content -LiteralPath $targetRelPath -Encoding utf8
      & git add . | Out-Null
      & git commit -m 'fix: adjust VIP post-install action' | Out-Null

      $headCommit = (& git rev-parse HEAD).Trim()
      $expr = "{0}:{1}" -f $headCommit, $targetRelPath

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = 'git'
      foreach ($arg in @('cat-file','-e',$expr)) { [void]$psi.ArgumentList.Add($arg) }
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true

      $procNoCwd = [System.Diagnostics.Process]::Start($psi)
      $procNoCwd.WaitForExit()
      $procNoCwd.ExitCode | Should -Not -Be 0

      $psiWorking = [System.Diagnostics.ProcessStartInfo]::new()
      $psiWorking.FileName = 'git'
      foreach ($arg in @('cat-file','-e',$expr)) { [void]$psiWorking.ArgumentList.Add($arg) }
      $psiWorking.RedirectStandardOutput = $true
      $psiWorking.RedirectStandardError = $true
      $psiWorking.UseShellExecute = $false
      $psiWorking.CreateNoWindow = $true
      $psiWorking.WorkingDirectory = $tempRepo

      $procWithCwd = [System.Diagnostics.Process]::Start($psiWorking)
      $procWithCwd.WaitForExit()
      $procWithCwd.ExitCode | Should -Be 0
    }
    finally {
      Pop-Location
    }
  }
}

Describe 'Compare-VIHistory cross-repo staging' -Tag 'Integration' {
  It 'produces comparison artifacts when scripts root override is provided' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $compareHistoryScript = Join-Path $repoRoot 'tools' 'Compare-VIHistory.ps1'

    $tempRepo = Join-Path $TestDrive 'crossrepo-history'
    New-Item -ItemType Directory -Path $tempRepo -Force | Out-Null

    Push-Location $tempRepo
    try {
      & git init | Out-Null
      & git config user.name 'CompareVI Tests' | Out-Null
      & git config user.email 'comparevi.tests@example.com' | Out-Null

      $targetRelPath = 'Tooling/deployment/VIP_Post-Install Custom Action.vi'
      New-Item -ItemType Directory -Path (Split-Path -Parent $targetRelPath) -Force | Out-Null

      'base version' | Set-Content -LiteralPath $targetRelPath -Encoding utf8
      & git add . | Out-Null
      & git commit -m 'feat: add VIP post-install action' | Out-Null

      'updated version' | Set-Content -LiteralPath $targetRelPath -Encoding utf8
      & git add . | Out-Null
      & git commit -m 'fix: adjust VIP post-install action' | Out-Null
      $headCommit = (& git rev-parse HEAD).Trim()
    }
    finally {
      Pop-Location
    }

    $stubPath = Join-Path $TestDrive 'Invoke-LVCompare.crossrepo.stub.ps1'
    @'
param(
  [Parameter(Mandatory = $true)][string]$BaseVi,
  [Parameter(Mandatory = $true)][string]$HeadVi,
  [string]$OutputDir,
  [string]$LabVIEWExePath,
  [string]$LabVIEWBitness = "64",
  [string]$LVComparePath,
  [string[]]$Flags,
  [switch]$ReplaceFlags,
  [switch]$AllowSameLeaf,
  [switch]$RenderReport,
  [ValidateSet("html","xml","text")][string[]]$ReportFormat = "html",
  [string]$JsonLogPath,
  [switch]$Quiet,
  [switch]$LeakCheck,
  [double]$LeakGraceSeconds = 0,
  [string]$LeakJsonPath,
  [string]$CaptureScriptPath,
  [switch]$Summary,
  [Nullable[int]]$TimeoutSeconds,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputDir) {
  $OutputDir = Join-Path $env:TEMP ("history-stub-" + [guid]::NewGuid().ToString("N"))
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$reportPath = Join-Path $OutputDir 'compare-report.html'
$capturePath = Join-Path $OutputDir 'lvcompare-capture.json'
$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'

"<html><body><h1>Stub Compare Report</h1></body></html>" | Set-Content -LiteralPath $reportPath -Encoding utf8
"" | Set-Content -LiteralPath $stdoutPath -Encoding utf8
"" | Set-Content -LiteralPath $stderrPath -Encoding utf8

[ordered]@{
  schema    = 'lvcompare-capture-v1'
  timestamp = (Get-Date).ToString('o')
  base      = $BaseVi
  head      = $HeadVi
  cliPath   = 'stub'
  args      = $Flags
  exitCode  = 0
  seconds   = 0.05
  command   = 'stub'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $capturePath -Encoding utf8

$parentDir = Split-Path -Parent $OutputDir
$outLeaf = Split-Path -Leaf $OutputDir
if ($outLeaf -like '*-artifacts') {
  $outName = $outLeaf.Substring(0, $outLeaf.Length - '-artifacts'.Length)
} else {
  $outName = $outLeaf
}
$summaryPath = Join-Path $parentDir ("{0}-summary.json" -f $outName)
$execPath = Join-Path $parentDir ("{0}-exec.json" -f $outName)

[ordered]@{
  schema      = 'ref-compare-summary/v1'
  generatedAt = (Get-Date).ToString('o')
  name        = Split-Path -Leaf $HeadVi
  path        = $HeadVi
  refA        = $BaseVi
  refB        = $HeadVi
  temp        = $OutputDir
  reportFormat= 'html'
  out         = [pscustomobject]@{
    captureJson = $capturePath
    reportPath  = $reportPath
    stdout      = $stdoutPath
    stderr      = $stderrPath
  }
  computed    = [ordered]@{
    baseBytes  = 0
    headBytes  = 0
    baseSha    = 'stub-base'
    headSha    = 'stub-head'
    expectDiff = $false
  }
  cli         = [pscustomobject]@{
    exitCode   = 0
    diff       = $false
    duration_s = 0.05
    command    = 'stub'
    cliPath    = 'stub'
  }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

[ordered]@{
  schema      = 'compare-exec/v1'
  generatedAt = (Get-Date).ToString('o')
  cliPath     = 'stub'
  command     = 'stub'
  args        = @()
  exitCode    = 0
  diff        = $false
  cwd         = (Get-Location).Path
  duration_s  = 0.05
  base        = $BaseVi
  head        = $HeadVi
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $execPath -Encoding utf8

exit 0
'@ | Set-Content -LiteralPath $stubPath -Encoding utf8

    $resultsDir = Join-Path $TestDrive 'crossrepo-history-results'
    $previousScriptsRoot = $env:COMPAREVI_SCRIPTS_ROOT
    $env:COMPAREVI_SCRIPTS_ROOT = $repoRoot
    try {
      Push-Location $tempRepo
      try {
        $args = @(
          '-NoLogo','-NoProfile','-File', $compareHistoryScript,
          '-TargetPath', 'Tooling/deployment/VIP_Post-Install Custom Action.vi',
          '-StartRef', $headCommit,
          '-MaxPairs', '1',
          '-RenderReport',
          '-FailOnDiff:$false',
          '-ResultsDir', $resultsDir,
          '-InvokeScriptPath', $stubPath,
          '-Quiet'
        )
        & pwsh @args | Out-Null
      }
      finally {
        Pop-Location
      }
    }
    finally {
      if ($null -ne $previousScriptsRoot) {
        $env:COMPAREVI_SCRIPTS_ROOT = $previousScriptsRoot
      } else {
        Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
      }
    }

    $manifestPath = Join-Path $resultsDir 'default' 'manifest.json'
    $manifestPath | Should -Exist
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 6
    $manifest.stats.missing | Should -Be 0
    $manifest.comparisons | Should -Not -BeNullOrEmpty
  }

  It 'emits native history paths when results dir is provider-qualified' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $compareHistoryScript = Join-Path $repoRoot 'tools' 'Compare-VIHistory.ps1'

    $tempRepo = Join-Path $TestDrive 'crossrepo-history-provider'
    New-Item -ItemType Directory -Path $tempRepo -Force | Out-Null

    Push-Location $tempRepo
    try {
      & git init | Out-Null
      & git config user.name 'CompareVI Tests' | Out-Null
      & git config user.email 'comparevi.tests@example.com' | Out-Null

      $targetRelPath = 'Tooling/deployment/VIP_Post-Install Custom Action.vi'
      New-Item -ItemType Directory -Path (Split-Path -Parent $targetRelPath) -Force | Out-Null

      'base version' | Set-Content -LiteralPath $targetRelPath -Encoding utf8
      & git add . | Out-Null
      & git commit -m 'feat: add VIP post-install action' | Out-Null

      'updated version' | Set-Content -LiteralPath $targetRelPath -Encoding utf8
      & git add . | Out-Null
      & git commit -m 'fix: adjust VIP post-install action' | Out-Null
      $headCommit = (& git rev-parse HEAD).Trim()
    }
    finally {
      Pop-Location
    }

    $stubPath = Join-Path $TestDrive 'Invoke-LVCompare.crossrepo.provider.stub.ps1'
    @'
param(
  [Parameter(Mandatory = $true)][string]$BaseVi,
  [Parameter(Mandatory = $true)][string]$HeadVi,
  [string]$OutputDir,
  [string]$LabVIEWExePath,
  [string]$LabVIEWBitness = "64",
  [string]$LVComparePath,
  [string[]]$Flags,
  [switch]$ReplaceFlags,
  [switch]$AllowSameLeaf,
  [switch]$RenderReport,
  [ValidateSet("html","xml","text")][string[]]$ReportFormat = "html",
  [string]$JsonLogPath,
  [switch]$Quiet,
  [switch]$LeakCheck,
  [double]$LeakGraceSeconds = 0,
  [string]$LeakJsonPath,
  [string]$CaptureScriptPath,
  [switch]$Summary,
  [Nullable[int]]$TimeoutSeconds,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputDir) {
  $OutputDir = Join-Path $env:TEMP ("history-stub-" + [guid]::NewGuid().ToString("N"))
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$reportPath = Join-Path $OutputDir 'compare-report.html'
$capturePath = Join-Path $OutputDir 'lvcompare-capture.json'
$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'

"<html><body><h1>Stub Compare Report</h1></body></html>" | Set-Content -LiteralPath $reportPath -Encoding utf8
"" | Set-Content -LiteralPath $stdoutPath -Encoding utf8
"" | Set-Content -LiteralPath $stderrPath -Encoding utf8

[ordered]@{
  schema    = 'lvcompare-capture-v1'
  timestamp = (Get-Date).ToString('o')
  base      = $BaseVi
  head      = $HeadVi
  cliPath   = 'stub'
  args      = $Flags
  exitCode  = 0
  seconds   = 0.05
  command   = 'stub'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $capturePath -Encoding utf8

$parentDir = Split-Path -Parent $OutputDir
$outLeaf = Split-Path -Leaf $OutputDir
if ($outLeaf -like '*-artifacts') {
  $outName = $outLeaf.Substring(0, $outLeaf.Length - '-artifacts'.Length)
} else {
  $outName = $outLeaf
}
$summaryPath = Join-Path $parentDir ("{0}-summary.json" -f $outName)
$execPath = Join-Path $parentDir ("{0}-exec.json" -f $outName)

[ordered]@{
  schema      = 'ref-compare-summary/v1'
  generatedAt = (Get-Date).ToString('o')
  name        = Split-Path -Leaf $HeadVi
  path        = $HeadVi
  refA        = $BaseVi
  refB        = $HeadVi
  temp        = $OutputDir
  reportFormat= 'html'
  out         = [pscustomobject]@{
    captureJson = $capturePath
    reportPath  = $reportPath
    stdout      = $stdoutPath
    stderr      = $stderrPath
  }
  computed    = [ordered]@{
    baseBytes  = 0
    headBytes  = 0
    baseSha    = 'stub-base'
    headSha    = 'stub-head'
    expectDiff = $false
  }
  cli         = [pscustomobject]@{
    exitCode   = 0
    diff       = $false
    duration_s = 0.05
    command    = 'stub'
    cliPath    = 'stub'
  }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

[ordered]@{
  schema      = 'compare-exec/v1'
  generatedAt = (Get-Date).ToString('o')
  cliPath     = 'stub'
  command     = 'stub'
  args        = @()
  exitCode    = 0
  diff        = $false
  cwd         = (Get-Location).Path
  duration_s  = 0.05
  base        = $BaseVi
  head        = $HeadVi
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $execPath -Encoding utf8

exit 0
'@ | Set-Content -LiteralPath $stubPath -Encoding utf8

    $resultsDir = Join-Path $TestDrive 'crossrepo-history-provider-results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $providerResultsDir = "Microsoft.PowerShell.Core\FileSystem::$resultsDir"
    $previousScriptsRoot = $env:COMPAREVI_SCRIPTS_ROOT
    $env:COMPAREVI_SCRIPTS_ROOT = $repoRoot
    try {
      Push-Location $tempRepo
      try {
        $args = @(
          '-NoLogo','-NoProfile','-File', $compareHistoryScript,
          '-TargetPath', 'Tooling/deployment/VIP_Post-Install Custom Action.vi',
          '-StartRef', $headCommit,
          '-MaxPairs', '1',
          '-RenderReport',
          '-FailOnDiff:$false',
          '-ResultsDir', $providerResultsDir,
          '-InvokeScriptPath', $stubPath,
          '-Quiet'
        )
        & pwsh @args | Out-Null
      }
      finally {
        Pop-Location
      }
    }
    finally {
      if ($null -ne $previousScriptsRoot) {
        $env:COMPAREVI_SCRIPTS_ROOT = $previousScriptsRoot
      } else {
        Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
      }
    }

    $aggregateManifestPath = Join-Path $resultsDir 'manifest.json'
    $modeManifestPath = Join-Path $resultsDir 'default' 'manifest.json'
    $historySummaryPath = Join-Path $resultsDir 'history-summary.json'

    $aggregateManifestPath | Should -Exist
    $modeManifestPath | Should -Exist
    $historySummaryPath | Should -Exist

    $aggregateManifest = Get-Content -LiteralPath $aggregateManifestPath -Raw | ConvertFrom-Json -Depth 8
    $modeManifest = Get-Content -LiteralPath $modeManifestPath -Raw | ConvertFrom-Json -Depth 8
    $historySummary = Get-Content -LiteralPath $historySummaryPath -Raw | ConvertFrom-Json -Depth 8

    foreach ($pathValue in @(
      [string]$aggregateManifest.modes[0].manifestPath,
      [string]$aggregateManifest.modes[0].resultsDir,
      [string]$modeManifest.resultsDir,
      [string]$historySummary.execution.resultsDir,
      [string]$historySummary.execution.manifestPath,
      [string]$historySummary.reports.markdownPath,
      [string]$historySummary.reports.htmlPath
    )) {
      if (-not [string]::IsNullOrWhiteSpace($pathValue)) {
        $pathValue | Should -Not -Match 'Microsoft\.PowerShell\.Core\\FileSystem::'
      }
    }
  }
}
