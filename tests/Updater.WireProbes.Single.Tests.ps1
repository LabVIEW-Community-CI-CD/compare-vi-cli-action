Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Updater wire probes single-path injection' -Tag 'Unit' {
  BeforeAll {
    $root = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:Updater = (Join-Path $root 'tools' 'workflows' 'update_workflows.py')
    if (-not (Test-Path -LiteralPath $script:Updater)) { throw "Updater script not found: $script:Updater" }
  }

  It 'injects probes in windows-single job and remains idempotent' {
    $wf = @'
name: CI Orchestrated (single synthetic)
on: { workflow_dispatch: {} }
jobs:
  windows-single:
    runs-on: [self-hosted, Windows, X64]
    steps:
    - uses: actions/checkout@v5
    - name: Ensure Invoker (start)
      uses: ./.github/actions/ensure-invoker
      with: { mode: start }
    - name: Runner Unblock Guard
      uses: ./.github/actions/runner-unblock-guard
    - name: Drift (fixture)
      uses: ./.github/actions/fixture-drift
    - name: Ensure Invoker (stop)
      uses: ./.github/actions/ensure-invoker
      with: { mode: stop }
    - name: Session index post (single)
      uses: ./.github/actions/session-index-post
    - name: Append final summary (single)
      run: echo summary
'@
    $tempPath = Join-Path $TestDrive 'ci-orchestrated.yml'
    Set-Content -LiteralPath $tempPath -Value $wf -Encoding UTF8
    & python $script:Updater --write $tempPath | Out-Null
    & python $script:Updater --write $tempPath | Out-Null
    $doc = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Yaml
    $getName = {
      param($step)
      if ($null -eq $step) { return $null }
      if ($step -is [System.Collections.IDictionary]) {
        if ($step.Contains('name')) { return [string]$step['name'] }
        return $null
      }
      $prop = $step.PSObject.Properties['name']
      if ($prop) { return [string]$prop.Value }
      return $null
    }
    $steps = $doc.jobs.'windows-single'.steps
    $names = @($steps | ForEach-Object { & $getName $_ }) | Where-Object { $_ }
    (@($names | Where-Object { $_ -eq 'Wire Probe (J1)' })).Count | Should -Be 1
    (@($names | Where-Object { $_ -eq 'Wire Probe (J2)' })).Count | Should -Be 1
    (@($names | Where-Object { $_ -eq 'Wire Session Index (S1)' })).Count | Should -Be 1
    (@($names | Where-Object { $_ -eq 'Wire Invoker (start)' })).Count | Should -Be 1
    (@($names | Where-Object { $_ -eq 'Wire Invoker (stop)' })).Count | Should -Be 1
    (@($names | Where-Object { $_ -eq 'Wire Guard (pre)' })).Count | Should -Be 1
    (@($names | Where-Object { $_ -eq 'Wire Guard (post)' })).Count | Should -Be 1
    (@($names | Where-Object { $_ -eq 'Wire Probe (P1)' })).Count | Should -Be 1
    $j1 = $null; $j2 = $null
    foreach ($step in $steps) {
      $name = & $getName $step
      if ($name -eq 'Wire Probe (J1)') { $j1 = $step }
      elseif ($name -eq 'Wire Probe (J2)') { $j2 = $step }
    }
    $j1 | Should -Not -BeNullOrEmpty
    $j2 | Should -Not -BeNullOrEmpty
    $j1If = if ($j1 -is [System.Collections.IDictionary]) { $j1['if'] } else { $j1.if }
    $j2If = if ($j2 -is [System.Collections.IDictionary]) { $j2['if'] } else { $j2.if }
    $j1If | Should -Not -BeNullOrEmpty
    $j2If | Should -Not -BeNullOrEmpty
    $j1If | Should -Match 'WIRE_PROBES'
    $j2If | Should -Match 'WIRE_PROBES'
  }
}
