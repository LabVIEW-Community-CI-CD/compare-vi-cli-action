Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Get-FixtureDriftComment' -Tag 'Unit' {
  BeforeAll {
    $script:FixtureDriftSetupError = $null
    $script:FixtureDriftDiagnostics = @{}

    # Initialize locals so StrictMode catch diagnostics do not fault when early setup fails
    $scriptPathCandidates = @()
    $repoCandidatePaths = @()
    $scriptPath = $null
    $repoRoot = $null
    $modulePath = $null

    try {
      if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $scriptPathCandidates += $PSCommandPath
      }
      if ($null -ne $MyInvocation -and $null -ne $MyInvocation.MyCommand) {
        $commandInfo = $MyInvocation.MyCommand
        $pathProp = $commandInfo.PSObject.Properties['Path']
        if ($pathProp -and -not [string]::IsNullOrWhiteSpace($pathProp.Value)) {
          $scriptPathCandidates += [string]$pathProp.Value
        }
      }
      if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $scriptPathCandidates += (Join-Path $PSScriptRoot 'FixtureDrift.Comment.Tests.ps1')
      }
      if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
        $scriptPathCandidates += (Join-Path $env:GITHUB_WORKSPACE 'tests' 'FixtureDrift.Comment.Tests.ps1')
      }

      $scriptPathCandidates = $scriptPathCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

      Write-Host "[FixtureDrift] scriptPath candidates: $($scriptPathCandidates -join ', ')" -ForegroundColor DarkCyan

      $scriptPath = $scriptPathCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
      if (-not $scriptPath) {
        throw [System.InvalidOperationException]::new('Unable to resolve script path for FixtureDrift.Comment tests.')
      }

      $testDir = Split-Path -Parent $scriptPath
      $repoCandidatePaths = @(
        (Join-Path $testDir '..'),
        $env:GITHUB_WORKSPACE
      ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

      Write-Host "[FixtureDrift] repo candidates: $($repoCandidatePaths -join ', ')" -ForegroundColor DarkCyan

      $repoRoot = $null
      foreach ($candidate in $repoCandidatePaths) {
        if (Test-Path -LiteralPath $candidate) {
          $resolved = Resolve-Path $candidate -ErrorAction SilentlyContinue
          if ($resolved) {
            $repoRoot = $resolved.ProviderPath
            break
          }
        }
      }
      if (-not $repoRoot) {
        throw [System.InvalidOperationException]::new('Unable to resolve repository root for FixtureDrift.Comment tests.')
      }

      $modulePath = Join-Path $repoRoot 'scripts' 'Build-FixtureDriftComment.ps1'

      if (-not (Test-Path -LiteralPath $modulePath)) {
        throw [System.IO.FileNotFoundException]::new("Fixture drift helper not found", $modulePath)
      }

      Write-Host "[FixtureDrift] scriptPath=$scriptPath" -ForegroundColor Cyan
      Write-Host "[FixtureDrift] repoRoot=$repoRoot" -ForegroundColor Cyan
      Write-Host "[FixtureDrift] modulePath=$modulePath" -ForegroundColor Cyan

      $script:FixtureDriftDiagnostics = [pscustomobject]@{
        ScriptPathCandidates = $scriptPathCandidates
        RepoCandidates       = $repoCandidatePaths
        SelectedScriptPath   = $scriptPath
        SelectedRepoRoot     = $repoRoot
        ModulePath           = $modulePath
      }

      . "$modulePath"
    } catch {
      $err = $_
      $diagnostics = @()
      if ($scriptPathCandidates) {
        $diagnostics += "scriptPathCandidates=[$($scriptPathCandidates -join ', ')]"
      }
      if ($repoCandidatePaths) {
        $diagnostics += "repoCandidates=[$($repoCandidatePaths -join ', ')]"
      }
      if ($scriptPath) {
        $diagnostics += "selectedScriptPath=$scriptPath"
      }
      if ($repoRoot) {
        $diagnostics += "selectedRepoRoot=$repoRoot"
      }
      $diagnosticText = if ($diagnostics) { ' | ' + ($diagnostics -join ' | ') } else { [string]::Empty }
      $msg = "Fixture drift test setup failed: {0}{1}" -f ($err.Exception.Message ?? $err.ToString()), $diagnosticText
      Write-Warning $msg
      $script:FixtureDriftSetupError = $msg
    }
  }

  It 'embeds sanitized HTML report inline' {
    if ($script:FixtureDriftSetupError) {
      throw $script:FixtureDriftSetupError
    }
    $reportPath = Join-Path $TestDrive 'report.html'
    Set-Content -LiteralPath $reportPath -Value "<html><body><h1>Title & < > ' `"</h1></body></html>" -Encoding utf8

    $result = Get-FixtureDriftComment -Marker '<!-- marker -->' -Status 'drift' -ExitCode '1' -RunUrl 'https://example/run' -ArtifactNames @('fixture-drift') -ArtifactPaths @('results/fixture-drift/compare-report.html') -ReportPath $reportPath
    $result | Should -Match '<details><summary>Fixture Drift HTML report \(inline preview\)</summary>'
    $result | Should -Match '&amp;'
    $result | Should -Match '&lt;'
    $result | Should -Match '&quot;'
    $result | Should -Match '&#39;'
    $result | Should -Not -Match '<html>'
  }

  It 'truncates large HTML' {
    if ($script:FixtureDriftSetupError) {
      throw $script:FixtureDriftSetupError
    }
    $reportPath = Join-Path $TestDrive 'report-large.html'
    $html = '<p>' + ('A' * 25000) + '</p>'
    Set-Content -LiteralPath $reportPath -Value $html -Encoding utf8

    $result = Get-FixtureDriftComment -Marker '<!-- marker -->' -Status 'drift' -ExitCode '1' -RunUrl 'https://example/run' -ReportPath $reportPath
    $result | Should -Match '\.\.\. \(truncated\)'
  }
}
