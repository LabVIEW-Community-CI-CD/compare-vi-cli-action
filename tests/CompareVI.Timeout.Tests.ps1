# Requires -Version 5.1

BeforeAll {
  $here = Split-Path -Parent $PSCommandPath
  $root = Resolve-Path (Join-Path $here '..')
  $script:CompareModule = Import-Module (Join-Path $root 'scripts' 'CompareVI.psm1') -Force -PassThru
}

Describe 'Wait-LVCompareProcess timeout guard' -Tag 'CompareVI','Unit' {
  It 'returns deterministic timeout exit code and terminates a hung process' {
    $result = InModuleScope $script:CompareModule.Name {
      $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $pwshPath
      $null = $psi.ArgumentList.Add('-NoLogo')
      $null = $psi.ArgumentList.Add('-NoProfile')
      $null = $psi.ArgumentList.Add('-Command')
      $null = $psi.ArgumentList.Add('Start-Sleep -Seconds 15')
      $psi.UseShellExecute = $false

      $process = [System.Diagnostics.Process]::Start($psi)
      try {
        $wait = Wait-LVCompareProcess -Process $process -TimeoutSeconds 1
        Start-Sleep -Milliseconds 250
        [pscustomobject]@{
          timedOut = [bool]$wait.TimedOut
          exitCode = [int]$wait.ExitCode
          hasExited = [bool]$process.HasExited
        }
      } finally {
        if ($process -and -not $process.HasExited) {
          try { $process.Kill($true) } catch {
            try { $process.Kill() } catch {}
          }
        }
      }
    }

    $result.timedOut | Should -BeTrue
    $result.exitCode | Should -Be 124
    $result.hasExited | Should -BeTrue
  }

  It 'preserves the child exit code when the process exits before the timeout' {
    $result = InModuleScope $script:CompareModule.Name {
      $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $pwshPath
      $null = $psi.ArgumentList.Add('-NoLogo')
      $null = $psi.ArgumentList.Add('-NoProfile')
      $null = $psi.ArgumentList.Add('-Command')
      $null = $psi.ArgumentList.Add('Start-Sleep -Milliseconds 200; exit 7')
      $psi.UseShellExecute = $false

      $process = [System.Diagnostics.Process]::Start($psi)
      try {
        $wait = Wait-LVCompareProcess -Process $process -TimeoutSeconds 5
        [pscustomobject]@{
          timedOut = [bool]$wait.TimedOut
          exitCode = [int]$wait.ExitCode
        }
      } finally {
        if ($process -and -not $process.HasExited) {
          try { $process.Kill($true) } catch {
            try { $process.Kill() } catch {}
          }
        }
      }
    }

    $result.timedOut | Should -BeFalse
    $result.exitCode | Should -Be 7
  }
}
