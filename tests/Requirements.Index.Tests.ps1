Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Requirements index' -Tag 'Unit','REQ:INDEX' {
  It 'lists every current requirement document with a valid relative link' {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $indexPath = Join-Path $repoRoot 'docs' 'requirements' 'index.md'
    $content = Get-Content -LiteralPath $indexPath -Raw
    $linkMatches = [regex]::Matches($content, '\[[^\]]+\]\(\./([^)]+\.md)\)')

    $linkedFiles = @($linkMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $requirementFiles = @(
      Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs' 'requirements') -File -Filter '*.md' |
        Where-Object { $_.Name -ne 'index.md' } |
        ForEach-Object { $_.Name } |
        Sort-Object
    )

    $linkedFiles | Should -Be $requirementFiles

    foreach ($file in $linkedFiles) {
      Test-Path -LiteralPath (Join-Path $repoRoot 'docs' 'requirements' $file) | Should -BeTrue
    }
  }
}
