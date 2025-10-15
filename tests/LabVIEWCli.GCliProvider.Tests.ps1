Set-StrictMode -Version Latest

Describe 'LabVIEW CLI g-cli provider' -Tag 'Unit' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/providers/gcli/Provider.psm1'
    $script:ProviderModule = Import-Module $modulePath -Force -PassThru
    $script:Provider = New-LVProvider
  }

  AfterAll {
    if ($script:ProviderModule) {
      Remove-Module $script:ProviderModule -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name Provider -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name ProviderModule -Scope Script -ErrorAction SilentlyContinue
  }

  It 'exposes provider metadata' {
    $Provider.Name() | Should -Be 'gcli'
    foreach ($op in @('CloseLabVIEW','CreateComparisonReport','RunVI','RunVIAnalyzer','RunUnitTests','MassCompile','ExecuteBuildSpec')) {
      $Provider.Supports($op) | Should -BeTrue
    }
    $Provider.Supports('UnknownOp') | Should -BeFalse
  }

  It 'builds RunVI arguments with booleans and positional inputs' {
    $args = $Provider.BuildArgs('RunVI', @{
      viPath = 'C:\fixture\RunMe.vi'
      showFP = $true
      abortOnError = $false
      arguments = @('one','two')
    })
    $args | Should -Be @(
      '--operation','RunVI',
      '--viPath','C:\fixture\RunMe.vi',
      '--showFP','true',
      '--abortOnError','false',
      '--argument','one',
      '--argument','two'
    )
  }

  It 'builds CreateComparisonReport arguments with optional fields' {
    $args = $Provider.BuildArgs('CreateComparisonReport', @{
      vi1 = 'C:\base.vi'
      vi2 = 'C:\head.vi'
      reportPath = 'C:\reports\diff.html'
      reportType = 'HTML'
    })
    $args | Should -Be @(
      '--operation','CreateComparisonReport',
      '--vi1','C:\base.vi',
      '--vi2','C:\head.vi',
      '--reportPath','C:\reports\diff.html',
      '--reportType','HTML'
    )
  }

  It 'omits optional CreateComparisonReport arguments when not provided' {
    $args = $Provider.BuildArgs('CreateComparisonReport', @{
      vi1 = 'C:\base.vi'
      vi2 = 'C:\head.vi'
    })
    $args | Should -Be @(
      '--operation','CreateComparisonReport',
      '--vi1','C:\base.vi',
      '--vi2','C:\head.vi'
    )
  }

  It 'builds MassCompile arguments with mixed value types' {
    $args = $Provider.BuildArgs('MassCompile', @{
      directoryToCompile = 'C:\src'
      massCompileLogFile = 'C:\logs\mass.txt'
      appendToMassCompileLog = $true
      numOfVIsToCache = 25
      reloadLVSBs = $false
    })
    $args | Should -Be @(
      '--operation','MassCompile',
      '--directoryToCompile','C:\src',
      '--massCompileLogFile','C:\logs\mass.txt',
      '--appendToMassCompileLog','true',
      '--numOfVIsToCache','25',
      '--reloadLVSBs','false'
    )
  }

  It 'uses buildSpec alias when provided' {
    $args = $Provider.BuildArgs('ExecuteBuildSpec', @{
      projectPath = 'C:\proj.lvproj'
      buildSpec = 'BuildAlias'
    })
    $args | Should -Be @(
      '--operation','ExecuteBuildSpec',
      '--projectPath','C:\proj.lvproj',
      '--buildSpecName','BuildAlias'
    )
  }
}
