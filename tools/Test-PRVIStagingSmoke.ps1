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
$scratchBranch = "smoke/vi-stage-$timestamp"
$prTitle = "Smoke: VI staging label test ($timestamp)"
$note = "staging smoke $timestamp"

Write-Host "Scratch branch: $scratchBranch"

if ($DryRun) {
    Write-Host "Dry-run mode: no changes will be made."
    Write-Host "Plan:"
    Write-Host "  - Fetch origin/$BaseBranch"
    Write-Host "  - Create $scratchBranch from origin/$BaseBranch"
    Write-Host "  - Scenario #1 (no-diff): copy fixtures/vi-attr/Head.vi over Base.vi, commit, push, dispatch pr-vi-staging.yml"
    Write-Host "  - Scenario #2 (diff): restore fixtures, copy fixtures/vi-attr/VI2.vi over Head.vi, commit, push, dispatch pr-vi-staging.yml"
    Write-Host "  - Verify both workflow runs succeed and label updates"
    Write-Host "  - Cleanup branch/PR (unless -KeepBranch)"
    return
}

$context = [ordered]@{
    InitialBranch = $initialBranch
    ScratchBranch = $scratchBranch
    Repo          = $repoInfo
    PrNumber      = $null
    PrUrl         = $null
    WorkflowRunId = $null
    Success       = $false
    ErrorMessage  = $null
    SummaryPath   = $null
    Note          = $note
    Summaries     = New-Object System.Collections.Generic.List[string]
}

try {
    Invoke-Git -Arguments @('fetch', 'origin', $BaseBranch)
    Invoke-Git -Arguments @('checkout', '-b', $scratchBranch, "origin/$BaseBranch")

    $context.Summaries = New-Object System.Collections.Generic.List[string]

    $fixtureRef = "origin/$BaseBranch"
    $resultsDir = Join-Path 'tests' 'results' '_agent' 'smoke' 'vi-stage'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    $scenarios = @(
        @{
            Name          = 'no-diff'
            CommitMessage = 'chore: synthetic VI changes for staging smoke'
            Prepare       = {
                Reset-FixtureFiles -Ref $fixtureRef
                Copy-ViContent -Source 'fixtures/vi-attr/Head.vi' -Destination 'fixtures/vi-attr/Base.vi'
                Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi')
            }.GetNewClosure()
        },
        @{
            Name          = 'vi2-diff'
            CommitMessage = 'chore: synthetic VI diff for staging smoke'
            Prepare       = {
                Reset-FixtureFiles -Ref $fixtureRef
                Copy-ViContent -Source 'fixtures/vi-attr/Head.vi' -Destination 'fixtures/vi-attr/Base.vi'
                Touch-ViFile -Path 'fixtures/vi-attr/Head.vi'
                Invoke-Git -Arguments @('add', 'fixtures/vi-attr/Base.vi', 'fixtures/vi-attr/Head.vi')
            }.GetNewClosure()
        }
    )

    $isFirstScenario = $true
    foreach ($scenario in $scenarios) {
        $scenarioName = $scenario.Name
        Write-Host "=== Running scenario: $scenarioName ==="

        $scenarioNote = "$note [$scenarioName]"
        $scenarioSummaryPath = Join-Path $resultsDir ("smoke-{0}-{1}.json" -f $timestamp, $scenarioName)
        $context.SummaryPath = $scenarioSummaryPath
        $context.Note = $scenarioNote

        & $scenario.Prepare

        Invoke-Git -Arguments @('commit', '-m', $scenario.CommitMessage)

        $pushArgs = if ($isFirstScenario) { @('push', '-u', 'origin', $scratchBranch) } else { @('push', 'origin', $scratchBranch) }
        Invoke-Git -Arguments $pushArgs

        if ($isFirstScenario) {
            $prBody = @(
                'Automation-only PR used to smoke test the VI staging workflow.',
                '',
                'Generated by tools/Test-PRVIStagingSmoke.ps1.'
            ) -join "`n"

            Invoke-Gh -Arguments @('pr', 'create',
                '--repo', $repoInfo.Slug,
                '--base', $BaseBranch,
                '--head', $scratchBranch,
                '--title', $prTitle,
                '--body', $prBody,
                '--draft') | Out-Null
            $prInfo = Get-PullRequestInfo -Repo $repoInfo -Branch $scratchBranch
            $context.PrNumber = [int]$prInfo.number
            $context.PrUrl = $prInfo.url
            Write-Host "Draft PR ##$($context.PrNumber) created at $($context.PrUrl)."
        }

        $auth = Get-GitHubAuth
        $dispatchUri = "https://api.github.com/repos/$($repoInfo.Slug)/actions/workflows/pr-vi-staging.yml/dispatches"
        $dispatchBody = @{
            ref    = $scratchBranch
            inputs = @{
                pr   = $context.PrNumber.ToString()
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
                '--branch', $scratchBranch,
                '--limit', '1',
                '--json', 'databaseId,status,conclusion,headBranch') -ExpectJson
            if ($runs -and $runs.Count -gt 0 -and $runs[0].headBranch -eq $scratchBranch) {
                $runId = $runs[0].databaseId
                if ($runs[0].status -eq 'completed') { break }
            }
            Start-Sleep -Seconds 5
        }

        if (-not $runId) {
            throw 'Unable to locate dispatched workflow run.'
        }
        $context.WorkflowRunId = $runId
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

        $labelInfo = Invoke-Gh -Arguments @('pr', 'view', $context.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--json', 'labels') -ExpectJson
        $labels = $labelInfo.labels | ForEach-Object { $_.name }
        if (-not ($labels -contains 'vi-staging-ready')) {
            throw "Expected label 'vi-staging-ready' not found on PR ##$($context.PrNumber)."
        }

        $summary = [ordered]@{
            branch   = $scratchBranch
            prNumber = $context.PrNumber
            runId    = $runId
            note     = $scenarioNote
            created  = (Get-Date).ToString('o')
            success  = $true
            url      = $context.PrUrl
        }
        $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $scenarioSummaryPath -Encoding utf8
        $context.Summaries.Add($scenarioSummaryPath) | Out-Null

        Write-Host "Scenario '$scenarioName' succeeded. Summary written to $scenarioSummaryPath"

        $isFirstScenario = $false
    }

    $context.Success = $true
}
catch {
    $context.ErrorMessage = $_.Exception.Message
    Write-Error $_
    throw
}
finally {
    try {
        $resultsDir = Join-Path 'tests' 'results' '_agent' 'smoke' 'vi-stage'
        New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
        if (-not $context.SummaryPath) {
            $context.SummaryPath = Join-Path $resultsDir "smoke-$timestamp.json"
            $summary = [ordered]@{
                branch   = $scratchBranch
                prNumber = $context.PrNumber
                runId    = $context.WorkflowRunId
                note     = $context.Note
                created  = (Get-Date).ToString('o')
                success  = $context.Success
                url      = $context.PrUrl
            }
            if ($context.ErrorMessage) {
                $summary.error = $context.ErrorMessage
            }
            $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $context.SummaryPath -Encoding utf8
        }
    } catch {
        Write-Warning "Failed to write smoke summary: $($_.Exception.Message)"
    }

    if ($DryRun -or $KeepBranch) {
        Write-Host 'Skipping cleanup per request.'
    } else {
        Write-Host 'Cleaning up scratch resources...'

        try {
            if ($context.PrNumber) {
                Invoke-Gh -Arguments @('pr', 'edit', $context.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--remove-label', 'vi-staging-ready') -ErrorAction SilentlyContinue | Out-Null
                Invoke-Gh -Arguments @('pr', 'close', $context.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--delete-branch') -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {
            Write-Warning "PR cleanup encountered an issue: $($_.Exception.Message)"
        }

        try {
            Invoke-Git -Arguments @('checkout', $context.InitialBranch) | Out-Null
        } catch {
            Write-Warning "Failed to restore branch $($context.InitialBranch): $($_.Exception.Message)"
        }

        try {
            Invoke-Git -Arguments @('branch', '-D', $context.ScratchBranch) | Out-Null
        } catch {
            # ignore
        }
    }
}
