Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PwshExePath {
  try {
    $cmd = Get-Command -Name 'pwsh' -ErrorAction Stop
    if ($cmd -and $cmd.Source) {
      return $cmd.Source
    }
  } catch {
    return $null
  }

  return $null
}

function Get-PwshProcessIds {
  try { return @((Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)) } catch { return @() }
}

function Stop-NewPwshProcesses {
  param(
    [int[]]$Baseline,
    [datetime]$NotBefore
  )
  try {
    $current = @(Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue)
    foreach ($p in $current) {
      if ($Baseline -and ($Baseline -contains $p.Id)) { continue }
      if ($NotBefore -and $p.StartTime -lt $NotBefore) { continue }
      try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
  } catch {}
}

function Invoke-DispatcherSafe {
  <#
  .SYNOPSIS
    Launches Invoke-PesterTests.ps1 as a child PowerShell process with safe defaults.
  .PARAMETER DispatcherPath
    Full path to Invoke-PesterTests.ps1
  .PARAMETER ResultsPath
    Results directory or file path argument to pass to dispatcher.
  .PARAMETER IncludePatterns
    Pester IncludePatterns string to limit discovery.
  .PARAMETER TimeoutSeconds
    Max seconds to allow child to run before forced kill.
  .PARAMETER AdditionalArgs
    Extra arguments passed through to the dispatcher.
  .PARAMETER TestsPath
    Tests root passed to the dispatcher (defaults to the repository tests directory).
  .OUTPUTS
    PSCustomObject with ExitCode, TimedOut, StdOut, StdErr
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$DispatcherPath,
    [Parameter(Mandatory)][string]$ResultsPath,
    [string]$IncludePatterns,
    [int]$TimeoutSeconds = 30,
    [string[]]$AdditionalArgs,
    [string]$TestsPath = 'tests'
  )

  $pwsh = Get-PwshExePath
  if (-not $pwsh) {
    throw 'pwsh executable not found on PATH; dispatcher cannot run.'
  }

  $args = @('-NoLogo','-NoProfile','-File', $DispatcherPath, '-TestsPath', $TestsPath, '-ResultsPath', $ResultsPath)
  if ($IncludePatterns) { $args += @('-IncludePatterns', $IncludePatterns) }
  if ($AdditionalArgs -and $AdditionalArgs.Count -gt 0) { $args += $AdditionalArgs }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $pwsh
  foreach ($a in $args) { $psi.ArgumentList.Add($a) }
  $psi.WorkingDirectory = (Resolve-Path '.').Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  # Minimize child work to avoid extra processes
  $psi.EnvironmentVariables['DISABLE_STEP_SUMMARY'] = '1'
  $psi.EnvironmentVariables['LOCAL_DISPATCHER']     = '1'
  $psi.EnvironmentVariables['SINGLE_INVOKER']       = '1'
  $psi.EnvironmentVariables['SUPPRESS_NESTED_DISCOVERY'] = '1'
  $psi.EnvironmentVariables['STUCK_GUARD']          = '0'
  $psi.EnvironmentVariables['DISABLE_SINGLE_INVOKER'] = '1'
  $psi.EnvironmentVariables['SUPPRESS_PATTERN_SELFTEST'] = '1'
  $psi.EnvironmentVariables['SUPPRESS_GUARD_SELFTEST'] = '1'

  $baseline  = Get-PwshProcessIds
  $startedAt = Get-Date

  $proc   = $null
  $stdout = ''
  $stderr = ''
  $timedOut = $false
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw 'Failed to start pwsh child process.' }

    # Read synchronously; bounded by TTL
    $waitMs = [math]::Max(1000, $TimeoutSeconds * 1000)
    if (-not $proc.WaitForExit($waitMs)) {
      $timedOut = $true
      try { $proc.Kill() } catch {}
      $null = $proc.WaitForExit(2000)
    }
    try { $stdout = $proc.StandardOutput.ReadToEnd() } catch {}
    try { $stderr = $proc.StandardError.ReadToEnd() } catch {}

    $code = if ($proc) { $proc.ExitCode } else { -1 }
    [pscustomobject]@{ ExitCode=$code; TimedOut=$timedOut; StdOut=$stdout; StdErr=$stderr }
  } finally {
    try { if ($proc) { $proc.Dispose() } } catch {}
    $childCleanupSucceeded = $false
    try {
      if ($proc -and $proc.Id) {
        # Snapshot all processes with parent linkage in one go
        $procs = @()
        try { $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) } catch { $procs = @() }
        if ($procs.Count -gt 0) {
          $childrenByParent = @{}
          foreach ($p in $procs) {
            $ppid = try { [int]$p.ParentProcessId } catch { -1 }
            if (-not $childrenByParent.ContainsKey($ppid)) { $childrenByParent[$ppid] = @() }
            $childrenByParent[$ppid] += $p
          }
          $stack = New-Object System.Collections.Generic.Stack[System.Int32]
          $visited = New-Object 'System.Collections.Generic.HashSet[int]'
          $stack.Push([int]$proc.Id) | Out-Null
          $killList = @()
          while ($stack.Count -gt 0) {
            $node = $stack.Pop()
            if (-not $visited.Add($node)) { continue }
            if ($childrenByParent.ContainsKey($node)) {
              foreach ($ch in $childrenByParent[$node]) {
                $stack.Push([int]$ch.ProcessId) | Out-Null
                # Only terminate PowerShell children to keep scope as tight as possible
                $name = try { [string]$ch.Name } catch { '' }
                if ($name -and ($name -ieq 'pwsh.exe' -or $name -ieq 'pwsh')) {
                  $killList += [int]$ch.ProcessId
                }
              }
            }
          }
          foreach ($pid in ($killList | Sort-Object -Unique)) {
            try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch {}
          }
          $childCleanupSucceeded = $true
        }
      }
    } catch {
      $childCleanupSucceeded = $false
    }

    if (-not $childCleanupSucceeded) {
      try { Stop-NewPwshProcesses -Baseline $baseline -NotBefore $startedAt } catch {}
    }
    # Do NOT blanket kill new pwsh processes anymore; we intentionally avoid the broad baseline sweep unless fallback executes.
  }
}

Export-ModuleMember -Function Get-PwshExePath, Invoke-DispatcherSafe
