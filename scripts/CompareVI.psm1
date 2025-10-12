Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared tokenization pattern
Import-Module (Join-Path $PSScriptRoot 'ArgTokenization.psm1') -Force

# Native helpers for idle and window activation control
if (-not ([System.Management.Automation.PSTypeName]'User32').Type) {
  Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
public static class User32 {
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
}
"@
}

function Get-UserIdleSeconds {
  try {
    $lii = New-Object LASTINPUTINFO
    $lii.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($lii)
    [void][User32]::GetLastInputInfo([ref]$lii)
    $tickCount = [Environment]::TickCount
    $idleMs = [uint32]($tickCount - $lii.dwTime)
    return [int]([math]::Round($idleMs/1000.0))
  } catch { return 0 }
}

function Get-CursorPos { try { $pt = New-Object POINT; [void][User32]::GetCursorPos([ref]$pt); return $pt } catch { $null } }
function Set-CursorPosXY([int]$x,[int]$y) { try { [void][User32]::SetCursorPos($x,$y) } catch {} }

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
  if (-not $tokens) { return $out }

  function Normalize-PathToken([string]$s) {
    if ($null -eq $s) { return $s }
    if ($s -match '^[A-Za-z]:/') { return ($s -replace '/', '\') }
    if ($s -match '^//') { return ($s -replace '/', '\') }
    return $s
  }

  function Ensure-UNCLeading([string]$s) {
    if ($null -eq $s) { return $s }
    $bs = [char]92
    if ($s.Length -gt 0 -and $s[0] -eq $bs) {
      $count = 0
      while ($count -lt $s.Length -and $s[$count] -eq $bs) { $count++ }
      if ($count -lt 4) {
        $needed = 4 - $count
        $prefix = [string]::new($bs, $needed)
        return ($prefix + $s)
      }
    }
    return $s
  }

  $currentFlagIndex = -1
  $currentValueIndex = -1

  for ($i = 0; $i -lt $tokens.Count; $i++) {
    $tok = $tokens[$i]
    if ($null -eq $tok) { continue }
    $tok = $tok.Trim()
    if (-not $tok) { continue }

    if ($tok.StartsWith('-') -and $tok.Contains('=')) {
      $eq = $tok.IndexOf('=')
      if ($eq -gt 0) {
        $flag = $tok.Substring(0, $eq)
        $val  = $tok.Substring($eq + 1)
        if ($val.StartsWith('"') -and $val.EndsWith('"')) { $val = $val.Substring(1, $val.Length - 2) }
        elseif ($val.StartsWith("'") -and $val.EndsWith("'")) { $val = $val.Substring(1, $val.Length - 2) }

        $segments = @()
        if ($val) { $segments += $val }
        while (($i + 1) -lt $tokens.Count) {
          $peek = $tokens[$i + 1]
          if ($null -eq $peek) { break }
          $peekTrim = $peek.Trim()
          if (-not $peekTrim) { $i++; continue }
          if ($peekTrim.StartsWith('-')) { break }
          $segments += $peekTrim
          $i++
        }

        if ($flag) { $out += $flag }
        if ($segments.Count -gt 0) {
          $joined = ($segments -join ' ')
          $out += (Ensure-UNCLeading (Normalize-PathToken $joined))
        }
        $currentFlagIndex = -1
        $currentValueIndex = -1
        continue
      }
    }

    if ($tok.StartsWith('-') -and $tok -match '\s+') {
      $idx = $tok.IndexOf(' ')
      if ($idx -gt 0) {
        $flag = $tok.Substring(0, $idx)
        $val  = $tok.Substring($idx + 1)
        if ($flag) { $out += $flag }
        if ($val) {
          $segments = @($val)
          while (($i + 1) -lt $tokens.Count) {
            $peek = $tokens[$i + 1]
            if ($null -eq $peek) { break }
            $peekTrim = $peek.Trim()
            if (-not $peekTrim) { $i++; continue }
            if ($peekTrim.StartsWith('-')) { break }
            $segments += $peekTrim
            $i++
          }
          $joined = ($segments -join ' ')
          $out += (Ensure-UNCLeading (Normalize-PathToken $joined))
        }
        $currentFlagIndex = -1
        $currentValueIndex = -1
        continue
      }
    }

    if ($tok.StartsWith('-')) {
      $out += $tok
      $currentFlagIndex = $out.Count - 1
      $currentValueIndex = -1
      continue
    }

    $normalizedToken = Normalize-PathToken $tok
    if ($currentFlagIndex -ge 0) {
      if ($currentValueIndex -ge 0) {
        $merged = ($out[$currentValueIndex] + ' ' + $normalizedToken).Trim()
        $out[$currentValueIndex] = Ensure-UNCLeading $merged
      } else {
        $out += (Ensure-UNCLeading $normalizedToken)
        $currentValueIndex = $out.Count - 1
      }
    } else {
      $out += (Ensure-UNCLeading $normalizedToken)
    }
  }

  return $out
}

function Resolve-LabVIEWCliPath {
  [CmdletBinding()]
  param([string]$Explicit)

  $candidates = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
  if ($Explicit) { [void]$candidates.Add($Explicit) }
  if ($env:LABVIEW_CLI_PATH) { [void]$candidates.Add($env:LABVIEW_CLI_PATH) }

  $defaultRoots = @()
  if ($env:ProgramFiles) { $defaultRoots += (Join-Path $env:ProgramFiles 'National Instruments') }
  if ($env:ProgramFiles(x86)) { $defaultRoots += (Join-Path $env:ProgramFiles(x86) 'National Instruments') }

  foreach ($root in $defaultRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    try {
      $labviewDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'LabVIEW*' -or $_.Name -like 'LabVIEW CLI*' }
      foreach ($dir in $labviewDirs) {
        $candidatePath = Join-Path $dir.FullName 'LabVIEWCLI.exe'
        [void]$candidates.Add($candidatePath)
      }
    } catch {}
    $sharedCli = Join-Path $root 'LabVIEW CLI\LabVIEWCLI.exe'
    [void]$candidates.Add($sharedCli)
  }

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      try { return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { return $candidate }
    }
  }

  throw 'LabVIEW CLI executable not found. Set LABVIEW_CLI_PATH to the LabVIEWCLI.exe path.'
}

function Get-LabVIEWCLIReportExtension {
  param([string]$Format)
  $fmt = if ($Format) { $Format.ToUpperInvariant() } else { 'XML' }
  switch ($fmt) {
    'XML' { '.xml' }
    'HTML' { '.html' }
    'HTM' { '.htm' }
    'WORD' { '.docx' }
    'DOC' { '.doc' }
    'DOCX' { '.docx' }
    'TXT' { '.txt' }
    'TEXT' { '.txt' }
    default { '.xml' }
  }
}

function Test-LabVIEWCLIReportDiff {
  param([string]$Path,[string]$Format)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ Diff = $null; Reason = 'missing' } }
  $fmt = if ($Format) { $Format.ToUpperInvariant() } else { 'XML' }
  if ($fmt -eq 'XML') {
    try {
      $xml = [xml](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
      $diffNodes = $null
      if ($xml) {
        $diffNodes = $xml.SelectNodes('//*[contains(translate(name(),"ABCDEFGHIJKLMNOPQRSTUVWXYZ","abcdefghijklmnopqrstuvwxyz"),"difference")]')
      }
      if ($diffNodes -and $diffNodes.Count -gt 0) { return @{ Diff = $true } }
      return @{ Diff = $false }
    } catch {
      return @{ Diff = $null; Reason = 'xml_parse_error'; Message = $_.Exception.Message }
    }
  }
  try {
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($text -match '(?i)no differences') { return @{ Diff = $false } }
    if ($text -match '(?i)difference') { return @{ Diff = $true } }
    return @{ Diff = $null; Reason = 'undetermined' }
  } catch {
    return @{ Diff = $null; Reason = 'read_error'; Message = $_.Exception.Message }
  }
}

function Invoke-CompareVIUsingLabVIEWCLI {
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

  if ($env:LVCI_COMPARE_MODE -and [string]::Equals($env:LVCI_COMPARE_MODE, 'labview-cli', [System.StringComparison]::OrdinalIgnoreCase)) {
    return Invoke-CompareVIUsingLabVIEWCLI @PSBoundParameters
  }
  if ($env:LVCI_GCLI_MODE -and (
        [string]::Equals($env:LVCI_GCLI_MODE, 'compare', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($env:LVCI_GCLI_MODE, 'on', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($env:LVCI_GCLI_MODE, 'g-cli', [System.StringComparison]::OrdinalIgnoreCase)
      )) {
    return Invoke-CompareVIUsingGCLI @PSBoundParameters
  }

  $pushed = $false
  if ($WorkingDirectory) {
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) { throw "working-directory not found: $WorkingDirectory" }
    Push-Location -LiteralPath $WorkingDirectory; $pushed = $true
  }

  try {
    if ([string]::IsNullOrWhiteSpace($Base)) { throw "Input 'base' is required and cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($Head)) { throw "Input 'head' is required and cannot be empty" }
    if (-not (Test-Path -LiteralPath $Base -PathType Any)) { throw "Base path not found: $Base" }
    if (-not (Test-Path -LiteralPath $Head -PathType Any)) { throw "Head path not found: $Head" }

    $baseItem = Get-Item -LiteralPath $Base -ErrorAction Stop
    $headItem = Get-Item -LiteralPath $Head -ErrorAction Stop
    if ($baseItem.PSIsContainer) { throw "Base path refers to a directory, expected a VI file: $($baseItem.FullName)" }
    if ($headItem.PSIsContainer) { throw "Head path refers to a directory, expected a VI file: $($headItem.FullName)" }

    $baseAbs = (Resolve-Path -LiteralPath $baseItem.FullName).Path
    $headAbs = (Resolve-Path -LiteralPath $headItem.FullName).Path

    $cliPath = Resolve-LabVIEWCliPath -Explicit $null

    $format = if ($env:LVCI_CLI_FORMAT) { $env:LVCI_CLI_FORMAT } else { 'XML' }
    $reportExt = Get-LabVIEWCLIReportExtension $format
    $resultsDir = Join-Path (Get-Location) 'tests/results/compare-cli'
    if (-not (Test-Path -LiteralPath $resultsDir)) { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null }
    $reportPath = Join-Path $resultsDir ('comparison-report' + $reportExt)

    $argsBuilder = New-Object System.Collections.Generic.List[string]
    [void]$argsBuilder.Add('CreateComparisonReport')
    [void]$argsBuilder.Add('--base')
    [void]$argsBuilder.Add($baseAbs)
    [void]$argsBuilder.Add('--head')
    [void]$argsBuilder.Add($headAbs)
    [void]$argsBuilder.Add('--format')
    [void]$argsBuilder.Add($format.ToUpperInvariant())
    [void]$argsBuilder.Add('--output')
    [void]$argsBuilder.Add($reportPath)

    if ($env:LVCI_CLI_EXTRA_ARGS) {
      foreach ($extra in (Get-LVCompareArgTokens -Spec $env:LVCI_CLI_EXTRA_ARGS)) {
        if (-not [string]::IsNullOrWhiteSpace($extra)) { [void]$argsBuilder.Add($extra) }
      }
    }

    $commandArgs = $argsBuilder.ToArray()
    $commandLine = ($commandArgs | ForEach-Object { Quote $_ }) -join ' '

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cliPath
    foreach ($arg in $commandArgs) { $psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()

    $timeoutSeconds = 120
    if ($env:LVCI_CLI_TIMEOUT_SECONDS) {
      $parsed = 0
      if ([int]::TryParse($env:LVCI_CLI_TIMEOUT_SECONDS, [ref]$parsed) -and $parsed -gt 0) { $timeoutSeconds = $parsed }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $proc.WaitForExit($timeoutSeconds * 1000)) {
      try { $proc.Kill() } catch {}
      throw "LabVIEW CLI compare timed out after $timeoutSeconds seconds."
    }
    $sw.Stop()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $exitCode = $proc.ExitCode
    $durationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 6)
    $durationNanoseconds = [long]([math]::Round($sw.Elapsed.Ticks * (1e9 / [double][System.Diagnostics.Stopwatch]::Frequency)))

    $diff = $null
    if ($exitCode -eq 0) { $diff = $false }
    elseif ($exitCode -eq 1) { $diff = $true }

    $reportEval = Test-LabVIEWCLIReportDiff -Path $reportPath -Format $format
    if ($reportEval.Diff -ne $null) { $diff = $reportEval.Diff }

    $diffUnknown = $false
    if ($diff -eq $null) { $diffUnknown = $true; $diff = $false }

    $pendingError = $null
    if ($exitCode -ge 2) { $pendingError = "LabVIEW CLI compare failed with exit code $exitCode" }
    if ($FailOnDiff -and $diff) { $pendingError = "LabVIEW CLI comparison reported differences (exit code $exitCode)" }
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { $pendingError = $pendingError ?? "LabVIEW CLI did not produce a report at $reportPath" }

    if ($GitHubOutputPath) {
      "exitCode=$exitCode" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "cliPath=$cliPath"   | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "command=$commandLine" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      $diffValue = if ($diffUnknown) { 'unknown' } elseif ($diff) { 'true' } else { 'false' }
      "diff=$diffValue" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "diffUnknown=$diffUnknown" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "shortCircuitedIdentical=false" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "compareDurationSeconds=$durationSeconds" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      "compareDurationNanoseconds=$durationNanoseconds" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
      if (Test-Path -LiteralPath $reportPath) { "reportPath=$reportPath" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8 }
    }

    if ($CompareExecJsonPath) {
      try {
        $exec = [pscustomobject]@{
          schema       = 'compare-exec/v1'
          generatedAt  = (Get-Date).ToString('o')
          mode         = 'labview-cli'
          cliPath      = $cliPath
          command      = $commandLine
          args         = @($commandArgs)
          exitCode     = $exitCode
          diff         = $diff
          diffUnknown  = $diffUnknown
          cwd          = (Get-Location).Path
          duration_s   = $durationSeconds
          duration_ns  = $durationNanoseconds
          base         = $baseAbs
          head         = $headAbs
          reportPath   = (Test-Path -LiteralPath $reportPath) ? (Resolve-Path -LiteralPath $reportPath).Path : $reportPath
          stdout       = $stdout
          stderr       = $stderr
        }
        $dir = Split-Path -Parent $CompareExecJsonPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $exec | ConvertTo-Json -Depth 6 | Out-File -FilePath $CompareExecJsonPath -Encoding utf8
      } catch { Write-Host "[comparevi] warn: failed to write CLI exec json: $_" -ForegroundColor DarkYellow }
    }

    if ($GitHubStepSummaryPath) {
      $diffSummary = if ($diffUnknown) { 'unknown' } elseif ($diff) { 'true' } else { 'false' }
      $summary = @(
        '### Compare VI (LabVIEW CLI)',
        "- Working directory: $((Get-Location).Path)",
        "- Base: $baseAbs",
        "- Head: $headAbs",
        "- CLI: $cliPath",
        "- Command: $commandLine",
        "- Exit code: $exitCode",
        "- Diff: $diffSummary",
        "- Duration (s): $durationSeconds"
      )
      if (Test-Path -LiteralPath $reportPath) { $summary += "- Report: $reportPath" } else { $summary += "- Report: (missing) $reportPath" }
      if ($reportEval.Reason) { $summary += "- Note: $($reportEval.Reason)" }
      $summary -join "`n" | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
    }

    if ($pendingError) { throw $pendingError }

    [pscustomobject]@{
      Base                         = $baseAbs
      Head                         = $headAbs
      Cwd                          = (Get-Location).Path
      CliPath                      = $cliPath
      Command                      = $commandLine
      ExitCode                     = $exitCode
      Diff                         = $diff
      CompareDurationSeconds       = $durationSeconds
      CompareDurationNanoseconds   = $durationNanoseconds
      ShortCircuitedIdenticalPath  = $false
      ReportPath                   = $reportPath
      Mode                         = 'labview-cli'
      DiffUnknown                  = $diffUnknown
    }
  }
  finally {
    if ($pushed) { Pop-Location }
  }
}

function Resolve-GCliPath {
  [CmdletBinding()]
  param([string]$Explicit)
  if ($Explicit) {
    if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return (Resolve-Path -LiteralPath $Explicit).Path }
  }
  if ($env:GCLI_PATH -and (Test-Path -LiteralPath $env:GCLI_PATH -PathType Leaf)) { return (Resolve-Path -LiteralPath $env:GCLI_PATH).Path }
  $cmds = @('g-cli','gcli','g-cli.exe','gcli.exe')
  foreach ($c in $cmds) {
    $gc = Get-Command $c -ErrorAction SilentlyContinue
    if ($gc -and $gc.Source) { return $gc.Source }
  }
  throw 'g-cli executable not found. Set GCLI_PATH or install g-cli in PATH.'
}

function Invoke-CompareVIUsingGCLI {
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
  try {
    if (-not (Test-Path -LiteralPath $Base -PathType Leaf)) { throw "Base path not found: $Base" }
    if (-not (Test-Path -LiteralPath $Head -PathType Leaf)) { throw "Head path not found: $Head" }

    $baseAbs = (Resolve-Path -LiteralPath $Base).Path
    $headAbs = (Resolve-Path -LiteralPath $Head).Path

    $gcli = Resolve-GCliPath -Explicit $null
    # Minimal implementation: probe version and fail with clear message until compare contract is finalized
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $gcli
    $psi.ArgumentList.Add('--version')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $null = $proc.WaitForExit(15000)
    $ver = $proc.StandardOutput.ReadToEnd().Trim()

    $message = 'g-cli compare path scaffolded; implement command wiring once contract is finalized.'
    if ($GitHubStepSummaryPath) {
      $lines = @(
        '### Compare VI (g-cli, scaffold)',
        "- g-cli: $gcli",
        if ($ver) { "- Version: $ver" },
        "- Base: $baseAbs",
        "- Head: $headAbs",
        "- Status: not-implemented"
      ) | Where-Object { $_ }
      $lines -join "`n" | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
    }

    throw $message
  }
  finally {
    if ($pushed) { Pop-Location }
  }
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
  $lvcomparePid = $null

  try {
    if ([string]::IsNullOrWhiteSpace($Base)) { throw "Input 'base' is required and cannot be empty" }
    if ([string]::IsNullOrWhiteSpace($Head)) { throw "Input 'head' is required and cannot be empty" }
    if (-not (Test-Path -LiteralPath $Base -PathType Any)) { throw "Base path not found: $Base" }
    if (-not (Test-Path -LiteralPath $Head -PathType Any)) { throw "Head path not found: $Head" }

    $baseItem = Get-Item -LiteralPath $Base -ErrorAction Stop
    $headItem = Get-Item -LiteralPath $Head -ErrorAction Stop
    if ($baseItem.PSIsContainer) { throw "Base path refers to a directory, expected a VI file: $($baseItem.FullName)" }
    if ($headItem.PSIsContainer) { throw "Head path refers to a directory, expected a VI file: $($headItem.FullName)" }

    $baseAbs = (Resolve-Path -LiteralPath $baseItem.FullName).Path
    $headAbs = (Resolve-Path -LiteralPath $headItem.FullName).Path
    $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
    $cliCandidate = $canonical

    $baseLeaf = Split-Path -Leaf $baseAbs
    $headLeaf = Split-Path -Leaf $headAbs
    if ($baseLeaf -ieq $headLeaf -and $baseAbs -ne $headAbs) { throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$baseAbs Head=$headAbs" }

    # Resolve LVCompare path. In preview mode, bypass file existence checks to allow unit tests
    if ($PreviewArgs) {
      $cli = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
    } else {
      $cli = if ($LvComparePath) { (Resolve-Cli -Explicit $LvComparePath) } else { (Resolve-Cli) }
    }
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

    # Validate LVCompare args early to prevent UI popups and provide clear errors
    $allowedFlags = @('-lvpath','-noattr','-nofp','-nofppos','-nobd','-nobdcosm','-nobdpos')
    $argsArr = @($cliArgs)
    if ($argsArr -and $argsArr.Count -gt 0) {
      for ($i = 0; $i -lt $argsArr.Count; $i++) {
        $tok = [string]$argsArr[$i]
        if (-not $tok) { continue }
        if ($tok.StartsWith('-')) {
          if ($tok -ieq '-lvpath') {
            if ($i -ge $argsArr.Count - 1) { throw "Invalid LVCompare args: -lvpath requires a following path value" }
            $next = [string]$argsArr[$i+1]
            if (-not $next -or $next.StartsWith('-')) { throw "Invalid LVCompare args: -lvpath must be followed by a path value" }
            $i++
            continue
          }
          if (-not ($allowedFlags -icontains $tok)) {
            throw "Invalid LVCompare flag: '$tok'. Allowed: $($allowedFlags -join ', ')"
          }
        }
      }
    }

    $cmdline = (Quote $cli) + ' ' + (Quote $baseAbs) + ' ' + (Quote $headAbs)
    if ($argsArr -and $argsArr.Count -gt 0) { $cmdline += ' ' + (($argsArr | ForEach-Object { Quote $_ }) -join ' ') }
    if ($PreviewArgs) { return $cmdline }

    $cwd = (Get-Location).Path
    # Notice helper
    function Write-LVNotice([hashtable]$h) {
      try {
        $dir = if ($env:LV_NOTICE_DIR) { $env:LV_NOTICE_DIR } else { Join-Path 'tests/results' '_lvcompare_notice' }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmssffff')
        $file = Join-Path $dir ("notice-" + $ts + ".json")
        ($h | ConvertTo-Json -Depth 6) | Out-File -FilePath $file -Encoding utf8
      } catch {}
    }

    if ($Executor) {
      $code = & $Executor $cli $baseAbs $headAbs ,$cliArgs
      $compareDurationSeconds = 0
      $compareDurationNanoseconds = 0
    } else {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $code = $null
      # Optional: wait for user idle before launching LVCompare to avoid mouse/focus disruption
      $idleWait = 0
      if ($env:LV_IDLE_WAIT_SECONDS -match '^[0-9]+$') { $idleWait = [int]$env:LV_IDLE_WAIT_SECONDS }
      if ($idleWait -gt 0) {
        $maxWait = 30; if ($env:LV_IDLE_MAX_WAIT_SECONDS -match '^[0-9]+$') { $maxWait = [int]$env:LV_IDLE_MAX_WAIT_SECONDS }
        $deadline = (Get-Date).AddSeconds($maxWait)
        while ((Get-Date) -lt $deadline) {
          if ((Get-UserIdleSeconds) -ge $idleWait) { break }
          Start-Sleep -Milliseconds 250
        }
      }
      $origCursor = $null; if ($env:LV_CURSOR_RESTORE -match '^(?i:1|true|yes|on)$') { $origCursor = Get-CursorPos }
      $noActivate = ($env:LV_NO_ACTIVATE -match '^(?i:1|true|yes|on)$')
      # Emit pre-launch notice
      $notice = @{ schema='lvcompare-notice/v1'; when=(Get-Date).ToString('o'); phase='pre-launch'; cli=$cli; base=$baseAbs; head=$headAbs; args=$cliArgs; cwd=$cwd; path=$cli }
      if ($CompareExecJsonPath) { $notice.execJsonPath = $CompareExecJsonPath }
      Write-Host ("[lvcompare-notice] Launching LVCompare: base='{0}' head='{1}' args='{2}'" -f $baseAbs,$headAbs,($cliArgs -join ' '))
      Write-LVNotice $notice

      if ($env:LV_SUPPRESS_UI -eq '1') {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cli
        $null = $psi.ArgumentList.Clear()
        $null = $psi.ArgumentList.Add($baseAbs)
        $null = $psi.ArgumentList.Add($headAbs)
        foreach ($a in $cliArgs) { if ($a) { $null = $psi.ArgumentList.Add([string]$a) } }
        $psi.UseShellExecute = $false
        try { $psi.CreateNoWindow = $true } catch {}
        try { $psi.WindowStyle = ($noActivate ? [System.Diagnostics.ProcessWindowStyle]::Minimized : [System.Diagnostics.ProcessWindowStyle]::Hidden) } catch {}
        $proc = [System.Diagnostics.Process]::Start($psi)
        $lvcomparePid = $proc.Id
        # Post-start notice with PID
        try {
          $n = @{ schema='lvcompare-notice/v1'; when=(Get-Date).ToString('o'); phase='post-start'; pid=$proc.Id; cli=$cli; base=$baseAbs; head=$headAbs; args=$cliArgs; cwd=$cwd; path=$cli }
          if ($CompareExecJsonPath) { $n.execJsonPath = $CompareExecJsonPath }
          Write-Host ("[lvcompare-notice] Started LVCompare PID={0}" -f $proc.Id)
          Write-LVNotice $n
        } catch {}
        if ($noActivate) {
          try {
            $null = $proc.WaitForInputIdle(5000)
            for ($i=0; $i -lt 20 -and $proc -and -not $proc.HasExited; $i++) {
              if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { [void][User32]::ShowWindowAsync($proc.MainWindowHandle, 7); break }
              Start-Sleep -Milliseconds 200; $proc.Refresh()
            }
          } catch {}
        }
        if ($origCursor -ne $null) { try { Set-CursorPosXY $origCursor.X $origCursor.Y } catch {} }
        $proc.WaitForExit()
        $code = [int]$proc.ExitCode
      } else {
        & $cli $baseAbs $headAbs @cliArgs
        $code = if (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) { $LASTEXITCODE } else { 0 }
        # We do not have PID in this path; record completion
        try {
          $n = @{ schema='lvcompare-notice/v1'; when=(Get-Date).ToString('o'); phase='completed'; exitCode=$code; cli=$cli; base=$baseAbs; head=$headAbs; args=$cliArgs; cwd=$cwd; path=$cli }
          if ($CompareExecJsonPath) { $n.execJsonPath = $CompareExecJsonPath }
          Write-Host ("[lvcompare-notice] Completed LVCompare with exitCode={0}" -f $code)
          Write-LVNotice $n
        } catch {}
      }
      $sw.Stop()
      $compareDurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 3)
      $compareDurationNanoseconds = [long]([double]$sw.ElapsedTicks * (1e9 / [double][System.Diagnostics.Stopwatch]::Frequency))
    }

    $diff = $false
    $pendingErrorMessage = $null
    if ($code -eq 1) {
      $diff = $true
      if ($FailOnDiff) { $pendingErrorMessage = "Compare CLI reported differences (exit code $code)" }
    } elseif ($code -ne 0) {
      $pendingErrorMessage = "Compare CLI failed with exit code $code"
    }

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
          args         = @($argsArr)
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

    if ($pendingErrorMessage) { throw $pendingErrorMessage }

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
    # Emit post-complete LabVIEW PID tracking notice
    try {
      $lvAfter = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
      $beforeSet = @{}
      foreach ($id in $lvBefore) { $beforeSet[[string]$id] = $true }
      $newLV = @(); foreach ($p in $lvAfter) { if (-not $beforeSet.ContainsKey([string]$p.Id)) { $newLV += [int]$p.Id } }
      $noticeComplete = @{ schema='lvcompare-notice/v1'; when=(Get-Date).ToString('o'); phase='post-complete'; labviewPids=$newLV; path=$cli }
      if ($lvcomparePid) { $noticeComplete.lvcomparePid = [int]$lvcomparePid }
      Write-LVNotice $noticeComplete
    } catch {}
    # Policy: do not close LabVIEW by default. Allow opt-in via ENABLE_LABVIEW_CLEANUP=1.
    $allowCleanup = ($env:ENABLE_LABVIEW_CLEANUP -match '^(?i:1|true|yes|on)$')
    if ($allowCleanup) {
      try {
        $deadline = (Get-Date).AddSeconds(90)
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
