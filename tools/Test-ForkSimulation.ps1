#Requires -Version 7.0
<#
.SYNOPSIS
Creates a fork-style pull request, runs the compare workflows, and optionally
cleans everything up again.

.DESCRIPTION
This helper simulates a fork contributor by copying a deterministic VI fixture,
committing the change on a scratch branch that lives on the fork remote
(`origin`), opening a draft PR against `upstream/<BaseBranch>`, and exercising
three compare passes:

1. The automatic **VI Compare (Fork PR)** workflow that runs on every fork PR.
2. The manual **PR VI Compare Staging** workflow (dispatched with the new PR).
3. The manual **PR VI History** workflow (also dispatched with the PR).

Each pass waits for the workflow to complete and fails fast if any job reports
`conclusion != success`. When `-KeepBranch` is omitted the helper closes the
draft PR, deletes the fork branch, and restores the working tree to its
original state. Use `-DryRun` to print the planned steps without mutating the
workspace or touching GitHub.

.PARAMETER BaseBranch
Upstream branch to branch from and target in the draft PR. Defaults to `develop`.

.PARAMETER KeepBranch
Skip cleanup so the scratch branch and draft PR remain available for inspection.

.PARAMETER DryRun
Emit the steps that would run without mutating git, GitHub, or the filesystem.
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
        [string[]]$Arguments,
        [switch]$IgnoreErrors
    )

    if ($DryRun) {
        Write-Host "[dry-run] git $($Arguments -join ' ')"
        return @()
    }

    $output = git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $IgnoreErrors) {
        throw "git $($Arguments -join ' ') failed:`n$output"
    }

    return @($output -split "`r?`n" | Where-Object { $_ -and $_.Trim() -ne '' })
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$ExpectJson,
        [switch]$IgnoreErrors
    )

    if ($DryRun) {
        Write-Host "[dry-run] gh $($Arguments -join ' ')"
        return $null
    }

    $output = gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $IgnoreErrors) {
        throw "gh $($Arguments -join ' ') failed:`n$output"
    }

    if ($ExpectJson) {
        if (-not $output) {
            return $null
        }
        return $output | ConvertFrom-Json
    }

    return @($output -split "`r?`n" | Where-Object { $_ -and $_.Trim() -ne '' })
}

function Ensure-GitClean {
    $statusRaw = Invoke-Git -Arguments @('status', '--porcelain')
    $status = @()
    if ($statusRaw) {
        if ($statusRaw -is [System.Array]) {
            $status = $statusRaw
        } else {
            $status = @($statusRaw)
        }
    }
    $status = @($status | Where-Object { $_ -and $_.Trim() -ne '' })
    if ($status.Count -gt 0) {
        throw "Working tree is not clean:`n$($status -join [Environment]::NewLine)"
    }
}

function Get-RemoteInfo {
    param(
        [Parameter(Mandatory)]
        [string]$RemoteName
    )

    if ($DryRun) {
        switch ($RemoteName) {
            'upstream' {
                return [PSCustomObject]@{
                    Owner      = 'LabVIEW-Community-CI-CD'
                    Repository = 'compare-vi-cli-action'
                    Slug       = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
                }
            }
            'origin' {
                return [PSCustomObject]@{
                    Owner      = 'fork-owner'
                    Repository = 'compare-vi-cli-action'
                    Slug       = 'fork-owner/compare-vi-cli-action'
                }
            }
            default {
                return [PSCustomObject]@{
                    Owner      = "dry-run-$RemoteName"
                    Repository = 'placeholder'
                    Slug       = "dry-run-$RemoteName/placeholder"
                }
            }
        }
    }

    $raw = Invoke-Git -Arguments @('remote', 'get-url', $RemoteName)
    $url = if ($raw -is [System.Array]) { $raw | Select-Object -First 1 } else { $raw }
    if (-not $url) {
        throw "Unable to resolve remote '$RemoteName'."
    }

    $pattern = '(?<=github\.com[:/])(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$'
    $match = [regex]::Match($url, $pattern)
    if (-not $match.Success) {
        throw "Remote '$RemoteName' does not appear to point at GitHub (value=$url)."
    }

    $owner = $match.Groups['owner'].Value
    $repo = $match.Groups['repo'].Value

    return [PSCustomObject]@{
        Owner = $owner
        Repository = $repo
        Slug = "$owner/$repo"
    }
}

function Copy-FixturePair {
    param(
        [Parameter(Mandatory)][string]$SourceBase,
        [Parameter(Mandatory)][string]$SourceHead,
        [Parameter(Mandatory)][string]$TargetBase,
        [Parameter(Mandatory)][string]$TargetHead
    )

    if ($DryRun) {
        Write-Host "[dry-run] Copy $SourceBase -> $TargetBase"
        Write-Host "[dry-run] Copy $SourceHead -> $TargetHead"
        return
    }

    [System.IO.File]::Copy($SourceBase, $TargetBase, $true)
    [System.IO.File]::Copy($SourceHead, $TargetHead, $true)
}

function Wait-WorkflowCompletion {
    param(
        [Parameter(Mandatory)][string]$WorkflowSelector,
        [string]$Branch,
        [DateTime]$CreatedAfter,
        [int]$TimeoutMinutes = 20,
        [string]$EventName,
        [long[]]$IgnoreRunIds = @()
    )

    if ($DryRun) {
        Write-Host "[dry-run] Would wait for workflow '$WorkflowSelector' (branch='$Branch')"
        return [PSCustomObject]@{
            htmlUrl    = '(dry-run)'
            status     = 'skipped'
            conclusion = 'skipped'
        }
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        if ((Get-Date) -gt $deadline) {
            throw "Workflow '$WorkflowSelector' did not finish within $TimeoutMinutes minute(s)."
        }

        $args = @(
            'run', 'list',
            '--workflow', $WorkflowSelector,
            '--json', 'databaseId,status,conclusion,headBranch,url,createdAt,event',
            '--limit', '20'
        )
        if ($Branch) {
            $args += @('--branch', $Branch)
        }

        $runs = Invoke-Gh -Arguments $args -ExpectJson
        if (-not $runs) {
            Start-Sleep -Seconds 5
            continue
        }

        $candidates = $runs
        if ($CreatedAfter) {
            $cutoff = $CreatedAfter.ToUniversalTime()
            $candidates = $candidates | Where-Object {
                try {
                    $created = [DateTime]::Parse($_.createdAt).ToUniversalTime()
                    return $created -ge $cutoff
                } catch {
                    return $false
                }
            }
        }

        if ($Branch) {
            $candidates = $candidates | Where-Object { $_.headBranch -eq $Branch }
        }
        if ($EventName) {
            $candidates = $candidates | Where-Object { $_.event -eq $EventName }
        }
        if ($IgnoreRunIds) {
            $candidates = $candidates | Where-Object { -not ($IgnoreRunIds -contains $_.databaseId) }
        }

        $match = $candidates | Sort-Object -Property createdAt -Descending | Select-Object -First 1
        if (-not $match) {
            Start-Sleep -Seconds 5
            continue
        }

        if ($match.status -eq 'completed') {
            if ($match.conclusion -ne 'success') {
                throw "Workflow '$WorkflowSelector' failed (conclusion=$($match.conclusion)). See $($match.url)"
            }
            Write-Host "Workflow '$WorkflowSelector' succeeded. See: $($match.url)"
            return $match
        }

        Start-Sleep -Seconds 10
    }
}

function Invoke-WorkflowDispatch {
    param(
        [Parameter(Mandatory)][string]$WorkflowFile,
        [hashtable]$Inputs,
        [string]$Ref,
        [string]$BranchForWait,
        [string]$Note,
        [int]$TimeoutMinutes = 20
    )

    $runNote = if ($Note) { $Note } else { "fork-sim $WorkflowFile" }
    $startTime = Get-Date
    $existingRuns = Invoke-Gh -ExpectJson -Arguments @(
        'run', 'list',
        '--workflow', $WorkflowFile,
        '--json', 'databaseId',
        '--limit', '20'
    )
    $existingIds = @()
    if ($existingRuns) {
        $existingIds = @($existingRuns | ForEach-Object { [long]$_.databaseId })
    }

    $args = @('workflow', 'run', $WorkflowFile)
    if ($Ref) {
        $args += @('--ref', $Ref)
    }
    $noteProvided = $false
    if ($null -ne $Inputs) {
        foreach ($key in $Inputs.Keys) {
            $value = $Inputs[$key]
            if ($null -ne $value) {
                $args += @('--field', "$key=$value")
            }
            if ($key -eq 'note') {
                $noteProvided = $true
                $runNote = $value
            }
        }
    }
    if (-not $noteProvided) {
        $args += @('--field', "note=$runNote")
    }

    Invoke-Gh -Arguments $args | Out-Null
    Write-Host "Dispatched $WorkflowFile (note='$runNote')"

    return Wait-WorkflowCompletion -WorkflowSelector $WorkflowFile -Branch $BranchForWait -CreatedAfter $startTime -TimeoutMinutes $TimeoutMinutes -EventName 'workflow_dispatch' -IgnoreRunIds $existingIds
}

Ensure-GitClean

$repoRoot = if ($DryRun) { (Get-Location).Path } else {
    $top = Invoke-Git -Arguments @('rev-parse', '--show-toplevel') | Select-Object -First 1
    if (-not $top) {
        throw 'Unable to resolve repository root.'
    }
    [System.IO.Path]::GetFullPath($top.Trim())
}

if (-not $DryRun) {
    Set-Location -LiteralPath $repoRoot
}

$upstream = Get-RemoteInfo -RemoteName 'upstream'
$fork = Get-RemoteInfo -RemoteName 'origin'
Write-Host "Upstream: $($upstream.Slug); Fork: $($fork.Slug)"

Invoke-Git -Arguments @('fetch', '--prune', 'upstream')
Invoke-Git -Arguments @('fetch', '--prune', 'origin')
Invoke-Git -Arguments @('checkout', $BaseBranch)
Invoke-Git -Arguments @('reset', '--hard', "upstream/$BaseBranch")

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')
$scratchBranch = "fork-sim/$timestamp"
$originalBranch = Invoke-Git -Arguments @('branch', '--show-current') | Select-Object -First 1

Invoke-Git -Arguments @('checkout', '-B', $scratchBranch)

$targetBaseVi = Join-Path 'fixtures' 'vi-attr' 'Base.vi'
$targetHeadVi = Join-Path 'fixtures' 'vi-attr' 'Head.vi'
$sourceBaseVi = Join-Path 'tmp-commit-236ffab' 'VI1.vi'
$sourceHeadVi = Join-Path 'tmp-commit-236ffab' 'VI2.vi'

Copy-FixturePair -SourceBase $sourceBaseVi -SourceHead $sourceHeadVi -TargetBase $targetBaseVi -TargetHead $targetHeadVi

Invoke-Git -Arguments @('add', $targetBaseVi, $targetHeadVi)
Invoke-Git -Arguments @('status', '--short')

$commitMessage = "Fork simulation VI diff ($timestamp)"
Invoke-Git -Arguments @('commit', '-m', $commitMessage)

if (-not $DryRun) {
    Invoke-Git -Arguments @('push', '--set-upstream', 'origin', $scratchBranch)
}

$prNumber = $null
$prUrl = $null
if (-not $DryRun) {
    Invoke-Gh -Arguments @(
        'pr', 'create',
        '--repo', $upstream.Slug,
        '--base', $BaseBranch,
        '--head', "$($fork.Owner):$scratchBranch",
        '--title', "[fork-sim] VI diff smoke ($timestamp)",
        '--body', "Automated fork simulation to exercise compare workflows.",
        '--draft'
    ) | Out-Null

    $prList = Invoke-Gh -ExpectJson -Arguments @(
        'pr', 'list',
        '--repo', $upstream.Slug,
        '--head', $scratchBranch,
        '--state', 'all',
        '--json', 'number,url'
    )
    $prPayload = $prList | Select-Object -First 1
    if (-not $prPayload) {
        throw 'Failed to resolve draft pull request metadata.'
    }
    $prNumber = [int]$prPayload.number
    $prUrl = $prPayload.url
    Write-Host "Opened draft PR #$prNumber ($prUrl)"
}

$summary = @()
$forkIgnoreIds = @()
if (-not $DryRun) {
    $existingForkRuns = Invoke-Gh -ExpectJson -Arguments @(
        'run', 'list',
        '--workflow', 'vi-compare-fork.yml',
        '--json', 'databaseId',
        '--limit', '20'
    )
    if ($existingForkRuns) {
        $forkIgnoreIds = @($existingForkRuns | ForEach-Object { [long]$_.databaseId })
    }
}
$autoRun = Wait-WorkflowCompletion -WorkflowSelector 'vi-compare-fork.yml' -Branch $scratchBranch -EventName 'pull_request' -IgnoreRunIds $forkIgnoreIds
$summary += [PSCustomObject]@{
    Pass       = 'fork-pr'
    Workflow   = 'VI Compare (Fork PR)'
    ResultUrl  = $autoRun.url
    Conclusion = $autoRun.conclusion
}

if ($prNumber) {
    $stagingNote = "fork-sim staging $timestamp"
    $stagingRun = Invoke-WorkflowDispatch -WorkflowFile 'pr-vi-staging.yml' -Inputs @{
        pr = $prNumber
        note = $stagingNote
    } -Ref $BaseBranch -BranchForWait $BaseBranch -TimeoutMinutes 25
    $summary += [PSCustomObject]@{
        Pass       = 'staging'
        Workflow   = 'PR VI Compare Staging'
        ResultUrl  = $stagingRun.url
        Conclusion = $stagingRun.conclusion
    }

    $historyNote = "fork-sim history $timestamp"
    $historyRun = Invoke-WorkflowDispatch -WorkflowFile 'pr-vi-history.yml' -Inputs @{
        pr = $prNumber
        note = $historyNote
    } -Ref $BaseBranch -BranchForWait $BaseBranch -TimeoutMinutes 25
    $summary += [PSCustomObject]@{
        Pass       = 'history'
        Workflow   = 'PR VI History'
        ResultUrl  = $historyRun.url
        Conclusion = $historyRun.conclusion
    }
} else {
    $summary += [PSCustomObject]@{
        Pass       = 'staging'
        Workflow   = 'PR VI Compare Staging'
        ResultUrl  = '(dry-run)'
        Conclusion = 'skipped'
    }
    $summary += [PSCustomObject]@{
        Pass       = 'history'
        Workflow   = 'PR VI History'
        ResultUrl  = '(dry-run)'
        Conclusion = 'skipped'
    }
}

if (-not $KeepBranch) {
    Write-Host 'Cleaning up scratch branch and draft PR.'
    if ($prNumber -and -not $DryRun) {
        Invoke-Gh -Arguments @('pr', 'close', $prNumber.ToString(), '--comment', 'Closing fork simulation run.', '--delete-branch') -IgnoreErrors | Out-Null
    }
    Invoke-Git -Arguments @('checkout', $BaseBranch)
    Invoke-Git -Arguments @('reset', '--hard', "upstream/$BaseBranch")
    if (-not $DryRun) {
        Invoke-Git -Arguments @('push', 'origin', '--delete', $scratchBranch) -IgnoreErrors | Out-Null
    }
    Invoke-Git -Arguments @('branch', '-D', $scratchBranch) -IgnoreErrors | Out-Null
} else {
    Write-Host "Keeping scratch branch '$scratchBranch' and draft PR for follow-up."
    if ($originalBranch) {
        Invoke-Git -Arguments @('checkout', $originalBranch)
    }
}

Write-Host ""
Write-Host "Fork simulation completed. Pass summary:"
foreach ($entry in $summary) {
    Write-Host (" - [{0}] {1} -> {2}" -f $entry.Conclusion, $entry.Workflow, $entry.ResultUrl)
}

if ($prUrl) {
    Write-Host ("Draft PR: {0}" -f $prUrl)
}
