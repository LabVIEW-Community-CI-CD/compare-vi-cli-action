set-strictmode -version latest
$ErrorActionPreference = 'Stop'

function Resolve-Cli {
  param(
    [string]$Explicit
  )
  $canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  $expectedLabVIEW64 = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'

  $testBypass = $false
  if ($env:LVCOMPARE_TEST_BYPASS -match '^(1|true)$') { $testBypass = $true }

  # If explicit path provided, enforce canonical path only
  if ($Explicit) {
    $resolved = try { (Resolve-Path -LiteralPath $Explicit -ErrorAction Stop).Path } catch { $Explicit }
    if ($resolved -ieq $canonical) {
      if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
        throw "LVCompare.exe not found at canonical path: $canonical"
      }
      return $canonical
    } else {
      throw "Only the canonical LVCompare path is supported: $canonical"
    }
  }

  # If environment variable provided, enforce canonical
  if ($env:LVCOMPARE_PATH) {
    $resolvedEnv = try { (Resolve-Path -LiteralPath $env:LVCOMPARE_PATH -ErrorAction Stop).Path } catch { $env:LVCOMPARE_PATH }
    if ($resolvedEnv -ieq $canonical) {
      if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
        throw "LVCompare.exe not found at canonical path: $canonical"
      }
      return $canonical
    } else {
      throw "Only the canonical LVCompare path is supported via LVCOMPARE_PATH: $canonical"
    }
  }

  # Test bypass: allow early return without verifying file existence or bitness when LVCOMPARE_TEST_BYPASS is set.
  # This supports unit tests that mock Resolve-Cli or do not rely on the actual binary being present.
  if ($testBypass) {
    return $canonical
  }

  # Default to canonical
  if (Test-Path -LiteralPath $canonical -PathType Leaf) {
    # Bitness guard: ensure the canonical LVCompare is 64-bit to avoid modal VI load collisions seen with 32-bit driver on 64-bit LabVIEW installs
    $allow32 = $false
    if ($env:LVCOMPARE_ALLOW_32BIT -match '^(1|true)$') { $allow32 = $true }
    if (-not $allow32 -and -not $testBypass) {
      try {
        $fs = [System.IO.File]::Open($canonical,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        try {
          $br = New-Object System.IO.BinaryReader($fs)
          $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
          $peOffset = $br.ReadInt32()
          $fs.Seek($peOffset + 4, [System.IO.SeekOrigin]::Begin) | Out-Null # skip 'PE\0\0' + Machine field start
          $machineBytes = $br.ReadUInt16()
          # 0x8664 = AMD64, 0x014C = I386
          if ($machineBytes -eq 0x014C) {
            throw "Detected 32-bit LVCompare.exe at canonical path but environment requires 64-bit. Ensure only the 64-bit LabVIEW Compare is installed. Expected associated LabVIEW executable at: $expectedLabVIEW64"
          }
        } finally { try { $fs.Close() } catch {}; try { $fs.Dispose() } catch {} }
      } catch {
        if (-not ($_.Exception.Message -like 'Detected 32-bit*')) {
          throw "Failed to validate LVCompare bitness: $($._Exception.Message)"
        } else { throw }
      }
    }
    return $canonical
  }

  throw "LVCompare.exe not found. Install at: $canonical"
}

function Quote($s) {
  if ($null -eq $s) { return '""' }
  if ($s -match '\s|"') { return '"' + ($s -replace '"','\"') + '"' } else { return $s }
}

function Invoke-CompareVI {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $Base,
    [Parameter(Mandatory)] [string] $Head,
    [string] $LvComparePath,
    [string] $LvCompareArgs = '',
    [string] $WorkingDirectory = '',
    [bool] $FailOnDiff = $true,
    [string] $GitHubOutputPath,
    [string] $GitHubStepSummaryPath,
    [ScriptBlock] $Executor
  )

  $pushed = $false
  if ($WorkingDirectory) {
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) { throw "working-directory not found: $WorkingDirectory" }
    Push-Location -LiteralPath $WorkingDirectory
    $pushed = $true
  }
  try {
    if ([string]::IsNullOrWhiteSpace($Base)) { throw "Input 'base' is required and cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($Head)) { throw "Input 'head' is required and cannot be empty" }
    if (-not (Test-Path -LiteralPath $Base)) { throw "Base VI not found: $Base" }
    if (-not (Test-Path -LiteralPath $Head)) { throw "Head VI not found: $Head" }

    $baseAbs = (Resolve-Path -LiteralPath $Base).Path
    $headAbs = (Resolve-Path -LiteralPath $Head).Path

    # Migration warning (naming): Prefer VI1.vi / VI2.vi over legacy Base.vi / Head.vi
    try {
      $baseLeafNow = Split-Path -Leaf $baseAbs
      $headLeafNow = Split-Path -Leaf $headAbs
      $legacyNames = @('Base.vi','Head.vi')
      $preferredNames = @('VI1.vi','VI2.vi')
      $usingLegacy = ($legacyNames -contains $baseLeafNow) -or ($legacyNames -contains $headLeafNow)
      # Emit only if at least one legacy and not both already preferred (avoid noise) and environment not explicitly bypassing
      if ($usingLegacy -and -not (($preferredNames -contains $baseLeafNow) -and ($preferredNames -contains $headLeafNow))) {
        Write-Host "[NamingMigrationWarning] Detected legacy VI naming ('$baseLeafNow','${headLeafNow}') – preferred names are VI1.vi / VI2.vi. Legacy names will be removed in a future minor release (planned v0.5.0). Update your workflow inputs and artifacts. See README migration note." -ForegroundColor Yellow
      }
    } catch { Write-Verbose "Naming migration warning suppressed: $($_.Exception.Message)" }

    $cli = Resolve-Cli -Explicit $LvComparePath

    # Preflight: same leaf filename but different paths – LVCompare raises an IDE dialog; stop early with actionable error
    $baseLeaf = Split-Path -Leaf $baseAbs
    $headLeaf = Split-Path -Leaf $headAbs
    if ($baseLeaf -ieq $headLeaf -and $baseAbs -ne $headAbs) {
      throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$baseAbs Head=$headAbs"
    }

    $cliArgs = @()
    if ($LvCompareArgs) {
      $pattern = '"[^"]+"|\S+'
      $tokens = [regex]::Matches($LvCompareArgs, $pattern) | ForEach-Object { $_.Value }
      foreach ($t in $tokens) { $cliArgs += $t.Trim('"') }
    }

    $cmdline = (@(Quote $cli; Quote $baseAbs; Quote $headAbs) + ($cliArgs | ForEach-Object { Quote $_ })) -join ' '

    # Relocated identical-path short-circuit (after args/tokenization so command reflects flags)
    if ($baseAbs -eq $headAbs) {
      $cwd = (Get-Location).Path
      $code = 0
      $diff = $false
      $compareDurationSeconds = 0
      $compareDurationNanoseconds = 0
      if ($GitHubOutputPath) {
        "exitCode=$code"   | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "cliPath=$cli"     | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "command=$cmdline" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "diff=false"       | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "compareDurationSeconds=$compareDurationSeconds" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "compareDurationNanoseconds=$compareDurationNanoseconds" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "shortCircuitedIdentical=true" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      }
      if ($GitHubStepSummaryPath) {
        $summaryLines = @(
          '### Compare VI',
          "- Working directory: $cwd",
          "- Base: $baseAbs",
          "- Head: $headAbs",
          "- CLI: $cli",
          "- Command: $cmdline",
          "- Exit code: $code",
          "- Diff: false",
          "- Duration (s): $compareDurationSeconds",
          "- Duration (ns): $compareDurationNanoseconds",
          '- Note: Short-circuited identical path comparison (no LVCompare invocation)'
        )
        ($summaryLines -join "`n") | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
      }
      return [pscustomobject]@{
        Base                        = $baseAbs
        Head                        = $headAbs
        Cwd                         = $cwd
        CliPath                     = $cli
        Command                     = $cmdline
        ExitCode                    = $code
        Diff                        = $diff
        CompareDurationSeconds      = $compareDurationSeconds
        CompareDurationNanoseconds  = $compareDurationNanoseconds
        ShortCircuitedIdenticalPath = $true
      }
    }

    # Measure execution time
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Execute via injected executor for tests, or call CLI directly
    $code = $null
    if ($Executor) {
      # Pass args as a single array to avoid unrolling
      $code = & $Executor $cli $baseAbs $headAbs ,$cliArgs
    }
    else {
      & $cli $baseAbs $headAbs @cliArgs
      # Capture exit code (use 0 as fallback if LASTEXITCODE not yet set in session)
      $code = if (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) { $LASTEXITCODE } else { 0 }
    }
  $sw.Stop()
  $compareDurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)
  # High resolution nanosecond precision (Stopwatch ticks * (1e9 / Frequency))
  $compareDurationNanoseconds = [long]([double]$sw.ElapsedTicks * (1e9 / [double][System.Diagnostics.Stopwatch]::Frequency))

    $cwd = (Get-Location).Path

    $diff = $false
    if ($code -eq 1) { $diff = $true }
    elseif ($code -eq 0) { $diff = $false }
    else {
      if ($GitHubOutputPath) {
        "exitCode=$code"   | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "cliPath=$cli"     | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "command=$cmdline" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "diff=false"       | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      }
      if ($GitHubStepSummaryPath) {
        $summaryLines = @(
          '### Compare VI',
          "- Working directory: $cwd",
          "- Base: $baseAbs",
          "- Head: $headAbs",
          "- CLI: $cli",
          "- Command: $cmdline",
          "- Exit code: $code",
          "- Diff: false"
        )
        ($summaryLines -join "`n") | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
      }
      throw "Compare CLI failed with exit code $code"
    }

    if ($GitHubOutputPath) {
      "exitCode=$code"        | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "cliPath=$cli"          | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "command=$cmdline"      | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      $diffLower = if ($diff) { 'true' } else { 'false' }
  "diff=$diffLower"       | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "shortCircuitedIdentical=false" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "compareDurationSeconds=$compareDurationSeconds" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "compareDurationNanoseconds=$compareDurationNanoseconds" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
    }

    if ($GitHubStepSummaryPath) {
      $diffStr = if ($diff) { 'true' } else { 'false' }
      $summaryLines = @(
        '### Compare VI',
        "- Working directory: $cwd",
        "- Base: $baseAbs",
        "- Head: $headAbs",
        "- CLI: $cli",
        "- Command: $cmdline",
        "- Exit code: $code",
        "- Diff: $diffStr",
  "- Duration (s): $compareDurationSeconds"
  "- Duration (ns): $compareDurationNanoseconds"
      )
      ($summaryLines -join "`n") | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
    }

    if ($diff -and $FailOnDiff) {
      throw 'Differences detected and fail-on-diff=true'
    }

    [pscustomobject]@{
      Base                   = $baseAbs
      Head                   = $headAbs
      Cwd                    = $cwd
      CliPath                = $cli
      Command                = $cmdline
      ExitCode               = $code
      Diff                   = $diff
      CompareDurationSeconds     = $compareDurationSeconds
      CompareDurationNanoseconds = $compareDurationNanoseconds
      # Always include this flag for downstream consumers (action.yml) to avoid property-missing errors
      ShortCircuitedIdenticalPath = $false
    }
  }
  finally {
    if ($pushed) { Pop-Location }
  }
}
