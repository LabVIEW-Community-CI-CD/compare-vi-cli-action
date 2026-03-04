Describe 'Requirements coverage companion' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $requirementsDoc = Join-Path $repoRoot 'docs/requirements/DOTNET_CLI_RELEASE_ASSET.md'
    $mappingDoc = Join-Path $repoRoot 'docs/requirements/DOTNET_CLI_POWERSHELL_MAPPING.md'
  }

  It 'documents preflight and diagnostics command contract' {
    # REQ:CLI-FR-001
    # REQ:CLI-FR-002
    $content = Get-Content -LiteralPath $requirementsDoc -Raw
    $content | Should -Match 'preflight'
    $content | Should -Match 'diagnostics'
  }

  It 'documents single compare mode contract and mapping requirement' {
    # REQ:CLI-FR-010
    # REQ:CLI-FR-011
    $content = Get-Content -LiteralPath $requirementsDoc -Raw
    $content | Should -Match 'compare single'
    $content | Should -Match 'mode'
    $content | Should -Match 'DOTNET_CLI_POWERSHELL_MAPPING\.md'
  }

  It 'documents range sequential contract and max-pairs behavior' {
    # REQ:CLI-FR-020
    # REQ:CLI-FR-021
    # REQ:CLI-FR-022
    $content = Get-Content -LiteralPath $requirementsDoc -Raw
    $content | Should -Match 'range-based'
    $content | Should -Match 'sequential'
    $content | Should -Match '--max-pairs'
  }

  It 'documents report and image index outputs in requirement contract' {
    # REQ:CLI-FR-030
    # REQ:CLI-FR-031
    # REQ:CLI-FR-041
    $content = Get-Content -LiteralPath $requirementsDoc -Raw
    $content | Should -Match 'HTML report'
    $content | Should -Match 'image index'
    $content | Should -Match 'outcome\.class'
  }

  It 'keeps requirements and mapping documentation deliverables in place' {
    # REQ:AC-001
    # REQ:AC-002
    Test-Path -LiteralPath $requirementsDoc | Should -BeTrue
    Test-Path -LiteralPath $mappingDoc | Should -BeTrue
  }

  It 'documents exit classification and legacy compatibility options' {
    # REQ:CLI-FR-040
    # REQ:CLI-FR-042
    $content = Get-Content -LiteralPath $requirementsDoc -Raw
    $content | Should -Match 'diff-only outcomes are pass-class'
    $content | Should -Match 'legacy exit-code compatibility option'
  }

  It 'documents timing telemetry and aggregate percentile expectations' {
    # REQ:CLI-FR-050
    # REQ:CLI-FR-051
    $content = Get-Content -LiteralPath $requirementsDoc -Raw
    $content | Should -Match 'per-item timing'
    $content | Should -Match 'p50'
    $content | Should -Match 'p90'
    $content | Should -Match 'p95'
  }

  It 'documents headless and non-interactive policy requirements' {
    # REQ:CLI-FR-060
    # REQ:CLI-FR-061
    # REQ:CLI-NFR-020
    $content = Get-Content -LiteralPath $requirementsDoc -Raw
    $content | Should -Match 'headless opt-in'
    $content | Should -Match 'fail fast'
    $content | Should -Match 'fail instead of prompting'
  }

  It 'documents release asset integrity and follow-up implementation scope' {
    # REQ:CLI-REL-001
    # REQ:CLI-REL-002
    # REQ:CLI-REL-003
    # REQ:CLI-REL-004
    # REQ:CLI-REL-010
    # REQ:AC-003
    # REQ:AC-004
    $releaseChecklist = Join-Path $repoRoot 'docs/requirements/DOTNET_CLI_RELEASE_CHECKLIST.md'
    $followupDraft = Join-Path $repoRoot 'docs/requirements/DOTNET_CLI_FOLLOWUP_IMPLEMENTATION_ISSUES.md'
    $checklistContent = Get-Content -LiteralPath $releaseChecklist -Raw
    $checklistContent | Should -Match 'SHA-256'
    $checklistContent | Should -Match 'SBOM'
    $checklistContent | Should -Match 'Provenance'
    $checklistContent | Should -Match 'naming'
    Test-Path -LiteralPath $followupDraft | Should -BeTrue
  }

  It 'documents reproducibility metadata signing and schema evolution non-functional requirements' {
    # REQ:CLI-NFR-001
    # REQ:CLI-NFR-002
    # REQ:CLI-NFR-010
    # REQ:CLI-NFR-030
    $content = Get-Content -LiteralPath $requirementsDoc -Raw
    $content | Should -Match 'Build inputs shall be reproducible'
    $content | Should -Match 'build metadata'
    $content | Should -Match 'cryptographically signed and verifiable'
    $content | Should -Match 'schema evolution shall be additive'
  }
}
