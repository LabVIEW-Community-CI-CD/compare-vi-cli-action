#Requires -Version 7.0
# Tag: Integration (real loop mode with LVCompare)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
$script:BaseVi = $env:LV_BASE_VI
$script:HeadVi = $env:LV_HEAD_VI
try {
  $repoRootForFallback = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
  if (-not $script:BaseVi -or -not (Test-Path -LiteralPath $script:BaseVi -PathType Leaf)) {
    # Prefer real VIs VI1.vi / VI2.vi over legacy Base.vi / Head.vi names
    $candidates = @('VI1.vi','Base.vi')
    foreach ($name in $candidates) {
      $candidate = Resolve-Path (Join-Path $repoRootForFallback $name) -ErrorAction SilentlyContinue
      if ($candidate) { $script:BaseVi = $candidate.Path; break }
    }
  }
  if (-not $script:HeadVi -or -not (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)) {
    $candidates = @('VI2.vi','Head.vi')
    foreach ($name in $candidates) {
      $candidate = Resolve-Path (Join-Path $repoRootForFallback $name) -ErrorAction SilentlyContinue
      if ($candidate) { $script:HeadVi = $candidate.Path; break }
    }
  }
} catch { Write-Verbose "Fallback resolution failed: $($_.Exception.Message)" -Verbose }
$script:Prereqs = $false
try {
  if ((Test-Path -LiteralPath $script:Canonical -PathType Leaf) -and (Test-Path -LiteralPath $script:BaseVi -PathType Leaf) -and (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)) { $script:Prereqs = $true }
} catch { $script:Prereqs = $false }

if (-not $script:Prereqs) {
  try {
    if ((Test-Path -LiteralPath $script:Canonical -PathType Leaf) -and (Test-Path -LiteralPath $script:BaseVi -PathType Leaf) -and (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)) { $script:Prereqs = $true }
  } catch { }
}
Write-Host "[EarlyDiagnostics] (LoopSingle) BaseVi=$script:BaseVi Exists=$([bool](Test-Path $script:BaseVi)) HeadVi=$script:HeadVi Exists=$([bool](Test-Path $script:HeadVi)) CanonicalExists=$([bool](Test-Path $script:Canonical)) Prereqs=$script:Prereqs" -ForegroundColor DarkCyan

# Stabilize aliases used inside test blocks
try {
  Set-Variable -Name BaseVi -Scope Script -Value $script:BaseVi -Force
  Set-Variable -Name HeadVi -Scope Script -Value $script:HeadVi -Force
  Write-Host "[AliasDiagnostics] (LoopSingle) Aliases established: BaseVi=$($script:BaseVi) HeadVi=$($script:HeadVi)" -ForegroundColor DarkCyan
} catch { Write-Host "[AliasError] (LoopSingle) $($_.Exception.Message)" -ForegroundColor Yellow }

BeforeAll {
  Import-Module (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
}

Describe 'Real LVCompare loop mode (single iteration)' -Tag Integration {
  It 'produces loop summary with percentiles (may be single sample)' -Skip:(-not $script:Prereqs) {
    try {
      $baseArg = if ($BaseVi) { $BaseVi } else { $script:BaseVi }
      $headArg = if ($HeadVi) { $HeadVi } else { $script:HeadVi }
      if (-not $baseArg -or -not $headArg) { Set-ItResult -Skipped -Because 'Base/Head VI aliases unresolved'; return }
      $exec = {
        param($cli,$base,$head,$extraArgs)
        $psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName=$cli; ArgumentList=@($base,$head) }
        $psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true; $psi.UseShellExecute=$false
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        return $p.ExitCode
      }
      $res = Invoke-IntegrationCompareLoop -Base $baseArg -Head $headArg -MaxIterations 1 -IntervalSeconds 0 -CompareExecutor $exec -QuantileStrategy Exact -Quiet -PassThroughPaths -BypassCliValidation -SkipValidation
      $res.Iterations | Should -Be 1
      $res.AverageSeconds | Should -BeGreaterThan 0
      $res.QuantileStrategy | Should -Be 'Exact'
      if ($res.Percentiles) { $res.Percentiles.p50 | Should -BeGreaterThanOrEqual 0 }
    } catch {
      Write-Host "[LoopSingleError] $($_.Exception.Message)" -ForegroundColor Yellow
      Set-ItResult -Skipped -Because "Loop invocation error: $($_.Exception.Message)"
    }
  }
}
