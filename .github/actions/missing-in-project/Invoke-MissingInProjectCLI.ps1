#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LVVersion,
    [Parameter(Mandatory)][ValidateSet('32','64')][string]$Arch,
    [Parameter(Mandatory)][string]$ProjectFile
)

$ErrorActionPreference = 'Stop'

$Script:HelperExitCode   = 0
$Script:MissingFileLines = @()
$Script:ParsingFailed    = $false

$HelperPath      = Join-Path $PSScriptRoot 'RunMissingCheckWithGCLI.ps1'
$MissingFilePath = Join-Path $PSScriptRoot 'missing_files.txt'
$DevModeSkip     = $false
$DevModeApplied  = $false

if (-not (Test-Path $HelperPath)) {
    Write-Host "Helper script not found: $HelperPath"
    exit 100
}

$repoRoot = $env:MIP_REPO_ROOT
if (-not $repoRoot) {
    try {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    } catch {
        $repoRoot = $null
    }
}
if (-not $repoRoot -or -not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
    throw "Unable to determine repository root. Set MIP_REPO_ROOT before invoking."
}

Import-Module (Join-Path $repoRoot 'tools' 'VendorTools.psm1') -Force

$resultsRoot = $env:MIP_RESULTS_ROOT
if (-not $resultsRoot) {
    $resultsRoot = Join-Path $repoRoot 'tests\results\_agent\missing-in-project'
}
if (-not (Test-Path -LiteralPath $resultsRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
}

$transcriptPath   = $null
$transcriptActive = $false
try {
    $timestamp = Get-Date -Format 'yyyyMMddTHHmmssfff'
    $transcriptPath = Join-Path $resultsRoot ("missing-in-project-{0}.log" -f $timestamp)
    Start-Transcript -Path $transcriptPath -Force -IncludeInvocationHeader | Out-Null
    $transcriptActive = $true
} catch {
    $transcriptPath = $null
    Write-Warning ("Failed to start transcript: {0}" -f $_.Exception.Message)
}

$gCliPath = Resolve-GCliPath
if ([string]::IsNullOrWhiteSpace($gCliPath)) {
    Write-Error "Unable to locate g-cli executable. Configure GCLI_EXE_PATH or labview-paths*.json so the automation can locate g-cli."
    exit 102
}
$gCliPath = (Resolve-Path -LiteralPath $gCliPath).Path
Write-Host ("Using g-cli executable: {0}" -f $gCliPath)
$previousGCliPath = $env:GCLI_EXE_PATH
$env:GCLI_EXE_PATH = $gCliPath

$iconEditorRoot = Join-Path $repoRoot 'vendor' 'icon-editor'
$enableDevModeScript  = Join-Path $repoRoot 'tools' 'icon-editor' 'Enable-DevMode.ps1'
$disableDevModeScript = Join-Path $repoRoot 'tools' 'icon-editor' 'Disable-DevMode.ps1'
$resetWorkspaceScript = if ($env:MIP_RESET_WORKSPACE_SCRIPT) {
    $env:MIP_RESET_WORKSPACE_SCRIPT
} else {
    Join-Path $repoRoot 'tools' 'icon-editor' 'Reset-IconEditorWorkspace.ps1'
}

if ($env:MIP_SKIP_DEVMODE) {
    $value = $env:MIP_SKIP_DEVMODE.ToLowerInvariant()
    if ($value -in @('1','true','yes','on')) {
        $DevModeSkip = $true
        Write-Host "Skipping icon editor dev-mode toggle by request (MIP_SKIP_DEVMODE=$($env:MIP_SKIP_DEVMODE))."
    }
}

$versionInt = 0
try { $versionInt = [int]$LVVersion } catch { $versionInt = 0 }
$bitnessInt = 0
try { $bitnessInt = [int]$Arch } catch { $bitnessInt = 64 }
$labviewCli = $null
try {
    $labviewCliOverride = $env:LABVIEW_CLI_COMMAND
    if (-not [string]::IsNullOrWhiteSpace($labviewCliOverride)) {
        $labviewCli = $labviewCliOverride
    } else {
        $labviewCli = Resolve-LabVIEWCLIPath -Version $versionInt -Bitness $bitnessInt
    }
} catch {
    $labviewCli = $null
}
$previousLvRoot = $null
if ($labviewCli) {
    try {
        $lvRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $labviewCli))
        $previousLvRoot = $env:NI_AppBuilder_LVRootPath
        $env:NI_AppBuilder_LVRootPath = $lvRoot
    } catch {
        Write-Warning "Failed to adjust NI_AppBuilder_LVRootPath: $($_.Exception.Message)"
    }
} elseif (-not $DevModeSkip) {
    Write-Warning "LabVIEW CLI executable not found; skipping icon editor dev-mode toggles."
    $DevModeSkip = $true
}

$projectCandidates = @()
if ([System.IO.Path]::IsPathRooted($ProjectFile)) {
    $projectCandidates += $ProjectFile
} else {
    $projectCandidates += (Join-Path (Get-Location) $ProjectFile)
    $projectCandidates += (Join-Path $repoRoot $ProjectFile)
    $projectCandidates += (Join-Path $PSScriptRoot $ProjectFile)
    $projectCandidates += $ProjectFile
}
$projectCandidates = $projectCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
$ResolvedProjectFile = $null
foreach ($candidate in $projectCandidates) {
    try {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $ResolvedProjectFile = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    } catch {
        # try next candidate
    }
}
if (-not $ResolvedProjectFile) {
    throw "Project file '$ProjectFile' could not be located. Checked working directory '$((Get-Location).Path)' and repo root '$repoRoot'."
}

function Invoke-DevModeToggle {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$ActionName
    )
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        Write-Warning ("Icon editor dev-mode script '{0}' not found; continuing without {1}." -f $ScriptPath, $ActionName)
        return $false
    }

    Write-Host ("==> Icon editor dev-mode: {0}" -f $ActionName)
    try {
        & $ScriptPath `
            -RepoRoot $repoRoot `
            -IconEditorRoot $iconEditorRoot `
            -Versions $versionInt `
            -Bitness $bitnessInt `
            -Operation 'Compare' | Out-Null
        return $true
    } catch {
        Write-Warning ("Icon editor dev-mode {0} failed: {1}" -f $ActionName, $_.Exception.Message)
        return $false
    }
}

function Write-MissingInProjectTelemetry {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][hashtable]$Payload
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }

    $target = Join-Path $Root 'last-run.json'
    $Payload | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $target -Encoding UTF8
    return $target
}

if (-not $DevModeSkip) {
    $DevModeApplied = Invoke-DevModeToggle -ScriptPath $enableDevModeScript -ActionName 'enable'
}

function Setup {
    Write-Host "=== Setup ==="
    Write-Host "LVVersion  : $LVVersion"
    Write-Host "Arch       : $Arch-bit"
    Write-Host "ProjectFile: $ResolvedProjectFile"

    if (Test-Path $MissingFilePath) {
        Remove-Item $MissingFilePath -Force -ErrorAction SilentlyContinue
        Write-Host "Deleted previous $MissingFilePath"
    }
}

function MainSequence {
    Write-Host "`n=== MainSequence ==="
    Write-Host "Invoking missing-file check via helper script.`n"

    & $HelperPath -LVVersion $LVVersion -Arch $Arch -ProjectFile $ResolvedProjectFile
    $Script:HelperExitCode = $LASTEXITCODE

    if ($Script:HelperExitCode -ne 0) {
        Write-Warning "Helper returned non-zero exit code: $Script:HelperExitCode"
    }

    if (Test-Path $MissingFilePath) {
        $Script:MissingFileLines = @(
            Get-Content $MissingFilePath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
        )
    } elseif ($Script:HelperExitCode -ne 0) {
        $Script:ParsingFailed = $true
        return
    }

    Write-Host ""
    $col1   = "FilePath"
    $lines = @($Script:MissingFileLines)
    $maxLen = if ($lines.Count -gt 0) { ($lines | Measure-Object -Maximum Length).Maximum } else { $col1.Length }

    Write-Host ($col1.PadRight($maxLen)) -ForegroundColor Cyan

    if ($lines.Count -eq 0) {
        $msg = "No missing files detected"
        Write-Host ($msg.PadRight($maxLen)) -ForegroundColor Green
    } else {
        foreach ($line in $lines) {
            Write-Host ($line.PadRight($maxLen)) -ForegroundColor Red
        }
    }
}

function Cleanup {
    Write-Host "`n=== Cleanup ==="
    $lines = @($Script:MissingFileLines)
    if ($Script:HelperExitCode -eq 0 -and $lines.Count -eq 0) {
        if (Test-Path $MissingFilePath) {
            Remove-Item $MissingFilePath -Force -ErrorAction SilentlyContinue
            Write-Host "All good - removed $MissingFilePath"
        }
    }
}

try {
    Setup
    MainSequence
    Cleanup
}
finally {
    if ($DevModeApplied -and -not $DevModeSkip) {
        [void] (Invoke-DevModeToggle -ScriptPath $disableDevModeScript -ActionName 'disable')
    }
    if ($labviewCli) {
        try { & $labviewCli --Kill | Out-Null } catch { Write-Warning "Failed to terminate LabVIEW via CLI: $($_.Exception.Message)" }
    }
    if ($previousLvRoot -ne $null) {
        $env:NI_AppBuilder_LVRootPath = $previousLvRoot
    }
    if ($previousGCliPath) {
        $env:GCLI_EXE_PATH = $previousGCliPath
    } else {
        Remove-Item Env:GCLI_EXE_PATH -ErrorAction SilentlyContinue
    }
    $resetScriptPath = $null
    if (-not [string]::IsNullOrWhiteSpace($resetWorkspaceScript)) {
        try {
            if (Test-Path -LiteralPath $resetWorkspaceScript -PathType Leaf) {
                $resetScriptPath = (Resolve-Path -LiteralPath $resetWorkspaceScript).Path
            } else {
                Write-Warning ("Workspace reset script '{0}' not found." -f $resetWorkspaceScript)
            }
        } catch {
            Write-Warning ("Failed to resolve workspace reset script '{0}': {1}" -f $resetWorkspaceScript, $_.Exception.Message)
        }
    }
    if ($resetScriptPath) {
        $resetVersions = @()
        if ($versionInt -gt 0) {
            $resetVersions = @($versionInt)
        } else {
            try {
                $parsedVersion = [int]$LVVersion
                if ($parsedVersion -gt 0) {
                    $resetVersions = @($parsedVersion)
                }
            } catch {
                $resetVersions = @()
            }
        }
        $resetBitness = @()
        $bitnessCandidate = $bitnessInt
        if ($bitnessCandidate -notin @(32,64)) {
            try { $bitnessCandidate = [int]$Arch } catch { $bitnessCandidate = 0 }
        }
        if ($bitnessCandidate -in @(32,64)) {
            $resetBitness = @($bitnessCandidate)
        }
        if ($resetVersions.Count -gt 0 -and $resetBitness.Count -gt 0) {
            try {
                & $resetScriptPath `
                    -RepoRoot $repoRoot `
                    -IconEditorRoot $iconEditorRoot `
                    -Versions $resetVersions `
                    -Bitness $resetBitness | Out-Null
            } catch {
                Write-Warning ("Failed to reset icon editor workspace via '{0}': {1}" -f $resetScriptPath, $_.Exception.Message)
            }
        } else {
            Write-Warning "Skipping workspace reset because LabVIEW version/bitness could not be determined."
        }
    }
    if ($transcriptActive) {
        try { Stop-Transcript | Out-Null } catch { Write-Warning ("Failed to stop transcript: {0}" -f $_.Exception.Message) }
    }
}

$passed     = ($Script:HelperExitCode -eq 0) -and (@($Script:MissingFileLines).Count -eq 0) -and (-not $Script:ParsingFailed)
$passedStr  = $passed.ToString().ToLowerInvariant()
$missingCsv = ($Script:MissingFileLines -join ',')

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "passed=$passedStr"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "missing-files=$missingCsv"
}

try {
    $resolvedProject = $ResolvedProjectFile
    $payload = [ordered]@{
        schema         = 'icon-editor/missing-in-project@v1'
        generatedAt    = (Get-Date).ToString('o')
        repoRoot       = $repoRoot
        resultsRoot    = $resultsRoot
        lvVersion      = $LVVersion
        arch           = $Arch
        projectFile    = $resolvedProject
        helperExitCode = $Script:HelperExitCode
        missingFiles   = $Script:MissingFileLines
        parsingFailed  = [bool]$Script:ParsingFailed
        passed         = [bool]$passed
        transcriptPath = $transcriptPath
    }
    Write-MissingInProjectTelemetry -Root $resultsRoot -Payload $payload | Out-Null
} catch {
    Write-Warning ("Failed to write missing-in-project telemetry: {0}" -f $_.Exception.Message)
}

if ($Script:ParsingFailed) {
    exit 1
} elseif (-not $passed) {
    exit 2
} else {
    exit 0
}
