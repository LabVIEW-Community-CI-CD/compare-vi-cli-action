Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import shared tokenization pattern
Import-Module (Join-Path $PSScriptRoot 'ArgTokenization.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'VendorTools.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'providers' 'ProviderRouter.psm1') -Force

# Allowed LVCompare flag definitions
$script:LVCompareNoValueFlags = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($flag in @('-noattr','-nofp','-nofppos','-nobd','-nobdcosm')) {
  [void]$script:LVCompareNoValueFlags.Add($flag)
}
$script:LVCompareNoValueFlags.Add('--c') | Out-Null
$script:LVCompareValueFlagRules = @{
  '-lvpath' = @{
    MissingMessage = 'Invalid LVCompare args: -lvpath requires a following path value'
    NextMessage    = 'Invalid LVCompare args: -lvpath must be followed by a path value'
  }
  '--log' = @{
    MissingMessage = 'Invalid LVCompare args: --log requires a following path value'
    NextMessage    = 'Invalid LVCompare args: --log must be followed by a path value'
  }
  '--a' = @{
    MissingMessage = 'Invalid LVCompare args: --a requires a following value'
    NextMessage    = 'Invalid LVCompare args: --a must be followed by a value'
  }
  '--b' = @{
    MissingMessage = 'Invalid LVCompare args: --b requires a following value'
    NextMessage    = 'Invalid LVCompare args: --b must be followed by a value'
  }
  '--flag' = @{
    MissingMessage = 'Invalid LVCompare args: --flag requires a following value'
    NextMessage    = 'Invalid LVCompare args: --flag must be followed by a value'
  }
}
$flagList = @()
foreach ($flag in $script:LVCompareNoValueFlags) { $flagList += $flag }
$flagList += $script:LVCompareValueFlagRules.Keys
$script:LVCompareAllowedFlagListText = ($flagList | Sort-Object -Unique) -join ', '

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

function Get-CanonicalCliCandidates {
  $primary = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  $secondary = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($primary) { $null = $candidates.Add($primary) }
  if ($secondary -and -not ($secondary -eq $primary)) { $null = $candidates.Add($secondary) }
  try {
    $resolved = Resolve-LVComparePath
    if ($resolved) {
      if (-not ($candidates | Where-Object { $_ -ieq $resolved })) {
        $null = $candidates.Insert(0, $resolved)
      }
    }
  } catch {}
  return @($candidates | Where-Object { $_ } | Select-Object -Unique)
}

function Resolve-Cli {
  param(
    [string]$Explicit
  )
  $candidates = Get-CanonicalCliCandidates

  function Normalize-Path([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }
    try { return (Resolve-Path -LiteralPath $PathValue -ErrorAction Stop).Path } catch { return $PathValue }
  }

  $formattedList = [string]::Join(', ', $candidates)

  if ($Explicit) {
    $resolvedExplicit = Normalize-Path $Explicit
    $match = $candidates | Where-Object { $_ -ieq $resolvedExplicit }
    if ($match) {
      $target = $match[0]
      if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "LVCompare.exe not found at canonical path: $target" }
      return $target
    }
    throw "Only canonical LVCompare path(s) are supported: $formattedList"
  }

  if ($env:LVCOMPARE_PATH) {
    $resolvedEnv = Normalize-Path $env:LVCOMPARE_PATH
    $matchEnv = $candidates | Where-Object { $_ -ieq $resolvedEnv }
    if ($matchEnv) {
      $targetEnv = $matchEnv[0]
      if (-not (Test-Path -LiteralPath $targetEnv -PathType Leaf)) { throw "LVCompare.exe not found at canonical path: $targetEnv" }
      return $targetEnv
    }
    throw "Only canonical LVCompare path(s) are supported via LVCOMPARE_PATH: $formattedList"
  }

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
  }

  throw "LVCompare.exe not found. Install at one of: $formattedList"
}


function Get-CompareVIPlan {
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [Parameter(Mandatory)][string]$HeadPath,
    [string[]]$Flags,
    [string]$ProviderId,
    [string]$LvComparePath
  )

  $parameters = @{
    vi1 = $BasePath
    vi2 = $HeadPath
  }

  if ($Flags -and $Flags.Count -gt 0) {
    $parameters['flags'] = @($Flags)
  }

  if ($LvComparePath) {
    $parameters['lvcomparePath'] = $LvComparePath
  }

  return Get-CompareVIProviderPlan -Operation 'CreateComparisonReport' -Provider $ProviderId -Parameters $parameters
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
    [string] $CompareExecJsonPath,
    [string] $CompareProvider
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

    if ($baseAbs -eq $headAbs) {
      $cwd = (Get-Location).Path
      $result = [pscustomobject]@{
        Base                       = $baseAbs
        Head                       = $headAbs
        Cwd                        = $cwd
        CliPath                    = $null
        Command                    = ''
        ExitCode                   = 0
        Diff                       = $false
        CompareDurationSeconds     = 0
        CompareDurationNanoseconds = 0
        ShortCircuitedIdenticalPath = $true
      }

      if ($GitHubOutputPath) {
        @(
          'exitCode=0'
          'cliPath='
          'command='
          'diff=false'
          'shortCircuitedIdentical=true'
          'compareDurationSeconds=0'
          'compareDurationNanoseconds=0'
        ) | ForEach-Object { $_ | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8 }
      }

      if ($GitHubStepSummaryPath) {
        $lines = @(
          '### Compare VI',
          "- Working directory: $cwd",
          "- Base: $baseAbs",
          "- Head: $headAbs",
          "- CLI: <short-circuited>",
          "- Command: (skipped; identical paths)",
          "- Exit code: 0",
          "- Diff: false",
          "- Duration (s): 0",
          "- Duration (ns): 0"
        )
        ($lines -join "`n") | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
      }

      return $result
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

    # Validate LVCompare flags and ensure required values are present
    $flagArgs = @($cliArgs)
    if ($flagArgs -and $flagArgs.Count -gt 0) {
      for ($i = 0; $i -lt $flagArgs.Count; $i++) {
        $tok = [string]$flagArgs[$i]
        if (-not $tok) { continue }
        # Ignore Pester-injected scaffolding tokens that can surface in ForEach name expansion
        if ($tok -match '^-_+Pester:') { continue }
        if ($tok.StartsWith('-')) {
          $flagKey = $tok.ToLowerInvariant()
          if ($script:LVCompareValueFlagRules.ContainsKey($flagKey)) {
            $rule = $script:LVCompareValueFlagRules[$flagKey]
            if ($i -ge $flagArgs.Count - 1) { throw $rule.MissingMessage }
            $next = [string]$flagArgs[$i + 1]
            if ($null -eq $next -or ([string]::IsNullOrWhiteSpace($next))) { throw $rule.MissingMessage }
            if ($next.StartsWith('-')) { throw $rule.NextMessage }
            $i++
            continue
          }
          if (-not $script:LVCompareNoValueFlags.Contains($flagKey)) {
            $message = "Invalid LVCompare flag '$tok'. Allowed flags: $script:LVCompareAllowedFlagListText"
            throw $message
          }
        }
      }
    }

    $argsArr = @()
    if ($PreviewArgs) {
      $cli = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
      $argsArr = @($baseAbs, $headAbs) + $flagArgs
      $cmdline = (Quote $cli)
      if ($argsArr -and $argsArr.Count -gt 0) {
        $cmdline += ' ' + (($argsArr | ForEach-Object { Quote $_ }) -join ' ')
      }
      return $cmdline
    }

    if ($Executor) {
      $cli = if ($LvComparePath) { (Resolve-Cli -Explicit $LvComparePath) } else { (Resolve-Cli) }
      $argsArr = @($baseAbs, $headAbs) + $flagArgs
      $cmdline = (Quote $cli)
      if ($argsArr -and $argsArr.Count -gt 0) {
        $cmdline += ' ' + (($argsArr | ForEach-Object { Quote $_ }) -join ' ')
      }
    } else {
      $resolvedCli = if ($LvComparePath) { (Resolve-Cli -Explicit $LvComparePath) } else { (Resolve-Cli) }
      $plan = Get-CompareVIPlan -BasePath $baseAbs -HeadPath $headAbs -Flags $flagArgs -ProviderId $CompareProvider -LvComparePath $resolvedCli
      $cli = $plan.binary
      $argsArr = @($plan.arguments)
      $cmdline = (Quote $cli)
      if ($argsArr -and $argsArr.Count -gt 0) {
        $cmdline += ' ' + (($argsArr | ForEach-Object { Quote $_ }) -join ' ')
      }
    }

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
      foreach ($a in $argsArr) {
        if ($null -ne $a) { $null = $psi.ArgumentList.Add([string]$a) }
      }
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
        & $cli @argsArr
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
          args         = @($cliArgs)
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

Export-ModuleMember -Function Get-CanonicalCliCandidates, Invoke-CompareVI, Resolve-Cli
