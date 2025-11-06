#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
}

$sourceRoot = Join-Path $RepoRoot 'vendor\icon-editor'
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Icon editor source root not found at '$sourceRoot'."
}

$mirrorMap = @{
    'resource' = 'resource'
    'Tooling'  = 'Tooling'
    'Test'     = 'Test'
    'vi.lib'   = 'vi.lib'
}

foreach ($entry in $mirrorMap.GetEnumerator()) {
    $source = Join-Path $sourceRoot $entry.Key
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        Write-Warning "Source directory '$source' skipped (not found)."
        continue
    }

    $destination = Join-Path $RepoRoot ('vendor\' + $entry.Value)
    Write-Host ("==> Mirroring {0} -> {1}" -f $source, $destination)

    if ($WhatIf) {
        Write-Host '    WhatIf set - skipping copy.'
        continue
    }

    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
    }

    $robocopyArgs = @($source, $destination, '/MIR', '/XD', '.git')
    $robocopyProcess = Start-Process -FilePath 'robocopy' -ArgumentList $robocopyArgs -Wait -PassThru
    if ($robocopyProcess.ExitCode -gt 3) {
        throw "robocopy failed for '$source' with exit code $($robocopyProcess.ExitCode)."
    }
}

if ($WhatIf) {
    return [pscustomobject]@{
        repoRoot = $RepoRoot
        mirrored = $false
    }
}

Write-Host 'Resource mirrors complete.'
return [pscustomobject]@{
    repoRoot = $RepoRoot
    mirrored = $true
}
