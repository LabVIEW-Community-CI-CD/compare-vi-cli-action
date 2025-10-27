#Requires -Version 7.0
<#
.SYNOPSIS
Stages VI pairs from a diff manifest using Stage-CompareInputs.

.DESCRIPTION
Loads a `vi-diff-manifest@v1` document (see Get-PRVIDiffManifest.ps1) and, for
each entry that includes both base and head paths, resolves the files on disk
and invokes Stage-CompareInputs.ps1. Pairs missing either side are skipped.

.PARAMETER ManifestPath
Path to the manifest JSON file.

.PARAMETER WorkingRoot
Optional directory used as the staging parent (passed through to
Stage-CompareInputs).

.PARAMETER DryRun
Show the staging plan without copying files.

.PARAMETER StageInvoker
Internal hook for tests – a script block used to stage VI pairs. When omitted,
the script runs tools/Stage-CompareInputs.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [string]$WorkingRoot,

    [switch]$DryRun,

    [scriptblock]$StageInvoker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest not found: $ManifestPath"
}

$raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "Manifest file is empty: $ManifestPath"
}

try {
    $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw "Manifest is not valid JSON: $($_.Exception.Message)"
}

if ($manifest.schema -ne 'vi-diff-manifest@v1') {
    throw "Unexpected manifest schema '$($manifest.schema)'. Expected 'vi-diff-manifest@v1'."
}

$pairs = @()
if ($manifest.pairs -is [System.Collections.IEnumerable]) {
    $pairs = @($manifest.pairs)
}

$repoRoot = (& git rev-parse --show-toplevel).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Unable to determine git repository root.'
}

function Resolve-ViPath {
    param(
        [string]$Path,
        [string]$ParameterName,
        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        try {
            return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        } catch {
            if ($AllowMissing) {
                Write-Verbose "Path not found for ${ParameterName}: $Path"
                return $null
            }
            throw "Unable to resolve $ParameterName path: $Path"
        }
    }

    $normalized = $Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $candidate = Join-Path $repoRoot $normalized
    try {
        return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    } catch {
        if ($AllowMissing) {
            Write-Verbose "Path not found for ${ParameterName}: $candidate"
            return $null
        }
        throw "Unable to resolve $ParameterName path: $candidate"
    }
}

$stageScriptPath = Join-Path $PSScriptRoot 'Stage-CompareInputs.ps1'
if (-not $StageInvoker) {
    $StageInvoker = {
        param(
            [string]$BaseVi,
            [string]$HeadVi,
            [string]$WorkingRoot,
            [string]$StageScript
        )

        $args = @{
            BaseVi = $BaseVi
            HeadVi = $HeadVi
        }
        if ($WorkingRoot) {
            $args.WorkingRoot = $WorkingRoot
        }
        & $StageScript @args
    }.GetNewClosure()
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($pair in $pairs) {
    $basePath = Resolve-ViPath -Path $pair.basePath -ParameterName 'basePath' -AllowMissing
    $headPath = Resolve-ViPath -Path $pair.headPath -ParameterName 'headPath' -AllowMissing

    if (-not $basePath -or -not $headPath) {
        Write-Verbose ("Skipping pair without full base/head: changeType={0}, base={1}, head={2}" -f $pair.changeType, $pair.basePath, $pair.headPath)
        continue
    }

    if ($DryRun) {
        $results.Add([pscustomobject]@{
            changeType = $pair.changeType
            basePath   = $basePath
            headPath   = $headPath
            staged     = $null
        })
        continue
    }

    $staged = & $StageInvoker $basePath $headPath $WorkingRoot $stageScriptPath
    $results.Add([pscustomobject]@{
        changeType = $pair.changeType
        basePath   = $basePath
        headPath   = $headPath
        staged     = $staged
    })
}

if ($DryRun) {
    if ($results.Count -eq 0) {
        Write-Host 'No VI pairs scheduled for staging.'
    } else {
        $results | Select-Object changeType, basePath, headPath |
            Format-Table -AutoSize |
            Out-String |
            ForEach-Object { Write-Host $_ }
    }
    return
}

return $results.ToArray()
