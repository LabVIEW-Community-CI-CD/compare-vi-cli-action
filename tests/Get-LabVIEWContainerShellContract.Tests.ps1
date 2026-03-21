Describe 'Get-LabVIEWContainerShellContract' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Get-LabVIEWContainerShellContract.ps1'
    $contractPath = Join-Path $repoRoot 'tools/policy/labview-container-shell-contract.json'
  }

  It 'returns the repository Windows shell contract' {
    $contract = & $scriptPath -Plane windows -ContractPath $contractPath

    $contract.plane | Should -Be 'windows'
    $contract.executable | Should -Be 'powershell'
    $contract.family | Should -Be 'windows-powershell'
    $contract.encodedCommand | Should -BeTrue
    $contract.pwshRequired | Should -BeFalse
    $contract.hostWrapperShell | Should -Be 'pwsh'
  }

  It 'returns the repository Linux shell contract' {
    $contract = & $scriptPath -Plane linux -ContractPath $contractPath

    $contract.plane | Should -Be 'linux'
    $contract.executable | Should -Be 'bash'
    $contract.family | Should -Be 'posix-bash'
    $contract.encodedCommand | Should -BeFalse
    $contract.pwshRequired | Should -BeFalse
    $contract.hostWrapperShell | Should -Be 'pwsh'
  }

  It 'fails closed when the contract schema drifts' {
    $badContractPath = Join-Path $TestDrive 'labview-container-shell-contract.json'
    @'
{
  "schema": "unexpected/v1",
  "hostWrapperShell": "pwsh",
  "planes": {
    "windows": {
      "executable": "powershell",
      "family": "windows-powershell",
      "encodedCommand": true,
      "pwshRequired": false
    }
  }
}
'@ | Set-Content -LiteralPath $badContractPath -Encoding utf8

    {
      & $scriptPath -Plane windows -ContractPath $badContractPath
    } | Should -Throw '*Unexpected LabVIEW container shell contract schema*'
  }
}
