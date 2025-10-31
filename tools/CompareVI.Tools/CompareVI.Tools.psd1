@{
  RootModule        = 'CompareVI.Tools.psm1'
  ModuleVersion     = '0.1.0'
  GUID              = '1f9b5f7f-1ab6-4db9-8e36-6b7a6d5e9c8f'
  Author            = 'LabVIEW Community CI'
  CompanyName       = 'LabVIEW Community'
  Copyright         = '(c) LabVIEW Community. All rights reserved.'
  Description       = 'Helpers for running Compare-VI history and staging workflows across repositories.'
  PowerShellVersion = '5.1'
  FunctionsToExport = @(
    'Invoke-CompareVIHistory',
    'Invoke-CompareRefsToTemp'
  )
  CmdletsToExport   = @()
  VariablesToExport = @()
  AliasesToExport   = @()
  PrivateData       = @{
    PSData = @{
      Tags = @('CompareVI','LabVIEW','VIHistory')
      ProjectUri = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action'
    }
  }
}
