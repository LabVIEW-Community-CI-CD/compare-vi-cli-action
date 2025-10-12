Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Agent context emission' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:AgentContextScript = Join-Path $repoRoot 'tools' 'Write-AgentContext.ps1'
    Test-Path -LiteralPath $script:AgentContextScript | Should -BeTrue
  }

  It 'writes toggle contract metadata to context.json' {
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir | Out-Null

    & pwsh -NoLogo -NoProfile -File $script:AgentContextScript -ResultsDir $resultsDir -Quiet | Out-Null
    $LASTEXITCODE | Should -Be 0

    $contextJsonPath = Join-Path $resultsDir '_agent' 'context' 'context.json'
    Test-Path -LiteralPath $contextJsonPath | Should -BeTrue

    $context = Get-Content -LiteralPath $contextJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $context.toggle | Should -Not -BeNullOrEmpty
    $context.toggle.schema | Should -Be 'agent-toggles/v1'
    $context.toggle.manifestDigest | Should -Match '^[a-f0-9]{64}$'
    $context.toggle.generatedAtUtc | Should -Not -BeNullOrEmpty
    $context.toggle.PSObject.Properties.Name | Should -Contain 'profiles'
  }
}
