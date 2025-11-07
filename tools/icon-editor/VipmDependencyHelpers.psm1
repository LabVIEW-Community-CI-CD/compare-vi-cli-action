#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-VipmCliReady {
    param(
        [Parameter(Mandatory)][string]$LabVIEWVersion,
        [Parameter(Mandatory)][string]$LabVIEWBitness,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $vipmCommand = Get-Command vipm -ErrorAction Stop

    $versionOutput = & $vipmCommand.Source '--version' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "VIPM CLI '--version' failed: $versionOutput"
    }

    & $vipmCommand.Source 'build' '--help' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "VIPM CLI 'build --help' failed; ensure VIPM is installed and accessible."
    }

    Import-Module (Join-Path $RepoRoot 'tools' 'VendorTools.psm1') -Force
    $labviewExe = Find-LabVIEWVersionExePath -Version ([int]$LabVIEWVersion) -Bitness ([int]$LabVIEWBitness)
    if (-not $labviewExe) {
        throw "LabVIEW $LabVIEWVersion ($LabVIEWBitness-bit) was not detected. Install or configure that version before applying VIPC dependencies."
    }

    return [pscustomobject]@{
        vipmVersion = $versionOutput.Trim()
        labviewExe  = $labviewExe
    }
}

function Initialize-VipmTelemetry {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $root = Join-Path $RepoRoot 'tests\results\_agent\icon-editor\vipm-install'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $root).Path
}

function Get-VipmInstalledPackages {
    param(
        [Parameter(Mandatory)][string]$LabVIEWVersion,
        [Parameter(Mandatory)][string]$LabVIEWBitness
    )

    $vipmCommand = Get-Command vipm -ErrorAction Stop
    $output = & $vipmCommand.Source 'list' '--installed' '--labview-version' $LabVIEWVersion '--labview-bitness' $LabVIEWBitness '--color-mode' 'never' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "vipm list --installed failed: $output"
    }

    $packages = @()
    foreach ($line in ($output -split [Environment]::NewLine)) {
        if ($line -match '^\s+(?<name>.+?)\s+\((?<identifier>.+?)\sv(?<version>[^\)]+)\)') {
            $packages += [ordered]@{
                name       = $Matches.name.Trim()
                identifier = $Matches.identifier.Trim()
                version    = $Matches.version.Trim()
            }
        }
    }

    return [pscustomobject]@{
        rawOutput = $output
        packages  = $packages
    }
}

function Write-VipmTelemetryLog {
    param(
        [Parameter(Mandatory)][string]$LogRoot,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Binary,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$StdOut,
        [string]$StdErr,
        [string]$LabVIEWVersion,
        [string]$LabVIEWBitness
    )

    $payload = [ordered]@{
        schema         = 'icon-editor/vipm-install@v1'
        generatedAt    = (Get-Date).ToString('o')
        provider       = $Provider
        binary         = $Binary
        arguments      = $Arguments
        workingDir     = $WorkingDirectory
        labviewVersion = $LabVIEWVersion
        labviewBitness = $LabVIEWBitness
        exitCode       = $ExitCode
        stdout         = ($StdOut ?? '').Trim()
        stderr         = ($StdErr ?? '').Trim()
    }

    $logName = ('vipm-install-{0:yyyyMMddTHHmmssfff}.json' -f (Get-Date))
    $logPath = Join-Path $LogRoot $logName
    $payload | ConvertTo-Json -InputObject $payload -Depth 128 | Set-Content -LiteralPath $logPath -Encoding UTF8
    return $logPath
}

function Write-VipmInstalledPackagesLog {
    param(
        [Parameter(Mandatory)][string]$LogRoot,
        [Parameter(Mandatory)][string]$LabVIEWVersion,
        [Parameter(Mandatory)][string]$LabVIEWBitness,
        [Parameter(Mandatory)][pscustomobject]$PackageInfo
    )

    $payload = [ordered]@{
        schema         = 'icon-editor/vipm-installed@v1'
        generatedAt    = (Get-Date).ToString('o')
        labviewVersion = $LabVIEWVersion
        labviewBitness = $LabVIEWBitness
        packages       = $PackageInfo.packages
        rawOutput      = $PackageInfo.rawOutput
    }

    $logName = ('vipm-installed-{0}-{1}bit-{2:yyyyMMddTHHmmssfff}.json' -f $LabVIEWVersion, $LabVIEWBitness, (Get-Date))
    $logPath = Join-Path $LogRoot $logName
    $payload | ConvertTo-Json -InputObject $payload -Depth 128 | Set-Content -LiteralPath $logPath -Encoding UTF8
    return $logPath
}

function Invoke-VipmProcess {
    param(
        [Parameter(Mandatory)][pscustomobject]$Invocation,
        [string]$WorkingDirectory
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Invocation.Binary
    foreach ($arg in $Invocation.Arguments) {
        if ($null -ne $arg) {
            [void]$psi.ArgumentList.Add([string]$arg)
        }
    }
    if ($WorkingDirectory) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($stdout) { Write-Host $stdout.Trim() }
    if ($stderr) { Write-Host $stderr.Trim() }

    if ($process.ExitCode -ne 0) {
        $message = "Process exited with code $($process.ExitCode)."
        if ($stderr) {
            $message += [Environment]::NewLine + $stderr.Trim()
        }
        throw $message
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Install-VipmVipc {
    param(
        [Parameter(Mandatory)][string]$VipcPath,
        [Parameter(Mandatory)][string]$LabVIEWVersion,
        [Parameter(Mandatory)][string]$LabVIEWBitness,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$TelemetryRoot
    )

    $params = @{
        vipcPath       = $VipcPath
        labviewVersion = $LabVIEWVersion
        labviewBitness = $LabVIEWBitness
    }

    $invocation = Get-VipmInvocation -Operation 'InstallVipc' -Params $params
    $result = Invoke-VipmProcess -Invocation $invocation -WorkingDirectory (Split-Path -Parent $VipcPath)
    Write-VipmTelemetryLog `
        -LogRoot $TelemetryRoot `
        -Provider $invocation.Provider `
        -Binary $invocation.Binary `
        -Arguments $invocation.Arguments `
        -WorkingDirectory (Split-Path -Parent $VipcPath) `
        -ExitCode $result.ExitCode `
        -StdOut $result.StdOut `
        -StdErr $result.StdErr `
        -LabVIEWVersion $LabVIEWVersion `
        -LabVIEWBitness $LabVIEWBitness | Out-Null

    $packageInfo = Get-VipmInstalledPackages -LabVIEWVersion $LabVIEWVersion -LabVIEWBitness $LabVIEWBitness
    Write-VipmInstalledPackagesLog `
        -LogRoot $TelemetryRoot `
        -LabVIEWVersion $LabVIEWVersion `
        -LabVIEWBitness $LabVIEWBitness `
        -PackageInfo $packageInfo | Out-Null

    return [ordered]@{
        version  = $LabVIEWVersion
        bitness  = $LabVIEWBitness
        packages = $packageInfo.packages
    }
}

function Show-VipmDependencies {
    param(
        [Parameter(Mandatory)][string]$LabVIEWVersion,
        [Parameter(Mandatory)][string]$LabVIEWBitness,
        [Parameter(Mandatory)][string]$TelemetryRoot
    )

    $packageInfo = Get-VipmInstalledPackages -LabVIEWVersion $LabVIEWVersion -LabVIEWBitness $LabVIEWBitness
    Write-VipmInstalledPackagesLog `
        -LogRoot $TelemetryRoot `
        -LabVIEWVersion $LabVIEWVersion `
        -LabVIEWBitness $LabVIEWBitness `
        -PackageInfo $packageInfo | Out-Null

    return [ordered]@{
        version  = $LabVIEWVersion
        bitness  = $LabVIEWBitness
        packages = $packageInfo.packages
    }
}

Export-ModuleMember -Function Test-VipmCliReady, Initialize-VipmTelemetry, Install-VipmVipc, Show-VipmDependencies
