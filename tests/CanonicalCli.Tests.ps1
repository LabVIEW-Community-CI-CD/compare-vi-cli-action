Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..') | Select-Object -ExpandProperty Path
$modulePath = Join-Path $repoRoot 'module' 'CompareLoop' 'CompareLoop.psd1'
Import-Module $modulePath -Force

Describe 'Test-CanonicalCli helper' -Tag 'Unit' {
  Context 'when canonical path missing' {
    It 'throws if executable not found' {
      # Retrieve existing value from module scope
      $moduleScriptScope = (Get-Module CompareLoop).SessionState
      $orig = $moduleScriptScope.PSVariable.Get('CanonicalLVCompare').Value
      try {
        $moduleScriptScope.PSVariable.Set('CanonicalLVCompare','Z:\__missing__\LVCompare.exe')
      { Test-CanonicalCli } | Should -Throw '*not found*'
      } finally {
        if ($orig) { $moduleScriptScope.PSVariable.Set('CanonicalLVCompare',$orig) }
      }
    }
  }
}

Describe 'Real CLI integration (placeholder)' -Tag 'Integration','CLI' {
  It 'invokes loop once against provided base/head paths (skipped if files or CLI absent)' -Skip:(-not (Test-Path 'C:\repos\main\ControlLoop.vi')) {
    $base = 'C:\repos\main\ControlLoop.vi'
    $head = 'C:\repos\feature\ControlLoop.vi'
    if (-not (Test-Path $head)) { Set-ItResult -Skipped -Reason 'Head VI path not present' ; return }
    # Require canonical executable for real run
    $exe = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
    if (-not (Test-Path $exe)) { Set-ItResult -Skipped -Reason 'LVCompare.exe not installed at canonical path' ; return }
    $r = Invoke-IntegrationCompareLoop -Base $base -Head $head -MaxIterations 1 -IntervalSeconds 0 -Quiet -FailOnDiff
    $r.Iterations | Should -Be 1
  }
}
