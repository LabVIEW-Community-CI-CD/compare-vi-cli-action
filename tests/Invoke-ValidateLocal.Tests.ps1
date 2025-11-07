$ErrorActionPreference = 'Stop'

function Convert-ArgumentListToMap {
    param([object[]]$ArgumentList)

    $map = [ordered]@{}
    if (-not $ArgumentList) { return $map }

    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        $token = $ArgumentList[$i]
        if ($token -isnot [string] -or -not $token.StartsWith('-')) { continue }

        $value = $true
        if ($i -lt ($ArgumentList.Count - 1)) {
            $next = $ArgumentList[$i + 1]
            if ($next -is [string] -and -not $next.StartsWith('-')) {
                $value = $next
                $i++
            }
        }
        $map[$token] = $value
    }

    return $map
}

function global:New-SyntheticIconEditorVip {
    $testRoot = (Get-PSDrive -Name TestDrive).Root
    $root = Join-Path $testRoot ("vip-root-{0}" -f ([guid]::NewGuid().ToString('n')))
    $systemRoot = Join-Path $testRoot ("vip-system-{0}" -f ([guid]::NewGuid().ToString('n')))
    $fixtureVip = Join-Path $testRoot ("synthetic-{0}.vip" -f ([guid]::NewGuid().ToString('n')))

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'Packages') -Force | Out-Null
    New-Item -ItemType Directory -Path $systemRoot -Force | Out-Null

    @"
[Package]
Name="ni_icon_editor"
Version="1.0.0.0"
[Description]
License="MIT"
"@ | Set-Content -LiteralPath (Join-Path $root 'spec') -Encoding utf8

    @"
[Package]
Name="ni_icon_editor_system"
Version="1.0.0.0"
[Description]
License="MIT"
"@ | Set-Content -LiteralPath (Join-Path $systemRoot 'spec') -Encoding utf8

    $deploymentRoot = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Tooling\deployment'
    $resourceRoot = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\resource'
    $testRootDir = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Test'
    foreach ($path in @($deploymentRoot, $resourceRoot, $testRootDir)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    Set-Content -LiteralPath (Join-Path $deploymentRoot 'runner_dependencies.vipc') -Value 'stub vipc' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $resourceRoot 'StubResource.vi') -Value 'resource' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $testRootDir 'StubTest.vi') -Value 'test' -Encoding utf8

    $systemVip = Join-Path $root 'Packages\ni_icon_editor_system-1.0.0.0.vip'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($systemRoot, $systemVip)
    [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $fixtureVip)

    Remove-Item -LiteralPath $root -Recurse -Force
    Remove-Item -LiteralPath $systemRoot -Recurse -Force

    return (Resolve-Path -LiteralPath $fixtureVip).ProviderPath
}

function global:Use-InvokeValidateLocalStubs {
    param([string]$RepoRoot)

    $paths = @{
        Describe = Join-Path $RepoRoot 'tools/icon-editor/Describe-IconEditorFixture.ps1'
        Prepare  = Join-Path $RepoRoot 'tools/icon-editor/Prepare-FixtureViDiffs.ps1'
        Invoke   = Join-Path $RepoRoot 'tools/icon-editor/Invoke-FixtureViDiffs.ps1'
        Render   = Join-Path $RepoRoot 'tools/icon-editor/Render-ViComparisonReport.ps1'
        Simulate = Join-Path $RepoRoot 'tools/icon-editor/Simulate-IconEditorBuild.ps1'
    }

    $backup = @{}
    foreach ($entry in $paths.GetEnumerator()) {
        $key = $entry.Key
        $path = $entry.Value
        $backup[$key] = Join-Path (Get-PSDrive -Name TestDrive).Root ("stub-{0}-{1}.ps1" -f $key.ToLowerInvariant(), [guid]::NewGuid().ToString('n'))
        Copy-Item -LiteralPath $path -Destination $backup[$key] -Force
    }

    $Global:InvokeValidateLocalStubLog = @()

    $describeStub = @'
param(
    [string]$FixturePath,
    [string]$ResultsRoot,
    [string]$OutputPath,
    [switch]$KeepWork,
    [switch]$SkipResourceOverlay,
    [string]$ResourceOverlayRoot
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'Describe'
    Parameters = [pscustomobject]@{
        FixturePath        = $FixturePath
        ResultsRoot        = $ResultsRoot
        SkipResourceOverlay= $SkipResourceOverlay.IsPresent
        ResourceOverlayRoot= $ResourceOverlayRoot
    }
}
if ($OutputPath) {
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
$summary = [pscustomobject]@{
    schema            = 'icon-editor/fixture-report@v1'
    fixtureOnlyAssets = @()
    artifacts         = @()
    manifest          = [pscustomobject]@{
        packageSmoke = [pscustomobject]@{ status = 'ok'; vipCount = 0 }
        simulation   = [pscustomobject]@{ enabled = $true }
    }
    source            = [pscustomobject]@{ fixturePath = $FixturePath }
}
if ($OutputPath) {
    $json = $summary | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8
}
$summary
'@

    $prepareStub = @'
param(
    [string]$ReportPath,
    [string]$BaselineManifestPath,
    [string]$BaselineFixturePath,
    [string]$OutputDir,
    [string]$ResourceOverlayRoot
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'Prepare'
    Parameters = [pscustomobject]@{
        OutputDir = $OutputDir
    }
}
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
'{"schema":"icon-editor/vi-diff-requests@v1","count":1,"requests":[{"category":"test","relPath":"tests\\StubTest.vi","base":null,"head":"head.vi"}]}' | Set-Content -LiteralPath (Join-Path $OutputDir 'vi-diff-requests.json') -Encoding utf8
'@

    $invokeStub = @'
param(
    [string]$RequestsPath,
    [string]$CapturesRoot,
    [string]$SummaryPath,
    [switch]$DryRun,
    [int]$TimeoutSeconds
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'InvokeDiffs'
    Parameters = [pscustomobject]@{
        RequestsPath = $RequestsPath
        CapturesRoot = $CapturesRoot
        SummaryPath  = $SummaryPath
        DryRun       = $DryRun.IsPresent
    }
}
if (-not (Test-Path -LiteralPath $CapturesRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $CapturesRoot -Force | Out-Null
}
$summaryDir = Split-Path -Parent $SummaryPath
if ($summaryDir -and -not (Test-Path -LiteralPath $summaryDir -PathType Container)) {
    New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
}
'{"counts":{"total":1}}' | Set-Content -LiteralPath $SummaryPath -Encoding utf8
'@

    $renderStub = @'
param(
    [string]$SummaryPath,
    [string]$OutputPath
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'RenderReport'
    Parameters = [pscustomobject]@{
        SummaryPath = $SummaryPath
        OutputPath  = $OutputPath
    }
}
if ($OutputPath) {
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    'report' | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
'@

    $simulateStub = @'
param(
    [string]$FixturePath,
    [string]$ResultsRoot,
    [object]$ExpectedVersion,
    [string]$VipDiffOutputDir,
    [string]$VipDiffRequestsPath,
    [switch]$KeepExtract,
    [switch]$SkipResourceOverlay,
    [string]$ResourceOverlayRoot
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'Simulate'
    Parameters = [pscustomobject]@{
        ResultsRoot         = $ResultsRoot
        VipDiffOutputDir    = $VipDiffOutputDir
        VipDiffRequestsPath = $VipDiffRequestsPath
        ResourceOverlayRoot = $ResourceOverlayRoot
    }
}
if (-not (Test-Path -LiteralPath $ResultsRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $ResultsRoot -Force | Out-Null
}
'{"schema":"icon-editor/build@v1"}' | Set-Content -LiteralPath (Join-Path $ResultsRoot 'manifest.json') -Encoding utf8
$vipDir = if ($VipDiffOutputDir) { $VipDiffOutputDir } else { Join-Path $ResultsRoot 'vip-vi-diff' }
if (-not (Test-Path -LiteralPath $vipDir -PathType Container)) {
    New-Item -ItemType Directory -Path $vipDir -Force | Out-Null
}
$requestsPath = if ($VipDiffRequestsPath) { $VipDiffRequestsPath } else { Join-Path $vipDir 'vi-diff-requests.json' }
'{"schema":"icon-editor/vi-diff-requests@v1","count":1,"requests":[{"category":"resource","relPath":"resource\\StubResource.vi","base":null,"head":"head.vi"}]}' | Set-Content -LiteralPath $requestsPath -Encoding utf8
'@

    Set-Content -LiteralPath $paths.Describe -Value $describeStub -Encoding utf8
    Set-Content -LiteralPath $paths.Prepare -Value $prepareStub -Encoding utf8
    Set-Content -LiteralPath $paths.Invoke -Value $invokeStub -Encoding utf8
    Set-Content -LiteralPath $paths.Render -Value $renderStub -Encoding utf8
    Set-Content -LiteralPath $paths.Simulate -Value $simulateStub -Encoding utf8

    return [pscustomobject]@{
        Paths  = $paths
        Backup = $backup
    }
}

function global:Restore-InvokeValidateLocalStubs {
    param($State)

    foreach ($entry in $State.Paths.GetEnumerator()) {
        $key = $entry.Key
        $path = $entry.Value
        Copy-Item -LiteralPath $State.Backup[$key] -Destination $path -Force
        Remove-Item -LiteralPath $State.Backup[$key] -Force
    }

    Remove-Variable -Name InvokeValidateLocalStubLog -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-ValidateLocal.ps1' -Tag 'IconEditor','LocalValidate' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name scriptPath -Value (Join-Path $repoRoot 'tools/icon-editor/Invoke-ValidateLocal.ps1')
        Set-Variable -Scope Script -Name baselineFixture -Value (Join-Path $repoRoot 'tests/fixtures/icon-editor/ni_icon_editor-1.4.1.794.vip')
        Set-Variable -Scope Script -Name baselineManifest -Value (Join-Path $repoRoot 'tests/fixtures/icon-editor/fixture-manifest-1.4.1.794.json')
        $script:originalGhToken = $env:GH_TOKEN
    }

    AfterAll {
        if ($null -ne $script:originalGhToken) {
            $env:GH_TOKEN = $script:originalGhToken
        } else {
            Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        }
    }

    It 'produces outputs in dry-run mode for legacy fixtures' {
        if (-not (Test-Path -LiteralPath $script:baselineFixture -PathType Leaf) -or
            -not (Test-Path -LiteralPath $script:baselineManifest -PathType Leaf)) {
            Set-ItResult -Skip -Because 'Legacy baseline fixture not available; skipping regression test.'
            return
        }

        $env:GH_TOKEN = 'local-validate-test'

        $resultsRoot = Join-Path $TestDrive 'local-validate'
        $tempManifest = Join-Path $TestDrive 'baseline-manifest.json'
        $manifest = Get-Content -LiteralPath $script:baselineManifest -Raw | ConvertFrom-Json -Depth 8
        $target = $manifest.entries | Select-Object -First 1
        if ($target) { $target.hash = '0000000000000000000000000000000000000000000000000000000000000000' }
        $manifest.generatedAt = (Get-Date).ToString('o')
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempManifest -Encoding utf8

        & $script:scriptPath `
            -SkipBootstrap `
            -DryRun `
            -SkipLVCompare `
            -BaselineFixture $script:baselineFixture `
            -BaselineManifest $tempManifest `
            -ResultsRoot $resultsRoot | Out-Null

        $reportPath = Join-Path $resultsRoot 'fixture-report.json'
        Test-Path -LiteralPath $reportPath | Should -BeTrue

        $requestsPath = Join-Path $resultsRoot 'vi-diff\vi-diff-requests.json'
        Test-Path -LiteralPath $requestsPath | Should -BeTrue
        $requests = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json -Depth 6
        $requests.count | Should -BeGreaterThan 0

        $summaryPath = Join-Path $resultsRoot 'vi-diff-captures\vi-comparison-summary.json'
        Test-Path -LiteralPath $summaryPath | Should -BeTrue
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 6
        $summary.counts.total | Should -BeGreaterThan 0

        $reportMd = Join-Path $resultsRoot 'vi-diff-captures\vi-comparison-report.md'
        Test-Path -LiteralPath $reportMd | Should -BeTrue
    }

    It 'skips bootstrap when -SkipBootstrap is specified' {
        $fixturePath = New-SyntheticIconEditorVip
        $resultsRoot = Join-Path $TestDrive 'validate-skip-bootstrap'

        $stubState = Use-InvokeValidateLocalStubs -RepoRoot $script:repoRoot
        Mock -CommandName pwsh -MockWith {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ArgumentList)
            Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        }
        Mock -CommandName node -MockWith {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ArgumentList)
        }

        $log = $null
        try {
            { & $script:scriptPath `
                -SkipBootstrap `
                -DryRun `
                -SkipLVCompare `
                -FixturePath $fixturePath `
                -ResultsRoot $resultsRoot } | Should -Not -Throw
            $log = $Global:InvokeValidateLocalStubLog
        }
        finally {
            Restore-InvokeValidateLocalStubs $stubState
        }

        Assert-MockCalled pwsh -Times 0
        Assert-MockCalled node -Times 0
        $describeEntry = $log | Where-Object { $_.Command -eq 'Describe' } | Select-Object -First 1
        $expectedOverlay = (Resolve-Path -LiteralPath (Join-Path $script:repoRoot 'vendor/icon-editor/resource')).Path
        $describeEntry.Parameters.ResourceOverlayRoot | Should -Be $expectedOverlay
        $describeEntry.Parameters.SkipResourceOverlay | Should -BeFalse
    }

    It 'invokes simulation helpers when IncludeSimulation is specified' {
        $fixturePath = New-SyntheticIconEditorVip
        $resultsRoot = Join-Path $TestDrive 'validate-simulation'
        $overlayRoot = Join-Path $TestDrive 'overlay'
        New-Item -ItemType Directory -Path $overlayRoot -Force | Out-Null

        $stubState = Use-InvokeValidateLocalStubs -RepoRoot $script:repoRoot
        Mock -CommandName pwsh -MockWith {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ArgumentList)
            Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        }
        Mock -CommandName node -MockWith {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ArgumentList)
        }

        $log = $null
        try {
            { & $script:scriptPath `
                -SkipBootstrap `
                -DryRun `
                -SkipLVCompare `
                -IncludeSimulation `
                -FixturePath $fixturePath `
                -ResultsRoot $resultsRoot `
                -ResourceOverlayRoot $overlayRoot } | Should -Not -Throw
            $log = $Global:InvokeValidateLocalStubLog
        }
        finally {
            Restore-InvokeValidateLocalStubs $stubState
        }

        $simulateEntry = $log | Where-Object { $_.Command -eq 'Simulate' } | Select-Object -First 1
        $simulateEntry.Parameters.ResourceOverlayRoot | Should -Be (Resolve-Path -LiteralPath $overlayRoot).Path

        $vipDiffRequests = Join-Path $resultsRoot 'vip-vi-diff' 'vi-diff-requests.json'
        Test-Path -LiteralPath $vipDiffRequests | Should -BeTrue

        $vipReport = Join-Path $resultsRoot 'vip-vi-diff-captures' 'vi-comparison-report.md'
        Test-Path -LiteralPath $vipReport | Should -BeTrue
    }

    It 'runs LVCompare when compare requests are present' {
        $fixturePath = New-SyntheticIconEditorVip
        $resultsRoot = Join-Path $TestDrive 'validate-full'
        $stubState = Use-InvokeValidateLocalStubs -RepoRoot $script:repoRoot

        Mock -CommandName pwsh -MockWith {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ArgumentList)
            Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        }

        $nodeInvocations = New-Object System.Collections.Generic.List[object]
        Mock -CommandName node -MockWith {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ArgumentList)
            $null = $nodeInvocations.Add(($ArgumentList | ForEach-Object { [string]$_ }))
        }

        $log = $null
        try {
            { & $script:scriptPath `
                -SkipBootstrap `
                -FixturePath $fixturePath `
                -ResultsRoot $resultsRoot } | Should -Not -Throw
            $log = $Global:InvokeValidateLocalStubLog
        }
        finally {
            Restore-InvokeValidateLocalStubs $stubState
        }

        $nodeInvocations.Count | Should -Be 2
        $invokeEntry = $log | Where-Object { $_.Command -eq 'InvokeDiffs' } | Select-Object -First 1
        $invokeEntry.Parameters.DryRun | Should -BeFalse

        $summaryPath = Join-Path $resultsRoot 'vi-diff-captures\vi-comparison-summary.json'
        Test-Path -LiteralPath $summaryPath | Should -BeTrue
    }
}
