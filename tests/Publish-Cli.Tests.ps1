Describe 'Publish-Cli shared package feed resolution' {
  BeforeAll {
    $candidateRoots = @()
    foreach ($candidate in @($PSScriptRoot, $PSCommandPath, (Get-Location).Path)) {
      if ([string]::IsNullOrWhiteSpace($candidate)) {
        continue
      }

      $resolved = $candidate
      if (Test-Path -LiteralPath $candidate) {
        $item = Get-Item -LiteralPath $candidate
        $resolved = if ($item.PSIsContainer) { $item.FullName } else { Split-Path -Parent $item.FullName }
      }
      $candidateRoots += $resolved
    }

    $repoRoot = $null
    foreach ($root in $candidateRoots | Select-Object -Unique) {
      $cursor = $root
      while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $marker = Join-Path $cursor 'tools' 'Publish-Cli.ps1'
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
          $repoRoot = $cursor
          break
        }

        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) {
          break
        }

        $cursor = $parent
      }

      if ($repoRoot) {
        break
      }
    }

    if (-not $repoRoot) {
      throw 'Unable to resolve repository root for Publish-Cli tests.'
    }

    $script:RepoRoot = $repoRoot
    $script:PublishCliScript = Join-Path $repoRoot 'tools' 'Publish-Cli.ps1'
    $script:CliProjectPath = Join-Path $repoRoot 'src' 'CompareVi.Tools.Cli' 'CompareVi.Tools.Cli.csproj'
    $script:SharedProjectPath = Join-Path $repoRoot 'src' 'CompareVi.Shared' 'CompareVi.Shared.csproj'

    [xml]$propsXml = Get-Content -Raw (Join-Path $repoRoot 'Directory.Build.props')
    $script:ExpectedSharedPackageVersion = ([string]($propsXml.Project.PropertyGroup.Version | Select-Object -First 1)).Trim()
  }

  It 'resolves the package-first shared feed version from Directory.Build.props text' {
    $outputRoot = Join-Path $TestDrive 'publish-output'
    $sharedFeed = Join-Path $TestDrive 'shared-feed'
    $sharedSourceReportPath = Join-Path $TestDrive 'shared-source-resolution.json'

    & $script:PublishCliScript `
      -ProjectPath $script:CliProjectPath `
      -SharedProjectPath $script:SharedProjectPath `
      -OutputRoot $outputRoot `
      -CompareViSharedPackageFeed $sharedFeed `
      -SharedSourceReportPath $sharedSourceReportPath `
      -CompareViSharedSource package-first `
      -PrepareSharedPackageFeed `
      -FailOnSharedFallback `
      -FrameworkDependent:$false `
      -SelfContained:$false `
      -Rids @('win-x64')

    Test-Path -LiteralPath $sharedSourceReportPath | Should -BeTrue
    $report = Get-Content -LiteralPath $sharedSourceReportPath -Raw | ConvertFrom-Json
    $report.requestedSource | Should -Be 'package-first'
    $report.resolvedSource | Should -Be 'package'
    $report.packageAvailable | Should -Be 'true'
    $report.packageVersion | Should -Be $script:ExpectedSharedPackageVersion
    $report.packageVersion | Should -Not -Be 'System.Xml.XmlElement'

    $nupkgPath = Join-Path $sharedFeed ("CompareVi.Shared.{0}.nupkg" -f $script:ExpectedSharedPackageVersion)
    Test-Path -LiteralPath $nupkgPath | Should -BeTrue
  }

  It 'honors an explicit shared package version when preparing the package feed' {
    $explicitVersion = '9.9.9-test.1'
    $outputRoot = Join-Path $TestDrive 'publish-output-explicit'
    $sharedFeed = Join-Path $TestDrive 'shared-feed-explicit'
    $sharedSourceReportPath = Join-Path $TestDrive 'shared-source-resolution-explicit.json'

    & $script:PublishCliScript `
      -ProjectPath $script:CliProjectPath `
      -SharedProjectPath $script:SharedProjectPath `
      -OutputRoot $outputRoot `
      -CompareViSharedPackageFeed $sharedFeed `
      -SharedSourceReportPath $sharedSourceReportPath `
      -CompareViSharedSource package-first `
      -CompareViSharedPackageVersion $explicitVersion `
      -PrepareSharedPackageFeed `
      -FailOnSharedFallback `
      -FrameworkDependent:$false `
      -SelfContained:$false `
      -Rids @('win-x64')

    Test-Path -LiteralPath $sharedSourceReportPath | Should -BeTrue
    $report = Get-Content -LiteralPath $sharedSourceReportPath -Raw | ConvertFrom-Json
    $report.requestedSource | Should -Be 'package-first'
    $report.resolvedSource | Should -Be 'package'
    $report.packageAvailable | Should -Be 'true'
    $report.packageVersion | Should -Be $explicitVersion

    $nupkgPath = Join-Path $sharedFeed ("CompareVi.Shared.{0}.nupkg" -f $explicitVersion)
    Test-Path -LiteralPath $nupkgPath | Should -BeTrue
  }
}
