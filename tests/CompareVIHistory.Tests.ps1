Describe 'Compare-VIHistory.ps1' {
  $repoRoot = (Get-Location).Path
  $scriptPath = Join-Path $repoRoot 'tools' 'Compare-VIHistory.ps1'
  Test-Path -LiteralPath $scriptPath -PathType Leaf | Should -BeTrue


  Context 'artifact handling' {
    It 'falls back to cli-report.html when compare report is renamed' {
      $scriptPath = Join-Path (Get-Location).Path 'tools' 'Compare-VIHistory.ps1'
      $stubTemplate = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$OutputDir,
  [string[]]$Flags
)
$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = Join-Path $env:TEMP ([guid]::NewGuid().ToString()) }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$exitCodeValue = 0
if ($env:STUB_COMPARE_EXITCODE) {
  $parsed = 0
  if ([int]::TryParse($env:STUB_COMPARE_EXITCODE, [ref]$parsed)) {
    $exitCodeValue = $parsed
  }
}

function Get-StubBool([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $false }
  switch -Regex ($value.ToLowerInvariant()) {
    '^(1|true|yes|on)$' { return $true }
    default { return $false }
  }
}

$diffFlag     = Get-StubBool $env:STUB_COMPARE_DIFF
$renameReport = Get-StubBool $env:STUB_COMPARE_RENAME_REPORT

$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$exitPath   = Join-Path $OutputDir 'lvcompare-exitcode.txt'
$reportPath = Join-Path $OutputDir 'compare-report.html'
$cliReport  = Join-Path $OutputDir 'cli-report.html'
$capPath    = Join-Path $OutputDir 'lvcompare-capture.json'

"Stub compare for $BaseVi -> $HeadVi (flags: $($Flags -join ' '))" | Out-File -LiteralPath $stdoutPath -Encoding utf8
'' | Out-File -LiteralPath $stderrPath -Encoding utf8
$exitCodeValue.ToString() | Out-File -LiteralPath $exitPath -Encoding utf8
'<html><body><h1>Stub Report</h1></body></html>' | Out-File -LiteralPath $reportPath -Encoding utf8

if (Test-Path -LiteralPath $cliReport) { Remove-Item -LiteralPath $cliReport -Force }

if ($renameReport) {
  Rename-Item -LiteralPath $reportPath -NewName (Split-Path $cliReport -Leaf)
} else {
  Copy-Item -LiteralPath $reportPath -Destination $cliReport -Force
}

$cap = [ordered]@{
  schema   = 'lvcompare-capture-v1'
  exitCode = $exitCodeValue
  seconds  = 0.02
  command  = 'stub'
  cliPath  = 'stub'
  base     = $BaseVi
  head     = $HeadVi
  diff     = $diffFlag
  args     = $Flags
  environment = [ordered]@{
    flags  = $Flags
    policy = 'default'
  }
  cli      = [ordered]@{
    exitCode   = $exitCodeValue
    diff       = $diffFlag
    highlights = @("stub: $HeadVi")
  }
}
$cap | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $capPath -Encoding utf8
'@
      $stubPath = Join-Path $TestDrive 'Invoke-LVCompare.stub.ps1'
      Set-Content -LiteralPath $stubPath -Value $stubTemplate -Encoding utf8

      $resultsDir = Join-Path $TestDrive 'history-fallback'
      $env:STUB_COMPARE_RENAME_REPORT = '1'
      $startRef = git rev-list HEAD --max-count=1 --first-parent -- 'VI1.vi' 2>$null | Where-Object { $_ } | Select-Object -First 1
      if ($LASTEXITCODE -ne 0 -or -not $startRef) {
        Set-ItResult -Skipped -Because "No commit for VI1.vi found in repo history."
        return
      }
      $startRef = $startRef.Trim()
      try {
        $invokeHistory = {
          param([string[]]$ExtraArgs, [string]$StartRef)
          $baseArgs = @(
            '-NoLogo', '-NoProfile',
            '-File', $scriptPath,
            '-TargetPath', 'VI1.vi',
            '-StartRef', $StartRef,
            '-MaxPairs', 2,
            '-ResultsDir', $resultsDir,
            '-InvokeScriptPath', $stubPath
          )
          if ($ExtraArgs) { $baseArgs += $ExtraArgs }
          $proc = Start-Process -FilePath 'pwsh' -ArgumentList $baseArgs -Wait -PassThru -WindowStyle Hidden
          return $proc.ExitCode
        }

        $exit = & $invokeHistory @() $startRef
        $exit | Should -Be 0

        $summaryPath = Join-Path $resultsDir 'history-summary.json'
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
          Set-ItResult -Skipped -Because "history summary not produced for branch window (likely no commits with VI present)"
          return
        }

        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 10
        $summary.schema | Should -Be 'vi-history-compare/v1'
        $executedPairs = @($summary.pairs | Where-Object { -not $_.skippedIdentical -and -not $_.skippedMissing })
        if ($executedPairs.Count -eq 0) {
          Set-ItResult -Skipped -Because "no executed pairs were generated for VI1.vi on this branch"
          return
        }

        $pair = $executedPairs | Select-Object -First 1
        $pair.reportHtml | Should -Not -BeNullOrEmpty
        $pair.reportHtml | Should -Match 'cli-report\.html$'
        Test-Path -LiteralPath $pair.reportHtml -PathType Leaf | Should -BeTrue
      }
      finally {
        Remove-Item Env:STUB_COMPARE_RENAME_REPORT -ErrorAction SilentlyContinue
        Remove-Item Env:STUB_COMPARE_EXITCODE -ErrorAction SilentlyContinue
        Remove-Item Env:STUB_COMPARE_DIFF -ErrorAction SilentlyContinue
      }
    }
  }

  Context 'diff exit handling' {
    It 'treats exit code 1 with diff as success unless FailOnDiff is set' {
      $scriptPath = Join-Path (Get-Location).Path 'tools' 'Compare-VIHistory.ps1'
      $stubTemplate = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$OutputDir,
  [string[]]$Flags
)
$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = Join-Path $env:TEMP ([guid]::NewGuid().ToString()) }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$exitCodeValue = 0
if ($env:STUB_COMPARE_EXITCODE) {
  $parsed = 0
  if ([int]::TryParse($env:STUB_COMPARE_EXITCODE, [ref]$parsed)) {
    $exitCodeValue = $parsed
  }
}

function Get-StubBool([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $false }
  switch -Regex ($value.ToLowerInvariant()) {
    '^(1|true|yes|on)$' { return $true }
    default { return $false }
  }
}

$diffFlag     = Get-StubBool $env:STUB_COMPARE_DIFF
$renameReport = Get-StubBool $env:STUB_COMPARE_RENAME_REPORT

$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$exitPath   = Join-Path $OutputDir 'lvcompare-exitcode.txt'
$reportPath = Join-Path $OutputDir 'compare-report.html'
$cliReport  = Join-Path $OutputDir 'cli-report.html'
$capPath    = Join-Path $OutputDir 'lvcompare-capture.json'

"Stub compare for $BaseVi -> $HeadVi (flags: $($Flags -join ' '))" | Out-File -LiteralPath $stdoutPath -Encoding utf8
'' | Out-File -LiteralPath $stderrPath -Encoding utf8
$exitCodeValue.ToString() | Out-File -LiteralPath $exitPath -Encoding utf8
'<html><body><h1>Stub Report</h1></body></html>' | Out-File -LiteralPath $reportPath -Encoding utf8

if (Test-Path -LiteralPath $cliReport) { Remove-Item -LiteralPath $cliReport -Force }

if ($renameReport) {
  Rename-Item -LiteralPath $reportPath -NewName (Split-Path $cliReport -Leaf)
} else {
  Copy-Item -LiteralPath $reportPath -Destination $cliReport -Force
}

$cap = [ordered]@{
  schema   = 'lvcompare-capture-v1'
  exitCode = $exitCodeValue
  seconds  = 0.02
  command  = 'stub'
  cliPath  = 'stub'
  base     = $BaseVi
  head     = $HeadVi
  diff     = $diffFlag
  args     = $Flags
  environment = [ordered]@{
    flags  = $Flags
    policy = 'default'
  }
  cli      = [ordered]@{
    exitCode   = $exitCodeValue
    diff       = $diffFlag
    highlights = @("stub: $HeadVi")
  }
}
$cap | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $capPath -Encoding utf8
'@
      $stubPath = Join-Path $TestDrive 'Invoke-LVCompare.diffstub.ps1'
      Set-Content -LiteralPath $stubPath -Value $stubTemplate -Encoding utf8

      $resultsDir = Join-Path $TestDrive 'history-diff'
      $env:STUB_COMPARE_EXITCODE = '1'
      $env:STUB_COMPARE_DIFF = '1'
      $startRef = git rev-list HEAD --max-count=1 --first-parent -- 'VI1.vi' 2>$null | Where-Object { $_ } | Select-Object -First 1
      if ($LASTEXITCODE -ne 0 -or -not $startRef) {
        Set-ItResult -Skipped -Because "No commit for VI1.vi found in repo history."
        return
      }
      $startRef = $startRef.Trim()
      try {
        $invokeHistory = {
          param([string[]]$ExtraArgs, [string]$StartRefValue)
          $baseArgs = @(
            '-NoLogo', '-NoProfile',
            '-File', $scriptPath,
            '-TargetPath', 'VI1.vi',
            '-StartRef', $StartRefValue,
            '-MaxPairs', 1,
            '-ResultsDir', $resultsDir,
            '-InvokeScriptPath', $stubPath
          )
          if ($ExtraArgs) { $baseArgs += $ExtraArgs }
          $proc = Start-Process -FilePath 'pwsh' -ArgumentList $baseArgs -Wait -PassThru -WindowStyle Hidden
          return $proc.ExitCode
        }

        $exit = & $invokeHistory @() $startRef
        $exit | Should -Be 0

        $summaryPath = Join-Path $resultsDir 'history-summary.json'
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
          Set-ItResult -Skipped -Because "history summary not produced for branch window (likely no commits with VI present)"
          return
        }

        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 10
        $pair = @($summary.pairs | Where-Object { -not $_.skippedIdentical -and -not $_.skippedMissing }) | Select-Object -First 1
        if (-not $pair) {
          Set-ItResult -Skipped -Because "no executed pairs were generated for VI1.vi on this branch"
          return
        }

        $pair.exitCode | Should -Be 0
        $pair.diff | Should -BeTrue
        if ($pair.lvcompare) {
          $pair.lvcompare.exitCode | Should -Be 1
          $pair.lvcompare.diff | Should -BeTrue
        }

        if (-not $pair.diff) {
          Set-ItResult -Skipped -Because "no diff detected for VI1.vi on this branch"
          return
        }

        $failArgs = @(
          '-NoLogo','-NoProfile',
          '-File', $scriptPath,
          '-TargetPath','VI1.vi',
          '-StartRef',$startRef,
          '-MaxPairs','1',
          '-ResultsDir', $resultsDir,
          '-InvokeScriptPath', $stubPath,
          '-FailOnDiff'
        )
        $null = pwsh $failArgs
        $LASTEXITCODE | Should -Be 1
      }
      finally {
        Remove-Item Env:STUB_COMPARE_RENAME_REPORT -ErrorAction SilentlyContinue
        Remove-Item Env:STUB_COMPARE_EXITCODE -ErrorAction SilentlyContinue
        Remove-Item Env:STUB_COMPARE_DIFF -ErrorAction SilentlyContinue
    }
  }
}

  Context 'step summary reporting' {
    BeforeAll {
      $stubTemplate = @'
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$OutputDir,
  [string[]]$Flags
)
$ErrorActionPreference = 'Stop'
if (-not $OutputDir) { $OutputDir = Join-Path $env:TEMP ([guid]::NewGuid().ToString()) }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$exitCodeValue = 0
if ($env:STUB_COMPARE_EXITCODE) {
  $parsed = 0
  if ([int]::TryParse($env:STUB_COMPARE_EXITCODE, [ref]$parsed)) {
    $exitCodeValue = $parsed
  }
}

function Get-StubBool([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $false }
  switch -Regex ($value.ToLowerInvariant()) {
    '^(1|true|yes|on)$' { return $true }
    default { return $false }
  }
}

$diffFlag = Get-StubBool $env:STUB_COMPARE_DIFF

$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$exitPath   = Join-Path $OutputDir 'lvcompare-exitcode.txt'
$reportPath = Join-Path $OutputDir 'compare-report.html'
$cliReport  = Join-Path $OutputDir 'cli-report.html'
$capPath    = Join-Path $OutputDir 'lvcompare-capture.json'

"Stub compare for $BaseVi -> $HeadVi (flags: $($Flags -join ' '))" | Out-File -LiteralPath $stdoutPath -Encoding utf8
'' | Out-File -LiteralPath $stderrPath -Encoding utf8
$exitCodeValue.ToString() | Out-File -LiteralPath $exitPath -Encoding utf8
'<html><body><h1>Stub Report</h1></body></html>' | Out-File -LiteralPath $reportPath -Encoding utf8

if (Test-Path -LiteralPath $cliReport) { Remove-Item -LiteralPath $cliReport -Force }
Copy-Item -LiteralPath $reportPath -Destination $cliReport -Force

$summaryPath = Join-Path $OutputDir 'summary.json'
$summary = [ordered]@{
  schema = 'compare-cli-summary/v1'
  cli    = [ordered]@{
    exitCode    = $exitCodeValue
    diff        = $diffFlag
    duration_s  = 0.05
    command     = 'stub'
  }
  out = [ordered]@{
    reportPath = $reportPath
  }
}
$summary | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $summaryPath -Encoding utf8

$cap = [ordered]@{
  schema   = 'lvcompare-capture-v1'
  exitCode = $exitCodeValue
  seconds  = 0.05
  command  = 'stub'
  cliPath  = 'stub'
  base     = $BaseVi
  head     = $HeadVi
  diff     = $diffFlag
  args     = $Flags
  cli      = $summary.cli
}
$cap | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $capPath -Encoding utf8
'@
      $scriptPath = Join-Path (Get-Location).Path 'tools' 'Compare-VIHistory.ps1'
      $script:SummaryStubPath = Join-Path $TestDrive 'Invoke-LVCompare.summary.ps1'
      Set-Content -LiteralPath $script:SummaryStubPath -Value $stubTemplate -Encoding utf8

      function Invoke-HistorySummary {
        param(
          [string]$ResultsDir,
          [string]$SummaryPath,
          [string[]]$ExtraArgs
        )
        $baseArgs = @(
          '-NoLogo','-NoProfile',
          '-File', $scriptPath,
          '-ViName','VI1.vi',
          '-Branch','HEAD',
          '-MaxPairs','1',
          '-ResultsDir', $ResultsDir,
          '-InvokeScriptPath', $script:SummaryStubPath,
          '-StepSummaryPath', $SummaryPath,
          '-Quiet'
        )
        if ($ExtraArgs) { $baseArgs += $ExtraArgs }
        $proc = Start-Process -FilePath 'pwsh' -ArgumentList $baseArgs -Wait -PassThru -WindowStyle Hidden
        return $proc.ExitCode
      }
    }

    It 'writes a table to the step summary when provided' {
      $resultsDir = Join-Path $TestDrive 'summary-no-diff'
      $summaryPath = Join-Path $TestDrive 'step-summary-no-diff.md'
      $exit = Invoke-HistorySummary -ResultsDir $resultsDir -SummaryPath $summaryPath -ExtraArgs @()
      $exit | Should -Be 0

      Test-Path -LiteralPath $summaryPath -PathType Leaf | Should -BeTrue
      $content = Get-Content -LiteralPath $summaryPath -Raw
      $content | Should -Match '\| Mode \| Processed \| Diffs \| Missing \| Last Diff \| Manifest \|'
      $content | Should -Not -Match '#### Mode:'
    }

    It 'notes diff artifacts in the summary when diffs are present' {
      $resultsDir = Join-Path $TestDrive 'summary-diff'
      $summaryPath = Join-Path $TestDrive 'step-summary-diff.md'
      $env:STUB_COMPARE_EXITCODE = '1'
      $env:STUB_COMPARE_DIFF = '1'
      try {
        $exit = Invoke-HistorySummary -ResultsDir $resultsDir -SummaryPath $summaryPath -ExtraArgs @()
        $exit | Should -Be 0

        $content = Get-Content -LiteralPath $summaryPath -Raw
        $content | Should -Match 'Diff artifacts are available under the `vi-compare-diff-artifacts` upload\.'
        $content | Should -Match '\| default \|'
      }
      finally {
        Remove-Item Env:STUB_COMPARE_EXITCODE -ErrorAction SilentlyContinue
        Remove-Item Env:STUB_COMPARE_DIFF -ErrorAction SilentlyContinue
      }
    }
  }
}
