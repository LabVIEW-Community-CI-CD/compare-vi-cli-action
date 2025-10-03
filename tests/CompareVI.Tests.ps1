# Requires -Version 5.1
# Pester v5 tests

BeforeAll {
  $here = Split-Path -Parent $PSCommandPath
  $root = Resolve-Path (Join-Path $here '..')
  . (Join-Path $root 'scripts' 'CompareVI.ps1')
  
  # Canonical path constant
  $script:canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  # Enable test bypass for Resolve-Cli to avoid filesystem dependency
  $script:_origBypass = $env:LVCOMPARE_TEST_BYPASS
  $env:LVCOMPARE_TEST_BYPASS = '1'
}

AfterAll {
  if ($null -ne $script:_origBypass) { $env:LVCOMPARE_TEST_BYPASS = $script:_origBypass } else { Remove-Item Env:LVCOMPARE_TEST_BYPASS -ErrorAction SilentlyContinue }
}

Describe 'Invoke-CompareVI core behavior' -Tag 'Unit' {
  BeforeEach {
    # Use Pester's native TestDrive
    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'a.vi'
    $b = Join-Path $vis 'b.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    New-Item -ItemType File -Path $b -Force | Out-Null

    # Create an Executor that simulates CLI behavior (exit 0 if base==head, else 1)
    $mockExecutor = {
      param($cli, $base, $head, $args)
      if ($env:FORCE_EXIT) { return [int]$env:FORCE_EXIT }
      # Compare absolute paths to handle resolution properly
      $baseResolved = try { (Resolve-Path -LiteralPath $base -ErrorAction Stop).Path } catch { $base }
      $headResolved = try { (Resolve-Path -LiteralPath $head -ErrorAction Stop).Path } catch { $head }
      if ($baseResolved -eq $headResolved) { return 0 } else { return 1 }
    }

    # Mock Resolve-Cli to return canonical path without checking if it exists
    Mock -CommandName Resolve-Cli -MockWith { param($Explicit) return $script:canonical }

    $script:a = $a; $script:b = $b; $script:vis = $vis; $script:mockExecutor = $mockExecutor
  }

  It 'returns diff=true when files differ and handles outputs' {
    $out = Join-Path $TestDrive 'out.txt'
    $sum = Join-Path $TestDrive 'summary.md'
    $res = Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $out -GitHubStepSummaryPath $sum -FailOnDiff:$false -Executor $mockExecutor
    $res.ExitCode | Should -Be 1
    $res.Diff | Should -BeTrue
    $res.CompareDurationSeconds | Should -BeGreaterOrEqual 0
    $res.CompareDurationNanoseconds | Should -BeGreaterOrEqual 0
    $outContent = Get-Content $out -Raw
    $outContent | Should -Match 'diff=true'
    $outContent | Should -Match 'compareDurationSeconds='
    $outContent | Should -Match 'compareDurationNanoseconds='
    $sumContent = Get-Content $sum -Raw
    $sumContent | Should -Match 'Diff:\s+true'
    # Escape parentheses in regex
    $sumContent | Should -Match 'Duration \(s\):'
    $sumContent | Should -Match 'Duration \(ns\):'
  }

  It 'throws when fail-on-diff is true but still writes outputs' {
    $out = Join-Path $TestDrive 'out.txt'
    { Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $out -FailOnDiff:$true -Executor $mockExecutor } | Should -Throw
    $outContent = Get-Content $out -Raw
    $outContent | Should -Match 'exitCode=1'
  }

  It 'returns diff=false for equal files' {
    # Use a mock that always returns 0 for this specific test
    $mockExecutorZero = { param($cli, $base, $head, $args) return 0 }
    $res = Invoke-CompareVI -Base $a -Head $a -FailOnDiff:$true -Executor $mockExecutorZero
    $res.ExitCode | Should -Be 0
    $res.Diff | Should -BeFalse
    $res.CompareDurationSeconds | Should -BeGreaterOrEqual 0
    $res.CompareDurationNanoseconds | Should -BeGreaterOrEqual 0
  }

  It 'handles unknown exit code by throwing but keeps outputs (diff=false)' {
    $out = Join-Path $TestDrive 'out.txt'
    $env:FORCE_EXIT = '2'
    { Invoke-CompareVI -Base $a -Head $b -GitHubOutputPath $out -FailOnDiff:$false -Executor $mockExecutor } | Should -Throw
    Remove-Item Env:FORCE_EXIT -ErrorAction SilentlyContinue
    $outContent = Get-Content $out -Raw
    $outContent | Should -Match 'diff=false'
  }

  It 'parses quoted args and reconstructs the command' {
    $res = Invoke-CompareVI -Base $a -Head $b -LvCompareArgs '--flag "C:\\Temp\\Spaced Path\\x"' -FailOnDiff:$false -Executor $mockExecutor
    # The command will contain the quoted argument with escaped backslashes
    $res.Command | Should -BeLike '*"C:\\Temp\\Spaced Path\\x"*'
  }

  It 'resolves relative paths from working-directory' {
    $res = Invoke-CompareVI -Base 'a.vi' -Head 'b.vi' -WorkingDirectory $vis -FailOnDiff:$false -Executor $mockExecutor
    $res.Base | Should -Be (Resolve-Path (Join-Path $vis 'a.vi')).Path
    $res.Head | Should -Be (Resolve-Path (Join-Path $vis 'b.vi')).Path
  }

  It 'throws when base or head not found' {
    { Invoke-CompareVI -Base 'missing.vi' -Head $a -Executor $mockExecutor } | Should -Throw
    { Invoke-CompareVI -Base $a -Head 'missing.vi' -Executor $mockExecutor } | Should -Throw
  }
}

Describe 'Resolve-Cli canonical path enforcement' -Tag 'Unit' {
  BeforeAll {
    $script:_origAllow32 = $env:LVCOMPARE_ALLOW_32BIT
    $env:LVCOMPARE_ALLOW_32BIT = '1'
  }
  AfterAll {
    if ($null -ne $script:_origAllow32) { $env:LVCOMPARE_ALLOW_32BIT = $script:_origAllow32 } else { Remove-Item Env:LVCOMPARE_ALLOW_32BIT -ErrorAction SilentlyContinue }
  }
  BeforeEach {
    # Use Pester's native TestDrive
    $vis = Join-Path $TestDrive 'vis'
    New-Item -ItemType Directory -Path $vis -Force | Out-Null
    $a = Join-Path $vis 'a.vi'
    $b = Join-Path $vis 'b.vi'
    New-Item -ItemType File -Path $a -Force | Out-Null
    New-Item -ItemType File -Path $b -Force | Out-Null

    # Create an Executor that simulates CLI behavior
    $mockExecutor = {
      param($cli, $base, $head, $args)
      return 0
    }

    # Reference the canonical path from BeforeAll
    $canonical = $script:canonical

    $script:a = $a; $script:b = $b; $script:vis = $vis; $script:mockExecutor = $mockExecutor
  }

  It 'rejects explicit lvComparePath when non-canonical' {
    $fakePath = Join-Path $TestDrive 'LVCompare.exe'
    New-Item -ItemType File -Path $fakePath -Force | Out-Null
    { Invoke-CompareVI -Base $a -Head $b -LvComparePath $fakePath -FailOnDiff:$false -Executor $mockExecutor } | Should -Throw -ExpectedMessage '*canonical*'
  }

  It 'rejects LVCOMPARE_PATH when non-canonical' {
    $fakePath = Join-Path $TestDrive 'LVCompare.exe'
    New-Item -ItemType File -Path $fakePath -Force | Out-Null
    $old = $env:LVCOMPARE_PATH
    try {
      $env:LVCOMPARE_PATH = $fakePath
      { Invoke-CompareVI -Base $a -Head $b -FailOnDiff:$false -Executor $mockExecutor } | Should -Throw -ExpectedMessage '*canonical*'
    } finally { $env:LVCOMPARE_PATH = $old }
  }

  It 'accepts explicit lvComparePath when canonical and exists' -Skip:(-not (Test-Path -LiteralPath 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe')) {
    $res = Invoke-CompareVI -Base $a -Head $b -LvComparePath $canonical -FailOnDiff:$false -Executor $mockExecutor
    $res.CliPath | Should -Be (Resolve-Path $canonical).Path
  }

  It 'accepts LVCOMPARE_PATH when canonical and exists' -Skip:(-not (Test-Path -LiteralPath 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe')) {
    $old = $env:LVCOMPARE_PATH
    try {
      $env:LVCOMPARE_PATH = $canonical
      $res = Invoke-CompareVI -Base $a -Head $b -FailOnDiff:$false -Executor $mockExecutor
      $res.CliPath | Should -Be (Resolve-Path $canonical).Path
    } finally { $env:LVCOMPARE_PATH = $old }
  }

  It 'falls back to canonical install path when present' -Skip:(-not (Test-Path -LiteralPath 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe')) {
    $old = $env:LVCOMPARE_PATH
    $oldPath = $env:PATH
    try {
      $env:LVCOMPARE_PATH = $null
      # PATH may still contain LVCompare, but canonical should win if PATH doesn't resolve
      $res = Invoke-CompareVI -Base $a -Head $b -FailOnDiff:$false -Executor $mockExecutor
      $res.CliPath | Should -Be (Resolve-Path $canonical).Path
    } finally {
      $env:LVCOMPARE_PATH = $old
      $env:PATH = $oldPath
    }
  }
}

