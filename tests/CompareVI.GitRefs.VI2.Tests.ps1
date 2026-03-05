Describe 'CompareVI with Git refs (VI2.vi at two commits)' -Tag 'CompareVI','Integration' {
  BeforeAll {
    $ErrorActionPreference = 'Stop'
    try { git --version | Out-Null } catch { throw 'git is required for this test' }
    $repoRoot = (Get-Location).Path
    $target = 'VI2.vi'
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $target))) {
      Set-ItResult -Skipped -Because "Target file not found: $target"
    }

    $revList = & git rev-list --max-count=50 HEAD -- $target
    if (-not $revList) { Set-ItResult -Skipped -Because 'No history for target'; return }
    $pairs = @()
    foreach ($a in $revList) { foreach ($b in $revList) { if ($a -ne $b) { $pairs += [pscustomobject]@{ A=$a; B=$b } } } }
    if (-not $pairs) { Set-ItResult -Skipped -Because 'Not enough refs' }
    Set-Variable -Name '_repo' -Value $repoRoot -Scope Script
    Set-Variable -Name '_pairs' -Value $pairs -Scope Script
    Set-Variable -Name '_target' -Value $target -Scope Script
  }

  It 'produces exec and summary JSON from two refs (non-failing check)' {
    $pair = $null
    foreach ($p in $_pairs) {
      & git show --no-renames -- "$($p.A):$_target" 1>$null 2>$null; $okA = ($LASTEXITCODE -eq 0)
      & git show --no-renames -- "$($p.B):$_target" 1>$null 2>$null; $okB = ($LASTEXITCODE -eq 0)
      if ($okA -and $okB) { $pair = $p; break }
    }
    if (-not $pair) { Set-ItResult -Skipped -Because 'No valid ref pair with content'; return }

    $rd = Join-Path $TestDrive 'ref-compare-vi2'
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repo 'tools/Compare-RefsToTemp.ps1') -Path $_target -RefA $pair.A -RefB $pair.B -ResultsDir $rd -OutName 'vi2' | Out-Null
    $exec = Join-Path $rd 'vi2-exec.json'
    $sum  = Join-Path $rd 'vi2-summary.json'
    Test-Path -LiteralPath $exec | Should -BeTrue
    Test-Path -LiteralPath $sum  | Should -BeTrue
    $e = Get-Content -LiteralPath $exec -Raw | ConvertFrom-Json
    $s = Get-Content -LiteralPath $sum  -Raw | ConvertFrom-Json

    [string]::IsNullOrWhiteSpace($e.base) | Should -BeFalse
    [string]::IsNullOrWhiteSpace($e.head) | Should -BeFalse
    (Split-Path -Leaf $e.base) | Should -Be 'Base.vi'
    (Split-Path -Leaf $e.head) | Should -Be 'Head.vi'
    $s.schema | Should -Be 'ref-compare-summary/v1'

    "VI2 refs: A=$($pair.A) B=$($pair.B) expectDiff=$($s.computed.expectDiff) cliDiff=$($s.cli.diff) exit=$($s.cli.exitCode)" | Write-Host
  }
}

