Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Cross-repo VI history docs' -Tag 'CompareVI' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $crossRepoDocPath = Join-Path $repoRoot 'docs' 'knowledgebase' 'CrossRepo-VIHistory.md'
    $readmePath = Join-Path $repoRoot 'README.md'

    $crossRepoDocPath | Should -Exist
    $readmePath | Should -Exist

    $script:crossRepoDoc = Get-Content -LiteralPath $crossRepoDocPath -Raw
    $script:readme = Get-Content -LiteralPath $readmePath -Raw
  }

  It 'documents the canonical downstream demo consumer for the local-first loop' {
    $script:crossRepoDoc | Should -Match 'LabVIEW-Community-CI-CD/labview-icon-editor-demo'
    $script:crossRepoDoc | Should -Match 'comparevi-history'
    $script:crossRepoDoc | Should -Match 'local-review'
    $script:crossRepoDoc | Should -Match 'local-proof'
    $script:crossRepoDoc | Should -Match 'priority:vi-history:budget'
    $script:crossRepoDoc | Should -Match 'cross-plane-performance-budget\.json'
    $script:crossRepoDoc | Should -Match 'develop'
    $script:crossRepoDoc | Should -Match 'VIP_Post-Install Custom Action\.vi'
  }

  It 'points README guidance at the downstream demo proof surface' {
    $script:readme | Should -Match 'LabVIEW-Community-CI-CD/labview-icon-editor-demo'
    $script:readme | Should -Match 'CrossRepo-VIHistory\.md'
  }
}
