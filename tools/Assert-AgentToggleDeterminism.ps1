[CmdletBinding()]
param(
  [string[]]$Profiles,
  [switch]$AllowEnvironmentOverrides,
  [string]$CliPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Profiles {
  param([string[]]$Values)
  $result = @()
  foreach ($value in $Values) {
    if (-not $value) { continue }
    foreach ($fragment in ($value -split ',')) {
      $trimmed = $fragment.Trim()
      if ($trimmed.Length -gt 0 -and -not $result.Contains($trimmed)) {
        $result += $trimmed
      }
    }
  }
  return ,$result
}

$repoRoot = (Resolve-Path '.').Path
if (-not $CliPath) {
  $CliPath = Join-Path $repoRoot 'dist/src/config/toggles-cli.js'
}
if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) {
  throw "Toggle CLI not found at: $CliPath"
}

$selectedProfiles = @()
if ($PSBoundParameters.ContainsKey('Profiles') -and $Profiles) {
  $selectedProfiles = Normalize-Profiles -Values $Profiles
} elseif ($env:AGENT_TOGGLE_PROFILES) {
  $selectedProfiles = Normalize-Profiles -Values @($env:AGENT_TOGGLE_PROFILES)
}
if ($selectedProfiles.Count -eq 0) {
  $selectedProfiles = @('ci-orchestrated')
}

$cliArgs = @('--format','values')
foreach ($profile in $selectedProfiles) {
  $cliArgs += '--profile'
  $cliArgs += $profile
}

$cliResult = & node $CliPath @cliArgs 2>&1
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
  $joined = if ($cliResult) { ($cliResult | Out-String).Trim() } else { '' }
  throw ("Toggle CLI failed with exit code {0}: {1}" -f $exitCode, $joined)
}

$manifest = $null
try {
  $manifest = $cliResult | ConvertFrom-Json -ErrorAction Stop
} catch {
  $preview = ($cliResult | Out-String).Trim()
  throw "Failed to parse toggle manifest JSON: $($_.Exception.Message)`n$preview"
}

if (-not $manifest) {
  throw 'Toggle CLI returned an empty manifest.'
}

$expectedDigest = [string]$manifest.manifestDigest
$expectedProfiles = @()
if ($manifest.PSObject.Properties['profiles']) {
  $expectedProfiles = @($manifest.profiles | ForEach-Object { "$_" })
}

$envDigest = [Environment]::GetEnvironmentVariable('AGENT_TOGGLE_MANIFEST_DIGEST')
$envProfilesRaw = [Environment]::GetEnvironmentVariable('AGENT_TOGGLE_PROFILES')
$envProfiles = if ($envProfilesRaw) {
  Normalize-Profiles -Values @($envProfilesRaw)
} else { @() }

$differences = @()
if ($expectedDigest -and $envDigest -and ($expectedDigest -ne $envDigest)) {
  $differences += [pscustomobject]@{
    Name     = 'AGENT_TOGGLE_MANIFEST_DIGEST'
    Expected = $expectedDigest
    Actual   = $envDigest
  }
} elseif (-not $envDigest) {
  $differences += [pscustomobject]@{
    Name     = 'AGENT_TOGGLE_MANIFEST_DIGEST'
    Expected = $expectedDigest
    Actual   = '(not set)'
  }
}

if ($expectedProfiles.Count -gt 0) {
  if ($envProfiles.Count -eq 0) {
    $differences += [pscustomobject]@{
      Name     = 'AGENT_TOGGLE_PROFILES'
      Expected = ($expectedProfiles -join ',')
      Actual   = '(not set)'
    }
  } elseif (($expectedProfiles -join ',') -ne ($envProfiles -join ',')) {
    $differences += [pscustomobject]@{
      Name     = 'AGENT_TOGGLE_PROFILES'
      Expected = ($expectedProfiles -join ',')
      Actual   = ($envProfiles -join ',')
    }
  }
}

$toggleMismatches = @()
if ($manifest.PSObject.Properties['toggles']) {
  foreach ($prop in $manifest.toggles.PSObject.Properties) {
    $expectedValue = if ($null -ne $prop.Value) { [string]$prop.Value } else { '' }
    $actualValue = [Environment]::GetEnvironmentVariable($prop.Name)
    if ($null -eq $actualValue) { $actualValue = '' } else { $actualValue = [string]$actualValue }
    if ($expectedValue -ne $actualValue) {
      $toggleMismatches += [pscustomobject]@{
        Name     = $prop.Name
        Expected = $expectedValue
        Actual   = $actualValue
      }
    }
  }
}

if ($toggleMismatches.Count -gt 0) {
  $differences += $toggleMismatches
}

if ($differences.Count -eq 0) {
  if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @(
      '### Agent Toggle Manifest',
      '',
      "- Digest: $expectedDigest",
      "- Profiles: $($expectedProfiles -join ',')"
    )
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }
  return
}

if ($AllowEnvironmentOverrides) {
  foreach ($diff in $differences) {
    Write-Warning ("Toggle override detected ({0}): expected '{1}', actual '{2}'." -f $diff.Name, $diff.Expected, $diff.Actual)
  }
  return
}

$messages = @('Agent toggle determinism assertion failed due to environment overrides:')
foreach ($diff in $differences) {
  $messages += ("- {0}: expected '{1}', actual '{2}'" -f $diff.Name, $diff.Expected, $diff.Actual)
}
throw ($messages -join "`n")
