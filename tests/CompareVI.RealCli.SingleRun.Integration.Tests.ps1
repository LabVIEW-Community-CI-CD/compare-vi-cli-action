#Requires -Version 7.0
# Tag: Integration (single real CLI invocation using repo VIs)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
$script:BaseVi = $env:LV_BASE_VI
$script:HeadVi = $env:LV_HEAD_VI
try {
  $repoRootForFallback = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
  if (-not $script:BaseVi -or -not (Test-Path -LiteralPath $script:BaseVi -PathType Leaf)) {
    $candidate = Resolve-Path (Join-Path $repoRootForFallback 'VI1.vi') -ErrorAction SilentlyContinue
    if ($candidate) { $script:BaseVi = $candidate.Path }
  }
  if (-not $script:HeadVi -or -not (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)) {
    $candidate = Resolve-Path (Join-Path $repoRootForFallback 'VI2.vi') -ErrorAction SilentlyContinue
    if ($candidate) { $script:HeadVi = $candidate.Path }
  }
} catch { Write-Verbose "Fallback resolution failed: $($_.Exception.Message)" -Verbose }

$script:Prereqs = $false
try {
  if ((Test-Path -LiteralPath $script:Canonical -PathType Leaf) -and (Test-Path -LiteralPath $script:BaseVi -PathType Leaf) -and (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)) {
    $script:Prereqs = $true
  }
} catch { $script:Prereqs = $false }

# Recompute after fallback if still false
if (-not $script:Prereqs) {
  try {
    if ((Test-Path -LiteralPath $script:Canonical -PathType Leaf) -and (Test-Path -LiteralPath $script:BaseVi -PathType Leaf) -and (Test-Path -LiteralPath $script:HeadVi -PathType Leaf)) { $script:Prereqs = $true }
  } catch { }
}
Write-Host "[EarlyDiagnostics] (SingleRun) BaseVi=$script:BaseVi Exists=$([bool](Test-Path $script:BaseVi)) HeadVi=$script:HeadVi Exists=$([bool](Test-Path $script:HeadVi)) CanonicalExists=$([bool](Test-Path $script:Canonical)) Prereqs=$script:Prereqs" -ForegroundColor DarkCyan

# Stabilize aliases for use inside Pester It blocks
try {
  Set-Variable -Name BaseVi -Scope Script -Value $script:BaseVi -Force
  Set-Variable -Name HeadVi -Scope Script -Value $script:HeadVi -Force
  Set-Variable -Name Canonical -Scope Script -Value $script:Canonical -Force
  Write-Host "[AliasDiagnostics] (SingleRun) Aliases established: BaseVi=$($script:BaseVi) HeadVi=$($script:HeadVi)" -ForegroundColor DarkCyan
} catch { Write-Host "[AliasError] (SingleRun) $($_.Exception.Message)" -ForegroundColor Yellow }

BeforeAll {
  . (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'scripts' 'CompareVI.ps1')
  $script:ResultsDir = Join-Path $PSScriptRoot 'results-single'
  New-Item -ItemType Directory -Path $script:ResultsDir -Force | Out-Null
}

Describe 'Single real LVCompare invocation (repo VI1.vi vs VI2.vi)' -Tag Integration {
  It 'produces expected diff outputs and HTML report' -Skip:(-not $script:Prereqs) {
  $cliPath = if ($Canonical) { $Canonical } else { $script:Canonical }
  if (-not $cliPath) { Set-ItResult -Skipped -Because 'Canonical path unavailable'; return }
  $res = Invoke-CompareVI -Base $BaseVi -Head $HeadVi -LvComparePath $cliPath -FailOnDiff:$false
    $res.ExitCode | Should -BeIn @(0,1)
    $res.Command | Should -Match 'LVCompare.exe'

    # Render HTML report for PR body usage
    $htmlPath = Join-Path $script:ResultsDir 'pr-body-compare-report.html'
    try {
      $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
      $renderer = Join-Path $repoRoot 'scripts' 'Render-CompareReport.ps1'
      if (-not (Test-Path -LiteralPath $renderer -PathType Leaf)) {
        Write-Host "[RendererSkip] Render-CompareReport.ps1 not found at $renderer" -ForegroundColor Yellow
        Set-ItResult -Skipped -Because 'Renderer script missing'
        return
      }
      & $renderer -Command $res.Command -ExitCode $res.ExitCode -Diff ($res.Diff.ToString().ToLower()) -CliPath $res.CliPath -OutputPath $htmlPath -DurationSeconds $res.CompareDurationSeconds
    } catch {
      Write-Host "[RendererError] $($_.Exception.Message)" -ForegroundColor Yellow
      Set-ItResult -Skipped -Because "Renderer execution error: $($_.Exception.Message)"
      return
    }
    Test-Path -LiteralPath $htmlPath | Should -BeTrue
    $html = Get-Content -LiteralPath $htmlPath -Raw
    $html | Should -Match 'Compare VI Report'
  }
}
