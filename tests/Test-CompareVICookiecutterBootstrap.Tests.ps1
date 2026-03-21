Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Test-CompareVICookiecutterBootstrap.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ProofScript = Join-Path $script:RepoRoot 'tools' 'Test-CompareVICookiecutterBootstrap.ps1'
    if (-not (Test-Path -LiteralPath $script:ProofScript -PathType Leaf)) {
      throw "Test-CompareVICookiecutterBootstrap.ps1 not found at $script:ProofScript"
    }
  }

  It 'runs the shared cookiecutter bootstrap proof and writes a validated receipt' {
    $proofRoot = Join-Path $TestDrive 'proof'
    $runtimeCacheRoot = Join-Path $TestDrive 'runtime'
    $scaffoldRoot = Join-Path $TestDrive 'scaffolds'
    $receiptPath = Join-Path $proofRoot 'bootstrap-proof.json'

    $output = & $script:ProofScript `
      -Platform $(if ($IsWindows) { 'windows' } else { 'linux' }) `
      -ProofRoot $proofRoot `
      -CookiecutterCacheRoot $runtimeCacheRoot `
      -ScaffoldOutputRoot $scaffoldRoot `
      -ReceiptPath $receiptPath 2>&1

    $LASTEXITCODE | Should -Be 0 -Because (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $proof = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
    $proof.schema | Should -Be 'comparevi-cookiecutter-bootstrap-proof@v1'
    $proof.status | Should -Be 'succeeded'
    $proof.platform | Should -Be $(if ($IsWindows) { 'windows' } else { 'linux' })
    $proof.runtimeCacheRoot | Should -Be $runtimeCacheRoot
    $proof.templateRuns.Count | Should -Be 2
    @($proof.templateRuns.templateId) | Should -Contain 'scenario-pack'
    @($proof.templateRuns.templateId) | Should -Contain 'corpus-seed'
    $proof.pythonExecutable | Should -Exist
    $receiptPath | Should -Exist

    foreach ($templateRun in $proof.templateRuns) {
      $templateRun.receiptPath | Should -Exist
      $templateRun.destinationPath | Should -Exist
      [int]$templateRun.generatedFileCount | Should -BeGreaterThan 0
    }
  }
}
