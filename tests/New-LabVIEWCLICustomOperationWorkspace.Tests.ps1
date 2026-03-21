Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'New-LabVIEWCLICustomOperationWorkspace.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ScaffoldScript = Join-Path $script:RepoRoot 'tools' 'New-LabVIEWCLICustomOperationWorkspace.ps1'
    if (-not (Test-Path -LiteralPath $script:ScaffoldScript -PathType Leaf)) {
      throw "New-LabVIEWCLICustomOperationWorkspace.ps1 not found at $script:ScaffoldScript"
    }

    function script:New-SyntheticSourceExample {
      param([Parameter(Mandatory)][string]$RootPath)

      New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
      $files = @{
        'AddTwoNumbers.lvclass' = 'class placeholder'
        'AddTwoNumbers.vi' = 'vi placeholder'
        'GetHelp.vi' = 'help placeholder'
        'RunOperation.vi' = 'run placeholder'
        'support\custom-operation-scaffold.json' = 'same leaf name as receipt'
        'support\Readme.txt' = 'nested file'
      }

      foreach ($entry in $files.GetEnumerator()) {
        $filePath = Join-Path $RootPath $entry.Key
        $parent = Split-Path -Parent $filePath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
          New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Set-Content -LiteralPath $filePath -Value $entry.Value -Encoding utf8
      }

      return $RootPath
    }
  }

  It 'scaffolds a disposable workspace, writes a receipt, and records the copied file inventory' {
    $sourcePath = New-SyntheticSourceExample -RootPath (Join-Path $TestDrive 'source-example')
    $destinationPath = Join-Path $TestDrive 'results-root' 'custom-op'
    $receiptPath = Join-Path $TestDrive 'receipts' 'custom-operation-scaffold.json'
    $labviewPathHint = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'

    $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
      -SourceExamplePath $sourcePath `
      -DestinationPath $destinationPath `
      -ReceiptPath $receiptPath `
      -LabVIEWPathHint $labviewPathHint 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $destinationPath | Should -Exist
    $receiptPath | Should -Exist
    (Join-Path $destinationPath 'AddTwoNumbers.vi') | Should -Exist
    (Join-Path $destinationPath 'RunOperation.vi') | Should -Exist
    (Join-Path $destinationPath 'support\Readme.txt') | Should -Exist

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 10
    $receipt.schema | Should -Be 'labview-cli-custom-operation-scaffold@v1'
    $receipt.status | Should -Be 'succeeded'
    $receipt.sourceKind | Should -Be 'ni-example'
    $receipt.sourceExampleName | Should -Be 'source-example'
    $receipt.sourceExists | Should -BeTrue
    $receipt.destinationExists | Should -BeTrue
    $receipt.destinationPolicy | Should -Be 'outside-repo'
    $receipt.labviewPathHint | Should -Be $labviewPathHint
    $receipt.labviewVersionHint | Should -Be '2026'
    $receipt.copiedFileCount | Should -Be 6
    @($receipt.copiedFiles) | Should -Contain 'AddTwoNumbers.vi'
    @($receipt.copiedFiles) | Should -Contain 'support/custom-operation-scaffold.json'
    @($receipt.copiedFiles) | Should -Contain 'support/Readme.txt'
  }

  It 'fails closed when the source example directory is missing' {
    $missingSource = Join-Path $TestDrive 'missing-example'
    $destinationPath = Join-Path $TestDrive 'results-root' 'custom-op'

    $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
      -SourceExamplePath $missingSource `
      -DestinationPath $destinationPath `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'scaffold source was not found'
  }

  It 'can scaffold from an installed-cli-operation style source without requiring AddTwoNumbers artifacts' {
    $sourcePath = Join-Path $TestDrive 'installed-operation-source'
    New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
    foreach ($relativePath in @(
      'GetHelp.vi',
      'RunOperation.vi',
      'Utilities\\ParseArguments.vi'
    )) {
      $filePath = Join-Path $sourcePath $relativePath
      $parent = Split-Path -Parent $filePath
      if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
      }
      Set-Content -LiteralPath $filePath -Value "placeholder for $relativePath" -Encoding utf8
    }

    $destinationPath = Join-Path $TestDrive 'results-root' 'installed-operation-workspace'
    $receiptPath = Join-Path $TestDrive 'receipts' 'installed-operation-scaffold.json'

    $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
      -SourceKind installed-cli-operation `
      -SourceExamplePath $sourcePath `
      -DestinationPath $destinationPath `
      -ReceiptPath $receiptPath `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 10
    $receipt.sourceKind | Should -Be 'installed-cli-operation'
    $receipt.sourceExampleName | Should -Be 'installed-operation-source'
    $receipt.copiedFileCount | Should -Be 3
    @($receipt.copiedFiles) | Should -Contain 'GetHelp.vi'
    @($receipt.copiedFiles) | Should -Contain 'RunOperation.vi'
    @($receipt.copiedFiles) | Should -Contain 'Utilities/ParseArguments.vi'
  }

  It 'fails closed when an installed-cli-operation source is missing RunOperation.vi' {
    $sourcePath = Join-Path $TestDrive 'installed-operation-missing-run'
    New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sourcePath 'GetHelp.vi') -Value 'help placeholder' -Encoding utf8
    $destinationPath = Join-Path $TestDrive 'results-root' 'invalid-installed-operation'

    $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
      -SourceKind installed-cli-operation `
      -SourceExamplePath $sourcePath `
      -DestinationPath $destinationPath `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Not -Be 0
    (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'expected ''RunOperation.vi'''
  }

  It 'fails closed when the destination already exists unless force is provided' {
    $sourcePath = New-SyntheticSourceExample -RootPath (Join-Path $TestDrive 'source-example')
    $destinationPath = Join-Path $TestDrive 'results-root' 'custom-op'
    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $destinationPath 'stale.txt') -Value 'stale' -Encoding utf8

    $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
      -SourceExamplePath $sourcePath `
      -DestinationPath $destinationPath `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Not -Be 0
    (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'Destination already exists'

    $forceOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
      -SourceExamplePath $sourcePath `
      -DestinationPath $destinationPath `
      -Force `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($forceOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    (Join-Path $destinationPath 'stale.txt') | Should -Not -Exist
    (Join-Path $destinationPath 'AddTwoNumbers.vi') | Should -Exist
  }

  It 'refuses to scaffold inside git-tracked source trees under the repository root' {
    $sourcePath = New-SyntheticSourceExample -RootPath (Join-Path $TestDrive 'source-example')
    $destinationPath = Join-Path $script:RepoRoot 'tools' 'tmp-custom-op'

    try {
      $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
        -SourceExamplePath $sourcePath `
        -DestinationPath $destinationPath `
        -SkipSchemaValidation 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'outside ''tests/results/_agent/custom-operation-scaffolds/'
    } finally {
      if (Test-Path -LiteralPath $destinationPath) {
        Remove-Item -LiteralPath $destinationPath -Recurse -Force
      }
    }
  }

  It 'allows repo-local destinations under the dedicated scaffold subtree but blocks the subtree root itself' {
    $sourcePath = New-SyntheticSourceExample -RootPath (Join-Path $TestDrive 'source-example')
    $scaffoldRoot = Join-Path $script:RepoRoot 'tests' 'results' '_agent' 'custom-operation-scaffolds'
    $destinationPath = Join-Path $scaffoldRoot 'manual-custom-operation-workspace'

    try {
      $runOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
        -SourceExamplePath $sourcePath `
        -DestinationPath $destinationPath `
        -SkipSchemaValidation 2>&1
      $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
      (Join-Path $destinationPath 'AddTwoNumbers.vi') | Should -Exist

      $rootOutput = & pwsh -NoLogo -NoProfile -File $script:ScaffoldScript `
        -SourceExamplePath $sourcePath `
        -DestinationPath $scaffoldRoot `
        -SkipSchemaValidation 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      (($rootOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'shared scaffold root itself'
    } finally {
      if (Test-Path -LiteralPath $destinationPath) {
        Remove-Item -LiteralPath $destinationPath -Recurse -Force
      }
    }
  }
}
