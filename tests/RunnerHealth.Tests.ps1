Import-Module Pester

Describe 'Collect-RunnerHealth.ps1' {
  BeforeAll {
    $script:runnerHealthScript = Join-Path (Resolve-Path '.').Path 'tools/Collect-RunnerHealth.ps1'
  }
  It 'produces JSON with required top-level fields' {
    $out = Join-Path $TestDrive 'results'
    & pwsh -NoLogo -NoProfile -File $script:runnerHealthScript -ResultsDir $out -EmitJson | Out-Null
    $jsonPath = Join-Path $out '_agent' 'runner-health.json'
    Test-Path $jsonPath | Should -BeTrue
    $j = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $j.schema | Should -Be 'runner-health/v1'
    $j.generatedAt | Should -Not -BeNullOrEmpty
    $j.env | Should -Not -BeNullOrEmpty
    $j.service | Should -Not -BeNullOrEmpty
  }

  It 'appends a concise summary when GITHUB_STEP_SUMMARY is set' {
    $out = Join-Path $TestDrive 'results'
    $summary = Join-Path $TestDrive 'summary.md'
    $env:GITHUB_STEP_SUMMARY = $summary
    try {
      & pwsh -NoLogo -NoProfile -File $script:runnerHealthScript -ResultsDir $out -AppendSummary | Out-Null
      Test-Path $summary | Should -BeTrue
      $text = Get-Content -LiteralPath $summary -Raw
      $text | Should -Match 'Runner Health'
      $text | Should -Match 'Service'
    } finally { Remove-Item -LiteralPath $summary -Force -ErrorAction SilentlyContinue; $env:GITHUB_STEP_SUMMARY = $null }
  }
}
