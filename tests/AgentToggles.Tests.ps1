Describe 'Agent toggle manifest' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Get-Location).Path
    $distCli = Join-Path $repoRoot 'dist' 'src' 'config' 'toggles-cli.js'
    if (-not (Test-Path -LiteralPath $distCli -PathType Leaf)) {
      Push-Location $repoRoot
      try {
        npm run build --silent | Out-Null
      } finally {
        Pop-Location
      }
    }

    $modulePath = Join-Path $repoRoot 'tools' 'AgentToggles.psm1'
    Import-Module $modulePath -Force
  }

  It 'resolves default boolean toggles' {
    $value = Get-AgentToggleValue -Key 'SKIP_SYNC_DEVELOP' -AsBoolean
    $value | Should -BeFalse
  }

  It 'applies profile overlays' {
    $value = Get-AgentToggleValue -Key 'HANDOFF_AUTOTRIM' -Profiles 'ci-orchestrated' -AsBoolean
    $value | Should -BeTrue
  }

  It 'prefers environment overrides' {
    $previous = [Environment]::GetEnvironmentVariable('LV_SUPPRESS_UI')
    try {
      [Environment]::SetEnvironmentVariable('LV_SUPPRESS_UI', '0')
      $value = Get-AgentToggleValue -Key 'LV_SUPPRESS_UI' -AsBoolean
      $value | Should -BeFalse
    } finally {
      if ($null -eq $previous) {
        [Environment]::SetEnvironmentVariable('LV_SUPPRESS_UI', $null)
      } else {
        [Environment]::SetEnvironmentVariable('LV_SUPPRESS_UI', $previous)
      }
    }
  }
}
