Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Orchestrator handshake markers' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $script:scriptPath = Join-Path $repoRoot 'scripts' 'On-FixtureValidationFail.ps1'
    $script:resultsDir = Join-Path $repoRoot 'tests' 'results'
    if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

    function New-StrictJson {
      param([int]$Exit,[hashtable]$Counts)
      $obj = [ordered]@{ ok = ($Exit -eq 0); exitCode = $Exit; summaryCounts = ([ordered]@{}) }
      foreach ($k in 'missing','untracked','tooSmall','hashMismatch','manifestError','duplicate','schema') {
        $obj.summaryCounts[$k] = if ($Counts.ContainsKey($k)) { [int]$Counts[$k] } else { 0 }
      }
      $fp = Join-Path $resultsDir ("strict-$Exit.json")
      ($obj | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $fp -Encoding utf8
      return $fp
    }
  }

  It 'emits reset/start/compare/end markers for drift path' {
    $strict = New-StrictJson -Exit 6 -Counts @{ hashMismatch = 1 }
    $outDir = Join-Path $resultsDir 'handshake-drift'
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    pwsh -NoLogo -NoProfile -File $scriptPath -StrictJson $strict -OutputDir $outDir -RenderReport -SimulateCompare | Out-Null
    $LASTEXITCODE | Should -Be 1

    Test-Path (Join-Path $outDir 'handshake-reset.json') | Should -BeTrue
    Test-Path (Join-Path $outDir 'handshake-start.json') | Should -BeTrue
    Test-Path (Join-Path $outDir 'handshake-compare.json') | Should -BeTrue
    Test-Path (Join-Path $outDir 'handshake-end.json') | Should -BeTrue

    $end = Get-Content -LiteralPath (Join-Path $outDir 'handshake-end.json') -Raw | ConvertFrom-Json
    $end.status | Should -Be 'drift'
  }

  It 'sets status ok in end marker for clean path' {
    $strict = New-StrictJson -Exit 0 -Counts @{}
    $outDir = Join-Path $resultsDir 'handshake-ok'
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    pwsh -NoLogo -NoProfile -File $scriptPath -StrictJson $strict -OutputDir $outDir | Out-Null
    $LASTEXITCODE | Should -Be 0
    $end = Get-Content -LiteralPath (Join-Path $outDir 'handshake-end.json') -Raw | ConvertFrom-Json
    $end.status | Should -Be 'ok'
  }

  It 'sets status fail-structural in end marker for structural issues' {
    $strict = New-StrictJson -Exit 4 -Counts @{ tooSmall = 1 }
    $outDir = Join-Path $resultsDir 'handshake-struct'
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    pwsh -NoLogo -NoProfile -File $scriptPath -StrictJson $strict -OutputDir $outDir | Out-Null
    $LASTEXITCODE | Should -Be 1
    $end = Get-Content -LiteralPath (Join-Path $outDir 'handshake-end.json') -Raw | ConvertFrom-Json
    $end.status | Should -Be 'fail-structural'
  }
}

