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

.PARAMETER Scenario
Selects which synthetic change set to exercise. Use `attribute` for the legacy
single-commit attr diff, `sequential` to replay multiple fixture commits, or
`mixed-same-commit` to mutate two VI targets in a single commit (strict signal
plus non-strict metadata-noise coverage), or `sequential-masscompile` to replay
masscompile-only commits around a mixed signal+noise commit.

.PARAMETER MaxPairs
Optional override for the `max_pairs` workflow input. Defaults to `6`.

.PARAMETER WorkflowTimeoutMinutes
Optional override for the `history_timeout_minutes` workflow input used by
`pr-vi-history.yml`. Defaults to `10` for smoke evidence runs.

.PARAMETER CompareTimeoutSeconds
Optional override for the `compare_timeout_seconds` workflow input used by
`pr-vi-history.yml`. Defaults to `600` for smoke evidence runs.

.PARAMETER BenchmarkBaselineWindow
Rolling baseline window (same scenario) used when computing KPI deltas.

.PARAMETER EvidenceIssueNumber
Optional issue number where KPI delta markdown should be posted.
#>
[CmdletBinding()]
param(
    [string]$BaseBranch = 'develop',
    [switch]$KeepBranch,
    [switch]$DryRun,
    [ValidateSet('attribute', 'sequential', 'mixed-same-commit', 'sequential-masscompile')]
    [string]$Scenario = 'attribute',
    [int]$MaxPairs = 6,
    [int]$WorkflowTimeoutMinutes = 10,
    [int]$CompareTimeoutSeconds = 600,
    [ValidateRange(1, 50)]
    [int]$BenchmarkBaselineWindow = 5,
    [int]$EvidenceIssueNumber = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$policyHelperPath = Join-Path $PSScriptRoot 'Resolve-VIHistoryPolicyDecision.ps1'
if (-not (Test-Path -LiteralPath $policyHelperPath -PathType Leaf)) {
    throw "Policy helper not found: $policyHelperPath"
}
. $policyHelperPath

$pairTimelineHelperPath = Join-Path $PSScriptRoot 'Get-VIHistoryPairTimeline.ps1'
if (-not (Test-Path -LiteralPath $pairTimelineHelperPath -PathType Leaf)) {
    throw "Pair timeline helper not found: $pairTimelineHelperPath"
}
. $pairTimelineHelperPath

$benchmarkWriterPath = Join-Path $PSScriptRoot 'Write-VIHistoryBenchmark.ps1'
if (-not (Test-Path -LiteralPath $benchmarkWriterPath -PathType Leaf)) {
    throw "Benchmark writer helper not found: $benchmarkWriterPath"
}

if ($WorkflowTimeoutMinutes -lt 1) {
    throw 'WorkflowTimeoutMinutes must be greater than zero.'
}
if ($CompareTimeoutSeconds -lt 1) {
    throw 'CompareTimeoutSeconds must be greater than zero.'
}

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

function Wait-WorkflowRunCompletion {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Repo,
        [Parameter(Mandatory)]
        [int64]$RunId,
        [int]$TimeoutMinutes = 60,
        [int]$PollSeconds = 5
    )

    $auth = Get-GitHubAuth
    $uri = "https://api.github.com/repos/$($Repo.Slug)/actions/runs/$RunId"
    $deadline = (Get-Date).ToUniversalTime().AddMinutes([Math]::Max(1, $TimeoutMinutes))
    $lastPollError = $null
    do {
        try {
            $run = Invoke-RestMethod -Uri $uri -Headers $auth.Headers -Method Get -ErrorAction Stop
            $lastPollError = $null
            if ($run.status -eq 'completed') {
                return $run
            }
        } catch {
            $lastPollError = $_
            $errorText = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { [string]$_ }
            $compactError = ($errorText -replace '\s+', ' ').Trim()
            $isTransient = $compactError -match '(?i)(unicorn|issues producing the response|502|503|504|gateway|temporar|timeout|timed out)'
            if (-not $isTransient) {
                throw
            }
            if ($compactError.Length -gt 220) {
                $compactError = $compactError.Substring(0, 220) + '...'
            }
            Write-Warning ("Transient workflow polling error for run {0}; retrying: {1}" -f $RunId, $compactError)
        }
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
    } while ((Get-Date).ToUniversalTime() -lt $deadline)

    $timeoutMessage = "Timed out waiting for workflow run $RunId to complete after $TimeoutMinutes minute(s)."
    if ($lastPollError -and $lastPollError.Exception -and $lastPollError.Exception.Message) {
        $lastMessage = ($lastPollError.Exception.Message -replace '\s+', ' ').Trim()
        if ($lastMessage.Length -gt 220) {
            $lastMessage = $lastMessage.Substring(0, 220) + '...'
        }
        $timeoutMessage = "$timeoutMessage Last polling error: $lastMessage"
    }
    throw $timeoutMessage
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

$script:HistoryTrackingFlagsByPath = @{}
function Enable-HistoryTracking {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $pathKey = $Path.ToLowerInvariant()
    if ($script:HistoryTrackingFlagsByPath.ContainsKey($pathKey)) {
        return
    }

    $trackingFlags = [ordered]@{
        assume = $false
        skip   = $false
    }

    try {
        $lsEntry = Invoke-Git -Arguments @('ls-files', '-v', $Path) | Select-Object -First 1
        if ($lsEntry) {
            $prefix = $lsEntry.Substring(0,1)
            if ($prefix -match '[Hh]') { $trackingFlags.assume = $true }
            if ($prefix -match '[Ss]') { $trackingFlags.skip = $true }
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

    $script:HistoryTrackingFlagsByPath[$pathKey] = $trackingFlags
}

function Restore-HistoryTracking {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $pathKey = $Path.ToLowerInvariant()
    if (-not $script:HistoryTrackingFlagsByPath.ContainsKey($pathKey)) {
        return
    }
    $trackingFlags = $script:HistoryTrackingFlagsByPath[$pathKey]

    try {
        if ($trackingFlags.assume) {
            Invoke-Git -Arguments @('update-index', '--assume-unchanged', $Path) | Out-Null
        }
        if ($trackingFlags.skip) {
            Invoke-Git -Arguments @('update-index', '--skip-worktree', $Path) | Out-Null
        }
    } catch {
        Write-Warning ("Failed to restore tracking flags for {0}: {1}" -f $Path, $_.Exception.Message)
    } finally {
        $script:HistoryTrackingFlagsByPath.Remove($pathKey) | Out-Null
    }
}


$script:SequentialFixtureCache = $null
$script:MixedSameCommitFixtureCache = $null
$script:SequentialMasscompileFixtureCache = $null

function Get-SequentialHistorySequence {
    if ($script:SequentialFixtureCache) {
        return $script:SequentialFixtureCache
    }

    $repoRoot = Invoke-Git -Arguments @('rev-parse', '--show-toplevel') | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'Unable to resolve repository root for sequential history fixture.'
    }

    $fixturePath = Join-Path $repoRoot 'fixtures' 'vi-history' 'sequential.json'
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw "Sequential history fixture not found: $fixturePath"
    }

    try {
        $fixtureRaw = Get-Content -LiteralPath $fixturePath -Raw -ErrorAction Stop
        $fixtureObj = $fixtureRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw ("Unable to parse sequential history fixture {0}: {1}" -f $fixturePath, $_.Exception.Message)
    }

    if ($fixtureObj.schema -ne 'vi-history-sequence@v1') {
        throw "Unsupported sequential fixture schema '$($fixtureObj.schema)' (expected vi-history-sequence@v1)."
    }

    if ([string]::IsNullOrWhiteSpace($fixtureObj.targetPath)) {
        throw 'Sequential history fixture must declare targetPath.'
    }

    if (-not $fixtureObj.steps -or $fixtureObj.steps.Count -eq 0) {
        throw 'Sequential history fixture must define at least one step.'
    }

    $targetResolved = if ([System.IO.Path]::IsPathRooted($fixtureObj.targetPath)) {
        $fixtureObj.targetPath
    } else {
        Join-Path $repoRoot $fixtureObj.targetPath
    }

    if (-not (Test-Path -LiteralPath $targetResolved -PathType Leaf)) {
        throw "Sequential history target not found on disk: $($fixtureObj.targetPath)"
    }

    $stepObjects = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($step in $fixtureObj.steps) {
        if (-not $step.source) {
            throw 'Sequential history fixture step missing source path.'
        }

        $resolvedSource = if ([System.IO.Path]::IsPathRooted($step.source)) {
            $step.source
        } else {
            Join-Path $repoRoot $step.source
        }

        if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
            throw "Sequential history source not found: $($step.source)"
        }

        $stepObjects.Add([pscustomobject]@{
            id             = $step.id
            title          = $step.title
            message        = $step.message
            source         = $step.source
            resolvedSource = $resolvedSource
        }) | Out-Null
    }

    $script:SequentialFixtureCache = [pscustomobject]@{
        path               = $fixturePath
        repoRoot           = $repoRoot
        targetPathRelative = $fixtureObj.targetPath
        targetPathResolved = $targetResolved
        steps              = $stepObjects
        maxPairs           = if ($fixtureObj.PSObject.Properties['maxPairs']) { [int]$fixtureObj.maxPairs } else { $null }
    }

    return $script:SequentialFixtureCache
}

function Get-MixedSameCommitFixture {
    if ($script:MixedSameCommitFixtureCache) {
        return $script:MixedSameCommitFixtureCache
    }

    $repoRoot = Invoke-Git -Arguments @('rev-parse', '--show-toplevel') | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'Unable to resolve repository root for mixed same-commit fixture.'
    }

    $fixturePath = Join-Path $repoRoot 'fixtures' 'vi-history' 'mixed-same-commit.json'
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw "Mixed same-commit fixture not found: $fixturePath"
    }

    try {
        $fixtureRaw = Get-Content -LiteralPath $fixturePath -Raw -ErrorAction Stop
        $fixtureObj = $fixtureRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw ("Unable to parse mixed same-commit fixture {0}: {1}" -f $fixturePath, $_.Exception.Message)
    }

    if ($fixtureObj.schema -ne 'vi-history-mixed-commit@v1') {
        throw "Unsupported mixed fixture schema '$($fixtureObj.schema)' (expected vi-history-mixed-commit@v1)."
    }
    if (-not $fixtureObj.commit -or -not $fixtureObj.commit.changes -or $fixtureObj.commit.changes.Count -lt 2) {
        throw 'Mixed same-commit fixture must define at least two commit changes.'
    }

    $changeObjects = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($change in $fixtureObj.commit.changes) {
        if (-not $change.targetPath) {
            throw 'Mixed same-commit fixture change missing targetPath.'
        }
        if (-not $change.source) {
            throw ("Mixed same-commit fixture change '{0}' missing source path." -f $change.targetPath)
        }

        $resolvedTarget = if ([System.IO.Path]::IsPathRooted($change.targetPath)) {
            $change.targetPath
        } else {
            Join-Path $repoRoot $change.targetPath
        }
        $resolvedSource = if ([System.IO.Path]::IsPathRooted($change.source)) {
            $change.source
        } else {
            Join-Path $repoRoot $change.source
        }
        if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Leaf)) {
            throw "Mixed fixture target not found: $($change.targetPath)"
        }
        if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
            throw "Mixed fixture source not found: $($change.source)"
        }

        $changeObjects.Add([pscustomobject]@{
            id               = $change.id
            title            = $change.title
            targetPath       = [string]$change.targetPath
            resolvedTarget   = [string]$resolvedTarget
            source           = [string]$change.source
            resolvedSource   = [string]$resolvedSource
            requireDiff      = [bool]$change.requireDiff
            minDiffs         = if ($change.PSObject.Properties['minDiffs']) { [int]$change.minDiffs } else { if ([bool]$change.requireDiff) { 1 } else { 0 } }
            classificationHint = if ($change.PSObject.Properties['classificationHint']) { [string]$change.classificationHint } else { $null }
        }) | Out-Null
    }

    $script:MixedSameCommitFixtureCache = [pscustomobject]@{
        path         = $fixturePath
        repoRoot     = $repoRoot
        maxPairs     = if ($fixtureObj.PSObject.Properties['maxPairs']) { [int]$fixtureObj.maxPairs } else { $null }
        commitMessage= if ($fixtureObj.commit.PSObject.Properties['message']) { [string]$fixtureObj.commit.message } else { 'chore: mixed same-commit VI history update' }
        changes      = $changeObjects
    }
    return $script:MixedSameCommitFixtureCache
}

function Get-SequentialMasscompileFixture {
    if ($script:SequentialMasscompileFixtureCache) {
        return $script:SequentialMasscompileFixtureCache
    }

    $repoRoot = Invoke-Git -Arguments @('rev-parse', '--show-toplevel') | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'Unable to resolve repository root for sequential masscompile fixture.'
    }

    $fixturePath = Join-Path $repoRoot 'fixtures' 'vi-history' 'sequential-masscompile.json'
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw "Sequential masscompile fixture not found: $fixturePath"
    }

    try {
        $fixtureRaw = Get-Content -LiteralPath $fixturePath -Raw -ErrorAction Stop
        $fixtureObj = $fixtureRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw ("Unable to parse sequential masscompile fixture {0}: {1}" -f $fixturePath, $_.Exception.Message)
    }

    if ($fixtureObj.schema -ne 'vi-history-sequence-matrix@v1') {
        throw "Unsupported sequential masscompile fixture schema '$($fixtureObj.schema)' (expected vi-history-sequence-matrix@v1)."
    }
    if (-not $fixtureObj.commits -or $fixtureObj.commits.Count -lt 1) {
        throw 'Sequential masscompile fixture must define at least one commit.'
    }

    $commitObjects = New-Object System.Collections.Generic.List[pscustomobject]
    $commitIdSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($commit in $fixtureObj.commits) {
        $commitId = if ($commit.PSObject.Properties['id']) { [string]$commit.id } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($commitId)) {
            $commitIdSet.Add($commitId) | Out-Null
        }
        if (-not $commit.changes -or $commit.changes.Count -lt 1) {
            throw ("Sequential masscompile commit '{0}' must define at least one change." -f $commitId)
        }

        $changeObjects = New-Object System.Collections.Generic.List[pscustomobject]
        foreach ($change in $commit.changes) {
            if (-not $change.targetPath) {
                throw ("Sequential masscompile commit '{0}' change missing targetPath." -f $commitId)
            }
            if (-not $change.source) {
                throw ("Sequential masscompile commit '{0}' change '{1}' missing source path." -f $commitId, $change.targetPath)
            }

            $resolvedTarget = if ([System.IO.Path]::IsPathRooted($change.targetPath)) {
                $change.targetPath
            } else {
                Join-Path $repoRoot $change.targetPath
            }
            $resolvedSource = if ([System.IO.Path]::IsPathRooted($change.source)) {
                $change.source
            } else {
                Join-Path $repoRoot $change.source
            }

            if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Leaf)) {
                throw ("Sequential masscompile target not found: {0}" -f $change.targetPath)
            }
            if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
                throw ("Sequential masscompile source not found: {0}" -f $change.source)
            }

            $changeObjects.Add([pscustomobject]@{
                id                = if ($change.PSObject.Properties['id']) { [string]$change.id } else { $null }
                title             = if ($change.PSObject.Properties['title']) { [string]$change.title } else { $null }
                targetPath        = [string]$change.targetPath
                resolvedTarget    = [string]$resolvedTarget
                source            = [string]$change.source
                resolvedSource    = [string]$resolvedSource
                requireDiff       = if ($change.PSObject.Properties['requireDiff']) { [bool]$change.requireDiff } else { $false }
                minDiffs          = if ($change.PSObject.Properties['minDiffs']) { [int]$change.minDiffs } else { if ($change.requireDiff) { 1 } else { 0 } }
                classificationHint= if ($change.PSObject.Properties['classificationHint']) { [string]$change.classificationHint } else { $null }
            }) | Out-Null
        }

        $commitObjects.Add([pscustomobject]@{
            id      = $commitId
            title   = if ($commit.PSObject.Properties['title']) { [string]$commit.title } else { $commitId }
            message = if ($commit.PSObject.Properties['message']) { [string]$commit.message } else { "chore: sequential masscompile step $($commitObjects.Count + 1)" }
            changes = $changeObjects
        }) | Out-Null
    }

    $script:SequentialMasscompileFixtureCache = [pscustomobject]@{
        path     = $fixturePath
        repoRoot = $repoRoot
        maxPairs = if ($fixtureObj.PSObject.Properties['maxPairs']) { [int]$fixtureObj.maxPairs } else { $null }
        commits  = $commitObjects
    }
    return $script:SequentialMasscompileFixtureCache
}

function Invoke-MixedSameCommitHistoryCommit {
    $fixture = Get-MixedSameCommitFixture
    Write-Verbose ("Mixed same-commit fixture loaded from {0}" -f $fixture.path)

    $expectedTargets = New-Object System.Collections.Generic.List[pscustomobject]
    $changedTargets = New-Object System.Collections.Generic.List[string]
    foreach ($change in $fixture.changes) {
        Write-Host ("Applying mixed same-commit change: {0} <= {1}" -f $change.targetPath, $change.source)
        Copy-VIContent -Source $change.resolvedSource -Destination $change.resolvedTarget
        $statusAfterStep = @(Invoke-Git -Arguments @('status', '--porcelain', '--', $change.targetPath))
        Write-Host ("Post-change status for {0}: {1}" -f $change.targetPath, ($statusAfterStep -join ' '))
        if ($statusAfterStep.Count -eq 0) {
            throw ("Mixed fixture change produced no delta for target '{0}'." -f $change.targetPath)
        }
        Invoke-Git -Arguments @('add', '-f', $change.targetPath) | Out-Null
        $changedTargets.Add([string]$change.targetPath) | Out-Null

        $expectedTargets.Add([pscustomobject]@{
            repoPath          = [string]$change.targetPath
            requireDiff       = [bool]$change.requireDiff
            minDiffs          = [int]$change.minDiffs
            classificationHint= $change.classificationHint
        }) | Out-Null
    }

    if ($changedTargets.Count -lt 2) {
        throw 'Mixed same-commit fixture did not stage at least two target files.'
    }

    Invoke-Git -Arguments @('commit', '-m', $fixture.commitMessage) | Out-Null

    return [pscustomobject]@{
        CommitSummaries = @(
            [pscustomobject]@{
                Title   = 'Mixed same-commit (signal + metadata-noise)'
                Source  = 'fixtures/vi-history/mixed-same-commit.json'
                Message = $fixture.commitMessage
            }
        )
        ExpectedTargets = @($expectedTargets)
        TargetPaths = @($changedTargets | Select-Object -Unique)
        SuggestedMaxPairs = $fixture.maxPairs
    }
}

function Get-HistorySummaryRowsFromComment {
    param(
        [Parameter(Mandatory)]
        [string]$CommentBody
    )

    $pattern = '\|\s*<code>(?<path>[^<]+)</code>\s*\|\s*(?<change>[^|]+)\|\s*(?<comparisons>\d+)\s*\|\s*(?<diffs>\d+)\s*\|\s*(?<status>[^|]+)\|'
    $matches = [regex]::Matches($CommentBody, $pattern)
    $rows = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($match in $matches) {
        if (-not $match.Success) { continue }
        $rows.Add([pscustomobject]@{
            path        = $match.Groups['path'].Value.Trim()
            change      = $match.Groups['change'].Value.Trim()
            comparisons = [int]$match.Groups['comparisons'].Value
            diffs       = [int]$match.Groups['diffs'].Value
            status      = $match.Groups['status'].Value.Trim()
        }) | Out-Null
    }
    return @($rows)
}

function Invoke-AttributeHistoryCommit {
    param(
        [Parameter(Mandatory)]
        [string]$TargetVi
    )

    $candidateSources = @(
        'fixtures/vi-attr/attr/HeadAttr.vi',
        'fixtures/vi-stage/fp-cosmetic/Head.vi',
        'fixtures/vi-attr/Base.vi'
    )

    $sourceVi = $null
    $statusAfterPrep = @()
    foreach ($candidate in $candidateSources) {
        Write-Host "Applying synthetic history change: $TargetVi <= $candidate"
        Copy-VIContent -Source $candidate -Destination $TargetVi
        $statusAfterPrep = @(Invoke-Git -Arguments @('status', '--short', '--', $TargetVi))
        Write-Host ("Post-change status for {0}: {1}" -f $TargetVi, ($statusAfterPrep -join ' '))
        if ($statusAfterPrep.Count -gt 0) {
            $sourceVi = $candidate
            break
        }
        Write-Host ("No delta produced by {0}; trying next attribute fixture." -f $candidate)
    }

    if (-not $sourceVi) {
        throw ("Unable to produce attribute scenario diff for target '{0}'. Tried: {1}" -f $TargetVi, ($candidateSources -join ', '))
    }

    Invoke-Git -Arguments @('add', '-f', $TargetVi) | Out-Null
    Invoke-Git -Arguments @('commit', '-m', 'chore: synthetic VI attr diff for history smoke') | Out-Null

    return @(
        [pscustomobject]@{
            Title   = 'VI Attribute'
            Source  = $sourceVi
            Message = 'chore: synthetic VI attr diff for history smoke'
        }
    )
}

function Invoke-SequentialHistoryCommits {
    param(
        [Parameter(Mandatory)]
        [string]$TargetVi
    )

    $fixture = Get-SequentialHistorySequence
    Write-Verbose ("Sequential fixture loaded from {0}" -f $fixture.path)

    $targetSource = if ([string]::IsNullOrWhiteSpace($TargetVi)) {
        $fixture.targetPathRelative
    } else {
        $TargetVi
    }

    $targetResolved = if ([System.IO.Path]::IsPathRooted($targetSource)) {
        $targetSource
    } else {
        Join-Path $fixture.repoRoot $targetSource
    }

    $targetRelative = if ([System.IO.Path]::IsPathRooted($targetSource)) {
        [System.IO.Path]::GetRelativePath($fixture.repoRoot, $targetResolved)
    } else {
        $targetSource
    }

    if ($fixture.targetPathRelative -and ($fixture.targetPathRelative -ne $targetRelative)) {
        Write-Verbose ("Sequential fixture target differs from supplied target: fixture={0}, requested={1}" -f $fixture.targetPathRelative, $targetRelative)
    }

    $commits = New-Object System.Collections.Generic.List[pscustomobject]
    for ($index = 0; $index -lt $fixture.steps.Count; $index++) {
        $step = $fixture.steps[$index]
        $stepNumber = $index + 1
        $displaySource = if ($step.source) { $step.source } else { $step.resolvedSource }
        Write-Host ("Applying sequential step {0}: {1} <= {2}" -f $stepNumber, $targetRelative, $displaySource)
        Copy-VIContent -Source $step.resolvedSource -Destination $targetResolved
        $statusAfterStep = @(Invoke-Git -Arguments @('status', '--porcelain', '--', $targetRelative))
        Write-Host ("Post-step status for {0}: {1}" -f $targetRelative, ($statusAfterStep -join ' '))
        if ($statusAfterStep.Count -eq 0) {
            Write-Host ("Sequential step {0} produced no file delta; skipping commit." -f $stepNumber)
            continue
        }
        Invoke-Git -Arguments @('add', '-f', $targetRelative) | Out-Null
        $commitMessage = if ([string]::IsNullOrWhiteSpace($step.message)) {
            "chore: sequential history step $stepNumber"
        } else {
            $step.message
        }
        Invoke-Git -Arguments @('commit', '-m', $commitMessage) | Out-Null
        $commits.Add([pscustomobject]@{
            Title   = if ($step.title) { $step.title } else { "Step $stepNumber" }
            Source  = $displaySource
            Message = $commitMessage
        }) | Out-Null
    }

    if ($commits.Count -lt 1) {
        throw 'Sequential history fixture produced no commits; every step resolved to a no-op for the target VI.'
    }

    return $commits.ToArray()
}

function Invoke-SequentialMasscompileHistoryCommits {
    $fixture = Get-SequentialMasscompileFixture
    Write-Verbose ("Sequential masscompile fixture loaded from {0}" -f $fixture.path)

    $targetExpectations = @{}
    $commitSummaries = New-Object System.Collections.Generic.List[pscustomobject]

    for ($commitIndex = 0; $commitIndex -lt $fixture.commits.Count; $commitIndex++) {
        $fixtureCommit = $fixture.commits[$commitIndex]
        $displayTitle = if ([string]::IsNullOrWhiteSpace($fixtureCommit.title)) { "Commit $($commitIndex + 1)" } else { [string]$fixtureCommit.title }
        Write-Host ("Applying sequential-masscompile commit {0}: {1}" -f ($commitIndex + 1), $displayTitle)

        $changedPaths = New-Object System.Collections.Generic.HashSet[string]
        $sourceNotes = New-Object System.Collections.Generic.List[string]
        foreach ($change in $fixtureCommit.changes) {
            Write-Host ("  - {0} <= {1}" -f $change.targetPath, $change.source)
            Copy-VIContent -Source $change.resolvedSource -Destination $change.resolvedTarget
            $statusAfterStep = @(Invoke-Git -Arguments @('status', '--porcelain', '--', $change.targetPath))
            if ($statusAfterStep.Count -gt 0) {
                Invoke-Git -Arguments @('add', '-f', $change.targetPath) | Out-Null
                $changedPaths.Add([string]$change.targetPath) | Out-Null
            } else {
                Write-Host ("    no staged delta for {0}; change treated as no-op" -f $change.targetPath)
            }
            $sourceNotes.Add(("{0} <= {1}" -f $change.targetPath, $change.source)) | Out-Null

            $targetKey = [string]$change.targetPath
            if (-not $targetExpectations.ContainsKey($targetKey)) {
                $targetExpectations[$targetKey] = [ordered]@{
                    repoPath          = $targetKey
                    requireDiff       = [bool]$change.requireDiff
                    minDiffs          = [int]$change.minDiffs
                    classificationHint= $change.classificationHint
                }
            } else {
                $existing = $targetExpectations[$targetKey]
                $existing.requireDiff = [bool]$existing.requireDiff -or [bool]$change.requireDiff
                $existing.minDiffs = [Math]::Max([int]$existing.minDiffs, [int]$change.minDiffs)
                if ([string]::IsNullOrWhiteSpace($existing.classificationHint) -and -not [string]::IsNullOrWhiteSpace($change.classificationHint)) {
                    $existing.classificationHint = [string]$change.classificationHint
                }
            }
        }

        if ($changedPaths.Count -eq 0) {
            Write-Host ("Sequential-masscompile commit {0} produced no staged changes; skipping commit." -f ($commitIndex + 1))
            continue
        }

        $commitMessage = if ([string]::IsNullOrWhiteSpace($fixtureCommit.message)) {
            "chore: sequential masscompile commit $($commitIndex + 1)"
        } else {
            [string]$fixtureCommit.message
        }
        Invoke-Git -Arguments @('commit', '-m', $commitMessage) | Out-Null
        $commitSummaries.Add([pscustomobject]@{
            Title   = $displayTitle
            Source  = [string]::Join(' | ', @($sourceNotes))
            Message = $commitMessage
        }) | Out-Null
    }

    if ($commitSummaries.Count -lt 1) {
        throw 'Sequential masscompile fixture produced no commits; every step resolved to a no-op.'
    }

    $expectedTargets = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($entry in $targetExpectations.GetEnumerator()) {
        $value = $entry.Value
        $expectedTargets.Add([pscustomobject]@{
            repoPath          = [string]$value.repoPath
            requireDiff       = [bool]$value.requireDiff
            minDiffs          = [int]$value.minDiffs
            classificationHint= if ($value.classificationHint) { [string]$value.classificationHint } else { $null }
        }) | Out-Null
    }

    return [pscustomobject]@{
        CommitSummaries = $commitSummaries.ToArray()
        ExpectedTargets = $expectedTargets.ToArray()
        SuggestedMaxPairs = if ($null -ne $fixture.maxPairs) { [int]$fixture.maxPairs } else { $null }
    }
}

Write-Verbose "Base branch: $BaseBranch"
Write-Verbose "KeepBranch: $KeepBranch"
Write-Verbose "DryRun: $DryRun"
Write-Verbose "Scenario: $Scenario"
Write-Verbose "MaxPairs: $MaxPairs"

$repoInfo = Get-RepoInfo
$initialBranch = Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1

$scenarioKey = $Scenario.ToLowerInvariant()
switch ($scenarioKey) {
    'attribute' {
        $scenarioBranchSuffix = 'attr'
        $scenarioDescription  = 'synthetic attribute difference'
        $scenarioExpectation  = '`/vi-history` workflow completes successfully'
        $scenarioPlanHint     = '- Replace fixtures/vi-attr/Head.vi with attribute variant and commit'
        $scenarioNeedsArtifactValidation = $false
        $scenarioRequiresMobilePreview = $false
    }
    'sequential' {
        $scenarioBranchSuffix = 'sequential'
        $scenarioDescription  = 'sequential multi-category history'
        $scenarioExpectation  = '`/vi-history` workflow reports multi-row diff summary'
        $scenarioPlanHint     = '- Apply sequential fixture commits from fixtures/vi-history/sequential.json (attribute, front panel, connector pane, control rename, block diagram cosmetic)'
        $scenarioNeedsArtifactValidation = $true
        $scenarioRequiresMobilePreview = $true
    }
    'mixed-same-commit' {
        $scenarioBranchSuffix = 'mixed'
        $scenarioDescription  = 'mixed same-commit two-target history'
        $scenarioExpectation  = '`/vi-history` workflow itemizes strict signal and non-strict metadata-noise targets from the same commit'
        $scenarioPlanHint     = '- Apply mixed same-commit fixture from fixtures/vi-history/mixed-same-commit.json (two targets in one commit)'
        $scenarioNeedsArtifactValidation = $true
        $scenarioRequiresMobilePreview = $false
    }
    'sequential-masscompile' {
        $scenarioBranchSuffix = 'sequential-masscompile'
        $scenarioDescription  = 'sequential masscompile-vs-signal history matrix'
        $scenarioExpectation  = '`/vi-history` workflow captures strict signal and non-strict masscompile noise across sequential commits'
        $scenarioPlanHint     = '- Apply sequential masscompile fixture from fixtures/vi-history/sequential-masscompile.json (masscompile-only + mixed signal commit chain)'
        $scenarioNeedsArtifactValidation = $true
        $scenarioRequiresMobilePreview = $false
    }
    default {
        throw "Unsupported scenario: $Scenario"
    }
}

# Preload scenario fixture data before we checkout the base branch. This keeps
# in-progress scenario definitions available when they are not yet on develop.
switch ($scenarioKey) {
    'sequential' {
        Get-SequentialHistorySequence | Out-Null
    }
    'mixed-same-commit' {
        Get-MixedSameCommitFixture | Out-Null
    }
    'sequential-masscompile' {
        Get-SequentialMasscompileFixture | Out-Null
    }
}

$effectiveMaxPairs = $MaxPairs
if (-not $PSBoundParameters.ContainsKey('MaxPairs')) {
    switch ($scenarioKey) {
        'sequential' {
            $sequentialFixture = Get-SequentialHistorySequence
            if ($null -ne $sequentialFixture.maxPairs) {
                $effectiveMaxPairs = [int]$sequentialFixture.maxPairs
            }
        }
        'mixed-same-commit' {
            $mixedFixture = Get-MixedSameCommitFixture
            if ($null -ne $mixedFixture.maxPairs) {
                $effectiveMaxPairs = [int]$mixedFixture.maxPairs
            }
        }
        'sequential-masscompile' {
            $sequentialMasscompileFixture = Get-SequentialMasscompileFixture
            if ($null -ne $sequentialMasscompileFixture.maxPairs) {
                $effectiveMaxPairs = [int]$sequentialMasscompileFixture.maxPairs
            }
        }
    }
}

$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
$branchName = "smoke/vi-history-$scenarioBranchSuffix-$timestamp"
$prTitle = "Smoke: VI history compare ($scenarioDescription; $timestamp)"
$prNote = "vi-history smoke $scenarioKey $timestamp"
$summaryDir = Join-Path 'tests' 'results' '_agent' 'smoke' 'vi-history'
New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
$summaryPath = Join-Path $summaryDir ("vi-history-smoke-{0}.json" -f $timestamp)
$workflowPath = '.github/workflows/pr-vi-history.yml'

$planSteps = [System.Collections.Generic.List[string]]::new()
$planSteps.Add("- Fetch origin/$BaseBranch") | Out-Null
$planSteps.Add("- Create branch $branchName from origin/$BaseBranch") | Out-Null
$planSteps.Add($scenarioPlanHint) | Out-Null
$planSteps.Add("- Push scratch branch and create draft PR") | Out-Null
$planSteps.Add("- Dispatch pr-vi-history.yml with PR input (max_pairs=$effectiveMaxPairs, history_timeout_minutes=$WorkflowTimeoutMinutes, compare_timeout_seconds=$CompareTimeoutSeconds)") | Out-Null
$planSteps.Add("- Wait for workflow completion and verify PR comment") | Out-Null
if ($scenarioNeedsArtifactValidation) {
    $planSteps.Add("- Download workflow artifact and validate diff/comparison counts") | Out-Null
}
$planSteps.Add("- Record summary under tests/results/_agent/smoke/vi-history/") | Out-Null
if (-not $KeepBranch) {
    $planSteps.Add("- Close draft PR and delete branch") | Out-Null
} else {
    $planSteps.Add("- Leave branch/PR for inspection (KeepBranch present)") | Out-Null
}

if ($DryRun) {
    Write-Host 'Dry-run mode: no changes will be made.'
    Write-Host 'Plan:'
    foreach ($step in $planSteps) {
        Write-Host "  $step"
    }
    return
}

Ensure-CleanWorkingTree

$scratchContext = [ordered]@{
    Branch        = $branchName
    PrNumber      = $null
    PrUrl         = $null
    RunId         = $null
    CommentFound  = $false
    WorkflowUrl   = $null
    Success       = $false
    Note          = $prNote
    Scenario      = $scenarioKey
    CommitCount   = 0
    Comparisons   = $null
    Diffs         = $null
    ArtifactValidated = $false
    mobilePreviewValidated = $false
    mobilePreviewImageCount = 0
    mobilePreviewCommentFound = $false
    CommentTruncated = $false
    TruncationReason = 'none'
    NetDiffAnchored = $false
    TargetExpectations = @()
    TargetValidation = @()
    Policy = [ordered]@{
        schema = 'vi-history-policy-gate@v1'
        strict = [ordered]@{
            total = 0
            pass = 0
            fail = 0
            failures = @()
        }
        smoke = [ordered]@{
            total = 0
            pass = 0
            warn = 0
            warnings = @()
        }
    }
    PairTimeline = @()
    PairClassification = [ordered]@{}
    PairTiming = [ordered]@{
        comparisonCount = 0
        totalSeconds = 0
        p50Seconds = $null
        p95Seconds = $null
    }
    Benchmark = [ordered]@{
        benchmarkPath = $null
        deltaPath = $null
        commentPath = $null
        baselineCount = 0
        deltaStatus = 'pending'
    }
    MaxPairsRequested = $MaxPairs
    MaxPairsEffective = $effectiveMaxPairs
    WorkflowTimeoutMinutes = $WorkflowTimeoutMinutes
    CompareTimeoutSeconds = $CompareTimeoutSeconds
    BenchmarkBaselineWindow = $BenchmarkBaselineWindow
    EvidenceIssueNumber = $EvidenceIssueNumber
    MobilePreviewRequired = $scenarioRequiresMobilePreview
}

$commitSummaries = @()
$expectedTargets = @()
$trackedHistoryPaths = New-Object System.Collections.Generic.List[string]

try {
    Invoke-Git -Arguments @('fetch', 'origin', $BaseBranch) | Out-Null

    Invoke-Git -Arguments @('checkout', "-B$branchName", "origin/$BaseBranch") | Out-Null

    switch ($scenarioKey) {
        'attribute' {
            $targetVi = 'fixtures/vi-attr/Head.vi'
            Enable-HistoryTracking -Path $targetVi
            $trackedHistoryPaths.Add($targetVi) | Out-Null
            $commitSummaries = Invoke-AttributeHistoryCommit -TargetVi $targetVi
            $expectedTargets = @(
                [pscustomobject]@{
                    repoPath          = $targetVi
                    requireDiff       = $true
                    minDiffs          = 1
                    classificationHint= 'signal'
                }
            )
        }
        'sequential' {
            $sequentialFixture = Get-SequentialHistorySequence
            $targetVi = if ([string]::IsNullOrWhiteSpace($sequentialFixture.targetPathRelative)) {
                'fixtures/vi-attr/Head.vi'
            } else {
                [string]$sequentialFixture.targetPathRelative
            }
            Enable-HistoryTracking -Path $targetVi
            $trackedHistoryPaths.Add($targetVi) | Out-Null
            $commitSummaries = Invoke-SequentialHistoryCommits -TargetVi $targetVi
            $netDiffPaths = @(Invoke-Git -Arguments @('diff', '--name-only', "origin/$BaseBranch", '--', $targetVi))
            if ($netDiffPaths.Count -eq 0) {
                $anchorSourceVi = 'fixtures/vi-attr/Base.vi'
                Write-Host ("Sequential scenario has no net diff against origin/{0}; applying anchor commit: {1} <= {2}" -f $BaseBranch, $targetVi, $anchorSourceVi)
                Copy-VIContent -Source $anchorSourceVi -Destination $targetVi
                $anchorStatus = @(Invoke-Git -Arguments @('status', '--porcelain', '--', $targetVi))
                if ($anchorStatus.Count -eq 0) {
                    throw 'Failed to produce net diff anchor change for sequential scenario.'
                }
                Invoke-Git -Arguments @('add', '-f', $targetVi) | Out-Null
                $anchorMessage = 'chore: sequential history net-diff anchor'
                Invoke-Git -Arguments @('commit', '-m', $anchorMessage) | Out-Null
                $commitSummaries += [pscustomobject]@{
                    Title   = 'Net-diff anchor'
                    Source  = $anchorSourceVi
                    Message = $anchorMessage
                }
                $scratchContext.NetDiffAnchored = $true
            }
            $expectedTargets = @(
                [pscustomobject]@{
                    repoPath          = $targetVi
                    requireDiff       = $true
                    minDiffs          = 1
                    classificationHint= 'signal'
                }
            )
        }
        'mixed-same-commit' {
            $mixedFixture = Get-MixedSameCommitFixture
            $uniqueTargets = New-Object System.Collections.Generic.HashSet[string]
            foreach ($change in $mixedFixture.changes) {
                $repoPath = [string]$change.targetPath
                if ([string]::IsNullOrWhiteSpace($repoPath)) {
                    continue
                }
                if ($uniqueTargets.Add($repoPath)) {
                    Enable-HistoryTracking -Path $repoPath
                    $trackedHistoryPaths.Add($repoPath) | Out-Null
                }
            }

            $mixedCommit = Invoke-MixedSameCommitHistoryCommit
            $commitSummaries = @($mixedCommit.CommitSummaries)
            $expectedTargets = @($mixedCommit.ExpectedTargets)
            if (-not $PSBoundParameters.ContainsKey('MaxPairs') -and $null -ne $mixedCommit.SuggestedMaxPairs) {
                $effectiveMaxPairs = [int]$mixedCommit.SuggestedMaxPairs
                $scratchContext.MaxPairsEffective = $effectiveMaxPairs
            }
        }
        'sequential-masscompile' {
            $matrixFixture = Get-SequentialMasscompileFixture
            $uniqueTargets = New-Object System.Collections.Generic.HashSet[string]
            foreach ($fixtureCommit in $matrixFixture.commits) {
                foreach ($change in $fixtureCommit.changes) {
                    $repoPath = [string]$change.targetPath
                    if ([string]::IsNullOrWhiteSpace($repoPath)) {
                        continue
                    }
                    if ($uniqueTargets.Add($repoPath)) {
                        Enable-HistoryTracking -Path $repoPath
                        $trackedHistoryPaths.Add($repoPath) | Out-Null
                    }
                }
            }

            $matrixResult = Invoke-SequentialMasscompileHistoryCommits
            $commitSummaries = @($matrixResult.CommitSummaries)
            $expectedTargets = @($matrixResult.ExpectedTargets)
            if (-not $PSBoundParameters.ContainsKey('MaxPairs') -and $null -ne $matrixResult.SuggestedMaxPairs) {
                $effectiveMaxPairs = [int]$matrixResult.SuggestedMaxPairs
                $scratchContext.MaxPairsEffective = $effectiveMaxPairs
            }
        }
    }
    if ($expectedTargets.Count -lt 1) {
        throw ("Scenario '{0}' did not produce expected target metadata." -f $scenarioKey)
    }
    $scratchContext.CommitCount = $commitSummaries.Count
    $scratchContext.TargetExpectations = @($expectedTargets)

    Invoke-Git -Arguments @('push', '-u', 'origin', $branchName) | Out-Null

    Write-Host "Creating draft PR for branch $branchName..."
    $prBodyLines = New-Object System.Collections.Generic.List[string]
    $prBodyLines.Add('# VI history smoke test') | Out-Null
    $prBodyLines.Add('') | Out-Null
    $prBodyLines.Add('*This PR was generated by tools/Test-PRVIHistorySmoke.ps1.*') | Out-Null
    $prBodyLines.Add('') | Out-Null
    $prBodyLines.Add("- Scenario: $scenarioDescription") | Out-Null
    $prBodyLines.Add("- Expectation: $scenarioExpectation") | Out-Null
    if ($commitSummaries.Count -gt 0) {
        $prBodyLines.Add('') | Out-Null
        $prBodyLines.Add('- Steps:') | Out-Null
        foreach ($commitSummary in $commitSummaries) {
            $prBodyLines.Add(("  - {0} (`{1}`)" -f $commitSummary.Title, $commitSummary.Source)) | Out-Null
        }
    }
    $prBody = $prBodyLines -join "`n"
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
            pr                      = $scratchContext.PrNumber.ToString()
            max_pairs               = $effectiveMaxPairs.ToString()
            history_timeout_minutes = $WorkflowTimeoutMinutes.ToString()
            compare_timeout_seconds = $CompareTimeoutSeconds.ToString()
        }
    } | ConvertTo-Json -Depth 4
    $dispatchStartedAtUtc = (Get-Date).ToUniversalTime()
    Write-Host 'Triggering pr-vi-history workflow via dispatch API...'
    Invoke-RestMethod -Uri $dispatchUri -Headers $auth.Headers -Method Post -Body $dispatchBody -ContentType 'application/json'
    Write-Host 'Workflow dispatch accepted.'

    Write-Host 'Waiting for workflow run to appear...'
    $runId = $null
    $workflowRunsUri = "https://api.github.com/repos/$($repoInfo.Slug)/actions/workflows/pr-vi-history.yml/runs?branch=$branchName&event=workflow_dispatch&per_page=20"
    $lastRunProbe = $null
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $runResponse = Invoke-RestMethod -Uri $workflowRunsUri -Headers $auth.Headers -Method Get -ErrorAction Stop
        $workflowRuns = @($runResponse.workflow_runs)
        if ($workflowRuns.Count -gt 0) {
            $candidate = $workflowRuns |
                Where-Object { $_.head_branch -eq $branchName } |
                Sort-Object { [DateTime]$_.created_at } -Descending |
                Select-Object -First 1
            if ($null -ne $candidate) {
                $runId = [int64]$candidate.id
                break
            }
        }
        $lastRunProbe = $workflowRuns | Select-Object -First 5
        Start-Sleep -Seconds 5
    }
    if (-not $runId) {
        $probeJson = if ($lastRunProbe) {
            $lastRunProbe | ConvertTo-Json -Depth 6 -Compress
        } else {
            '[]'
        }
        throw ("Unable to locate dispatched workflow run. Dispatch started at {0:o}. Last run probe: {1}" -f $dispatchStartedAtUtc, $probeJson)
    }
    $scratchContext.RunId = $runId
    $scratchContext.WorkflowUrl = "https://github.com/$($repoInfo.Slug)/actions/runs/$runId"
    Write-Host "Workflow run id: $runId"

    Write-Host ("Waiting for workflow run completion (id={0}, timeout={1}m)..." -f $runId, [Math]::Max($WorkflowTimeoutMinutes + 20, 40))
    $runSummary = Wait-WorkflowRunCompletion -Repo $repoInfo -RunId $runId -TimeoutMinutes ([Math]::Max($WorkflowTimeoutMinutes + 20, 40))
    if ($runSummary.conclusion -ne 'success') {
        $runDetails = Invoke-Gh -Arguments @('run', 'view', $runId.ToString(), '--repo', $repoInfo.Slug, '--json', 'conclusion,jobs,url') -ExpectJson
        $failedJobs = @($runDetails.jobs | Where-Object { $_.conclusion -in @('failure','cancelled','timed_out','startup_failure') })
        $jobSummary = if ($failedJobs.Count -gt 0) {
            $failedJobs |
                ForEach-Object {
                    $failedStep = @($_.steps | Where-Object { $_.conclusion -in @('failure','cancelled','timed_out','startup_failure') } | Select-Object -First 1)
                    if ($failedStep.Count -gt 0) {
                        "{0}:{1}" -f $_.name, $failedStep[0].name
                    } else {
                        "{0}:{1}" -f $_.name, $_.conclusion
                    }
                } |
                Select-Object -Unique |
                Join-String -Separator '; '
        } else {
            'no failed job details available'
        }
        throw ("Workflow run {0} concluded with '{1}' ({2}). URL: {3}" -f $runId, $runSummary.conclusion, $jobSummary, $runDetails.url)
    }

    Write-Host 'Verifying PR comment includes history summary...'
    $prDetails = Invoke-Gh -Arguments @('pr', 'view', $scratchContext.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--json', 'comments') -ExpectJson
    $commentBodies = @()
    if ($prDetails -and $prDetails.comments) {
        $commentBodies = @($prDetails.comments | ForEach-Object { $_.body })
    }
    $historyComment = $commentBodies | Where-Object { $_ -like '*VI history compare*' } | Select-Object -First 1
    $scratchContext.CommentFound = [bool]$historyComment
    if (-not $historyComment) {
        throw 'Expected `/vi-history` comment not found on the draft PR.'
    }
    $mobilePreviewHeaderMatch = [regex]::Match($historyComment, '(?im)^###\s+Mobile Preview\s*$')
    $mobilePreviewImageMatches = [regex]::Matches($historyComment, '<img\s+[^>]*src=["''][^"''>]*history-image-[^"''>]*["''][^>]*>')
    $scratchContext.mobilePreviewCommentFound = $mobilePreviewHeaderMatch.Success
    $scratchContext.mobilePreviewImageCount = $mobilePreviewImageMatches.Count
    if ($historyComment -match 'Summary truncated for comment size safety') {
        $scratchContext.CommentTruncated = $true
        $scratchContext.TruncationReason = 'max-markdown-length'
    } elseif ($historyComment -match 'Timeline rows truncated for mobile/comment-size safety') {
        $scratchContext.CommentTruncated = $true
        $scratchContext.TruncationReason = 'timeline-row-drop'
    } else {
        $scratchContext.CommentTruncated = $false
        $scratchContext.TruncationReason = 'none'
    }

    $commentRows = @(Get-HistorySummaryRowsFromComment -CommentBody $historyComment)
    if ($commentRows.Count -eq 0) {
        Write-Warning 'Unable to parse comparison/diff rows from the history comment.'
    }

    $targetValidations = New-Object System.Collections.Generic.List[pscustomobject]
    $targetValidationByPath = @{}
    $strictFailures = New-Object System.Collections.Generic.List[pscustomobject]
    $smokeWarnings = New-Object System.Collections.Generic.List[pscustomobject]
    $totalComparisons = 0
    $totalDiffs = 0
    foreach ($expectedTarget in $expectedTargets) {
        $row = $commentRows | Where-Object { $_.path -eq $expectedTarget.repoPath } | Select-Object -First 1
        $comparisons = if ($row) { [int]$row.comparisons } else { 0 }
        $diffs = if ($row) { [int]$row.diffs } else { 0 }
        $status = if ($row) { [string]$row.status } else { 'missing' }
        $requiredDiffs = [Math]::Max(0, [int]$expectedTarget.minDiffs)

        $commentDecision = Resolve-VIHistoryPolicyDecision `
            -TargetPath ([string]$expectedTarget.repoPath) `
            -RequireDiff ([bool]$expectedTarget.requireDiff) `
            -MinDiffs $requiredDiffs `
            -Comparisons $comparisons `
            -Diffs $diffs `
            -Status $status `
            -Missing:(-not [bool]$row)

        if ($commentDecision.hardFail) {
            $strictFailures.Add([pscustomobject]@{
                source      = 'comment'
                targetPath  = [string]$expectedTarget.repoPath
                reasonCode  = [string]$commentDecision.reasonCode
                reason      = [string]$commentDecision.reasonMessage
            }) | Out-Null
            throw ("[strict policy][comment] {0}" -f $commentDecision.reasonMessage)
        }
        if ($commentDecision.warning) {
            $warningRecord = [pscustomobject]@{
                source      = 'comment'
                targetPath  = [string]$expectedTarget.repoPath
                reasonCode  = [string]$commentDecision.reasonCode
                reason      = [string]$commentDecision.reasonMessage
            }
            $smokeWarnings.Add($warningRecord) | Out-Null
            Write-Warning ("[smoke policy][comment] {0}" -f $commentDecision.reasonMessage)
        }

        $totalComparisons += $comparisons
        $totalDiffs += $diffs
        $validationRecord = [pscustomobject]@{
            repoPath            = [string]$expectedTarget.repoPath
            comparisons         = $comparisons
            diffs               = $diffs
            status              = $status
            requireDiff         = [bool]$expectedTarget.requireDiff
            minDiffs            = [int]$expectedTarget.minDiffs
            classificationHint  = if ($expectedTarget.PSObject.Properties['classificationHint']) { [string]$expectedTarget.classificationHint } else { $null }
            policyClass         = [string]$commentDecision.policyClass
            commentPolicyOutcome= [string]$commentDecision.outcome
            commentPolicyReason = [string]$commentDecision.reasonMessage
            artifactPolicyOutcome= 'pending'
            artifactPolicyReason = $null
        }
        $targetValidations.Add($validationRecord) | Out-Null
        $targetValidationByPath[[string]$expectedTarget.repoPath] = $validationRecord
    }
    $scratchContext.TargetValidation = @($targetValidations)
    $scratchContext.Comparisons = $totalComparisons
    $scratchContext.Diffs = $totalDiffs

    if ($scenarioNeedsArtifactValidation) {
        if ($scenarioKey -eq 'sequential') {
            $expectedSequentialComparisons = [Math]::Max(1, $commitSummaries.Count)
            if ($effectiveMaxPairs -gt 0) {
                $expectedSequentialComparisons = [Math]::Max(1, [Math]::Min($expectedSequentialComparisons, $effectiveMaxPairs))
            }
            $sequentialTarget = $targetValidations | Where-Object { $_.repoPath -eq 'fixtures/vi-attr/Head.vi' } | Select-Object -First 1
            if (-not $sequentialTarget) {
                $sequentialTarget = $targetValidations | Select-Object -First 1
            }
            if ($sequentialTarget.comparisons -lt $expectedSequentialComparisons) {
                throw ("Expected at least {0} comparisons for sequential scenario, but comment reported {1}." -f $expectedSequentialComparisons, $sequentialTarget.comparisons)
            }
        }
        $artifactDir = Join-Path $summaryDir ("artifact-$timestamp")
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
        Invoke-Gh -Arguments @(
            'run', 'download',
            $runId.ToString(),
            '--repo', $repoInfo.Slug,
            '--name', ("pr-vi-history-{0}" -f $scratchContext.PrNumber),
            '--dir', $artifactDir
        ) | Out-Null

        $summaryFile = Get-ChildItem -LiteralPath $artifactDir -Recurse -Filter 'vi-history-summary.json' | Select-Object -First 1
        if (-not $summaryFile) {
            throw 'Summary JSON not found in downloaded artifact.'
        }
        $summaryData = Get-Content -LiteralPath $summaryFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $pairInsight = Get-VIHistoryPairTimeline -Summary $summaryData
        $scratchContext.PairTimeline = @($pairInsight.rows)
        $scratchContext.PairClassification = if ($pairInsight.classificationCounts) { $pairInsight.classificationCounts } else { [ordered]@{} }
        $scratchContext.PairTiming = if ($pairInsight.timing) {
            $pairInsight.timing
        } else {
            [ordered]@{
                comparisonCount = 0
                totalSeconds = 0
                p50Seconds = $null
                p95Seconds = $null
            }
        }
        $targetSummaries = @($summaryData.targets)
        if ($targetSummaries.Count -eq 0) {
            throw 'Summary JSON does not contain target entries.'
        }

        foreach ($expectedTarget in $expectedTargets) {
            $summaryTarget = $targetSummaries | Where-Object { $_.repoPath -eq $expectedTarget.repoPath } | Select-Object -First 1
            $artifactComparisons = if ($summaryTarget -and $summaryTarget.stats) { [int]$summaryTarget.stats.processed } else { 0 }
            $artifactDiffs = if ($summaryTarget -and $summaryTarget.stats) { [int]$summaryTarget.stats.diffs } else { 0 }
            $requiredDiffs = [Math]::Max(0, [int]$expectedTarget.minDiffs)
            $artifactStatus = if (-not $summaryTarget) {
                'missing'
            } elseif ($artifactDiffs -gt 0) {
                'diff'
            } elseif ($artifactComparisons -gt 0) {
                'match'
            } else {
                'missing'
            }
            $artifactDecision = Resolve-VIHistoryPolicyDecision `
                -TargetPath ([string]$expectedTarget.repoPath) `
                -RequireDiff ([bool]$expectedTarget.requireDiff) `
                -MinDiffs $requiredDiffs `
                -Comparisons $artifactComparisons `
                -Diffs $artifactDiffs `
                -Status $artifactStatus `
                -Missing:(-not [bool]$summaryTarget)

            if ($artifactDecision.hardFail) {
                $strictFailures.Add([pscustomobject]@{
                    source      = 'artifact'
                    targetPath  = [string]$expectedTarget.repoPath
                    reasonCode  = [string]$artifactDecision.reasonCode
                    reason      = [string]$artifactDecision.reasonMessage
                }) | Out-Null
                throw ("[strict policy][artifact] {0}" -f $artifactDecision.reasonMessage)
            }
            if ($artifactDecision.warning) {
                $warningRecord = [pscustomobject]@{
                    source      = 'artifact'
                    targetPath  = [string]$expectedTarget.repoPath
                    reasonCode  = [string]$artifactDecision.reasonCode
                    reason      = [string]$artifactDecision.reasonMessage
                }
                $smokeWarnings.Add($warningRecord) | Out-Null
                Write-Warning ("[smoke policy][artifact] {0}" -f $artifactDecision.reasonMessage)
            }

            $targetValidation = $targetValidationByPath[[string]$expectedTarget.repoPath]
            if ($targetValidation) {
                $targetValidation.artifactPolicyOutcome = [string]$artifactDecision.outcome
                $targetValidation.artifactPolicyReason = [string]$artifactDecision.reasonMessage
            }

            if ($scenarioKey -eq 'sequential' -and $summaryTarget -and $summaryTarget.repoPath -eq 'fixtures/vi-attr/Head.vi') {
                $expectedSequentialComparisons = [Math]::Max(1, $commitSummaries.Count)
                if ($effectiveMaxPairs -gt 0) {
                    $expectedSequentialComparisons = [Math]::Max(1, [Math]::Min($expectedSequentialComparisons, $effectiveMaxPairs))
                }
                if ($artifactComparisons -lt $expectedSequentialComparisons) {
                    throw ("Summary JSON reported {0} comparisons for sequential target; expected at least {1}." -f $artifactComparisons, $expectedSequentialComparisons)
                }
            }
        }

        $imageIndexFiles = @(Get-ChildItem -LiteralPath $artifactDir -Recurse -Filter 'vi-history-image-index.json' -File)
        if ($imageIndexFiles.Count -lt 1) {
            throw 'vi-history-image-index.json not found in downloaded artifact.'
        }
        $previewImageFiles = Get-ChildItem -LiteralPath $artifactDir -Recurse -File |
            Where-Object { $_.Name -like 'history-image-*' -and $_.FullName -match '[\\/]+previews[\\/]' }
        $previewImageCount = if ($previewImageFiles) { @($previewImageFiles).Count } else { 0 }
        if ($scenarioRequiresMobilePreview) {
            if ($previewImageCount -lt 1) {
                throw ("Scenario '{0}' expected preview image files (`previews/history-image-*`) but none were found." -f $scenarioKey)
            }
            if (-not $mobilePreviewHeaderMatch.Success) {
                throw ("Scenario '{0}' comment is missing the `### Mobile Preview` section." -f $scenarioKey)
            }
            if ($mobilePreviewImageMatches.Count -lt 1) {
                throw ("Scenario '{0}' comment did not include preview image tags (`history-image-*`)." -f $scenarioKey)
            }
            $scratchContext.mobilePreviewValidated = $true
        } else {
            $scratchContext.mobilePreviewValidated = $true
            if ($previewImageCount -gt 0 -and -not $mobilePreviewHeaderMatch.Success) {
                Write-Warning ("Scenario '{0}' produced preview images but comment did not include a Mobile Preview heading." -f $scenarioKey)
            }
        }
        $scratchContext.mobilePreviewImageCount = [Math]::Max($scratchContext.mobilePreviewImageCount, $previewImageCount)
        $scratchContext.ArtifactValidated = $true
        try {
            Remove-Item -LiteralPath $artifactDir -Recurse -Force
        } catch {
            Write-Warning ("Failed to delete temporary artifact directory {0}: {1}" -f $artifactDir, $_.Exception.Message)
        }
    }

    $policyStrictTotal = 0
    $policyStrictPass = 0
    $policySmokeTotal = 0
    $policySmokePass = 0
    $policySmokeWarn = 0
    foreach ($validation in @($targetValidations)) {
        if (-not $validation) { continue }
        $isStrict = [bool]$validation.requireDiff
        $commentOutcome = if ($validation.PSObject.Properties['commentPolicyOutcome']) { [string]$validation.commentPolicyOutcome } else { 'pass' }
        $artifactOutcome = if ($validation.PSObject.Properties['artifactPolicyOutcome']) { [string]$validation.artifactPolicyOutcome } else { 'pass' }
        $hasWarn = @($commentOutcome, $artifactOutcome) -contains 'warn'

        if ($isStrict) {
            $policyStrictTotal++
            if ($commentOutcome -ne 'fail' -and $artifactOutcome -ne 'fail') {
                $policyStrictPass++
            }
        } else {
            $policySmokeTotal++
            if ($hasWarn) {
                $policySmokeWarn++
            } else {
                $policySmokePass++
            }
        }
    }

    $scratchContext.Policy.strict.total = $policyStrictTotal
    $scratchContext.Policy.strict.pass = $policyStrictPass
    $scratchContext.Policy.strict.fail = $strictFailures.Count
    $scratchContext.Policy.strict.failures = @($strictFailures)
    $scratchContext.Policy.smoke.total = $policySmokeTotal
    $scratchContext.Policy.smoke.pass = $policySmokePass
    $scratchContext.Policy.smoke.warn = $policySmokeWarn
    $scratchContext.Policy.smoke.warnings = @($smokeWarnings)

    if ($smokeWarnings.Count -gt 0) {
        Write-Host ("Policy summary: strict pass={0}/{1}, strict fail={2}; smoke pass={3}/{4}, smoke warn={5}" -f `
                $policyStrictPass, $policyStrictTotal, $strictFailures.Count, $policySmokePass, $policySmokeTotal, $policySmokeWarn)
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
    foreach ($trackedPath in ($trackedHistoryPaths | Select-Object -Unique)) {
        Restore-HistoryTracking -Path $trackedPath
    }

    $scratchContext.SummaryGeneratedAt = (Get-Date).ToString('o')
    $scratchContext.KeepBranch = [bool]$KeepBranch
    $scratchContext.BaseBranch = $BaseBranch
    $scratchContext.MaxPairs = $effectiveMaxPairs
    $scratchContext.InitialBranch = $initialBranch
    $scratchContext | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8

    try {
        $benchmarkResult = & $benchmarkWriterPath `
            -SmokeSummaryPath $summaryPath `
            -BaselineWindow $BenchmarkBaselineWindow
        if ($benchmarkResult) {
            $scratchContext.Benchmark.benchmarkPath = if ($benchmarkResult.PSObject.Properties['benchmarkPath']) { [string]$benchmarkResult.benchmarkPath } else { $null }
            $scratchContext.Benchmark.deltaPath = if ($benchmarkResult.PSObject.Properties['deltaPath']) { [string]$benchmarkResult.deltaPath } else { $null }
            $scratchContext.Benchmark.commentPath = if ($benchmarkResult.PSObject.Properties['commentPath']) { [string]$benchmarkResult.commentPath } else { $null }
            $scratchContext.Benchmark.baselineCount = if ($benchmarkResult.PSObject.Properties['baselineCount']) { [int]$benchmarkResult.baselineCount } else { 0 }
            $scratchContext.Benchmark.deltaStatus = if ($benchmarkResult.PSObject.Properties['deltaStatus']) { [string]$benchmarkResult.deltaStatus } else { 'unknown' }

            $commentMarkdown = if ($benchmarkResult.PSObject.Properties['commentMarkdown']) { [string]$benchmarkResult.commentMarkdown } else { $null }
            if (-not [string]::IsNullOrWhiteSpace($commentMarkdown)) {
                if ($scratchContext.PrNumber) {
                    try {
                        Invoke-Gh -Arguments @('pr', 'comment', $scratchContext.PrNumber.ToString(), '--repo', $repoInfo.Slug, '--body', $commentMarkdown) | Out-Null
                        Write-Host ("Posted KPI delta comment to PR #{0}." -f $scratchContext.PrNumber)
                    } catch {
                        Write-Warning ("Failed to post KPI delta comment to PR #{0}: {1}" -f $scratchContext.PrNumber, $_.Exception.Message)
                    }
                }
                if ($EvidenceIssueNumber -gt 0) {
                    try {
                        Invoke-Gh -Arguments @('issue', 'comment', $EvidenceIssueNumber.ToString(), '--repo', $repoInfo.Slug, '--body', $commentMarkdown) | Out-Null
                        Write-Host ("Posted KPI delta comment to issue #{0}." -f $EvidenceIssueNumber)
                    } catch {
                        Write-Warning ("Failed to post KPI delta comment to issue #{0}: {1}" -f $EvidenceIssueNumber, $_.Exception.Message)
                    }
                }
            }
        }
    } catch {
        Write-Warning ("Failed to generate KPI benchmark/delta artifacts: {0}" -f $_.Exception.Message)
    }

    $scratchContext | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    Write-Host "Summary written to $summaryPath"

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
}
