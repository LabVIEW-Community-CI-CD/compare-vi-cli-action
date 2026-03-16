Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Close-LabVIEW.ps1' -Tag 'Unit' {
  It 'forwards TimeoutSeconds and normalized parameters to Invoke-LVOperation' {
    $repoRoot = Join-Path $TestDrive 'repo'
    $toolsDir = Join-Path $repoRoot 'tools'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'tools' 'Close-LabVIEW.ps1') -Destination (Join-Path $toolsDir 'Close-LabVIEW.ps1') -Force

    $capturePath = Join-Path $repoRoot 'invoke-capture.json'
    $moduleStub = @"
function Invoke-LVOperation {
  param(
    [string]`$Operation,
    [hashtable]`$Params,
    [string]`$Provider = 'auto',
    [switch]`$Preview,
    [int]`$TimeoutSeconds = 300
  )

  [ordered]@{
    Operation      = `$Operation
    Params         = `$Params
    Provider       = `$Provider
    Preview        = `$Preview.IsPresent
    TimeoutSeconds = `$TimeoutSeconds
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath '$capturePath' -Encoding utf8

  return [pscustomobject]@{
    provider = 'stub'
    command  = 'stub-command'
    exitCode = 0
  }
}

Export-ModuleMember -Function Invoke-LVOperation
"@
    Set-Content -LiteralPath (Join-Path $toolsDir 'LabVIEWCli.psm1') -Value $moduleStub -Encoding UTF8

    $labviewExe = Join-Path $repoRoot 'LabVIEW.exe'
    Set-Content -LiteralPath $labviewExe -Value '' -Encoding ascii

    & pwsh -NoLogo -NoProfile -File (Join-Path $toolsDir 'Close-LabVIEW.ps1') `
      -LabVIEWExePath $labviewExe `
      -Provider stub-provider `
      -TimeoutSeconds 7 *> $null

    $LASTEXITCODE | Should -Be 0
    Test-Path -LiteralPath $capturePath | Should -BeTrue

    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 6
    $capture.Operation | Should -Be 'CloseLabVIEW'
    $capture.Provider | Should -Be 'stub-provider'
    $capture.TimeoutSeconds | Should -Be 7
    $capture.Preview | Should -BeFalse
    $capture.Params.labviewPath | Should -Be $labviewExe
  }
}
