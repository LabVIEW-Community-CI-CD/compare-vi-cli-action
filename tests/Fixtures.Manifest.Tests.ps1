Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture manifest enforcement' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $script:validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    $script:manifest = Join-Path $repoRoot 'fixtures.manifest.json'
    $script:vi1 = Join-Path $repoRoot 'VI1.vi'
    $script:originalManifest = Get-Content -LiteralPath $manifest -Raw
    function Set-ManifestBytesToActual {
      $m = Get-Content -LiteralPath $script:manifest -Raw | ConvertFrom-Json
      foreach ($it in $m.items) {
        $path = Join-Path $repoRoot $it.path
        $it.bytes = (Get-Item -LiteralPath $path).Length
      }
      ($m | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $script:manifest -Encoding utf8 -NoNewline
    }
  }

  It 'baseline passes with size-only enforcement (hash mismatches ignored)' {
    # Ignore hash mismatches; with recorded bytes matching fixtures, expect success
    pwsh -NoLogo -NoProfile -File $validator -TestAllowFixtureUpdate | Out-Null
    $LASTEXITCODE | Should -Be 0
  }

  It 'detects hash mismatch without token (exit 6 precedence when only mismatch)' {
    try {
      Set-ManifestBytesToActual
      $m = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
      # Invalidate hash for VI1.vi
      ($m.items | Where-Object { $_.path -eq 'VI1.vi' }).sha256 = 'BADHASH'
      ($m | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $manifest -Encoding utf8 -NoNewline
  pwsh -NoLogo -NoProfile -File $validator -DisableToken | Out-Null
      $LASTEXITCODE | Should -Be 6
    } finally {
      $originalManifest | Set-Content -LiteralPath $manifest -Encoding utf8 -NoNewline
    }
  }

  It 'ignores hash mismatch with test override flag (returns ok when only mismatch)' {
    try {
      Set-ManifestBytesToActual
      $m = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
      ($m.items | Where-Object { $_.path -eq 'VI2.vi' }).sha256 = 'DEADBEEF'
      ($m | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $manifest -Encoding utf8 -NoNewline
  pwsh -NoLogo -NoProfile -File $validator -TestAllowFixtureUpdate -DisableToken | Out-Null
      $LASTEXITCODE | Should -Be 0
    } finally {
      $originalManifest | Set-Content -LiteralPath $manifest -Encoding utf8 -NoNewline
    }
  }

  It 'emits structured JSON with -Json flag (success with recorded bytes)' {
    try {
      Set-ManifestBytesToActual
      # Ignore hash mismatches to assert clean JSON success when sizes are permissive
      $json = pwsh -NoLogo -NoProfile -File $validator -Json -TestAllowFixtureUpdate | Out-String | ConvertFrom-Json
      $json.ok | Should -Be $true
      $json.exitCode | Should -Be 0
      $json.manifestPresent | Should -Be $true
      $json.fixtureCount | Should -Be 2
      $json.issues.Count | Should -Be 0
      $json.fixtures.Count | Should -Be 2
      $json.summaryCounts.missing | Should -Be 0
      $json.summaryCounts.hashMismatch | Should -Be 0
      $json.summaryCounts.schema | Should -Be 0
    } finally {
      $originalManifest | Set-Content -LiteralPath $manifest -Encoding utf8 -NoNewline
    }
  }
}
