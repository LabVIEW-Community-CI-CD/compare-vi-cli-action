# CompareVI-TestPlane: host-neutral
Describe 'CompareVI with Git refs (VI2.vi at two commits)' -Tag 'CompareVI','Integration' {
  BeforeAll {
    $ErrorActionPreference = 'Stop'
    $script:_skipCompareVIGitRefsReason = $null
    try { git --version | Out-Null } catch { throw 'git is required for this test' }
    $repoRoot = (Get-Location).Path
    $target = 'VI2.vi'
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $target))) {
      $script:_skipCompareVIGitRefsReason = "Target file not found: $target"
      return
    }

    $revList = & git rev-list --max-count=50 HEAD -- $target
    if (-not $revList) {
      $script:_skipCompareVIGitRefsReason = 'No history for target'
      return
    }
    $pairs = @()
    foreach ($a in $revList) { foreach ($b in $revList) { if ($a -ne $b) { $pairs += [pscustomobject]@{ A=$a; B=$b } } } }
    if (-not $pairs) {
      $script:_skipCompareVIGitRefsReason = 'Not enough refs'
      return
    }
    Set-Variable -Name '_repo' -Value $repoRoot -Scope Script
    Set-Variable -Name '_pairs' -Value $pairs -Scope Script
    Set-Variable -Name '_target' -Value $target -Scope Script
  }

  It 'produces exec and summary JSON from two refs (non-failing check)' {
    if ($script:_skipCompareVIGitRefsReason) {
      Set-ItResult -Skipped -Because $script:_skipCompareVIGitRefsReason
      return
    }
    $pair = $null
    foreach ($p in $_pairs) {
      & git show --no-renames -- "$($p.A):$_target" 1>$null 2>$null; $okA = ($LASTEXITCODE -eq 0)
      & git show --no-renames -- "$($p.B):$_target" 1>$null 2>$null; $okB = ($LASTEXITCODE -eq 0)
      if ($okA -and $okB) { $pair = $p; break }
    }
    if (-not $pair) { Set-ItResult -Skipped -Because 'No valid ref pair with content'; return }

    $rd = Join-Path $TestDrive 'ref-compare-vi2'
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    $stubPath = Join-Path $_repo 'tests/stubs/Invoke-LVCompare.stub.ps1'
    & pwsh -NoLogo -NoProfile -File (Join-Path $_repo 'tools/Compare-RefsToTemp.ps1') `
      -Path $_target `
      -RefA $pair.A `
      -RefB $pair.B `
      -ResultsDir $rd `
      -OutName 'vi2' `
      -Detailed `
      -RenderReport `
      -InvokeScriptPath $stubPath `
      -FailOnDiff:$false | Out-Null
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

  It 'strips provider-qualified results paths from emitted ref-compare artifacts' {
    if ($script:_skipCompareVIGitRefsReason) {
      Set-ItResult -Skipped -Because $script:_skipCompareVIGitRefsReason
      return
    }
    $pair = $null
    foreach ($p in $_pairs) {
      & git show --no-renames -- "$($p.A):$_target" 1>$null 2>$null; $okA = ($LASTEXITCODE -eq 0)
      & git show --no-renames -- "$($p.B):$_target" 1>$null 2>$null; $okB = ($LASTEXITCODE -eq 0)
      if ($okA -and $okB) { $pair = $p; break }
    }
    if (-not $pair) { Set-ItResult -Skipped -Because 'No valid ref pair with content'; return }

    $rd = Join-Path $TestDrive 'ref-compare-vi2-provider'
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    $providerResultsDir = "Microsoft.PowerShell.Core\FileSystem::$rd"
    $stubPath = Join-Path $_repo 'tests/stubs/Invoke-LVCompare.stub.ps1'

    & pwsh -NoLogo -NoProfile -File (Join-Path $_repo 'tools/Compare-RefsToTemp.ps1') `
      -Path $_target `
      -RefA $pair.A `
      -RefB $pair.B `
      -ResultsDir $providerResultsDir `
      -OutName 'vi2-provider' `
      -Detailed `
      -RenderReport `
      -InvokeScriptPath $stubPath `
      -FailOnDiff:$false | Out-Null

    $sum = Join-Path $rd 'vi2-provider-summary.json'
    $sum | Should -Exist
    $summary = Get-Content -LiteralPath $sum -Raw | ConvertFrom-Json -Depth 10
    foreach ($pathValue in @(
      [string]$summary.out.execJson,
      [string]$summary.out.captureJson,
      [string]$summary.out.stdout,
      [string]$summary.out.stderr,
      [string]$summary.out.reportHtml,
      [string]$summary.out.reportPath,
      [string]$summary.out.artifactDir
    )) {
      if (-not [string]::IsNullOrWhiteSpace($pathValue)) {
        $pathValue | Should -Not -Match 'Microsoft\.PowerShell\.Core\\FileSystem::'
      }
    }
  }
}
