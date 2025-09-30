# Requires -Version 5.1
# Additional tests focusing on input/output validation without executing any external CLI

BeforeAll {
  $here = Split-Path -Parent $PSCommandPath
  $root = Resolve-Path (Join-Path $here '..')
  . (Join-Path $root 'scripts' 'CompareVI.ps1')
}

Describe 'Invoke-CompareVI input and output validation (no CLI)' {
  BeforeEach {
    # Use Pester's TestDrive or create a temp directory that works cross-platform
    $tempBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
    $TestDrive = Join-Path $tempBase ("comparevi-io-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $TestDrive -Force | Out-Null

    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'a.vi'
    $b = Join-Path $vis 'b.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    New-Item -ItemType File -Path $b -Force | Out-Null

    # Always mock Resolve-Cli to avoid any dependency on real installations
    Mock -CommandName Resolve-Cli -MockWith { 'C:\fake\LVCompare.exe' } -Verifiable

    $script:a = $a; $script:b = $b; $script:vis = $vis; $script:td = $TestDrive
  }

  AfterEach {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $td
  }

  It 'validates required inputs and file existence' {
    { Invoke-CompareVI -Base '' -Head $a -Executor { 0 } } | Should -Throw
    { Invoke-CompareVI -Base $a -Head '' -Executor { 0 } } | Should -Throw
    { Invoke-CompareVI -Base 'missing.vi' -Head $a -Executor { 0 } } | Should -Throw
    { Invoke-CompareVI -Base $a -Head 'missing.vi' -Executor { 0 } } | Should -Throw
  }

  It 'resolves relative paths from working-directory' {
    $res = Invoke-CompareVI -Base 'a.vi' -Head 'b.vi' -WorkingDirectory $vis -Executor { 0 }
    $res.Base | Should -Be (Resolve-Path (Join-Path $vis 'a.vi')).Path
    $res.Head | Should -Be (Resolve-Path (Join-Path $vis 'b.vi')).Path
  }

  It 'parses quoted lvCompareArgs and includes them in the reconstructed command' {
    $exec = { param($cli,$base,$head,$arr) return 0 }
    $res = Invoke-CompareVI -Base $a -Head $b -LvCompareArgs '--flag "C:\\Temp\\Spaced Path\\x"' -Executor $exec
    # Validate command contains the flag and the quoted path (robust match)
    $res.Command | Should -Match '--flag\s+"C:.*Spaced Path.*x"'
  }

  It 'writes outputs and summary for exit code 0 (diff=false)' {
    $out = Join-Path $td 'out.txt'
    $sum = Join-Path $td 'sum.md'
    $res = Invoke-CompareVI -Base $a -Head $a -GitHubOutputPath $out -GitHubStepSummaryPath $sum -Executor { 0 }
    $res.Diff | Should -BeFalse
    (Get-Content $out -Raw) | Should -Match 'exitCode=0'
    (Get-Content $out -Raw) | Should -Match 'diff=false'
    (Get-Content $sum -Raw) | Should -Match 'Diff: false'
  }

  It 'writes outputs then throws for unknown exit code (diff=false)' {
    $out = Join-Path $td 'out.txt'
    $sum = Join-Path $td 'sum.md'
    { Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $out -GitHubStepSummaryPath $sum -Executor { 2 } } | Should -Throw
    (Get-Content $out -Raw) | Should -Match 'exitCode=2'
    (Get-Content $out -Raw) | Should -Match 'diff=false'
    (Get-Content $sum -Raw) | Should -Match 'Exit code: 2'
  }

  It 'throws when fail-on-diff is true with exit code 1, but writes outputs' {
    $out = Join-Path $td 'out.txt'
    { Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $out -FailOnDiff:$true -Executor { 1 } } | Should -Throw
    (Get-Content $out -Raw) | Should -Match 'exitCode=1'
    (Get-Content $out -Raw) | Should -Match 'diff=true'
  }

  It 'uses mocked Resolve-Cli value in result' {
    $res = Invoke-CompareVI -Base $a -Head $b -Executor { 0 }
    $res.CliPath | Should -Be 'C:\fake\LVCompare.exe'
  }
}
