#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Providers = @{}

function Register-GCliProvider {
    param([Parameter(Mandatory)][object]$Provider)

    foreach ($member in @('Name','ResolveBinaryPath','Supports','BuildArgs')) {
        if (-not ($Provider | Get-Member -Name $member -ErrorAction SilentlyContinue)) {
            throw "Provider registration failed: missing required method '$member'."
        }
    }

    $name = $Provider.Name()
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'Provider registration failed: Name() returned empty.'
    }

    $script:Providers[$name.ToLowerInvariant()] = $Provider
}

function Get-GCliProviders {
    return $script:Providers.GetEnumerator() | ForEach-Object { $_.Value }
}

function Get-GCliProviderByName {
    param([Parameter(Mandatory)][string]$Name)

    $key = $Name.ToLowerInvariant()
    if ($script:Providers.ContainsKey($key)) {
        return $script:Providers[$key]
    }
    return $null
}

function Import-GCliProviderModules {
    $providerRoot = Join-Path $PSScriptRoot 'providers'
    if (-not (Test-Path -LiteralPath $providerRoot -PathType Container)) { return }

    $modules = Get-ChildItem -Path $providerRoot -Directory -ErrorAction SilentlyContinue
    foreach ($modDir in $modules) {
        $modulePath = $null
        $manifestPath = Join-Path $modDir.FullName ("{0}.Provider.psd1" -f $modDir.Name)
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $modulePath = $manifestPath
        } else {
            $fallbackPath = Join-Path $modDir.FullName 'Provider.psm1'
            if (Test-Path -LiteralPath $fallbackPath -PathType Leaf) {
                $modulePath = $fallbackPath
            }
        }
        if (-not $modulePath) { continue }
        try {
            $moduleInfo = Import-Module $modulePath -Force -PassThru
            $command = Get-Command -Name 'New-GCliProvider' -Module $moduleInfo.Name -ErrorAction Stop
            $provider = & $command
            if (-not $provider) { throw 'New-GCliProvider returned null.' }
            Register-GCliProvider -Provider $provider
        } catch {
            Write-Warning ("Failed to import g-cli provider from {0}: {1}" -f $modulePath, $_.Exception.Message)
        }
    }
}

Import-GCliProviderModules

function Get-GCliInvocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [hashtable]$Params,
        [string]$ProviderName
    )

    $candidates = @()
    if ($ProviderName) {
        $provider = Get-GCliProviderByName -Name $ProviderName
        if (-not $provider) {
            throw "g-cli provider '$ProviderName' is not registered."
        }
        $candidates = @($provider)
    } else {
        $candidates = Get-GCliProviders
    }

    foreach ($provider in $candidates) {
        if (-not $provider.Supports($Operation)) { continue }

        $binary = $provider.ResolveBinaryPath()
        if ([string]::IsNullOrWhiteSpace($binary)) {
            throw ("Provider '{0}' failed to resolve g-cli binary path." -f $provider.Name())
        }

        $arguments = $provider.BuildArgs($Operation, $Params)
        if (-not $arguments) {
            $arguments = @()
        }

        return [pscustomobject]@{
            Provider  = $provider.Name()
            Binary    = $binary
            Arguments = @($arguments)
        }
    }

    $available = (Get-GCliProviders | ForEach-Object { $_.Name() }) -join ', '
    throw "No g-cli provider registered that supports operation '$Operation'. Registered providers: $available"
}

Export-ModuleMember -Function Get-GCliInvocation, Get-GCliProviders, Get-GCliProviderByName

