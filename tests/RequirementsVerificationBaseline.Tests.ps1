Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Requirements verification baseline' -Tag 'Unit' {
  It 'does not allow synthetic unknown or uncovered requirement debt' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $baselinePath = Join-Path $repoRoot 'tools' 'policy' 'requirements-verification-baseline.json'
    $baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json

    @($baseline.allowlist.unknownRequirementIds) | Should -BeNullOrEmpty
    @($baseline.allowlist.uncoveredRequirementIds) | Should -BeNullOrEmpty
  }
}
