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

  It 'includes manifest digest in payload' {
    $payload = Get-AgentToggleValues
    $payload.manifestDigest | Should -Match '^[a-f0-9]{64}$'
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

  It 'detects unexpected environment overrides when strict' {
    $previous = [Environment]::GetEnvironmentVariable('SKIP_SYNC_DEVELOP')
    try {
      [Environment]::SetEnvironmentVariable('SKIP_SYNC_DEVELOP', '1')
      { Assert-AgentToggleDeterminism } | Should -Throw
    } finally {
      if ($null -eq $previous) {
        [Environment]::SetEnvironmentVariable('SKIP_SYNC_DEVELOP', $null)
      } else {
        [Environment]::SetEnvironmentVariable('SKIP_SYNC_DEVELOP', $previous)
      }
    }
  }

  It 'permits overrides when allowed' {
    $previous = [Environment]::GetEnvironmentVariable('SKIP_SYNC_DEVELOP')
    try {
      [Environment]::SetEnvironmentVariable('SKIP_SYNC_DEVELOP', '1')
      $payload = Assert-AgentToggleDeterminism -AllowEnvironmentOverrides
      $payload.values.SKIP_SYNC_DEVELOP.source | Should -Be 'environment'
    } finally {
      if ($null -eq $previous) {
        [Environment]::SetEnvironmentVariable('SKIP_SYNC_DEVELOP', $null)
      } else {
        [Environment]::SetEnvironmentVariable('SKIP_SYNC_DEVELOP', $previous)
      }
    }
  }
}
