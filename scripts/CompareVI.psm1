Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared tokenization pattern
Import-Module (Join-Path $PSScriptRoot 'ArgTokenization.psm1') -Force

function Resolve-Cli {
  param(
    [string]$Explicit
  )
  $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'

  if ($Explicit) {
    $resolved = try { (Resolve-Path -LiteralPath $Explicit -ErrorAction Stop).Path } catch { $Explicit }
    if ($resolved -ieq $canonical) {
      if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) { throw "LVCompare.exe not found at canonical path: $canonical" }
      return $canonical
    } else { throw "Only the canonical LVCompare path is supported: $canonical" }
  }

  if ($env:LVCOMPARE_PATH) {
    $resolvedEnv = try { (Resolve-Path -LiteralPath $env:LVCOMPARE_PATH -ErrorAction Stop).Path } catch { $env:LVCOMPARE_PATH }
    if ($resolvedEnv -ieq $canonical) {
      if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) { throw "LVCompare.exe not found at canonical path: $canonical" }
      return $canonical
    } else { throw "Only the canonical LVCompare path is supported via LVCOMPARE_PATH: $canonical" }
  }

  if (Test-Path -LiteralPath $canonical -PathType Leaf) { return $canonical }
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
    if ($s -match '^[A-Za-z]:/') { return ($s -replace '/', '\\') }
    if ($s -match '^//') { return ($s -replace '/', '\\') }
    return $s
  }
  foreach ($t in $tokens) {
    if ($null -eq $t) { continue }
    $tok = $t.Trim()
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
    if ($tok.StartsWith('-') -and $tok -match '\\s+') {
      $idx = $tok.IndexOf(' ')
      if ($idx -gt 0) {
        $flag = $tok.Substring(0,$idx)
        $val = $tok.Substring($idx+1)
        if ($flag) { $out += $flag }
        if ($val) { $out += (Normalize-PathToken $val) }
        continue
      }
    }
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
    [switch] $PreviewArgs,
    [string] $CompareExecJsonPath
  )

  $pushed = $false
  if ($WorkingDirectory) {
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) { throw "working-directory not found: $WorkingDirectory" }
    Push-Location -LiteralPath $WorkingDirectory; $pushed = $true
  }
  $lvBefore = @(); try { $lvBefore = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}

  try {
    if ([string]::IsNullOrWhiteSpace($Base)) { throw "Input 'base' is required and cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($Head)) { throw "Input 'head' is required and cannot be empty" }
    if (-not (Test-Path -LiteralPath $Base)) { throw "Base VI not found: $Base" }
    if (-not (Test-Path -LiteralPath $Head)) { throw "Head VI not found: $Head" }

    $baseAbs = (Resolve-Path -LiteralPath $Base).Path
    $headAbs = (Resolve-Path -LiteralPath $Head).Path
    $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
    $cliCandidate = $canonical

    $baseLeaf = Split-Path -Leaf $baseAbs
    $headLeaf = Split-Path -Leaf $headAbs
    if ($baseLeaf -ieq $headLeaf -and $baseAbs -ne $headAbs) { throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$baseAbs Head=$headAbs" }

    $cli = if ($LvComparePath) { (Resolve-Cli -Explicit $LvComparePath) } else { (Resolve-Cli) }
    $cliArgs = @()
    if ($LvCompareArgs) {
      $raw = $LvCompareArgs
      $tokens = @()
      if ($raw -is [System.Array]) { $tokens = @($raw | ForEach-Object { [string]$_ }) } else { $tokens = [string]$raw }
      $cliArgs = Convert-ArgTokenList -tokens (Get-LVCompareArgTokens -Spec $tokens)
    }
    # Hint: if LABVIEW_EXE is provided and -lvpath is not present, inject it to prefer the existing LabVIEW instance
    try {
      if ($env:LABVIEW_EXE -and -not ($cliArgs | Where-Object { $_ -ieq '-lvpath' })) {
        $cliArgs = @('-lvpath', [string]$env:LABVIEW_EXE) + $cliArgs
      }
    } catch {}

    $cmdline = (Quote $cli) + ' ' + (Quote $baseAbs) + ' ' + (Quote $headAbs)
    if ($cliArgs -and $cliArgs.Count -gt 0) { $cmdline += ' ' + (($cliArgs | ForEach-Object { Quote $_ }) -join ' ') }
    if ($PreviewArgs) { return $cmdline }

    $cwd = (Get-Location).Path
    if ($Executor) {
      $code = & $Executor $cli $baseAbs $headAbs ,$cliArgs
      $compareDurationSeconds = 0
      $compareDurationNanoseconds = 0
    } else {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $code = $null
    if ($env:LV_SUPPRESS_UI -eq '1') {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cli
        $null = $psi.ArgumentList.Clear()
        $null = $psi.ArgumentList.Add($baseAbs)
        $null = $psi.ArgumentList.Add($headAbs)
        foreach ($a in $cliArgs) { if ($a) { $null = $psi.ArgumentList.Add([string]$a) } }
        $psi.UseShellExecute = $false
        try { $psi.CreateNoWindow = $true } catch {}
        try { $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden } catch {}
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        $code = [int]$proc.ExitCode
      } else {
        & $cli $baseAbs $headAbs @cliArgs
        $code = if (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) { $LASTEXITCODE } else { 0 }
      }
      $sw.Stop()
      $compareDurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)
      $compareDurationNanoseconds = [long]([double]$sw.ElapsedTicks * (1e9 / [double][System.Diagnostics.Stopwatch]::Frequency))
    }

    $diff = $false
    if ($code -eq 1) { $diff = $true }
    elseif ($code -ne 0) { throw "Compare CLI failed with exit code $code" }

    if ($GitHubOutputPath) {
      "exitCode=$code" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "cliPath=$cli"   | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "command=$cmdline" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      $diffLower = if ($diff) { 'true' } else { 'false' }
      "diff=$diffLower" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "shortCircuitedIdentical=false" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "compareDurationSeconds=$compareDurationSeconds" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "compareDurationNanoseconds=$compareDurationNanoseconds" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
    }

    if ($CompareExecJsonPath) {
      try {
        $exec = [pscustomobject]@{
          schema       = 'compare-exec/v1'
          generatedAt  = (Get-Date).ToString('o')
          cliPath      = $cli
          command      = $cmdline
          exitCode     = $code
          diff         = $diff
          cwd          = $cwd
          duration_s   = $compareDurationSeconds
          duration_ns  = $compareDurationNanoseconds
          base         = $baseAbs
          head         = $headAbs
        }
        $dir = Split-Path -Parent $CompareExecJsonPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $exec | ConvertTo-Json -Depth 6 | Out-File -FilePath $CompareExecJsonPath -Encoding utf8 -ErrorAction Stop
      } catch { Write-Host "[comparevi] warn: failed to write exec json: $_" -ForegroundColor DarkYellow }
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
        "- Duration (s): $compareDurationSeconds",
        "- Duration (ns): $compareDurationNanoseconds"
      )
      ($summaryLines -join "`n") | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
    }

    [pscustomobject]@{
      Base                         = $baseAbs
      Head                         = $headAbs
      Cwd                          = $cwd
      CliPath                      = $cli
      Command                      = $cmdline
      ExitCode                     = $code
      Diff                         = $diff
      CompareDurationSeconds       = $compareDurationSeconds
      CompareDurationNanoseconds   = $compareDurationNanoseconds
      ShortCircuitedIdenticalPath  = $false
    }
  }
  finally {
    # Policy: do not close LabVIEW by default. Allow opt-in via ENABLE_LABVIEW_CLEANUP=1.
    $allowCleanup = ($env:ENABLE_LABVIEW_CLEANUP -match '^(?i:1|true|yes|on)$')
    if ($allowCleanup) {
      try {
        $deadline = (Get-Date).AddSeconds(10)
        do {
          $closedAny = $false
          $lvAfter = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
          if ($lvAfter) {
            $beforeSet = @{}
            foreach ($id in $lvBefore) { $beforeSet[[string]$id] = $true }
            $newOnes = @(); foreach ($p in $lvAfter) { if (-not $beforeSet.ContainsKey([string]$p.Id)) { $newOnes += $p } }
            foreach ($proc in $newOnes) {
              try {
                $null = $proc.CloseMainWindow(); Start-Sleep -Milliseconds 500
                if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
                $closedAny = $true
              } catch {}
            }
          }
          if (-not $closedAny) { break }
          Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
      } catch {}
    }
    if ($pushed) { Pop-Location }
  }
}

Export-ModuleMember -Function Invoke-CompareVI

