# Requires -Version 5.1
# Additional tests focusing on input/output validation without executing any external CLI

BeforeAll {
  $here = Split-Path -Parent $PSCommandPath
  $root = Resolve-Path (Join-Path $here '..')
  . (Join-Path $root 'scripts' 'CompareVI.ps1')
  # Enable test bypass so Resolve-Cli does not require real binary presence
  $script:_origBypass = $env:LVCOMPARE_TEST_BYPASS
  $env:LVCOMPARE_TEST_BYPASS = '1'
}

AfterAll {
  if ($null -ne $script:_origBypass) { $env:LVCOMPARE_TEST_BYPASS = $script:_origBypass } else { Remove-Item Env:LVCOMPARE_TEST_BYPASS -ErrorAction SilentlyContinue }
}

Describe 'Invoke-CompareVI input and output validation (no CLI)' {
  BeforeEach {
    # Use Pester's native TestDrive
    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'a.vi'
    $b = Join-Path $vis 'b.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    New-Item -ItemType File -Path $b -Force | Out-Null

    # Always mock Resolve-Cli to avoid any dependency on real installations
    # Return the canonical path
    $canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    Mock -CommandName Resolve-Cli -MockWith { $canonical } -Verifiable

    $script:a = $a; $script:b = $b; $script:vis = $vis; $script:canonical = $canonical
  }

  It 'validates required inputs and file existence' {
    { Invoke-CompareVI -Base '' -Head $a -Executor { 0 } } | Should -Throw
    { Invoke-CompareVI -Base $a -Head '' -Executor { 0 } } | Should -Throw
    { Invoke-CompareVI -Base 'missing.vi' -Head $a -Executor { 0 } } | Should -Throw
    { Invoke-CompareVI -Base $a -Head 'missing.vi' -Executor { 0 } } | Should -Throw
  }

  It 'resolves relative paths from working-directory' {
    $res = Invoke-CompareVI -Base 'a.vi' -Head 'b.vi' -WorkingDirectory $vis -Executor { 0 }
    # Compare canonical absolute paths to avoid 8.3 short path vs long path differences
    [System.IO.Path]::GetFullPath($res.Base) | Should -Be ([System.IO.Path]::GetFullPath($a))
    [System.IO.Path]::GetFullPath($res.Head) | Should -Be ([System.IO.Path]::GetFullPath($b))
  }

  It 'throws when working-directory does not exist' {
    { Invoke-CompareVI -Base $a -Head $b -WorkingDirectory (Join-Path $TestDrive 'missing-dir') -Executor { 0 } } | Should -Throw
  }

  It 'parses quoted lvCompareArgs and includes them in the reconstructed command' {
    $exec = { param($cli,$base,$head,$arr) return 0 }
    $res = Invoke-CompareVI -Base $a -Head $b -LvCompareArgs '--flag "C:\\Temp\\Spaced Path\\x"' -Executor $exec
    # Validate command contains the flag and the quoted path (robust match)
    $res.Command | Should -Match '--flag\s+"C:.*Spaced Path.*x"'
  }

  It 'supports multiple lvCompareArgs including appended values with spaces' {
    $exec = { param($cli,$base,$head,$arr) return 0 }
    $argLine = '--a 1 --b "two words" --c'
    $res = Invoke-CompareVI -Base $a -Head $b -LvCompareArgs $argLine -Executor $exec
    $res.Command | Should -Match '--a\s+1'
    $res.Command | Should -Match '--b\s+"two words"'
    $res.Command | Should -Match '--c(\s|$)'
  }

  It 'writes outputs and summary for exit code 0 (diff=false)' {
    $out = Join-Path $TestDrive 'out.txt'
    $sum = Join-Path $TestDrive 'sum.md'
    $res = Invoke-CompareVI -Base $a -Head $a -GitHubOutputPath $out -GitHubStepSummaryPath $sum -Executor { 0 }
    $res.Diff | Should -BeFalse
    $res.CompareDurationSeconds | Should -BeGreaterOrEqual 0
    $res.CompareDurationNanoseconds | Should -BeGreaterOrEqual 0
    (Get-Content $out -Raw) | Should -Match 'exitCode=0'
    (Get-Content $out -Raw) | Should -Match 'diff=false'
    (Get-Content $out -Raw) | Should -Match 'compareDurationSeconds='
    (Get-Content $out -Raw) | Should -Match 'compareDurationNanoseconds='
    (Get-Content $sum -Raw) | Should -Match 'Diff: false'
    # Escape parentheses in regex
    (Get-Content $sum -Raw) | Should -Match 'Duration \(s\):'
    (Get-Content $sum -Raw) | Should -Match 'Duration \(ns\):'
  }

  It 'does not throw when fail-on-diff is false and exit code is 1 (diff=true)' {
    $out = Join-Path $TestDrive 'out.txt'
    $res = Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $out -FailOnDiff:$false -Executor { 1 }
    $res.Diff | Should -BeTrue
    $res.CompareDurationSeconds | Should -BeGreaterOrEqual 0
    $res.CompareDurationNanoseconds | Should -BeGreaterOrEqual 0
    (Get-Content $out -Raw) | Should -Match 'exitCode=1'
    (Get-Content $out -Raw) | Should -Match 'diff=true'
    (Get-Content $out -Raw) | Should -Match 'compareDurationSeconds='
    (Get-Content $out -Raw) | Should -Match 'compareDurationNanoseconds='
  }

  It 'writes outputs then throws for unknown exit code (diff=false)' {
    $out = Join-Path $TestDrive 'out.txt'
    $sum = Join-Path $TestDrive 'sum.md'
    { Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $out -GitHubStepSummaryPath $sum -Executor { 2 } } | Should -Throw
    (Get-Content $out -Raw) | Should -Match 'exitCode=2'
    (Get-Content $out -Raw) | Should -Match 'diff=false'
    (Get-Content $sum -Raw) | Should -Match 'Exit code: 2'
  }

  It 'throws when fail-on-diff is true with exit code 1, but writes outputs' {
    $out = Join-Path $TestDrive 'out.txt'
    { Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $out -FailOnDiff:$true -Executor { 1 } } | Should -Throw
    (Get-Content $out -Raw) | Should -Match 'exitCode=1'
    (Get-Content $out -Raw) | Should -Match 'diff=true'
  }

  It 'uses mocked Resolve-Cli value in result' {
    $res = Invoke-CompareVI -Base $a -Head $b -Executor { 0 }
    $res.CliPath | Should -Be $canonical
  }

  It 'quotes base/head when working-directory path contains spaces' {
    $exec = { param($cli,$base,$head,$arr) return 0 }
    $spacedDir = Join-Path $TestDrive 'space dir'
    New-Item -ItemType Directory -Path $spacedDir -Force | Out-Null
    Copy-Item -LiteralPath $a -Destination (Join-Path $spacedDir 'a.vi') -Force
    Copy-Item -LiteralPath $b -Destination (Join-Path $spacedDir 'b.vi') -Force
    $res = Invoke-CompareVI -Base 'a.vi' -Head 'b.vi' -WorkingDirectory $spacedDir -Executor $exec
    $baseAbs = [System.IO.Path]::GetFullPath((Join-Path $spacedDir 'a.vi'))
    $headAbs = [System.IO.Path]::GetFullPath((Join-Path $spacedDir 'b.vi'))
    $res.Command | Should -Match ('"' + [regex]::Escape($baseAbs) + '"')
    $res.Command | Should -Match ('"' + [regex]::Escape($headAbs) + '"')
  }
}
