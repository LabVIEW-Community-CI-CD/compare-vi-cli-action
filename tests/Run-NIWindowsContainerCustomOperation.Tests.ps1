#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Run-NIWindowsContainerCustomOperation.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:RunnerScript = Join-Path $script:RepoRoot 'tools' 'Run-NIWindowsContainerCustomOperation.ps1'
    if (-not (Test-Path -LiteralPath $script:RunnerScript -PathType Leaf)) {
      throw "Run-NIWindowsContainerCustomOperation.ps1 not found at $script:RunnerScript"
    }
  }

  It 'writes a probe-ok capture from a stub preflight contract' {
    $resultsRoot = Join-Path $TestDrive 'results-root'
    $preflightScript = Join-Path $TestDrive 'Stub-WindowsPreflight.ps1'
    Set-Content -LiteralPath $preflightScript -Encoding utf8 -Value @'
param(
  [string]$Image,
  [string]$ResultsDir
)
$resolvedResultsDir = [System.IO.Path]::GetFullPath($ResultsDir)
if (-not (Test-Path -LiteralPath $resolvedResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resolvedResultsDir -Force | Out-Null
}
$reportPath = Join-Path $resolvedResultsDir 'windows-ni-2026q1-host-preflight.json'
[ordered]@{
  schema = 'docker-runtime-manager@v1'
  contexts = [ordered]@{
    final = 'desktop-windows'
    finalOsType = 'windows'
  }
  probes = [ordered]@{
    windows = [ordered]@{
      status = 'success'
      image = $Image
    }
  }
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Output $reportPath
'@

    $output = & pwsh -NoLogo -NoProfile -File $script:RunnerScript `
      -Probe `
      -ResultsRoot $resultsRoot `
      -PreflightScriptPath $preflightScript *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $capturePath = Join-Path $resultsRoot 'ni-windows-custom-operation-capture.json'
    $capturePath | Should -Exist
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 12
    $capture.schema | Should -Be 'ni-windows-container-custom-operation/v1'
    $capture.status | Should -Be 'probe-ok'
    $capture.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
    $capture.dockerServerOs | Should -Be 'windows'
    $capture.dockerContext | Should -Be 'desktop-windows'
    $capture.preflightPath | Should -Match 'windows-ni-2026q1-host-preflight\.json$'
  }

  It 'keeps the in-container command on native powershell instead of pwsh' {
    $scriptText = Get-Content -LiteralPath $script:RunnerScript -Raw

    $scriptText | Should -Match 'powershell -NoLogo -NoProfile -EncodedCommand'
    $scriptText | Should -Match '\$dockerArgs \+= @\(\s*\$Image,\s*''powershell'',\s*''-NoLogo'',\s*''-NoProfile'',\s*''-EncodedCommand'''
    $scriptText | Should -Not -Match '\$dockerArgs \+= @\(\s*\$Image,\s*''pwsh'''
  }
}
