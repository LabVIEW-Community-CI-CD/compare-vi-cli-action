Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Variable -Name skipGuardSelfTest -Scope Script -Value $false -Force
Set-Variable -Name skipReason -Scope Script -Value 'Dispatcher guard self-test suppressed in nested dispatcher context' -Force

Describe 'Dispatcher results path guard (read-only directory)' -Tag 'Unit' {
  BeforeAll {
    if ($env:SUPPRESS_GUARD_SELFTEST -eq '1') {
      $script:skipGuardSelfTest = $true
      $script:skipReason = 'Dispatcher guard self-test suppressed in nested dispatcher context'
      return
    }

    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    $script:repoRoot = $root
    $script:dispatcherPath = Join-Path $root 'Invoke-PesterTests.ps1'
    Test-Path -LiteralPath $script:dispatcherPath | Should -BeTrue
    Import-Module (Join-Path $root 'tests' '_helpers' 'DispatcherTestHelper.psm1') -Force

    $script:pwshPath = Get-PwshExePath
    if ($script:pwshPath) {
      $script:pwshAvailable = $true
      $script:skipReason = $null
    } else {
      $script:pwshAvailable = $false
      $script:skipReason = 'pwsh executable not available on PATH'
    }
  }

  It 'fails and emits a guard crumb when ResultsPath is a read-only directory' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipGuardSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Dispatcher guard self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    if (-not $script:pwshAvailable) {
      Set-ItResult -Skipped -Because $script:skipReason
      return
    }

    $resultsDir = Join-Path $TestDrive 'blocked-dir'
    New-Item -ItemType Directory -Path $resultsDir | Out-Null
    # Make the directory non-writable for the current user using an explicit DENY ACL rule
    $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $resultsDir
    $denyRights = [System.Security.AccessControl.FileSystemRights]::Write,
                  [System.Security.AccessControl.FileSystemRights]::CreateFiles,
                  [System.Security.AccessControl.FileSystemRights]::CreateDirectories,
                  [System.Security.AccessControl.FileSystemRights]::AppendData,
                  [System.Security.AccessControl.FileSystemRights]::WriteData
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
               [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($who, $denyRights, $inherit, $prop, 'Deny')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $resultsDir -AclObject $acl

    $crumbPath = Join-Path $script:repoRoot 'tests/results/_diagnostics/guard.json'
    if (Test-Path -LiteralPath $crumbPath) { Remove-Item -LiteralPath $crumbPath -Force }

    try {
      $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcherPath -ResultsPath $resultsDir -IncludePatterns 'Invoke-PesterTests.ErrorHandling.*.ps1' -TimeoutSeconds 20
      $res.TimedOut | Should -BeFalse
      $res.ExitCode | Should -Not -Be 0

      $combined = ($res.StdOut + "`n" + $res.StdErr)
      $combined | Should -Match 'Results directory is not writable'

      Test-Path -LiteralPath $crumbPath | Should -BeTrue
      $crumb = Get-Content -LiteralPath $crumbPath -Raw | ConvertFrom-Json
      $crumb.path | Should -Be $resultsDir
      $pattern = [regex]::Escape($resultsDir)
      $crumb.message | Should -Match $pattern
    } finally {
      try {
        # Remove the explicit deny rule to restore write access
        $acl2 = Get-Acl -LiteralPath $resultsDir
        $acl2.RemoveAccessRule($rule) | Out-Null
        Set-Acl -LiteralPath $resultsDir -AclObject $acl2
      } catch {}
    }
  }
}
