#Requires -Version 7.0

<#
.SYNOPSIS
    Compares VIPM operations across provider backends and records telemetry.

.DESCRIPTION
    Drives scenarios (e.g. InstallVipc, BuildVip) through the VIPM provider
    framework, invoking each requested provider and capturing duration, exit
    codes, warnings, and artifact hashes.  Results append to
    tests/results/_agent/vipm-provider-matrix.json so successive runs build a
    history that can be analysed in CI or locally.

.PARAMETER Providers
    One or more provider names to exercise. Defaults to @('vipm'). Providers not
    currently registered are recorded as provider-missing (unless
    -SkipMissingProviders is supplied).

.PARAMETER Scenario
    Optional hashtable array describing scenarios. When omitted a default
    InstallVipc scenario using runner_dependencies.vipc is executed.

.PARAMETER ScenarioFile
    JSON file containing an array of scenario definitions compatible with the
    -Scenario format.

.PARAMETER OutputPath
    Destination for the aggregated telemetry JSON. Defaults to
    tests/results/_agent/vipm-provider-matrix.json (appending existing entries).

.PARAMETER SkipMissingProviders
    Suppresses telemetry entries for providers that are not currently
    registered. Useful when running locally without alternate backends.

.EXAMPLE
    pwsh -File tools/Vipm/Invoke-ProviderComparison.ps1

    Runs the default InstallVipc scenario through the vipm provider, appending
    results to tests/results/_agent/vipm-provider-matrix.json.

.EXAMPLE
    pwsh -File tools/Vipm/Invoke-ProviderComparison.ps1 `
        -Providers vipm -OutputPath (Join-Path $PWD 'vipm-matrix.json') `
        -ScenarioFile scenarios/vipm.json

    Executes scenarios supplied via JSON and writes telemetry alongside the repo.
#>

[CmdletBinding()]
param(
    [string[]]$Providers = @('vipm'),
    [object[]]$Scenario,
    [string]$ScenarioFile,
    [string]$OutputPath,
    [switch]$SkipMissingProviders
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    param([string]$StartPath = (Get-Location).Path)
    try {
        $root = git -C $StartPath rev-parse --show-toplevel 2>$null
        if ($root) { return (Resolve-Path -LiteralPath $root.Trim()).Path }
    } catch {}
    return (Resolve-Path -LiteralPath $StartPath).Path
}

function Resolve-ScenarioPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $RepoRoot $Path) -ErrorAction Stop).Path
}

function Invoke-VipmOperation {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][hashtable]$Params,
        [Parameter(Mandatory)][string]$ProviderName
    )

    $result = [ordered]@{
        Status          = 'success'
        DurationSeconds = 0.0
        ExitCode        = $null
        Warnings        = @()
        StdOut          = @()
        StdErr          = @()
        Error           = $null
        Invocation      = $null
    }

    try {
        $invocation = Get-VipmInvocation -Operation $Operation -Params $Params -ProviderName $ProviderName
        $result.Invocation = $invocation
    } catch {
        $result.Status = 'provider-error'
        $result.Error  = $_.Exception.Message
        return [pscustomobject]$result
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $result.Invocation.Binary
    foreach ($arg in $result.Invocation.Arguments) {
        [void]$psi.ArgumentList.Add($arg)
    }
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc   = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
    } catch {
        $stopwatch.Stop()
        $result.Status = 'failed'
        $result.Error  = $_.Exception.Message
        return [pscustomobject]$result
    }
    $stopwatch.Stop()

    $result.DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    $result.ExitCode        = $proc.ExitCode
    $result.StdOut          = ($stdout -split "`r?`n") | Where-Object { $_ } 
    $result.StdErr          = ($stderr -split "`r?`n") | Where-Object { $_ } 
    $result.Warnings        = ($result.StdOut + $result.StdErr) |
        Where-Object { $_ -match '\bWARN\b' -or $_ -match '\bWarning\b' -or $_ -match '\bError\b' }

    if ($proc.ExitCode -ne 0) {
        $result.Status = 'failed'
        if (-not $result.Error) {
            $result.Error = "Process exited with code $($proc.ExitCode)."
        }
    }

    return [pscustomobject]$result
}

$repoRoot = Resolve-RepoRoot -StartPath (Join-Path $PSScriptRoot '..\..')
$originalLocation = Get-Location
Push-Location $repoRoot
try {

if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'tests\results\_agent\vipm-provider-matrix.json'
}

$scenarios = @()
if ($Scenario) {
    $scenarios = $Scenario
} elseif ($ScenarioFile) {
    $scenarioContent = Get-Content -LiteralPath $ScenarioFile -Raw
    $scenarios = $scenarioContent | ConvertFrom-Json
} else {
    $scenarios = @(
        [ordered]@{
            Name      = 'install-runner-dependencies'
            Operation = 'InstallVipc'
            VipcPath  = '.github/actions/apply-vipc/runner_dependencies.vipc'
            Targets   = @(
                @{ LabVIEWVersion = '2025'; SupportedBitness = '64' }
            )
        }
    )
}

Import-Module (Join-Path $repoRoot 'tools' 'Vipm.psm1') -Force

$telemetry = New-Object System.Collections.Generic.List[object]
$summary   = New-Object System.Collections.Generic.List[object]

foreach ($scenario in $scenarios) {
    $scenarioName = $scenario.Name
    if (-not $scenarioName) { $scenarioName = $scenario.Operation }

    foreach ($providerName in ($Providers | Select-Object -Unique)) {
        $record = [ordered]@{
            timestamp        = (Get-Date).ToString('o')
            scenario         = $scenarioName
            provider         = $providerName
            operation        = $scenario.Operation
            status           = 'skipped'
            durationSeconds  = 0.0
            warnings         = @()
            error            = $null
            details          = @()
            artifacts        = @()
        }

        $provider = Get-VipmProviderByName -Name $providerName
        if (-not $provider) {
            if ($SkipMissingProviders) { continue }
            $record.status = 'provider-missing'
            $record.error  = "Provider '$providerName' is not registered."
            $telemetry.Add([pscustomobject]$record) | Out-Null
            $summary.Add([pscustomobject]@{
                Scenario = $scenarioName
                Provider = $providerName
                Status   = $record.status
                Duration = 0.0
            }) | Out-Null
            continue
        }

        switch ($scenario.Operation) {
            'InstallVipc' {
                $vipcPath = Resolve-ScenarioPath -Path $scenario.VipcPath -RepoRoot $repoRoot
                if (-not (Test-Path -LiteralPath $vipcPath -PathType Leaf)) {
                    $record.status = 'missing-input'
                    $record.error  = "VIPC file not found at '$vipcPath'."
                    $telemetry.Add([pscustomobject]$record) | Out-Null
                    $summary.Add([pscustomobject]@{
                        Scenario = $scenarioName
                        Provider = $providerName
                        Status   = $record.status
                        Duration = 0.0
                    }) | Out-Null
                    continue
                }

                $targets = @()
                if ($scenario.Targets) { $targets = $scenario.Targets }
                if (-not $targets) {
                    $record.status = 'missing-targets'
                    $record.error  = 'InstallVipc scenario requires Targets array.'
                    $telemetry.Add([pscustomobject]$record) | Out-Null
                    $summary.Add([pscustomobject]@{
                        Scenario = $scenarioName
                        Provider = $providerName
                        Status   = $record.status
                        Duration = 0.0
                    }) | Out-Null
                    continue
                }

                $totalDuration = 0.0
                $overallStatus = 'success'
                $warnings      = New-Object System.Collections.Generic.List[string]
                $errors        = New-Object System.Collections.Generic.List[string]
                $detailItems   = New-Object System.Collections.Generic.List[object]

                foreach ($target in $targets) {
                    $targetVersion = [string]$target.LabVIEWVersion
                    $targetBitness = [string]$target.SupportedBitness
                    $params = @{
                        vipcPath       = $vipcPath
                        labviewVersion = $targetVersion
                        labviewBitness = $targetBitness
                    }

                    $operationResult = Invoke-VipmOperation -Operation 'InstallVipc' -Params $params -ProviderName $providerName
                    $totalDuration += $operationResult.DurationSeconds
                    if ($operationResult.Warnings) { $warnings.AddRange($operationResult.Warnings) }
                    if ($operationResult.Error)    { $errors.Add($operationResult.Error) }
                    if ($operationResult.Status -ne 'success') { $overallStatus = $operationResult.Status }

                    $detailItems.Add([pscustomobject]@{
                        labviewVersion = $targetVersion
                        supportedBitness = $targetBitness
                        status = $operationResult.Status
                        durationSeconds = $operationResult.DurationSeconds
                        exitCode = $operationResult.ExitCode
                        warnings = $operationResult.Warnings
                        error    = $operationResult.Error
                    }) | Out-Null
                }

                $record.status          = $overallStatus
                $record.durationSeconds = [Math]::Round($totalDuration, 3)
                $record.warnings        = $warnings.ToArray()
                if ($errors.Count -gt 0) { $record.error = ($errors.ToArray() -join '; ') }
                $record.details         = $detailItems.ToArray()
            }
            'BuildVip' {
                $vipbPath = Resolve-ScenarioPath -Path $scenario.VipbPath -RepoRoot $repoRoot
                if (-not (Test-Path -LiteralPath $vipbPath -PathType Leaf)) {
                    $record.status = 'missing-input'
                    $record.error  = "VIPB file not found at '$vipbPath'."
                    $telemetry.Add([pscustomobject]$record) | Out-Null
                    $summary.Add([pscustomobject]@{
                        Scenario = $scenarioName
                        Provider = $providerName
                        Status   = $record.status
                        Duration = 0.0
                    }) | Out-Null
                    continue
                }

                $params = @{
                    vipbPath        = $vipbPath
                }
                if ($scenario.OutputDirectory) {
                    $params.outputDirectory = Resolve-ScenarioPath -Path $scenario.OutputDirectory -RepoRoot $repoRoot
                    if (-not (Test-Path -LiteralPath $params.outputDirectory -PathType Container)) {
                        New-Item -ItemType Directory -Path $params.outputDirectory -Force | Out-Null
                    }
                }
                if ($scenario.BuildVersion) { $params.buildVersion = [string]$scenario.BuildVersion }
                if ($scenario.AdditionalOptions) { $params.additionalOptions = $scenario.AdditionalOptions }

                $operationResult = Invoke-VipmOperation -Operation 'BuildVip' -Params $params -ProviderName $providerName
                $record.status          = $operationResult.Status
                $record.durationSeconds = [Math]::Round($operationResult.DurationSeconds, 3)
                $record.warnings        = $operationResult.Warnings
                $record.error           = $operationResult.Error
                $record.details         = @([pscustomobject]@{
                    status = $operationResult.Status
                    durationSeconds = $operationResult.DurationSeconds
                    exitCode        = $operationResult.ExitCode
                    warnings        = $operationResult.Warnings
                    error           = $operationResult.Error
                })

                if ($scenario.Artifacts) {
                    $artifactSummaries = New-Object System.Collections.Generic.List[object]
                    foreach ($artifact in $scenario.Artifacts) {
                        $artifactPath = Resolve-ScenarioPath -Path $artifact -RepoRoot $repoRoot
                        if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
                            $hash = Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
                            $artifactSummaries.Add([pscustomobject]@{
                                path   = $artifactPath
                                status = 'present'
                                sha256 = $hash.Hash
                            }) | Out-Null
                        } else {
                            $artifactSummaries.Add([pscustomobject]@{
                                path   = $artifactPath
                                status = 'missing'
                                sha256 = $null
                            }) | Out-Null
                        }
                    }
                    $record.artifacts = $artifactSummaries.ToArray()
                }
            }
            default {
                $record.status = 'unsupported-operation'
                $record.error  = "Operation '$($scenario.Operation)' not implemented."
            }
        }

        $telemetry.Add([pscustomobject]$record) | Out-Null
        $summary.Add([pscustomobject]@{
            Scenario = $scenarioName
            Provider = $providerName
            Status   = $record.status
            Duration = $record.durationSeconds
        }) | Out-Null
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$existing = @()
if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
    try {
        $raw = Get-Content -LiteralPath $OutputPath -Raw
        if ($raw) {
            $existing = $raw | ConvertFrom-Json -Depth 8
            if ($existing -isnot [System.Collections.IEnumerable]) {
                $existing = @($existing)
            }
        }
    } catch {
        Write-Warning "Unable to parse existing telemetry at '$OutputPath': $($_.Exception.Message). Overwriting."
        $existing = @()
    }
}

$combined = @()
$combined += $existing
$combined += $telemetry

$combined | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host ''
Write-Host 'VIPM Provider Comparison Summary' -ForegroundColor Cyan
foreach ($entry in $summary) {
    Write-Host (" - {0} via {1}: {2} ({3}s)" -f $entry.Scenario, $entry.Provider, $entry.Status, $entry.Duration)
}

    $finalResults = $telemetry.ToArray()
}
finally {
    Pop-Location
}

return $finalResults
