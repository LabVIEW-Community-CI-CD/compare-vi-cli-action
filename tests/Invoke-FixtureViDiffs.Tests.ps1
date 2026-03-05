$ErrorActionPreference = 'Stop'

Describe 'Invoke-FixtureViDiffs.ps1' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptPath = Join-Path $repoRoot 'tools/icon-editor/Invoke-FixtureViDiffs.ps1'
        $resolved = Get-Item -LiteralPath $scriptPath
        Set-Variable -Name scriptInvoker -Scope Script -Value $resolved
    }

    It 'creates summary and marks dry-run entries' {
        $requestsPath = Join-Path $TestDrive 'requests.json'
        $capturesRoot = Join-Path $TestDrive 'captures'
        $summaryPath = Join-Path $TestDrive 'summary.json'

        $baseVi = Join-Path $TestDrive 'Base.vi'
        $headVi = Join-Path $TestDrive 'Head.vi'
        Set-Content -LiteralPath $baseVi -Value 'stub'
        Set-Content -LiteralPath $headVi -Value 'stub'

        $requests = [ordered]@{
            schema = 'icon-editor/vi-diff-requests@v1'
            generatedAt = (Get-Date).ToString('o')
            count = 1
            requests = @(
                [ordered]@{
                    name = 'Sample.vi'
                    relPath = 'tests/Unit Tests/Sample.vi'
                    category = 'test'
                    base = $baseVi
                    head = $headVi
                }
            )
        }
        $requests | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestsPath -Encoding utf8

        $summary = & $script:scriptInvoker `
            -RequestsPath $requestsPath `
            -CapturesRoot $capturesRoot `
            -SummaryPath $summaryPath `
            -DryRun

        $summary.counts.dryRun | Should -Be 1
        $summary.requests.Count | Should -Be 1
        $summary.requests[0].status | Should -Be 'dry-run'
        Test-Path -LiteralPath $summaryPath | Should -BeTrue
    }

    It 'records comparison outcomes using a stub compare script' {
        $requestsPath = Join-Path $TestDrive 'requests.json'
        $capturesRoot = Join-Path $TestDrive 'captures'
        $summaryPath = Join-Path $TestDrive 'summary.json'
        $stubScript = Join-Path $TestDrive 'stub-compare.ps1'

        $baseVi = Join-Path $TestDrive 'BaseDiff.vi'
        $headVi = Join-Path $TestDrive 'HeadDiff.vi'
        Set-Content -LiteralPath $baseVi -Value 'diff'
        Set-Content -LiteralPath $headVi -Value 'diff'

        $requests = [ordered]@{
            schema = 'icon-editor/vi-diff-requests@v1'
            generatedAt = (Get-Date).ToString('o')
            count = 1
            requests = @(
                [ordered]@{
                    name = 'Diff.vi'
                    relPath = 'tests/Unit Tests/Diff.vi'
                    category = 'test'
                    base = $baseVi
                    head = $headVi
                }
            )
        }
        $requests | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $requestsPath -Encoding utf8

        $stubContent = @'
param(
    [Parameter(Mandatory)][string]$BaseVi,
    [Parameter(Mandatory)][string]$HeadVi,
    [string]$OutputRoot,
    [string]$WarmupMode,
    [switch]$UseRawPaths,
    [int]$TimeoutSeconds,
    [switch]$RenderReport,
    [string]$NoiseProfile,
    [switch]$DisableTimeout,
    [switch]$DisableCleanup,
    [Parameter(ValueFromRemainingArguments=$true)][object[]]$Rest
)
$compareDir = Join-Path $OutputRoot 'compare'
New-Item -ItemType Directory -Force -Path $compareDir | Out-Null
$session = [ordered]@{
    schema = 'teststand-compare-session/v1'
    at = (Get-Date).ToString('o')
    outcome = @{ exitCode = 1; seconds = 3; diff = $true }
    error = $null
}
$session | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'session-index.json') -Encoding utf8
$cap = @{ exitCode = 1; seconds = 3; command = 'stub'; environment = @{ cli = @{ message = 'differences detected' } } }
$cap | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $compareDir 'lvcompare-capture.json') -Encoding utf8
$global:LASTEXITCODE = 1
return
'@
        Set-Content -LiteralPath $stubScript -Value $stubContent -Encoding utf8

        $summary = & $script:scriptInvoker `
            -RequestsPath $requestsPath `
            -CapturesRoot $capturesRoot `
            -SummaryPath $summaryPath `
            -CompareScript $stubScript

        $summary.counts.different | Should -Be 1
        $summary.counts.compared | Should -Be 1
        $summary.requests[0].status | Should -Be 'different'
        $pairDir = Join-Path $capturesRoot $summary.requests[0].captureDir
        Test-Path -LiteralPath (Join-Path $pairDir 'session-index.json') | Should -BeTrue
    }
}
