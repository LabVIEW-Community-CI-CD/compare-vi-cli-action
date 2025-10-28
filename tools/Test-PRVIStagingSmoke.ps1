#Requires -Version 7.0
<#
.SYNOPSIS
End-to-end smoke test for the PR VI staging workflow.

.DESCRIPTION
Creates a disposable branch with synthetic VI changes, opens a draft PR,
dispatches `pr-vi-staging.yml`, ensures the run succeeds, and verifies the
`vi-staging-ready` label appears. By default, the scratch branch/PR are cleaned
up once the smoke passes.

.PARAMETER BaseBranch
Branch to branch from when generating the synthetic changes. Defaults to
`develop`.

.PARAMETER KeepBranch
Skip cleanup so the branch and draft PR remain available for inspection.

.PARAMETER DryRun
Emit the planned steps without executing them.
#>
[CmdletBinding()]
param(
    [string]$BaseBranch = 'develop',
    [switch]$KeepBranch,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )
    $output = git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed:`n$output"
    }
    return @($output -split "`r?`n" | Where-Object { $_ -ne '' })
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$ExpectJson
    )
    $output = gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed:`n$output"
    }
    if ($ExpectJson) {
        if (-not $output) { return $null }
        return $output | ConvertFrom-Json
    }
    return $output
}

function Touch-ViFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "VI file not found: $Path"
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 1) {
        throw "VI file is empty: $Path"
    }
    $bytes[-1] = $bytes[-1] -bxor 1
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Copy-ViContent {
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Source VI file not found: $Source"
    }

    $destDir = Split-Path -Parent $Destination
    if ($destDir -and -not (Test-Path -LiteralPath $destDir -PathType Container)) {
        throw "Destination directory not found: $destDir"
    }

    [System.IO.File]::Copy($Source, $Destination, $true)
}

function Reset-FixtureFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Ref
    )

    Invoke-Git -Arguments @('checkout', $Ref, '--', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi') | Out-Null
}

function Get-VIStagingSmokeScenarios {
    param(
        [Parameter(Mandatory)]
        [string]$FixtureRef
    )

    $noDiffPrep = {
        Reset-FixtureFiles -Ref $FixtureRef
        Copy-ViContent -Source 'fixtures/vi-attr/Head.vi' -Destination 'fixtures/vi-attr/Base.vi'
        Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi')
    }.GetNewClosure()

    $vi2BaseFixture = 'tmp-commit-236ffab/VI1.vi'
    $vi2HeadFixture = 'tmp-commit-236ffab/VI2.vi'
    if (-not (Test-Path -LiteralPath $vi2BaseFixture -PathType Leaf)) {
        throw "Block-diagram base fixture missing: $vi2BaseFixture"
    }
    if (-not (Test-Path -LiteralPath $vi2HeadFixture -PathType Leaf)) {
        throw "Block-diagram head fixture missing: $vi2HeadFixture"
    }
    $vi2BaseBytes = [System.IO.File]::ReadAllBytes($vi2BaseFixture)
    $vi2HeadBytes = [System.IO.File]::ReadAllBytes($vi2HeadFixture)

    $vi2DiffPrep = {
        Reset-FixtureFiles -Ref $FixtureRef
        [System.IO.File]::WriteAllBytes('fixtures/vi-attr/Base.vi', $vi2BaseBytes)
        [System.IO.File]::WriteAllBytes('fixtures/vi-attr/Head.vi', $vi2HeadBytes)
        Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi')
    }.GetNewClosure()

    $attrBasePath = 'fixtures/vi-attr/attr/BaseAttr.vi'
    $attrHeadPath = 'fixtures/vi-attr/attr/HeadAttr.vi'
    if (-not (Test-Path -LiteralPath $attrBasePath -PathType Leaf)) {
        throw "Attr-diff base fixture missing: $attrBasePath"
    }
    if (-not (Test-Path -LiteralPath $attrHeadPath -PathType Leaf)) {
        throw "Attr-diff head fixture missing: $attrHeadPath"
    }
    $attrBaseBytes = [System.IO.File]::ReadAllBytes($attrBasePath)
    $attrHeadBytes = [System.IO.File]::ReadAllBytes($attrHeadPath)

    $attrDiffPrep = {
        Reset-FixtureFiles -Ref $FixtureRef
        [System.IO.File]::WriteAllBytes('fixtures/vi-attr/Base.vi', $attrBaseBytes)
        [System.IO.File]::WriteAllBytes('fixtures/vi-attr/Head.vi', $attrHeadBytes)
        Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi')
    }.GetNewClosure()

    $fpCosmeticPrep = {
        Reset-FixtureFiles -Ref $FixtureRef
        Copy-ViContent -Source 'fixtures/vi-stage/fp-cosmetic/Base.vi' -Destination 'fixtures/vi-attr/Base.vi'
        Copy-ViContent -Source 'fixtures/vi-stage/fp-cosmetic/Head.vi' -Destination 'fixtures/vi-attr/Head.vi'
        Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi')
    }.GetNewClosure()

    $connectorPanePrep = {
        Reset-FixtureFiles -Ref $FixtureRef
        Copy-ViContent -Source 'fixtures/vi-stage/connector-pane/Base.vi' -Destination 'fixtures/vi-attr/Base.vi'
        Copy-ViContent -Source 'fixtures/vi-stage/connector-pane/Head.vi' -Destination 'fixtures/vi-attr/Head.vi'
        Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi')
    }.GetNewClosure()

    $bdCosmeticPrep = {
        Reset-FixtureFiles -Ref $FixtureRef
        Copy-ViContent -Source 'fixtures/vi-stage/bd-cosmetic/Base.vi' -Destination 'fixtures/vi-attr/Base.vi'
        Copy-ViContent -Source 'fixtures/vi-stage/bd-cosmetic/Head.vi' -Destination 'fixtures/vi-attr/Head.vi'
        Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi')
    }.GetNewClosure()

    $controlRenamePrep = {
        Reset-FixtureFiles -Ref $FixtureRef
        Copy-ViContent -Source 'fixtures/vi-stage/control-rename/Base.vi' -Destination 'fixtures/vi-attr/Base.vi'
        Copy-ViContent -Source 'fixtures/vi-stage/control-rename/Head.vi' -Destination 'fixtures/vi-attr/Head.vi'
        Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi')
    }.GetNewClosure()

    $fpWindowPrep = {
        Reset-FixtureFiles -Ref $FixtureRef
        Copy-ViContent -Source 'fixtures/vi-stage/fp-window/Base.vi' -Destination 'fixtures/vi-attr/Base.vi'
        Copy-ViContent -Source 'fixtures/vi-stage/fp-window/Head.vi' -Destination 'fixtures/vi-attr/Head.vi'
        Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi')
    }.GetNewClosure()

    return @(
        [ordered]@{
            Name          = 'no-diff'
            Description   = 'Copy Head.vi onto Base.vi so LVCompare reports no differences.'
            Expectation   = 'match'
            CommitMessage = 'chore: synthetic VI changes for staging smoke'
            Prepare       = $noDiffPrep
        },
        [ordered]@{
            Name          = 'vi2-diff'
            Description   = 'Copy tracked fixtures tmp-commit-236ffab/{VI1,VI2}.vi onto Base.vi/Head.vi for a block diagram cosmetic diff.'
            Expectation   = 'diff'
            CommitMessage = 'chore: synthetic VI diff for staging smoke'
            Prepare       = $vi2DiffPrep
        },
        [ordered]@{
            Name          = 'attr-diff'
            Description   = 'Stage VI1/VI2 fixture pair to exercise metadata-focused differences.'
            Expectation   = 'diff'
            CommitMessage = 'chore: synthetic VI attribute diff for staging smoke'
            Prepare       = $attrDiffPrep
        },
        [ordered]@{
            Name          = 'fp-cosmetic'
            Description   = 'Stage fp-cosmetic fixture pair to exercise front panel cosmetic differences.'
            Expectation   = 'diff'
            CommitMessage = 'chore: synthetic VI front panel cosmetic diff for staging smoke'
            Prepare       = $fpCosmeticPrep
        },
        [ordered]@{
            Name          = 'connector-pane'
            Description   = 'Stage connector-pane fixture pair to exercise connector pane wiring differences.'
            Expectation   = 'diff'
            CommitMessage = 'chore: synthetic VI connector pane diff for staging smoke'
            Prepare       = $connectorPanePrep
        },
        [ordered]@{
            Name          = 'bd-cosmetic'
            Description   = 'Stage bd-cosmetic fixture pair to exercise block diagram cosmetic differences.'
            Expectation   = 'diff'
            CommitMessage = 'chore: synthetic VI block diagram cosmetic diff for staging smoke'
            Prepare       = $bdCosmeticPrep
        },
        [ordered]@{
            Name          = 'control-rename'
            Description   = 'Stage control-rename fixture pair to exercise front panel control rename differences.'
            Expectation   = 'diff'
            CommitMessage = 'chore: synthetic VI control rename diff for staging smoke'
            Prepare       = $controlRenamePrep
        },
        [ordered]@{
            Name          = 'fp-window'
            Description   = 'Stage fp-window fixture pair to exercise front panel window sizing differences.'
            Expectation   = 'diff'
            CommitMessage = 'chore: synthetic VI window size diff for staging smoke'
            Prepare       = $fpWindowPrep
        }
    )
}

function Get-RepoInfo {
    if ($env:GITHUB_REPOSITORY -and ($env:GITHUB_REPOSITORY -match '^(?<owner>[^/]+)/(?<name>.+)$')) {
        return [ordered]@{
            Slug  = $env:GITHUB_REPOSITORY
            Owner = $Matches['owner']
            Name  = $Matches['name']
        }
    }
    $remote = Invoke-Git -Arguments @('remote', 'get-url', 'origin') | Select-Object -First 1
    if ($remote -match 'github.com[:/](?<owner>[^/]+)/(?<name>.+?)(?:\.git)?$') {
        return [ordered]@{
            Slug  = "$($Matches['owner'])/$($Matches['name'])"
            Owner = $Matches['owner']
            Name  = $Matches['name']
        }
    }
    throw 'Unable to determine repository slug.'
}

function Get-GitHubAuth {
    $token = $env:GH_TOKEN
    if (-not $token) {
        $token = $env:GITHUB_TOKEN
    }
    if (-not $token) {
        throw 'GH_TOKEN or GITHUB_TOKEN must be set.'
    }

    $headers = @{
        Authorization = "Bearer $token"
        Accept        = 'application/vnd.github+json'
        'User-Agent'  = 'compare-vi-staging-smoke'
    }

    return [ordered]@{
        Token   = $token
        Headers = $headers
    }
}

function Get-PullRequestInfo {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Repo,
        [Parameter(Mandatory)]
        [string]$Branch,
        [int]$Attempts = 10,
        [int]$DelaySeconds = 2
    )

    $auth = Get-GitHubAuth
    $headers = $auth.Headers

    $lastError = $null
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            $uri = "https://api.github.com/repos/$($Repo.Slug)/pulls?head=$($Repo.Owner):$Branch&state=open"
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
            if ($response -and $response.Count -gt 0) {
                return $response[0]
            }
        } catch {
            $lastError = $_
        }
        if ($attempt -lt $Attempts - 1) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    if ($lastError) {
        throw "Failed to locate scratch PR: $($lastError.Exception.Message)"
    }
    throw 'Failed to locate scratch PR.'
}

Write-Verbose "Base branch: $BaseBranch"
Write-Verbose "KeepBranch: $KeepBranch"
Write-Verbose "DryRun: $DryRun"

$repoInfo = Get-RepoInfo
$initialBranch = Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1
Write-Host "Current branch: $initialBranch"

$status = @(Invoke-Git -Arguments @('status', '--porcelain'))
if ($status.Count -eq 1 -and [string]::IsNullOrWhiteSpace($status[0])) {
    $status = @()
}
if ($status.Count -gt 0 -and -not $DryRun) {
    throw 'Working tree not clean. Commit or stash changes before running the smoke test.'
}

$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
$branchPrefix = "smoke/vi-stage-$timestamp"
$prTitle = "Smoke: VI staging label test ($timestamp)"
$note = "staging smoke $timestamp"
$fixtureRef = "origin/$BaseBranch"
$scenarios = Get-VIStagingSmokeScenarios -FixtureRef $fixtureRef
$originalFlagsMode = [System.Environment]::GetEnvironmentVariable('RUN_STAGED_LVCOMPARE_FLAGS_MODE', 'Process')
$restoreFlagsMode = $false
if ([string]::IsNullOrWhiteSpace($originalFlagsMode)) {
    [System.Environment]::SetEnvironmentVariable('RUN_STAGED_LVCOMPARE_FLAGS_MODE', 'replace', 'Process')
    $restoreFlagsMode = $true
}

$metadataHelperPath = Join-Path (Get-Location) 'tools' 'Get-VICompareMetadata.ps1'
$metadataHelperContent = $null
if (Test-Path -LiteralPath $metadataHelperPath -PathType Leaf) {
    $metadataHelperContent = Get-Content -LiteralPath $metadataHelperPath -Raw
} else {
    Write-Warning "Optional metadata helper not found at $metadataHelperPath; pre-compare metadata will be skipped."
}
$metadataInvoker = {
    param(
        [string]$BaseVi,
        [string]$HeadVi,
        [string]$MetadataPath,
        [string]$HelperContent
    )
    if (-not $HelperContent) { return $null }
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("Get-VICompareMetadata-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
    try {
        Set-Content -LiteralPath $tempPath -Value $HelperContent -Encoding utf8
        return & pwsh -NoLogo -NoProfile -File $tempPath `
            -BaseVi $BaseVi `
            -HeadVi $HeadVi `
            -OutputPath $MetadataPath `
            -ReplaceFlags
    } finally {
        Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
    }
}.GetNewClosure()

Write-Host "Branch prefix: $branchPrefix"

if ($DryRun) {
    Write-Host "Dry-run mode: no changes will be made."
    Write-Host "Plan:"
    Write-Host "  - Fetch origin/$BaseBranch"
    Write-Host "  - Create $branchPrefix-<scenario> branches from origin/$BaseBranch"
    for ($idx = 0; $idx -lt $scenarios.Count; $idx++) {
        $scenario = $scenarios[$idx]
        $label = "Scenario #{0} ({1})" -f ($idx + 1), $scenario.Name
        $expectation = if ($scenario.Expectation) { " (expectation: $($scenario.Expectation))" } else { '' }
        $description = if ($scenario.Description) { $scenario.Description } else { 'No description provided.' }
        Write-Host ("  - {0}: {1}{2}" -f $label, $description, $expectation)
    }
    Write-Host "  - Verify both workflow runs succeed and label updates"
    Write-Host "  - Cleanup branch/PR (unless -KeepBranch)"
    return
}

$scenarioContexts = New-Object System.Collections.Generic.List[pscustomobject]
$overallContext = [ordered]@{
    InitialBranch    = $initialBranch
    Repo             = $repoInfo
    ScenarioContexts = $scenarioContexts
    Success          = $false
    ErrorMessage     = $null
}

try {
    Invoke-Git -Arguments @('fetch', 'origin', $BaseBranch)

    $resultsDir = Join-Path 'tests' 'results' '_agent' 'smoke' 'vi-stage'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    foreach ($scenario in $scenarios) {
        $scenarioName = $scenario.Name
        $scenarioBranch = "{0}-{1}" -f $branchPrefix, $scenarioName
        Write-Host "=== Running scenario: $scenarioName ==="

        Invoke-Git -Arguments @('checkout', '-B', $scenarioBranch, "origin/$BaseBranch")

        $scenarioNote = "$note [$scenarioName]"
        $scenarioSummaryPath = Join-Path $resultsDir ("smoke-{0}-{1}.json" -f $timestamp, $scenarioName)
        $scenarioMetadataPath = Join-Path $resultsDir ("smoke-{0}-{1}-metadata.json" -f $timestamp, $scenarioName)

        $scenarioCtx = [pscustomobject]@{
            Branch      = $scenarioBranch
            Scenario    = $scenarioName
            Note        = $scenarioNote
            SummaryPath = $scenarioSummaryPath
            MetadataPath= $scenarioMetadataPath
            PrNumber    = $null
            PrUrl       = $null
            RunId       = $null
            Success     = $false
        }
        $scenarioContexts.Add($scenarioCtx) | Out-Null

        & $scenario.Prepare

        $metadata = $null
        try {
            $metadata = & $metadataInvoker `
                -BaseVi (Join-Path 'fixtures' 'vi-attr' 'Base.vi') `
                -HeadVi (Join-Path 'fixtures' 'vi-attr' 'Head.vi') `
                -MetadataPath $scenarioMetadataPath `
                -HelperContent $metadataHelperContent
        } catch {
            Write-Warning ("Failed to capture pre-compare metadata for scenario '{0}': {1}" -f $scenarioName, $_.Exception.Message)
        }
        if ($metadata) {
            $scenarioCtx | Add-Member -NotePropertyName Metadata -NotePropertyValue $metadata -Force
        }

        Invoke-Git -Arguments @('commit', '-m', $scenario.CommitMessage)
        Invoke-Git -Arguments @('push', '-u', 'origin', $scenarioBranch)

        $scenarioTitle = "Smoke: VI staging [$scenarioName] ($timestamp)"
        $prBody = @(
            'Automation-only PR used to smoke test the VI staging workflow.',
            '',
            "Scenario: $scenarioName",
            '',
            'Generated by tools/Test-PRVIStagingSmoke.ps1.'
        ) -join "`n"

        Invoke-Gh -Arguments @('pr', 'create',
            '--repo', $repoInfo.Slug,
            '--base', $BaseBranch,
            '--head', $scenarioBranch,
            '--title', $scenarioTitle,
            '--body', $prBody,
            '--draft') | Out-Null
        $prInfo = Get-PullRequestInfo -Repo $repoInfo -Branch $scenarioBranch
        $scenarioCtx.PrNumber = [int]$prInfo.number
        $scenarioCtx.PrUrl = $prInfo.url
        Write-Host "Draft PR ##$($scenarioCtx.PrNumber) created at $($scenarioCtx.PrUrl)."

        $auth = Get-GitHubAuth
        $dispatchUri = "https://api.github.com/repos/$($repoInfo.Slug)/actions/workflows/pr-vi-staging.yml/dispatches"
        $dispatchBody = @{
            ref    = $scenarioBranch
            inputs = @{
                pr   = $scenarioCtx.PrNumber.ToString()
                note = $scenarioNote
            }
        } | ConvertTo-Json -Depth 4
        Write-Host "Triggering pr-vi-staging workflow via dispatch API..."
        Invoke-RestMethod -Uri $dispatchUri -Headers $auth.Headers -Method Post -Body $dispatchBody -ContentType 'application/json'
        Write-Host 'Workflow dispatch accepted.'

        Write-Host 'Waiting for pr-vi-staging workflow to complete...'
        $runId = $null
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $runs = Invoke-Gh -Arguments @('run', 'list',
                '--workflow', 'pr-vi-staging.yml',
                '--branch', $scenarioBranch,
                '--limit', '1',
                '--json', 'databaseId,status,conclusion,headBranch') -ExpectJson
            if ($runs -and $runs.Count -gt 0 -and $runs[0].headBranch -eq $scenarioBranch) {
                $runId = $runs[0].databaseId
                if ($runs[0].status -eq 'completed') { break }
            }
            Start-Sleep -Seconds 5
        }

        if (-not $runId) {
            throw 'Unable to locate dispatched workflow run.'
        }
        $scenarioCtx.RunId = $runId
        Write-Host "Workflow run id: $runId"

        Write-Host "Monitoring workflow run $runId..."
        $watchArgs = @('tools/npm/run-script.mjs', 'ci:watch:rest', '--', '--workflow', '.github/workflows/pr-vi-staging.yml', '--run-id', $runId)
        $watchOutput = node @watchArgs
        if ($LASTEXITCODE -ne 0) {
            throw ("Watcher exited with code {0}:`n{1}" -f $LASTEXITCODE, $watchOutput)
        }
        Write-Host $watchOutput

        $runSummary = Invoke-Gh -Arguments @('run', 'view', $runId.ToString(), '--json', 'conclusion') -ExpectJson
        if ($runSummary.conclusion -ne 'success') {
            throw "Workflow run $runId concluded with '$($runSummary.conclusion)'."
        }

        $labelInfo = Invoke-Gh -Arguments @('pr', 'view', $scenarioCtx.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--json', 'labels') -ExpectJson
        $labels = $labelInfo.labels | ForEach-Object { $_.name }
        if (-not ($labels -contains 'vi-staging-ready')) {
            throw "Expected label 'vi-staging-ready' not found on PR ##$($scenarioCtx.PrNumber)."
        }

        $summary = [ordered]@{
            branch   = $scenarioBranch
            prNumber = $scenarioCtx.PrNumber
            runId    = $scenarioCtx.RunId
            note     = $scenarioNote
            created  = (Get-Date).ToString('o')
            success  = $true
            url      = $scenarioCtx.PrUrl
            metadata = if ($scenarioCtx.PSObject.Properties['Metadata'] -and $scenarioCtx.Metadata) { $scenarioCtx.Metadata } else { $null }
        }
        $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $scenarioSummaryPath -Encoding utf8

        Write-Host "Scenario '$scenarioName' succeeded. Summary written to $scenarioSummaryPath"
        $scenarioCtx.Success = $true
    }

    $overallContext.Success = $true
}
catch {
    $overallContext.ErrorMessage = $_.Exception.Message
    Write-Error $_
    throw
}
finally {
    try {
        Reset-FixtureFiles -Ref "origin/$BaseBranch"
        Invoke-Git -Arguments @('checkout', $overallContext.InitialBranch) | Out-Null
    } catch {
        Write-Warning "Failed to restore fixtures or branch: $($_.Exception.Message)"
    }

    if ($DryRun -or $KeepBranch) {
        Write-Host 'Skipping cleanup per request.'
    } else {
        Write-Host 'Cleaning up scratch resources...'
        foreach ($scenarioCtx in $scenarioContexts) {
            try {
                if ($scenarioCtx.PrNumber) {
                    Invoke-Gh -Arguments @('pr', 'edit', $scenarioCtx.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--remove-label', 'vi-staging-ready') -ErrorAction SilentlyContinue | Out-Null
                    Invoke-Gh -Arguments @('pr', 'close', $scenarioCtx.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--delete-branch') -ErrorAction SilentlyContinue | Out-Null
                }
            } catch {
                Write-Warning "PR cleanup encountered an issue for scenario '$($scenarioCtx.Scenario)': $($_.Exception.Message)"
            }

            try {
                Invoke-Git -Arguments @('branch', '-D', $scenarioCtx.Branch) | Out-Null
            } catch {
                # ignore branch delete failures
            }
        }
    }

    if ($restoreFlagsMode) {
        [System.Environment]::SetEnvironmentVariable('RUN_STAGED_LVCOMPARE_FLAGS_MODE', $originalFlagsMode, 'Process')
    }
}
    if (-not (Test-Path -LiteralPath 'VI2.vi' -PathType Leaf)) {
        throw "Diff fixture missing: VI2.vi"
    }
