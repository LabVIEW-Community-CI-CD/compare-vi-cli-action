Describe 'Summarize-PesterCategories' -Tag 'Unit' {
  BeforeAll {
    $script:summaryPath = Join-Path $TestDrive 'step-summary.md'
    $env:GITHUB_STEP_SUMMARY = $script:summaryPath
    $script:base = Join-Path $TestDrive 'cats'
    New-Item -ItemType Directory -Force -Path $script:base | Out-Null

    foreach ($cat in @('dispatcher','fixtures')) {
      $dir = Join-Path (Join-Path $script:base $cat) 'tests/results'
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $si = [ordered]@{
        schema = 'session-index/v1'
        status = 'ok'
        total = 3
        passed = 3
        failed = 0
        errors = 0
        skipped = 0
        duration_s = 0.42
      } | ConvertTo-Json
      Set-Content -LiteralPath (Join-Path $dir 'session-index.json') -Value $si -Encoding UTF8
    }
  }

  AfterAll {
    Remove-Item Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
  }

  It 'writes per-category totals to the job summary' {
    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Summarize-PesterCategories.ps1') -BaseDir $script:base -Categories @('dispatcher','fixtures')
    Test-Path -LiteralPath $script:summaryPath | Should -BeTrue
    $content = Get-Content -LiteralPath $script:summaryPath -Raw
    $content | Should -Match '### Pester Categories'
    $content | Should -Match 'dispatcher: status=ok, total=3'
    $content | Should -Match 'fixtures: status=ok, total=3'
  }

  It 'reads session-index from a downloaded artifact layout' {
    Remove-Item -LiteralPath $script:summaryPath -ErrorAction SilentlyContinue
    $catRoot = Join-Path $script:base 'downloaded'
    New-Item -ItemType Directory -Force -Path $catRoot | Out-Null
    $si = [ordered]@{
      schema = 'session-index/v1'
      status = 'ok'
      total = 5
      passed = 5
      failed = 0
      errors = 0
      skipped = 0
      duration_s = 1.23
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $catRoot 'session-index.json') -Value $si -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Summarize-PesterCategories.ps1') -BaseDir $script:base -Categories @('downloaded')

    Test-Path -LiteralPath $script:summaryPath | Should -BeTrue
    $content = Get-Content -LiteralPath $script:summaryPath -Raw
    $content | Should -Match 'downloaded: status=ok, total=5'
  }
}
