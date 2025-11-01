#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$ProbeCli
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This helper is intended for Windows hosts only.'
}

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not $scriptDir) { throw 'Unable to determine script directory.' }
$repoRoot = Split-Path -Parent $scriptDir
if (-not $repoRoot) { throw 'Unable to determine repository root.' }

$configPath = Join-Path $repoRoot 'configs\labview-paths.json'
$config = $null
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse labview-paths.json at $configPath: $($_.Exception.Message)"
    }
}

function Resolve-CandidatePath {
    param(
        [string]$PathValue
    )
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue.Trim())
    try {
        $resolved = (Resolve-Path -LiteralPath $expanded -ErrorAction Stop).Path
        return $resolved
    } catch {
        return $expanded
    }
}

$paths = [ordered]@{
    LabVIEWExePath  = $null
    LVComparePath   = $null
    LabVIEWCLIPath  = $null
    ConfigSource    = if ($config) { $configPath } else { $null }
}

if ($config) {
    if ($config.PSObject.Properties['LabVIEWExePath'])  { $paths.LabVIEWExePath = Resolve-CandidatePath $config.LabVIEWExePath }
    if ($config.PSObject.Properties['LVComparePath'])   { $paths.LVComparePath  = Resolve-CandidatePath $config.LVComparePath }
    if ($config.PSObject.Properties['LabVIEWCLIPath'])  { $paths.LabVIEWCLIPath = Resolve-CandidatePath $config.LabVIEWCLIPath }
}

$defaultRoots = @(
    'C:\Program Files\National Instruments\LabVIEW 2025',
    'C:\Program Files\National Instruments\LabVIEW 2024',
    'C:\Program Files\National Instruments\LabVIEW 2023'
)

function Ensure-Path {
    param(
        [string]$Key,
        [string]$Candidate
    )
    if (-not [string]::IsNullOrWhiteSpace($paths[$Key])) { return }
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return }
    $resolved = Resolve-CandidatePath $Candidate
    $paths[$Key] = $resolved
}

foreach ($root in $defaultRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    Ensure-Path -Key 'LabVIEWExePath' -Candidate (Join-Path $root 'LabVIEW.exe')
    Ensure-Path -Key 'LVComparePath'  -Candidate (Join-Path $root 'Shared\LabVIEW Compare\LVCompare.exe')
    Ensure-Path -Key 'LabVIEWCLIPath' -Candidate (Join-Path $root 'Shared\LabVIEW CLI\LabVIEWCLI.exe')
}

if (-not $paths.LabVIEWCLIPath) {
    $cmd = Get-Command LabVIEWCLI.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $paths.LabVIEWCLIPath = $cmd.Source
    }
}

$missing = @()
foreach ($key in @('LabVIEWExePath','LVComparePath','LabVIEWCLIPath')) {
    $candidate = $paths[$key]
    if (-not $candidate) {
        $missing += $key
        continue
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $missing += $key
    }
}

if ($missing.Count -gt 0) {
    Write-Warning "The following required paths are missing or invalid:"
    foreach ($key in $missing) {
        Write-Warning ("  {0}: {1}" -f $key, ($paths[$key] ?? '(not set)'))
    }
    Write-Warning "Update configs\labview-paths.json or install the LabVIEW CLI components, then re-run this check."
    exit 1
}

Write-Host ''
Write-Host 'LabVIEW/LVCompare configuration:' -ForegroundColor Cyan
Write-Host ("  LabVIEWExePath : {0}" -f $paths.LabVIEWExePath)
Write-Host ("  LVComparePath  : {0}" -f $paths.LVComparePath)
Write-Host ("  LabVIEWCLIPath : {0}" -f $paths.LabVIEWCLIPath)
if ($paths.ConfigSource) {
    Write-Host ("  Config file    : {0}" -f $paths.ConfigSource)
}
Write-Host ''

if ($ProbeCli.IsPresent) {
    Write-Host 'Probing LabVIEW CLI...'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $paths.LabVIEWCLIPath
    $psi.ArgumentList.Add('--help')
    $psi.WorkingDirectory = $repoRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        Write-Host $stdout
        Write-Host $stderr
        throw "LabVIEW CLI probe (--help) exited with code $($proc.ExitCode). Inspect output above."
    }
    Write-Host 'LabVIEW CLI responded to --help successfully.' -ForegroundColor Green
}

Write-Host 'LVCompare setup verified.' -ForegroundColor Green

[pscustomobject]@{
    LabVIEWExePath = $paths.LabVIEWExePath
    LVComparePath  = $paths.LVComparePath
    LabVIEWCLIPath = $paths.LabVIEWCLIPath
    ConfigSource   = $paths.ConfigSource
}
