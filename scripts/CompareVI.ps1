set-strictmode -version latest
$ErrorActionPreference = 'Stop'

function Resolve-Cli {
  param(
    [string]$Explicit
  )
  $canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'

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

  # Default to canonical
  if (Test-Path -LiteralPath $canonical -PathType Leaf) {
    return $canonical
  }

  throw "LVCompare.exe not found. Install at: $canonical"
}

function Quote($s) {
  if ($null -eq $s) { return '""' }
  if ($s -match '\s|"') { return '"' + ($s -replace '"','\"') + '"' } else { return $s }
}

function Convert-ArgTokenList([string[]]$tokens) {
  $out = @()
  function Normalize-PathToken([string]$s) {
    if ($null -eq $s) { return $s }
    # Convert Windows-style forward slashes to backslashes for drive-letter and UNC forms
    if ($s -match '^[A-Za-z]:/') { return ($s.Replace('/', [IO.Path]::DirectorySeparatorChar)) }
    if ($s -match '^//') { return ($s.Replace('/', [IO.Path]::DirectorySeparatorChar)) }
    return $s
  }
  foreach ($t in $tokens) {
    if ($null -eq $t) { continue }
    $tok = $t.Trim()
    # Handle -flag=value (strip quotes from value)
    if ($tok.StartsWith('-') -and $tok.Contains('=')) {
      $eq = $tok.IndexOf('=')
      if ($eq -gt 0) {
        $flag = $tok.Substring(0,$eq)
        $val = $tok.Substring($eq+1)
        if ($val.StartsWith('"') -and $val.EndsWith('"')) { $val = $val.Substring(1,$val.Length-2) }
        elseif ($val.StartsWith("'") -and $val.EndsWith("'")) { $val = $val.Substring(1,$val.Length-2) }
        if ($flag) { $out += $flag }
        if ($val) { $out += (Normalize-PathToken $val) }
        continue
      }
    }
    # Handle combined "-flag value" provided as a single token (e.g., quoted as one string in YAML)
    if ($tok.StartsWith('-') -and $tok -match '\s+') {
      $idx = $tok.IndexOf(' ')
      if ($idx -gt 0) {
        $flag = $tok.Substring(0,$idx)
        $val = $tok.Substring($idx+1)
        if ($flag) { $out += $flag }
        if ($val) { $out += (Normalize-PathToken $val) }
        continue
      }
    }
    # If token looks like a value (not a flag), normalize path slashes
    if (-not $tok.StartsWith('-')) { $tok = Normalize-PathToken $tok }
    $out += $tok
  }
  return $out
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
    [ScriptBlock] $Executor,
    [switch] $PreviewArgs
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

  # Determine candidate CLI path string (avoid validating if preview-only)
  $canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  $cliCandidate = $canonical

    # Preflight: same leaf filename but different paths – LVCompare raises an IDE dialog; stop early with actionable error
    $baseLeaf = Split-Path -Leaf $baseAbs
    $headLeaf = Split-Path -Leaf $headAbs
    if ($baseLeaf -ieq $headLeaf -and $baseAbs -ne $headAbs) {
      throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$baseAbs Head=$headAbs"
    }

    $cliArgs = @()
    if ($LvCompareArgs) {
      # Tokenize by comma and/or whitespace while respecting quotes
      $pattern = '"[^\"]+"|''[^'']+''|[^,\s]+'
      $tokens = [regex]::Matches($LvCompareArgs, $pattern) | ForEach-Object { $_.Value }
      foreach ($t in $tokens) {
        $tok = $t.Trim()
        if ($tok.StartsWith('"') -and $tok.EndsWith('"')) { $tok = $tok.Substring(1, $tok.Length-2) }
        elseif ($tok.StartsWith("'") -and $tok.EndsWith("'")) { $tok = $tok.Substring(1, $tok.Length-2) }
        if ($tok) { $cliArgs += $tok }
      }
      # Normalize combined flag/value tokens
      $cliArgs = Convert-ArgTokenList -tokens $cliArgs
    }

  # For preview, we show the canonical path string (no existence check needed)
  $cmdline = (@(Quote $cliCandidate; Quote $baseAbs; Quote $headAbs) + ($cliArgs | ForEach-Object { Quote $_ })) -join ' '

    # Preview mode: print tokens/command and skip CLI invocation
    if ($PreviewArgs -or $env:LV_PREVIEW -eq '1') {
      if ($GitHubOutputPath) {
        "cliPath=$cliCandidate"     | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "command=$cmdline" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
        "previewArgs=true" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      }
      if (-not $PSBoundParameters.ContainsKey('Quiet') -and -not $env:GITHUB_ACTIONS) {
        Write-Host 'Preview (no CLI invocation):' -ForegroundColor Cyan
        Write-Host "  CLI:     $cliCandidate" -ForegroundColor Gray
        Write-Host "  Base:    $baseAbs" -ForegroundColor Gray
        Write-Host "  Head:    $headAbs" -ForegroundColor Gray
        Write-Host ("  Tokens:  {0}" -f (($cliArgs) -join ' | ')) -ForegroundColor Gray
        Write-Host ("  Command: {0}" -f $cmdline) -ForegroundColor Gray
      }
      return [pscustomobject]@{
        Base                       = $baseAbs
        Head                       = $headAbs
        CliPath                    = $cliCandidate
        Command                    = $cmdline
        ExitCode                   = 0
        Diff                       = $false
        CompareDurationSeconds     = 0
        CompareDurationNanoseconds = 0
        PreviewArgs                = $true
      }
    }

    # Resolve CLI only when actually executing
    $cli = Resolve-Cli -Explicit $LvComparePath

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
