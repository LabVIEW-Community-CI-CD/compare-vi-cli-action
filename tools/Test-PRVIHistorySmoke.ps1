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
single-commit attr diff, or `sequential` to replay multiple fixture commits and
validate richer history output.

.PARAMETER MaxPairs
Optional override for the `max_pairs` workflow input. Defaults to `6`.
#>
[CmdletBinding()]
param(
    [string]$BaseBranch = 'develop',
    [switch]$KeepBranch,
    [switch]$DryRun,
    [ValidateSet('attribute', 'sequential')]
    [string]$Scenario = 'attribute',
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


$script:SequentialFixtureCache = $null

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

function Invoke-AttributeHistoryCommit {
    param(
        [Parameter(Mandatory)]
        [string]$TargetVi
    )

    $sourceVi = 'fixtures/vi-attr/Base.vi'
    Write-Host "Applying synthetic history change: $TargetVi <= $sourceVi"
    Copy-VIContent -Source $sourceVi -Destination $TargetVi
    $statusAfterPrep = Invoke-Git -Arguments @('status', '--short', $TargetVi)
    Write-Host ("Post-change status for {0}: {1}" -f $TargetVi, ($statusAfterPrep -join ' '))
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
        $statusAfterStep = Invoke-Git -Arguments @('status', '--short', $targetRelative)
        Write-Host ("Post-step status for {0}: {1}" -f $targetRelative, ($statusAfterStep -join ' '))
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

    return $commits.ToArray()
}

Write-Verbose "Base branch: $BaseBranch"
Write-Verbose "KeepBranch: $KeepBranch"
Write-Verbose "DryRun: $DryRun"
Write-Verbose "Scenario: $Scenario"
Write-Verbose "MaxPairs: $MaxPairs"

$repoInfo = Get-RepoInfo
$initialBranch = Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1

Ensure-CleanWorkingTree

$scenarioKey = $Scenario.ToLowerInvariant()
switch ($scenarioKey) {
    'attribute' {
        $scenarioBranchSuffix = 'attr'
        $scenarioDescription  = 'synthetic attribute difference'
        $scenarioExpectation  = '`/vi-history` workflow completes successfully'
        $scenarioPlanHint     = '- Replace fixtures/vi-attr/Head.vi with attribute variant and commit'
        $scenarioNeedsArtifactValidation = $false
    }
    'sequential' {
        $scenarioBranchSuffix = 'sequential'
        $scenarioDescription  = 'sequential multi-category history'
        $scenarioExpectation  = '`/vi-history` workflow reports multi-row diff summary'
        $scenarioPlanHint     = '- Apply sequential fixture commits from fixtures/vi-history/sequential.json (attribute, front panel, connector pane, control rename, block diagram cosmetic)'
        $scenarioNeedsArtifactValidation = $true
    }
    default {
        throw "Unsupported scenario: $Scenario"
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
$planSteps.Add("- Dispatch pr-vi-history.yml with PR input (max_pairs=$MaxPairs)") | Out-Null
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
}

$commitSummaries = @()

try {
    Invoke-Git -Arguments @('fetch', 'origin', $BaseBranch) | Out-Null

    Invoke-Git -Arguments @('checkout', "-B$branchName", "origin/$BaseBranch") | Out-Null

    $targetVi = 'fixtures/vi-attr/Head.vi'
    Enable-HistoryTracking -Path $targetVi

    switch ($scenarioKey) {
        'attribute' {
            $commitSummaries = Invoke-AttributeHistoryCommit -TargetVi $targetVi
        }
        'sequential' {
            $commitSummaries = Invoke-SequentialHistoryCommits -TargetVi $targetVi
        }
    }
    $scratchContext.CommitCount = $commitSummaries.Count

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
    $historyComment = $commentBodies | Where-Object { $_ -like '*VI history compare*' } | Select-Object -First 1
    $scratchContext.CommentFound = [bool]$historyComment
    if (-not $historyComment) {
        throw 'Expected `/vi-history` comment not found on the draft PR.'
    }

    $rowPattern = '\|\s*<code>fixtures/vi-attr/Head\.vi</code>\s*\|\s*(?<change>[^|]+)\|\s*(?<comparisons>\d+)\s*\|\s*(?<diffs>\d+)\s*\|\s*(?<status>[^|]+)\|'
    $rowMatch = [regex]::Match($historyComment, $rowPattern)
    if ($rowMatch.Success) {
        $scratchContext.Comparisons = [int]$rowMatch.Groups['comparisons'].Value
        $scratchContext.Diffs = [int]$rowMatch.Groups['diffs'].Value
    } else {
        Write-Warning 'Unable to parse comparison/diff counts from the history comment.'
    }

    if ($scenarioKey -eq 'sequential') {
        if (-not $rowMatch.Success) {
            throw 'Failed to parse sequential summary row from history comment.'
        }
        $comparisonsValue = [int]$rowMatch.Groups['comparisons'].Value
        $diffsValue = [int]$rowMatch.Groups['diffs'].Value
        $statusValue = $rowMatch.Groups['status'].Value.Trim()
        if ($comparisonsValue -lt [Math]::Max(1, $commitSummaries.Count)) {
            throw ("Expected at least {0} comparisons, but comment reported {1}." -f [Math]::Max(1, $commitSummaries.Count), $comparisonsValue)
        }
        if ($diffsValue -lt 1) {
            throw 'Sequential history comment should report at least one diff.'
        }
        if ($statusValue -notlike '*diff*') {
            throw ("Expected status column to mark diff but saw '{0}'." -f $statusValue)
        }

        $artifactDir = Join-Path $summaryDir ("artifact-$timestamp")
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
        Invoke-Gh -Arguments @(
            'run', 'download',
            $runId.ToString(),
            '--name', ("pr-vi-history-{0}" -f $scratchContext.PrNumber),
            '--dir', $artifactDir
        ) | Out-Null

        $summaryFile = Get-ChildItem -LiteralPath $artifactDir -Recurse -Filter 'vi-history-summary.json' | Select-Object -First 1
        if (-not $summaryFile) {
            throw 'Summary JSON not found in downloaded artifact.'
        }
        $summaryData = Get-Content -LiteralPath $summaryFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $targetSummary = $summaryData.targets | Select-Object -First 1
        if (-not $targetSummary) {
            throw 'Summary JSON does not contain target entries.'
        }
        $artifactComparisons = if ($targetSummary.stats) { [int]$targetSummary.stats.processed } else { 0 }
        $artifactDiffs = if ($targetSummary.stats) { [int]$targetSummary.stats.diffs } else { 0 }
        if ($artifactComparisons -lt [Math]::Max(1, $commitSummaries.Count)) {
            throw ("Summary JSON reported {0} comparisons; expected at least {1}." -f $artifactComparisons, [Math]::Max(1, $commitSummaries.Count))
        }
        if ($artifactDiffs -lt 1) {
            throw 'Summary JSON should report at least one diff for sequential history smoke.'
        }
        $scratchContext.ArtifactValidated = $true
        try {
            Remove-Item -LiteralPath $artifactDir -Recurse -Force
        } catch {
            Write-Warning ("Failed to delete temporary artifact directory {0}: {1}" -f $artifactDir, $_.Exception.Message)
        }
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
