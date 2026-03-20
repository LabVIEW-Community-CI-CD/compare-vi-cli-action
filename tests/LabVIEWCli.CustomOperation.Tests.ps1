Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-LVCustomOperation' -Tag 'Unit' {
  BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'tools' 'LabVIEWCli.psm1'
    Import-Module $modulePath -Force
  }

  It 'returns a preview command for a custom operation through the shared abstraction' {
    $previousCli = $env:LABVIEWCLI_PATH
    $cliPath = Join-Path $TestDrive 'LabVIEWCLI.exe'
    $labviewPath = Join-Path $TestDrive 'LabVIEW.exe'
    $operationRoot = Join-Path $TestDrive 'AddTwoNumbers'
    Set-Content -LiteralPath $cliPath -Value '' -Encoding utf8
    Set-Content -LiteralPath $labviewPath -Value '' -Encoding utf8
    New-Item -ItemType Directory -Path $operationRoot -Force | Out-Null
    Set-Item Env:LABVIEWCLI_PATH $cliPath

    try {
      $preview = Invoke-LVCustomOperation `
        -CustomOperationName 'AddTwoNumbers' `
        -AdditionalOperationDirectory $operationRoot `
        -Arguments @('-x', '1', '-y', '2') `
        -Headless `
        -LogToConsole `
        -LabVIEWPath $labviewPath `
        -Provider 'labviewcli' `
        -Preview

      $preview | Should -Not -BeNullOrEmpty
      $preview.operation | Should -Be 'RunCustomOperation'
      $preview.provider | Should -Be 'labviewcli'
      $preview.args | Should -Contain '-AdditionalOperationDirectory'
      $preview.args | Should -Contain '-Headless'
      $preview.args | Should -Contain '-LogToConsole'
      $preview.args | Should -Contain '-x'
    } finally {
      if ($previousCli) {
        Set-Item Env:LABVIEWCLI_PATH $previousCli
      } else {
        Remove-Item Env:LABVIEWCLI_PATH -ErrorAction SilentlyContinue
      }
    }
  }
}
