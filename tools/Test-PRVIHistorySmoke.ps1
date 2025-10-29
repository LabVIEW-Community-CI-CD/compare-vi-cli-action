#Requires -Version 7.0
<#
.SYNOPSIS
End-to-end smoke test for the PR VI history workflow.

.DESCRIPTION
Creates a disposable branch with a synthetic VI change, opens a draft PR,
dispatches `pr-vi-history.yml`, monitors the workflow to completion, and
verifies that the PR comment includes the history summary. By default the PR
and branch are deleted once the smoke run succeeds.

.PARAMETER BaseBranch
Branch to branch from when generating the synthetic history change. Defaults to
`develop`.

.PARAMETER KeepBranch
Skip cleanup so the scratch branch and draft PR remain available for inspection.

.PARAMETER DryRun
Emit the planned steps without executing them.

.PARAMETER MaxPairs
Optional override for the `max_pairs` workflow input. Defaults to `6`.
#>
[CmdletBinding()]
param(
    [string]$BaseBranch = 'develop',
    [switch]$KeepBranch,
    [switch]$DryRun,
    [int]$MaxPairs = 6
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
        'User-Agent'  = 'compare-vi-history-smoke'
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

function Ensure-CleanWorkingTree {
    $status = @(Invoke-Git -Arguments @('status', '--porcelain'))
    if ($status.Count -eq 1 -and [string]::IsNullOrWhiteSpace($status[0])) {
        $status = @()
    }
    if ($status.Count -gt 0) {
        throw 'Working tree not clean. Commit or stash changes before running the smoke test.'
    }
}

function Copy-VIContent {
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

$script:HistoryTrackingFlags = [ordered]@{
    assume = $false
    skip   = $false
}
function Enable-HistoryTracking {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    try {
        $lsEntry = Invoke-Git -Arguments @('ls-files', '-v', $Path) | Select-Object -First 1
        if ($lsEntry) {
            $prefix = $lsEntry.Substring(0,1)
            if ($prefix -match '[Hh]') { $script:HistoryTrackingFlags.assume = $true }
            if ($prefix -match '[Ss]') { $script:HistoryTrackingFlags.skip = $true }
        }
    } catch {
        Write-Warning ("Failed to query tracking flags for {0}: {1}" -f $Path, $_.Exception.Message)
    }

    try {
        Invoke-Git -Arguments @('update-index', '--no-assume-unchanged', $Path) | Out-Null
        Invoke-Git -Arguments @('update-index', '--no-skip-worktree', $Path) | Out-Null
    } catch {
        Write-Warning ("Failed to adjust tracking flags for {0}: {1}" -f $Path, $_.Exception.Message)
    }
}

function Restore-HistoryTracking {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    try {
        if ($script:HistoryTrackingFlags.assume) {
            Invoke-Git -Arguments @('update-index', '--assume-unchanged', $Path) | Out-Null
        }
        if ($script:HistoryTrackingFlags.skip) {
            Invoke-Git -Arguments @('update-index', '--skip-worktree', $Path) | Out-Null
        }
    } catch {
        Write-Warning ("Failed to restore tracking flags for {0}: {1}" -f $Path, $_.Exception.Message)
    } finally {
        $script:HistoryTrackingFlags.assume = $false
        $script:HistoryTrackingFlags.skip = $false
    }
}

Write-Verbose "Base branch: $BaseBranch"
Write-Verbose "KeepBranch: $KeepBranch"
Write-Verbose "DryRun: $DryRun"
Write-Verbose "MaxPairs: $MaxPairs"

$repoInfo = Get-RepoInfo
$initialBranch = Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1

Ensure-CleanWorkingTree

$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
$branchName = "smoke/vi-history-$timestamp"
$prTitle = "Smoke: VI history compare ($timestamp)"
$prNote = "vi-history smoke $timestamp"
$summaryDir = Join-Path 'tests' 'results' '_agent' 'smoke' 'vi-history'
New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
$summaryPath = Join-Path $summaryDir ("vi-history-smoke-{0}.json" -f $timestamp)
$workflowPath = '.github/workflows/pr-vi-history.yml'

if ($DryRun) {
    Write-Host 'Dry-run mode: no changes will be made.'
    Write-Host 'Plan:'
    Write-Host "  - Fetch origin/$BaseBranch"
    Write-Host "  - Create branch $branchName from origin/$BaseBranch"
    Write-Host "  - Replace fixtures/vi-attr/Head.vi with attribute variant and commit"
    Write-Host "  - Push scratch branch and create draft PR"
    Write-Host "  - Dispatch pr-vi-history.yml with PR input (max_pairs=$MaxPairs)"
    Write-Host '  - Wait for workflow completion and verify PR comment'
    Write-Host '  - Record summary under tests/results/_agent/smoke/vi-history/'
    if (-not $KeepBranch) {
        Write-Host '  - Close draft PR and delete branch'
    } else {
        Write-Host '  - Leave branch/PR for inspection (KeepBranch present)'
    }
    return
}

$scratchContext = [ordered]@{
    Branch        = $branchName
    PrNumber      = $null
    PrUrl         = $null
    RunId         = $null
    CommentFound  = $false
    WorkflowUrl   = $null
    Success       = $false
    Note          = $prNote
}

try {
    Invoke-Git -Arguments @('fetch', 'origin', $BaseBranch) | Out-Null

    Invoke-Git -Arguments @('checkout', "-B$branchName", "origin/$BaseBranch") | Out-Null

    $sourceVi = 'fixtures/vi-attr/Base.vi'
    $targetVi = 'fixtures/vi-attr/Head.vi'
    Enable-HistoryTracking -Path $targetVi
    Write-Host "Applying synthetic history change: $targetVi <= $sourceVi"
    Copy-VIContent -Source $sourceVi -Destination $targetVi
    $statusAfterPrep = Invoke-Git -Arguments @('status', '--short', $targetVi)
    Write-Host ("Post-change status for {0}: {1}" -f $targetVi, ($statusAfterPrep -join ' '))
    Invoke-Git -Arguments @('add', '-f', $targetVi) | Out-Null
    Invoke-Git -Arguments @('commit', '-m', 'chore: synthetic VI attr diff for history smoke') | Out-Null

    Invoke-Git -Arguments @('push', '-u', 'origin', $branchName) | Out-Null

    Write-Host "Creating draft PR for branch $branchName..."
    $prBody = @(
        '# VI history smoke test',
        '',
        '*This PR was generated by tools/Test-PRVIHistorySmoke.ps1.*',
        '',
        '- Scenario: synthetic attribute difference',
        '- Expectation: `/vi-history` workflow completes successfully'
    ) -join "`n"
    Invoke-Gh -Arguments @('pr', 'create',
        '--repo', $repoInfo.Slug,
        '--base', $BaseBranch,
        '--head', $branchName,
        '--title', $prTitle,
        '--body', $prBody,
        '--draft') | Out-Null

    $prInfo = Get-PullRequestInfo -Repo $repoInfo -Branch $branchName
    $scratchContext.PrNumber = [int]$prInfo.number
    $scratchContext.PrUrl = $prInfo.html_url
    Write-Host "Draft PR ##$($scratchContext.PrNumber) created at $($scratchContext.PrUrl)."

    $auth = Get-GitHubAuth
    $dispatchUri = "https://api.github.com/repos/$($repoInfo.Slug)/actions/workflows/pr-vi-history.yml/dispatches"
    $dispatchBody = @{
        ref    = $branchName
        inputs = @{
            pr        = $scratchContext.PrNumber.ToString()
            max_pairs = $MaxPairs.ToString()
        }
    } | ConvertTo-Json -Depth 4
    Write-Host 'Triggering pr-vi-history workflow via dispatch API...'
    Invoke-RestMethod -Uri $dispatchUri -Headers $auth.Headers -Method Post -Body $dispatchBody -ContentType 'application/json'
    Write-Host 'Workflow dispatch accepted.'

    Write-Host 'Waiting for workflow run to appear...'
    $runId = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $runs = Invoke-Gh -Arguments @(
            'run', 'list',
            '--workflow', 'pr-vi-history.yml',
            '--branch', $branchName,
            '--limit', '1',
            '--json', 'databaseId,status,conclusion,headBranch'
        ) -ExpectJson
        if ($runs -and $runs.Count -gt 0 -and $runs[0].headBranch -eq $branchName) {
            $runId = $runs[0].databaseId
            if ($runs[0].status -eq 'completed') { break }
        }
        Start-Sleep -Seconds 5
    }
    if (-not $runId) {
        throw 'Unable to locate dispatched workflow run.'
    }
    $scratchContext.RunId = $runId
    $scratchContext.WorkflowUrl = "https://github.com/$($repoInfo.Slug)/actions/runs/$runId"
    Write-Host "Workflow run id: $runId"

    Write-Host "Watching workflow run $runId..."
    Invoke-Gh -Arguments @('run', 'watch', $runId.ToString(), '--exit-status') | Out-Null

    $runSummary = Invoke-Gh -Arguments @('run', 'view', $runId.ToString(), '--json', 'conclusion') -ExpectJson
    if ($runSummary.conclusion -ne 'success') {
        throw "Workflow run $runId concluded with '$($runSummary.conclusion)'."
    }

    Write-Host 'Verifying PR comment includes history summary...'
    $prDetails = Invoke-Gh -Arguments @('pr', 'view', $scratchContext.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--json', 'comments') -ExpectJson
    $commentBodies = @()
    if ($prDetails -and $prDetails.comments) {
        $commentBodies = @($prDetails.comments | ForEach-Object { $_.body })
    }
    $scratchContext.CommentFound = $commentBodies | Where-Object { $_ -like '*VI history compare*' } | ForEach-Object { $true } | Select-Object -First 1
    if (-not $scratchContext.CommentFound) {
        throw 'Expected `/vi-history` comment not found on the draft PR.'
    }

    $scratchContext.Success = $true
    Write-Host 'Smoke run succeeded.'
}
catch {
    $scratchContext.Success = $false
    $scratchContext.ErrorMessage = $_.Exception.Message
    Write-Error $_
    throw
}
finally {
    try {
        Invoke-Git -Arguments @('checkout', $initialBranch) | Out-Null
    } catch {
        Write-Warning ("Failed to return to initial branch {0}: {1}" -f $initialBranch, $_.Exception.Message)
    }
    Restore-HistoryTracking -Path 'fixtures/vi-attr/Head.vi'

    if (-not $KeepBranch) {
        Write-Host 'Cleaning up scratch PR and branch...'
        try {
            if ($scratchContext.PrNumber) {
                Invoke-Gh -Arguments @('pr', 'close', $scratchContext.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--delete-branch') | Out-Null
            }
        } catch {
            Write-Warning "PR cleanup encountered an issue: $($_.Exception.Message)"
        }
        try {
            Invoke-Git -Arguments @('branch', '-D', $branchName) | Out-Null
        } catch {
            # ignore branch delete failures
        }
        try {
            Invoke-Git -Arguments @('push', 'origin', "--delete", $branchName) | Out-Null
        } catch {
            # ignore remote delete failures
        }
    } else {
        Write-Host 'KeepBranch specified - leaving scratch PR and branch in place.'
    }

    $scratchContext.SummaryGeneratedAt = (Get-Date).ToString('o')
    $scratchContext.KeepBranch = [bool]$KeepBranch
    $scratchContext.BaseBranch = $BaseBranch
    $scratchContext.MaxPairs = $MaxPairs
    $scratchContext.InitialBranch = $initialBranch

    $scratchContext | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    Write-Host "Summary written to $summaryPath"
}
