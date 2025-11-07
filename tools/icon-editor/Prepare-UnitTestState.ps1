#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).ProviderPath
$iconEditorRoot = Join-Path $repoRoot 'vendor' 'icon-editor'

Write-Host '=== Icon Editor Unit-Test Readiness ==='
Write-Host 'This helper outlines the prerequisites the unit suites expect:'
Write-Host '  • Dev mode enabled for MissingInProject targets (Invoke-MissingInProjectCLI).'
Write-Host '  • VIPC dependencies applied via VIPM CLI (Invoke-VipmDependencies).'
Write-Host '  • MissingInProject CLI run completed successfully.'
Write-Host 'Once these are satisfied, run Invoke-PesterTests.ps1 -Tags Unit.'

if (-not $Validate) {
    Write-Host ''
    Write-Host 'Pass -Validate to perform basic checks against existing telemetry.'
    return
}

Write-Host 'Validating readiness markers...'

$markers = @()

# Dev-mode state
$devModeStatePath = Join-Path $repoRoot 'tests' 'results' '_agent' 'icon-editor' 'dev-mode-state.json'
if (Test-Path -LiteralPath $devModeStatePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $devModeStatePath -Raw | ConvertFrom-Json
    $markers += [pscustomobject]@{
        Name = 'DevModeState'
        Ready = [bool]$state.Active
        Details = $devModeStatePath
    }
} else {
    $markers += [pscustomobject]@{
        Name = 'DevModeState'
        Ready = $false
        Details = 'dev-mode-state.json missing'
    }
}

# VIPM dependency telemetry
$vipmTelemetryDir = Join-Path $repoRoot 'tests' 'results' '_agent' 'icon-editor' 'vipm-install'
$vipmLog = $null
if (Test-Path -LiteralPath $vipmTelemetryDir -PathType Container) {
    $vipmLog = Get-ChildItem -LiteralPath $vipmTelemetryDir -Filter 'vipm-installed-*.json' |
        Sort-Object LastWriteTime |
        Select-Object -Last 1
}
$markers += [pscustomobject]@{
    Name = 'VipmInstalledPackages'
    Ready = [bool]$vipmLog
    Details = if ($vipmLog) { $vipmLog.FullName } else { 'No vipm-installed logs found' }
}

# MissingInProject CLI marker
$missingResults = Join-Path $repoRoot 'tests' 'results' '_agent' 'missing-in-project' 'last-run.json'
$markers += [pscustomobject]@{
    Name = 'MissingInProjectCLI'
    Ready = Test-Path -LiteralPath $missingResults -PathType Leaf
    Details = if (Test-Path -LiteralPath $missingResults -PathType Leaf) { $missingResults } else { 'missing-in-project telemetry missing' }
}

$allReady = $true
foreach ($marker in $markers) {
    $statusSymbol = if ($marker.Ready) { '[OK]' } else { '[  ]' }
    Write-Host ("{0} {1} -> {2}" -f $statusSymbol, $marker.Name, $marker.Details)
    if (-not $marker.Ready) { $allReady = $false }
}

if (-not $allReady) {
    throw 'Unit-test prerequisites are not satisfied. See markers above.'
}

Write-Host 'All readiness markers satisfied.'
