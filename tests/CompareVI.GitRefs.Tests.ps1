# CompareVI-TestPlane: host-neutral
Describe 'CompareVI with Git refs (same path at two commits)' -Tag 'CompareVI','Integration' {
  BeforeAll {
    $ErrorActionPreference = 'Stop'
    # Require git
    try { git --version | Out-Null } catch { throw 'git is required for this test' }
    $repoRoot = (Get-Location).Path
    $target = 'VI1.vi'
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $target))) {
      Set-ItResult -Skipped -Because "Target file not found: $target"
    }

    # Collect recent refs that touched the file
    $revList = & git rev-list --max-count=50 HEAD -- $target
    if (-not $revList) { Set-ItResult -Skipped -Because 'No history for target'; return }
    $pairs = @()
    foreach ($a in $revList) {
      foreach ($b in $revList) {
        if ($a -ne $b) { $pairs += [pscustomobject]@{ A=$a; B=$b } }
      }
    }
    if (-not $pairs) { Set-ItResult -Skipped -Because 'Not enough refs' }
    Set-Variable -Name '_repo' -Value $repoRoot -Scope Script
    Set-Variable -Name '_pairs' -Value $pairs -Scope Script
    Set-Variable -Name '_target' -Value $target -Scope Script
  }

  It 'produces exec and summary JSON from two refs (non-failing check)' {
    # Find a pair that both produce file content; first successful used
    $pair = $null
    foreach ($p in $_pairs) {
      & git show --no-renames -- "$($p.A):$_target" 1>$null 2>$null
      $okA = ($LASTEXITCODE -eq 0)
      & git show --no-renames -- "$($p.B):$_target" 1>$null 2>$null
      $okB = ($LASTEXITCODE -eq 0)
      if ($okA -and $okB) { $pair = $p; break }
    }
    if (-not $pair) { Set-ItResult -Skipped -Because 'No valid ref pair with content'; return }

    $rd = Join-Path $TestDrive 'ref-compare'
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    $stubPath = Join-Path $_repo 'tests/stubs/Invoke-LVCompare.stub.ps1'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repo 'tools/Compare-RefsToTemp.ps1') `
      -Path $_target `
      -RefA $pair.A `
      -RefB $pair.B `
      -ResultsDir $rd `
      -OutName 'test' `
      -Detailed `
      -RenderReport `
      -InvokeScriptPath $stubPath `
      -FailOnDiff:$false | Out-Null
    $exec = Join-Path $rd 'test-exec.json'
    $sum  = Join-Path $rd 'test-summary.json'
    Test-Path -LiteralPath $exec | Should -BeTrue
    Test-Path -LiteralPath $sum  | Should -BeTrue
    $e = Get-Content -LiteralPath $exec -Raw | ConvertFrom-Json
    $s = Get-Content -LiteralPath $sum  -Raw | ConvertFrom-Json

    # Non-failing validation: ensure exec fields present and temp rename performed
    [string]::IsNullOrWhiteSpace($e.base) | Should -BeFalse
    [string]::IsNullOrWhiteSpace($e.head) | Should -BeFalse
    (Split-Path -Leaf $e.base) | Should -Be 'Base.vi'
    (Split-Path -Leaf $e.head) | Should -Be 'Head.vi'
    $s.schema | Should -Be 'ref-compare-summary/v1'
    $s.path   | Should -Be $_target
    $s.name   | Should -Be (Split-Path -Leaf $_target)

    # Print brief info for test logs
    "refs: A=$($pair.A) B=$($pair.B) expectDiff=$($s.computed.expectDiff) cliDiff=$($s.cli.diff) exit=$($s.cli.exitCode)" | Write-Host
  }

  It 'resolves a temp root when TEMP-style environment variables are missing' {
    $pair = $null
    foreach ($p in $_pairs) {
      & git show --no-renames -- "$($p.A):$_target" 1>$null 2>$null
      $okA = ($LASTEXITCODE -eq 0)
      & git show --no-renames -- "$($p.B):$_target" 1>$null 2>$null
      $okB = ($LASTEXITCODE -eq 0)
      if ($okA -and $okB) { $pair = $p; break }
    }
    if (-not $pair) { Set-ItResult -Skipped -Because 'No valid ref pair with content'; return }

    $resultsDir = Join-Path $TestDrive 'ref-compare-temp-fallback'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $stubPath = Join-Path $_repo 'tests/stubs/Invoke-LVCompare.stub.ps1'

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    foreach ($arg in @(
      '-NoLogo',
      '-NoProfile',
      '-File',
      (Join-Path $_repo 'tools/Compare-RefsToTemp.ps1'),
      '-Path',
      $_target,
      '-RefA',
      $pair.A,
      '-RefB',
      $pair.B,
      '-ResultsDir',
      $resultsDir,
      '-OutName',
      'temp-fallback',
      '-Detailed',
      '-RenderReport',
      '-InvokeScriptPath',
      $stubPath,
      '-FailOnDiff:$false'
    )) {
      [void]$psi.ArgumentList.Add($arg)
    }
    $psi.WorkingDirectory = $_repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($name in @('TEMP','TMP','TMPDIR','RUNNER_TEMP')) {
      [void]$psi.Environment.Remove($name)
    }
    $psi.Environment['STUB_COMPARE_DIFF'] = '1'

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
      if ($stdout) { Write-Host $stdout }
      if ($stderr) { Write-Host $stderr }
    }
    $proc.ExitCode | Should -Be 0

    $summaryPath = Join-Path $resultsDir 'temp-fallback-summary.json'
    $execPath = Join-Path $resultsDir 'temp-fallback-exec.json'
    Test-Path -LiteralPath $summaryPath | Should -BeTrue
    Test-Path -LiteralPath $execPath | Should -BeTrue

    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
    [int]$summary.cli.exitCode | Should -Be 1
    ($summary.out.reportHtml -as [string]) | Should -Match 'compare-report.html'
  }

  It 'supports detailed capture mode with stub LVCompare' {
    $pair = $null
    foreach ($p in $_pairs) {
      & git show --no-renames -- "$($p.A):$_target" 1>$null 2>$null
      $okA = ($LASTEXITCODE -eq 0)
      & git show --no-renames -- "$($p.B):$_target" 1>$null 2>$null
      $okB = ($LASTEXITCODE -eq 0)
      if ($okA -and $okB) { $pair = $p; break }
    }
    if (-not $pair) { Set-ItResult -Skipped -Because 'No valid ref pair with content'; return }

    $stub = Join-Path $TestDrive 'Invoke-LVCompare.stub.ps1'
    $stubContent = @'
param(
  [Parameter(Mandatory=$true)][string]$BaseVi,
  [Parameter(Mandatory=$true)][string]$HeadVi,
  [string]$OutputDir,
  [string]$LabVIEWExePath,
  [string]$LVComparePath,
  [string[]]$Flags,
  [switch]$RenderReport,
  [switch]$Quiet,
  [switch]$LeakCheck,
  [double]$LeakGraceSeconds = 0,
  [string]$LeakJsonPath,
  [string]$CaptureScriptPath,
  [Nullable[int]]$TimeoutSeconds,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = Join-Path $env:TEMP ("stub-" + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$exitPath   = Join-Path $OutputDir 'lvcompare-exitcode.txt'
$reportPath = Join-Path $OutputDir 'compare-report.html'
$capturePath= Join-Path $OutputDir 'lvcompare-capture.json'
$imagesDir  = Join-Path $OutputDir 'cli-images'
$stdoutLines = @(
  'Comparison Summary:',
  'Block Diagram Differences detected.',
  'VI Attributes changed: VI Description mismatch.'
)
$stdoutLines | Set-Content -LiteralPath $stdoutPath -Encoding utf8
'' | Set-Content -LiteralPath $stderrPath -Encoding utf8
'1' | Set-Content -LiteralPath $exitPath -Encoding utf8
if ($RenderReport.IsPresent) {
  '<html><body><h1>Stub Report</h1></body></html>' | Set-Content -LiteralPath $reportPath -Encoding utf8
}
New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0x01,0x02,0x03))
if (-not $LVComparePath) { $LVComparePath = 'C:\Stub\LVCompare.exe' }
$artifacts = [ordered]@{
  reportSizeBytes = 256
  imageCount      = 1
  exportDir       = $imagesDir
  images          = @(
    [ordered]@{
      index      = 0
      mimeType   = 'image/png'
      byteLength = 3
      savedPath  = (Join-Path $imagesDir 'cli-image-00.png')
    }
  )
}
$capture = [ordered]@{
  schema    = 'lvcompare-capture-v1'
  timestamp = (Get-Date).ToString('o')
  base      = $BaseVi
  head      = $HeadVi
  cliPath   = $LVComparePath
  args      = $Flags
  exitCode  = 1
  seconds   = 0.42
  stdoutLen = 64
  stderrLen = 0
  command   = ("LVCompare.exe ""{0}"" ""{1}""" -f $BaseVi,$HeadVi)
  environment = [ordered]@{
    cli = [ordered]@{
      artifacts = $artifacts
    }
  }
}
$capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capturePath -Encoding utf8

if ($LeakCheck -and $LeakJsonPath) {
  $leakDir = Split-Path -Parent $LeakJsonPath
  if ($leakDir) { New-Item -ItemType Directory -Path $leakDir -Force | Out-Null }
  $leakInfo = [ordered]@{
    schema       = 'lvcompare-leak-v1'
    generatedAt  = (Get-Date).ToString('o')
    leakDetected = $false
    processes    = @()
    graceSeconds = $LeakGraceSeconds
  }
  $leakInfo | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LeakJsonPath -Encoding utf8
}
exit 1
'@
    Set-Content -LiteralPath $stub -Value $stubContent -Encoding utf8

    $resultsDir = Join-Path $TestDrive 'ref-compare-detail'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repo 'tools/Compare-RefsToTemp.ps1') `
      -ViName (Split-Path -Leaf $_target) `
      -RefA $pair.A `
      -RefB $pair.B `
      -ResultsDir $resultsDir `
      -OutName 'detail' `
      -Detailed `
      -RenderReport `
      -InvokeScriptPath $stub `
      -LeakCheck `
      -LeakGraceSeconds 2.5 `
      -LeakJsonPath (Join-Path $resultsDir 'detail-leak.json') `
      -FailOnDiff:$false | Out-Null

    $exec = Join-Path $resultsDir 'detail-exec.json'
    $sum  = Join-Path $resultsDir 'detail-summary.json'
    Test-Path -LiteralPath $exec | Should -BeTrue
    Test-Path -LiteralPath $sum  | Should -BeTrue

    $s = Get-Content -LiteralPath $sum -Raw | ConvertFrom-Json
    Copy-Item -LiteralPath $sum -Destination (Join-Path $_repo 'tests/results/gitrefs-detail-summary.json') -Force
    [int]$s.cli.exitCode | Should -Be 1
    ($s.out.captureJson -as [string]) | Should -Match 'lvcompare-capture.json'
    ($s.out.reportHtml -as [string])  | Should -Match 'compare-report.html'
    $s.path | Should -Be $_target
    $s.cli.highlights | Should -Contain 'Block Diagram Differences detected.'
    $s.cli.artifacts.imageCount | Should -Be 1
    $s.cli.artifacts.leakDetected | Should -BeFalse
    $s.cli.artifacts.graceSeconds | Should -Be 2.5
    $s.cli.artifacts.PSObject.Properties.Name | Should -Contain 'processes'
  }

  It 'derives explicit diff categories from HTML reports when stdout lacks category hints' {
    $pair = $null
    foreach ($p in $_pairs) {
      & git show --no-renames -- "$($p.A):$_target" 1>$null 2>$null
      $okA = ($LASTEXITCODE -eq 0)
      & git show --no-renames -- "$($p.B):$_target" 1>$null 2>$null
      $okB = ($LASTEXITCODE -eq 0)
      if ($okA -and $okB) { $pair = $p; break }
    }
    if (-not $pair) { Set-ItResult -Skipped -Because 'No valid ref pair with content'; return }

    $stub = Join-Path $TestDrive 'Invoke-LVCompare.report-only.stub.ps1'
    $stubContent = @'
param(
  [Parameter(Mandatory=$true)][string]$BaseVi,
  [Parameter(Mandatory=$true)][string]$HeadVi,
  [string]$OutputDir,
  [string]$LabVIEWExePath,
  [string]$LVComparePath,
  [string[]]$Flags,
  [switch]$RenderReport,
  [switch]$Quiet,
  [string]$LeakJsonPath,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = Join-Path $env:TEMP ("stub-report-only-" + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$capturePath= Join-Path $OutputDir 'lvcompare-capture.json'
$reportPath = Join-Path $OutputDir 'compare-report.html'
$imagesDir  = Join-Path $OutputDir 'cli-images'

'Stub LVCompare run with report-only categories.' | Set-Content -LiteralPath $stdoutPath -Encoding utf8
'' | Set-Content -LiteralPath $stderrPath -Encoding utf8

$reportHtml = @"
<!DOCTYPE html>
<html>
<body>
  <div class="included-attributes">
    <ul class="inclusion-list">
      <li class="checked">Block Diagram Cosmetic</li>
    </ul>
  </div>
  <details open>
    <summary class="difference-cosmetic-heading">1. Block Diagram Cosmetic - Wiring</summary>
    <ol class="detailed-description-list">
      <li class="diff-detail-cosmetic">Wire adjusted</li>
    </ol>
  </details>
</body>
</html>
"@
    $reportHtml | Set-Content -LiteralPath $reportPath -Encoding utf8

New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0x01,0x02,0x03))
if (-not $LVComparePath) { $LVComparePath = 'C:\Stub\LVCompare.exe' }

$capture = [ordered]@{
  schema    = 'lvcompare-capture-v1'
  timestamp = (Get-Date).ToString('o')
  base      = $BaseVi
  head      = $HeadVi
  cliPath   = $LVComparePath
  args      = $Flags
  exitCode  = 1
  seconds   = 0.15
  stdoutLen = 1
  stderrLen = 0
  command   = ("LVCompare.exe ""{0}"" ""{1}""" -f $BaseVi,$HeadVi)
  environment = [ordered]@{
    cli = [ordered]@{
      artifacts = [ordered]@{
        reportSizeBytes = 256
        imageCount      = 1
        exportDir       = $imagesDir
        images          = @(
          [ordered]@{
            index      = 0
            mimeType   = 'image/png'
            byteLength = 3
            savedPath  = (Join-Path $imagesDir 'cli-image-00.png')
          }
        )
      }
    }
  }
}
$capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capturePath -Encoding utf8
exit 1
'@
    Set-Content -LiteralPath $stub -Value $stubContent -Encoding utf8

    $resultsDir = Join-Path $TestDrive 'ref-compare-report-derived'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repo 'tools/Compare-RefsToTemp.ps1') `
      -ViName (Split-Path -Leaf $_target) `
      -RefA $pair.A `
      -RefB $pair.B `
      -ResultsDir $resultsDir `
      -OutName 'report-derived' `
      -Detailed `
      -RenderReport `
      -InvokeScriptPath $stub `
      -FailOnDiff:$false | Out-Null

    $sum = Join-Path $resultsDir 'report-derived-summary.json'
    Test-Path -LiteralPath $sum | Should -BeTrue

    $summary = Get-Content -LiteralPath $sum -Raw | ConvertFrom-Json -Depth 10
    $summary.cli.categories | Should -Contain 'Block Diagram Cosmetic'
    (($summary.cli.categoryDetails | Where-Object { $_.slug -eq 'block-diagram-cosmetic' }).Count) | Should -Be 1
    $summary.cli.categoryBuckets | Should -Contain 'ui-visual'
    $summary.cli.highlights | Should -Contain 'Block Diagram Cosmetic - Wiring'
  }
}
