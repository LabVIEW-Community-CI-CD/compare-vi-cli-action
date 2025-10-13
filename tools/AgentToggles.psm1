#Requires -Version 7.0
Set-StrictMode -Version Latest

$script:toolsRoot = Split-Path -Parent $PSCommandPath
$script:repoRoot = Split-Path -Parent $script:toolsRoot
$script:cliPath = Join-Path $script:repoRoot 'dist' 'src' 'config' 'toggles-cli.js'
$script:valuesCache = @{}
$script:contractCache = $null
$script:jsonDepth = 16

function Get-NodeCommandPath {
  $node = Get-Command node -ErrorAction Stop
  return $node.Source
}

function Assert-ToggleCli {
  if (-not (Test-Path -LiteralPath $script:cliPath -PathType Leaf)) {
    throw "Toggle CLI not found at $script:cliPath. Run 'npm run build' to compile TypeScript assets."
  }
}

function Invoke-ToggleCli {
  param(
    [string[]]$Arguments
  )
  Assert-ToggleCli
  $nodePath = Get-NodeCommandPath
  $result = & $nodePath $script:cliPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Toggle CLI exited with code $LASTEXITCODE."
  }
  return $result
}

function ConvertTo-AgentTogglePrimitive {
  param(
    $Value,
    [ValidateSet('string','number','boolean')]
    [string]$Type
  )

  switch ($Type) {
    'boolean' {
      if ($Value -is [bool]) { return $Value }
      if ($Value -is [string]) {
        $normalized = $Value.Trim().ToLowerInvariant()
        switch ($normalized) {
          '1' { return $true }
          '0' { return $false }
          'true' { return $true }
          'false' { return $false }
          'yes' { return $true }
          'no' { return $false }
          'on' { return $true }
          'off' { return $false }
        }
      }
      if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [float]) {
        return [math]::Abs([double]$Value) -gt 0
      }
      throw "Unable to coerce value '$Value' to boolean."
    }
    'number' {
      if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) { return [double]$Value }
      if ($Value -is [int] -or $Value -is [long]) { return [double]$Value }
      if ($Value -is [string]) {
        $parsed = $null
        if ([double]::TryParse($Value, [ref]$parsed)) {
          return [double]$parsed
        }
      }
      throw "Unable to coerce value '$Value' to number."
    }
    'string' {
      return [string]$Value
    }
    default {
      return $Value
    }
  }
}

function Apply-EnvironmentOverrides {
  param(
    [pscustomobject]$Payload
  )
  if (-not $Payload -or -not $Payload.values) {
    return
  }

  foreach ($property in $Payload.values.PSObject.Properties) {
    $key = $property.Name
    $entry = $property.Value
    $envValue = [System.Environment]::GetEnvironmentVariable($key)
    if ($null -ne $envValue -and $envValue -ne '') {
      try {
        $coerced = ConvertTo-AgentTogglePrimitive -Value $envValue -Type $entry.valueType
        $entry.value = $coerced
        $entry.source = 'environment'
        if ($entry.PSObject.Properties.Name -contains 'profile') {
          $entry.profile = $null
        }
        if ($entry.PSObject.Properties.Name -contains 'variant') {
          $entry.variant = $null
        }
      } catch {
        $message = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
        Write-Warning ("Failed to coerce environment override for {0}: {1}" -f $key, $message)
      }
    }
  }
}

function Get-AgentToggleContract {
  if ($script:contractCache) {
    return $script:contractCache
  }

  $output = Invoke-ToggleCli -Arguments @('--format','json','--pretty')
  $manifest = $output | ConvertFrom-Json -Depth $script:jsonDepth

  if (-not $manifest) {
    throw 'Toggle CLI returned empty manifest.'
  }
  if (-not ($manifest.PSObject.Properties.Name -contains 'manifestDigest')) {
    throw 'Toggle manifest payload missing manifestDigest.'
  }

  $contract = [pscustomobject]@{
    manifest        = $manifest
    manifestDigest  = $manifest.manifestDigest
    schema          = $manifest.schema
    schemaVersion   = $manifest.schemaVersion
    generatedAtUtc  = $manifest.generatedAtUtc
  }

  $script:contractCache = $contract
  return $contract
}

function Get-AgentToggleManifest {
  $contract = Get-AgentToggleContract
  return $contract.manifest
}

function Get-AgentToggleValues {
  param(
    [string[]]$Profiles,
    [string]$Describe,
    [string]$It,
    [string[]]$Tags
  )

  $profilesKey = if ($Profiles) { ($Profiles | Sort-Object) -join ',' } else { '' }
  $tagsKey = if ($Tags) { ($Tags | Sort-Object) -join ',' } else { '' }
  $cacheKey = "{0}|{1}|{2}|{3}" -f $profilesKey, ($Describe ?? ''), ($It ?? ''), $tagsKey
  $output = $null
  if ($script:valuesCache.ContainsKey($cacheKey)) {
    $output = $script:valuesCache[$cacheKey]
  } else {
    $arguments = @('--format','values')
    if ($Profiles) {
      foreach ($profile in $Profiles) {
        $arguments += @('--profile', $profile)
      }
    }
    if ($Describe) {
      $arguments += @('--describe', $Describe)
    }
    if ($It) {
      $arguments += @('--it', $It)
    }
    if ($Tags) {
      foreach ($tag in $Tags) {
        $arguments += @('--tag', $tag)
      }
    }

    $output = Invoke-ToggleCli -Arguments $arguments
    $script:valuesCache[$cacheKey] = $output
  }

  $payload = $output | ConvertFrom-Json -Depth $script:jsonDepth
  $contract = Get-AgentToggleContract

  if (-not $payload) {
    throw 'Toggle values payload missing.'
  }
  if (-not ($payload.PSObject.Properties.Name -contains 'manifestDigest')) {
    throw 'Toggle values payload missing manifestDigest.'
  }
  if ($payload.manifestDigest -ne $contract.manifestDigest) {
    throw "Toggle manifest digest mismatch (contract $($contract.manifestDigest) vs payload $($payload.manifestDigest))."
  }

  Apply-EnvironmentOverrides -Payload $payload
  return $payload
}

function Get-AgentToggleValue {
  param(
    [Parameter(Mandatory)]
    [string]$Key,
    [string[]]$Profiles,
    [string]$Describe,
    [string]$It,
    [string[]]$Tags,
    [switch]$AsBoolean,
    [switch]$AsNumber,
    [switch]$IncludeMetadata
  )

  $payload = Get-AgentToggleValues -Profiles $Profiles -Describe $Describe -It $It -Tags $Tags
  if (-not $payload.values.PSObject.Properties.Name -contains $Key) {
    throw "Toggle '$Key' not present in manifest."
  }
  $entry = $payload.values.$Key
  if ($IncludeMetadata) {
    return $entry
  }

  $value = $entry.value
  if ($AsBoolean) {
    return ConvertTo-AgentTogglePrimitive -Value $value -Type 'boolean'
  }
  if ($AsNumber) {
    return ConvertTo-AgentTogglePrimitive -Value $value -Type 'number'
  }
  if ($entry.valueType -eq 'string') {
    return [string]$value
  }
  return $value
}

function Assert-AgentToggleDeterminism {
  param(
    [string[]]$Profiles,
    [string]$Describe,
    [string]$It,
    [string[]]$Tags,
    [switch]$AllowEnvironmentOverrides
  )

  $payload = Get-AgentToggleValues -Profiles $Profiles -Describe $Describe -It $It -Tags $Tags
  $overrides = @(
    $payload.values.PSObject.Properties | Where-Object { $_.Value.source -eq 'environment' }
  )

  if ($overrides.Count -gt 0 -and -not $AllowEnvironmentOverrides) {
    $names = $overrides | ForEach-Object { $_.Name }
    $list = [string]::Join(', ', $names)
    throw "Environment overrides detected for toggles: $list"
  }

  return $payload
}

Export-ModuleMember -Function Get-AgentToggleContract, Get-AgentToggleManifest, Get-AgentToggleValues, Get-AgentToggleValue, Assert-AgentToggleDeterminism
