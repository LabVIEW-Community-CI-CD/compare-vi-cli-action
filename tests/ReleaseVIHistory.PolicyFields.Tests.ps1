Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Get-ReleaseVIHistoryPolicyFields.ps1' -Tag 'Unit' {
  It 'extracts fields from an explicit policy file path' {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $root 'tools/Get-ReleaseVIHistoryPolicyFields.ps1'

    $policyPath = Join-Path $TestDrive 'release-vi-history-policy.json'
    @{
      tagClass = 'stable'
      enforcementSource = 'migration.tagClassEnforcement.stable'
      enforcementMode = 'hard'
      rawOutcome = 'pass'
      outcome = 'pass'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $policyPath -Encoding utf8

    $result = & $scriptPath -PolicySummaryPath $policyPath
    $result.tagClass | Should -Be 'stable'
    $result.enforcementSource | Should -Be 'migration.tagClassEnforcement.stable'
    $result.enforcementMode | Should -Be 'hard'
    $result.rawOutcome | Should -Be 'pass'
    $result.outcome | Should -Be 'pass'
    $result.policyPath | Should -Be (Resolve-Path -LiteralPath $policyPath).Path
  }

  It 'resolves latest policy file under search root when path is omitted' {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $root 'tools/Get-ReleaseVIHistoryPolicyFields.ps1'

    $olderDir = Join-Path $TestDrive 'older'
    $newerDir = Join-Path $TestDrive 'newer'
    New-Item -ItemType Directory -Path $olderDir -Force | Out-Null
    New-Item -ItemType Directory -Path $newerDir -Force | Out-Null

    $olderPath = Join-Path $olderDir 'release-vi-history-policy.json'
    $newerPath = Join-Path $newerDir 'release-vi-history-policy.json'

    @{
      tagClass = 'rc'
      enforcementSource = 'migration.tagClassEnforcement.rc'
      enforcementMode = 'soft'
      rawOutcome = 'warn'
      outcome = 'warn'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $olderPath -Encoding utf8

    Start-Sleep -Milliseconds 50

    @{
      tagClass = 'stable'
      enforcementSource = 'migration.tagClassEnforcement.stable'
      enforcementMode = 'hard'
      rawOutcome = 'pass'
      outcome = 'pass'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $newerPath -Encoding utf8

    $result = & $scriptPath -SearchRoot $TestDrive
    $result.tagClass | Should -Be 'stable'
    $result.enforcementMode | Should -Be 'hard'
    $result.policyPath | Should -Be $newerPath
  }
}