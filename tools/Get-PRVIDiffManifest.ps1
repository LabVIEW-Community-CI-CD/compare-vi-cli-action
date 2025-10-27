#Requires -Version 7.0
<#
.SYNOPSIS
Generates a manifest of VI path pairs for pull-request comparisons.

.DESCRIPTION
This is the initial scaffold for issue #324. The script will eventually detect
`.vi` changes between two git refs and emit a `vi-diff-manifest@v1` JSON file.
Implementation is intentionally stubbed out while the spike design is finalized.

.PARAMETER BaseRef
Git ref (commit, branch, or tag) representing the comparison baseline.

.PARAMETER HeadRef
Git ref that contains the proposed changes.

.PARAMETER OutputPath
Optional filesystem path for the generated JSON manifest. Defaults to stdout.

.PARAMETER IgnorePattern
One or more glob patterns to exclude from the diff scan.

.PARAMETER DryRun
Emit a human-readable summary instead of writing JSON (planned).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BaseRef,

    [Parameter(Mandatory)]
    [string]$HeadRef,

    [string]$OutputPath,

    [string[]]$IgnorePattern = @(),

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Verbose "Base ref: $BaseRef"
Write-Verbose "Head ref: $HeadRef"

if ($PSBoundParameters.ContainsKey('OutputPath')) {
    Write-Verbose "Output path: $OutputPath"
}

if ($IgnorePattern.Count -gt 0) {
    Write-Verbose ("Ignore patterns: {0}" -f ($IgnorePattern -join ', '))
}

if ($DryRun) {
    Write-Verbose 'Dry-run mode enabled.'
}

function New-WildcardMatcher {
    param(
        [string]$Pattern
    )
    try {
        return [System.Management.Automation.WildcardPattern]::new(
            $Pattern,
            [System.Management.Automation.WildcardOptions]::IgnoreCase
        )
    } catch {
        throw "Invalid ignore pattern '$Pattern': $($_.Exception.Message)"
    }
}

$ignoreMatchers = @()
if ($IgnorePattern) {
    $ignoreMatchers = $IgnorePattern | ForEach-Object { New-WildcardMatcher -Pattern $_ }
}

function Should-IgnorePath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    foreach ($matcher in $ignoreMatchers) {
        if ($matcher.IsMatch($Path)) {
            return $true
        }
    }

    return $false
}

function Test-IsViPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return [System.String]::Equals(
        [System.IO.Path]::GetExtension($Path),
        '.vi',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-SortKey {
    param(
        [pscustomobject]$Entry
    )

    if ($Entry.headPath) {
        return $Entry.headPath
    }

    return $Entry.basePath
}

function Invoke-Git {
    param(
        [string[]]$Arguments
    )

    Write-Verbose ("git {0}" -f ($Arguments -join ' '))
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = 'git'
    $processInfo.RedirectStandardError = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.Arguments = [string]::Join(' ', $Arguments)
    $processInfo.WorkingDirectory = (Get-Location).ProviderPath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    if (-not $process.Start()) {
        throw 'Failed to start git process.'
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        $message = "git exited with code $($process.ExitCode)"
        if ($stderr) {
            $message = "${message}:`n$stderr"
        }
        throw $message
    }

    return @{
        StdOut = $stdout
        StdErr = $stderr
    }
}

$repoRootResult = Invoke-Git -Arguments @('rev-parse', '--show-toplevel')
$repoRoot = $repoRootResult.StdOut.Trim()
if (-not $repoRoot) {
    throw 'Unable to determine git repository root.'
}

Push-Location -Path $repoRoot
try {
    $diffArgs = @(
        'diff',
        '--name-status',
        '--find-renames=90',
        '--diff-filter=AMRD',
        $BaseRef,
        $HeadRef,
        '--'
    )

    $diffResult = Invoke-Git -Arguments $diffArgs
    $diffLines = $diffResult.StdOut -split "`r?`n" | Where-Object { $_ -and $_.Trim().Length -gt 0 }

    $pairs = @()

    foreach ($line in $diffLines) {
        $columns = $line -split "`t"
        if ($columns.Count -lt 2) {
            Write-Verbose "Skipping unrecognized diff line: $line"
            continue
        }

        $statusToken = $columns[0]
        $changeType = $null
        $basePath = $null
        $headPath = $null
        $renameScore = $null

        if ($statusToken -like 'R*') {
            if ($columns.Count -lt 3) {
                Write-Verbose "Skipping malformed rename line: $line"
                continue
            }
            $changeType = 'renamed'
            $renameScoreValue = $statusToken.Substring(1)
            $renameScoreParsed = 0
            if ([int]::TryParse($renameScoreValue, [ref]$renameScoreParsed)) {
                $renameScore = $renameScoreParsed
            } else {
                Write-Verbose "Unable to parse rename score from token '$statusToken'."
            }
            $basePath = $columns[1]
            $headPath = $columns[2]
        } elseif ($statusToken -eq 'A') {
            $changeType = 'added'
            $headPath = $columns[1]
        } elseif ($statusToken -eq 'M') {
            $changeType = 'modified'
            $basePath = $columns[1]
            $headPath = $columns[1]
        } elseif ($statusToken -eq 'D') {
            $changeType = 'deleted'
            $basePath = $columns[1]
        } else {
            Write-Verbose "Skipping unsupported status '$statusToken' for line: $line"
            continue
        }

        # Normalize paths to use forward slashes (git default).
        if ($basePath) {
            $basePath = $basePath.Replace('\', '/')
        }
        if ($headPath) {
            $headPath = $headPath.Replace('\', '/')
        }

        if ($basePath -and -not (Test-IsViPath -Path $basePath)) {
            if (-not ($headPath -and (Test-IsViPath -Path $headPath))) {
                Write-Verbose "Skipping non-VI change: $line"
                continue
            }
        } elseif ($headPath -and -not (Test-IsViPath -Path $headPath)) {
            if (-not ($basePath -and (Test-IsViPath -Path $basePath))) {
                Write-Verbose "Skipping non-VI change: $line"
                continue
            }
        }

        if ((Should-IgnorePath -Path $basePath) -or (Should-IgnorePath -Path $headPath)) {
            Write-Verbose "Skipping ignored path(s) for line: $line"
            continue
        }

        $entry = [ordered]@{
            changeType = $changeType
            basePath   = $basePath
            headPath   = $headPath
        }

        if ($renameScore -ne $null) {
            $entry.renameScore = $renameScore
        }

        $pairs += [PSCustomObject]$entry
    }

    if ($pairs.Count -gt 0) {
        $pairs = @($pairs | Sort-Object -Property @{ Expression = { Get-SortKey $_ } })
    }

    if ($DryRun) {
        if ($pairs.Count -eq 0) {
            Write-Host "No VI changes detected between '$BaseRef' and '$HeadRef'."
        } else {
            $pairs |
                Select-Object changeType, basePath, headPath, renameScore |
                Format-Table -AutoSize |
                Out-String |
                ForEach-Object { Write-Host $_ }
        }
        return
    }

    $manifest = [ordered]@{
        schema       = 'vi-diff-manifest@v1'
        generatedAt  = (Get-Date).ToString('o')
        baseRef      = $BaseRef
        headRef      = $HeadRef
        ignore       = $IgnorePattern
        pairs        = $pairs
    }

    $json = $manifest | ConvertTo-Json -Depth 5

    if ($OutputPath) {
        $outputDirectory = Split-Path -Parent $OutputPath
        if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
            Write-Verbose "Creating output directory: $outputDirectory"
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.Encoding]::UTF8)
        Write-Verbose "Manifest written to $OutputPath"
    } else {
        Write-Output $json
    }
}
finally {
    Pop-Location
}
