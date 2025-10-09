Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture pair block schema and digest' -Tag 'Unit' {
  It 'validates pair fields and digest' {
    $root = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $path = Join-Path $root 'fixtures.manifest.json'
    Test-Path -LiteralPath $path | Should -BeTrue
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 6

    # Top-level basics
    $manifest.schema | Should -Be 'fixture-manifest-v1'
    @($manifest.items).Count | Should -BeGreaterThan 0

    # Pair block exists when both roles exist
    $base = @($manifest.items | Where-Object { $_.role -eq 'base' })[0]
    $head = @($manifest.items | Where-Object { $_.role -eq 'head' })[0]
    $base | Should -Not -BeNullOrEmpty
    $head | Should -Not -BeNullOrEmpty

    $pair = $manifest.pair
    $pair | Should -Not -BeNullOrEmpty

    # Shape checks
    $pair.schema     | Should -Be 'fixture-pair/v1'
    [string]::IsNullOrWhiteSpace([string]$pair.basePath) | Should -BeFalse
    [string]::IsNullOrWhiteSpace([string]$pair.headPath) | Should -BeFalse
    $pair.algorithm  | Should -Be 'sha256'
    [string]::IsNullOrWhiteSpace([string]$pair.canonical) | Should -BeFalse
    ([string]$pair.digest) | Should -Match '^[A-F0-9]{64}$'

    if ($pair.expectedOutcome) { ([string]$pair.expectedOutcome) | Should -Match '^(identical|diff|any)$' }
    if ($pair.enforce)         { ([string]$pair.enforce)         | Should -Match '^(notice|warn|fail)$' }

    # Deterministic recompute
    $bSha = ([string]$base.sha256).ToUpperInvariant()
    $hSha = ([string]$head.sha256).ToUpperInvariant()
    $bLen = [int64]$base.bytes
    $hLen = [int64]$head.bytes
    $canonical = 'sha256:{0}|bytes:{1}|sha256:{2}|bytes:{3}' -f $bSha,$bLen,$hSha,$hLen
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $calcDigest = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)) | ForEach-Object { $_.ToString('X2') }) -join ''

    $pair.canonical | Should -Be $canonical
    $pair.digest    | Should -Be $calcDigest
  }
}

