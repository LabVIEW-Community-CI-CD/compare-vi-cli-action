# Requires -Version 5.1
# Pester v5 tests

$here = Split-Path -Parent $PSCommandPath
$root = Resolve-Path (Join-Path $here '..')
. (Join-Path $root 'scripts' 'CompareVI.ps1')

# Canonical path candidates
Set-Variable -Name canonicalCandidates -Scope Script -Value @() -Force
Set-Variable -Name canonical -Scope Script -Value $null -Force
Set-Variable -Name existingCanonicalPath -Scope Script -Value $null -Force

$script:canonicalCandidates = Get-CanonicalCliCandidates
if (-not $script:canonicalCandidates -or $script:canonicalCandidates.Count -eq 0) {
  $script:canonicalCandidates = @('C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe', 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW Compare\LVCompare.exe')
}
$script:canonical = $script:canonicalCandidates[0]
$script:existingCanonicalPath = $script:canonicalCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

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

    $script:a = $a; $script:b = $b; $script:vis = $vis; $script:mockExecutor = $mockExecutor
  }

  It 'rejects explicit lvComparePath when non-canonical' {
    $fakePath = Join-Path $TestDrive 'LVCompare.exe'
    New-Item -ItemType File -Path $fakePath -Force | Out-Null
    { Invoke-CompareVI -Base $a -Head $b -LvComparePath $fakePath -FailOnDiff:$false -Executor $mockExecutor } | Should -Throw -ExpectedMessage '*canonical*'
  }

  It 'prefers x86 candidate when LVCOMPARE_BITNESS requests 32-bit' {
    $x64Path = Join-Path $TestDrive 'Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    $x86Path = Join-Path $TestDrive 'Program Files (x86)\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    [System.IO.Directory]::CreateDirectory((Split-Path $x64Path)) | Out-Null
    [System.IO.Directory]::CreateDirectory((Split-Path $x86Path)) | Out-Null
    New-Item -ItemType File -Path $x64Path -Force | Out-Null
    New-Item -ItemType File -Path $x86Path -Force | Out-Null
    Mock -CommandName Get-CanonicalCliCandidates -ModuleName CompareVI -MockWith { @($x64Path, $x86Path) }
    $oldPref = $env:LVCOMPARE_BITNESS
    $oldLvPath = $env:LVCOMPARE_PATH
    try {
      $env:LVCOMPARE_BITNESS = 'x86'
      # Ensure LVCOMPARE_PATH does not interfere (canonical-only policy)
      Remove-Item Env:LVCOMPARE_PATH -ErrorAction SilentlyContinue
      $resolved = Resolve-Cli
      $resolved | Should -Be ([System.IO.Path]::GetFullPath($x86Path))
    } finally {
      if ($null -eq $oldPref) { Remove-Item Env:LVCOMPARE_BITNESS -ErrorAction SilentlyContinue } else { $env:LVCOMPARE_BITNESS = $oldPref }
      if ($null -eq $oldLvPath) { Remove-Item Env:LVCOMPARE_PATH -ErrorAction SilentlyContinue } else { $env:LVCOMPARE_PATH = $oldLvPath }
    }
  }

  It 'allows PreferredBitness parameter to override environment selection' {
    $x64Path = Join-Path $TestDrive 'Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    $x86Path = Join-Path $TestDrive 'Program Files (x86)\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    [System.IO.Directory]::CreateDirectory((Split-Path $x64Path)) | Out-Null
    [System.IO.Directory]::CreateDirectory((Split-Path $x86Path)) | Out-Null
    New-Item -ItemType File -Path $x64Path -Force | Out-Null
    New-Item -ItemType File -Path $x86Path -Force | Out-Null
    Mock -CommandName Get-CanonicalCliCandidates -ModuleName CompareVI -MockWith { @($x86Path, $x64Path) }
    $oldPref = $env:LVCOMPARE_BITNESS
    $oldLvPath = $env:LVCOMPARE_PATH
    try {
      $env:LVCOMPARE_BITNESS = 'x86'
      Remove-Item Env:LVCOMPARE_PATH -ErrorAction SilentlyContinue
      $resolved = Resolve-Cli -PreferredBitness 'x64'
      $resolved | Should -Be ([System.IO.Path]::GetFullPath($x64Path))
    } finally {
      if ($null -eq $oldPref) { Remove-Item Env:LVCOMPARE_BITNESS -ErrorAction SilentlyContinue } else { $env:LVCOMPARE_BITNESS = $oldPref }
      if ($null -eq $oldLvPath) { Remove-Item Env:LVCOMPARE_PATH -ErrorAction SilentlyContinue } else { $env:LVCOMPARE_PATH = $oldLvPath }
    }
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

  It 'accepts explicit lvComparePath when canonical and exists' {
    $existingVar = Get-Variable -Name existingCanonicalPath -Scope Script -ErrorAction SilentlyContinue
    $path = if ($existingVar) { $existingVar.Value } else { $null }
    if (-not $path) {
      Set-ItResult -Skipped -Because 'Canonical LVCompare path not available on this host'
      return
    }
    $res = Invoke-CompareVI -Base $a -Head $b -LvComparePath $path -FailOnDiff:$false -Executor $mockExecutor
    $res.CliPath | Should -Be (Resolve-Path $path).Path
  }

  It 'accepts LVCOMPARE_PATH when canonical and exists' {
    $existingVar = Get-Variable -Name existingCanonicalPath -Scope Script -ErrorAction SilentlyContinue
    $path = if ($existingVar) { $existingVar.Value } else { $null }
    if (-not $path) {
      Set-ItResult -Skipped -Because 'Canonical LVCompare path not available on this host'
      return
    }
    $old = $env:LVCOMPARE_PATH
    try {
      $env:LVCOMPARE_PATH = $path
      $res = Invoke-CompareVI -Base $a -Head $b -FailOnDiff:$false -Executor $mockExecutor
      $res.CliPath | Should -Be (Resolve-Path $path).Path
    } finally { $env:LVCOMPARE_PATH = $old }
  }

  It 'falls back to canonical install path when present' {
    $existingVar = Get-Variable -Name existingCanonicalPath -Scope Script -ErrorAction SilentlyContinue
    $path = if ($existingVar) { $existingVar.Value } else { $null }
    if (-not $path) {
      Set-ItResult -Skipped -Because 'Canonical LVCompare path not available on this host'
      return
    }
    $old = $env:LVCOMPARE_PATH
    $oldPath = $env:PATH
    try {
      $env:LVCOMPARE_PATH = $null
      # PATH may still contain LVCompare, but canonical should win if PATH doesn't resolve
      $res = Invoke-CompareVI -Base $a -Head $b -FailOnDiff:$false -Executor $mockExecutor
      $res.CliPath | Should -Be (Resolve-Path $path).Path
    } finally {
      $env:LVCOMPARE_PATH = $old
      $env:PATH = $oldPath
    }
  }
}

