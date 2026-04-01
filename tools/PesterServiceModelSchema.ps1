Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SchemaVersionMajor {
  param([AllowNull()][AllowEmptyString()][string]$SchemaVersion)

  if ([string]::IsNullOrWhiteSpace($SchemaVersion)) {
    return $null
  }

  if ($SchemaVersion -match '^(?<major>\d+)(?:\.\d+){0,2}$') {
    return [int]$matches.major
  }

  return $null
}

function Read-PesterServiceModelJsonDocument {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)][string]$ContractName
  )

  if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
    return [pscustomobject]@{
      contractName       = $ContractName
      path               = $PathValue
      present            = $false
      valid              = $false
      classification     = 'missing-file'
      reason             = "$ContractName-missing"
      document           = $null
      actualSchema       = $null
      actualSchemaVersion = $null
      parseError         = $null
    }
  }

  try {
    $document = Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json -ErrorAction Stop
    return [pscustomobject]@{
      contractName       = $ContractName
      path               = $PathValue
      present            = $true
      valid              = $true
      classification     = 'ok'
      reason             = "$ContractName-ok"
      document           = $document
      actualSchema       = if ($document.PSObject.Properties.Name -contains 'schema') { [string]$document.schema } else { $null }
      actualSchemaVersion = if ($document.PSObject.Properties.Name -contains 'schemaVersion') { [string]$document.schemaVersion } else { $null }
      parseError         = $null
    }
  } catch {
    return [pscustomobject]@{
      contractName       = $ContractName
      path               = $PathValue
      present            = $true
      valid              = $false
      classification     = 'unsupported-schema'
      reason             = "$ContractName-invalid-json"
      document           = $null
      actualSchema       = $null
      actualSchemaVersion = $null
      parseError         = [string]$_.Exception.Message
    }
  }
}

function Test-PesterServiceModelSchemaContract {
  param(
    [Parameter(Mandatory = $true)]$DocumentState,
    [string]$ExpectedSchema,
    [string]$SchemaVersionProperty = 'schemaVersion',
    [int]$ExpectedSchemaVersionMajor = 0,
    [switch]$RequireSchemaVersion
  )

  if (-not $DocumentState.present) {
    return $DocumentState
  }

  if (-not $DocumentState.valid) {
    return $DocumentState
  }

  $document = $DocumentState.document
  $actualSchema = if ($document.PSObject.Properties.Name -contains 'schema') { [string]$document.schema } else { $null }
  $actualSchemaVersion = if ($document.PSObject.Properties.Name -contains $SchemaVersionProperty) { [string]$document.$SchemaVersionProperty } else { $null }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedSchema) -and $actualSchema -ne $ExpectedSchema) {
    return [pscustomobject]@{
      contractName       = $DocumentState.contractName
      path               = $DocumentState.path
      present            = $true
      valid              = $false
      classification     = 'unsupported-schema'
      reason             = "$($DocumentState.contractName)-unsupported-schema"
      document           = $document
      actualSchema       = $actualSchema
      actualSchemaVersion = $actualSchemaVersion
      parseError         = $null
    }
  }

  if ($RequireSchemaVersion -or ($document.PSObject.Properties.Name -contains $SchemaVersionProperty)) {
    if ([string]::IsNullOrWhiteSpace($actualSchemaVersion)) {
      return [pscustomobject]@{
        contractName       = $DocumentState.contractName
        path               = $DocumentState.path
        present            = $true
        valid              = $false
        classification     = 'unsupported-schema'
        reason             = "$($DocumentState.contractName)-schema-version-missing"
        document           = $document
        actualSchema       = $actualSchema
        actualSchemaVersion = $actualSchemaVersion
        parseError         = $null
      }
    }

    if ($ExpectedSchemaVersionMajor -gt 0) {
      $actualMajor = Get-SchemaVersionMajor -SchemaVersion $actualSchemaVersion
      if ($null -eq $actualMajor) {
        return [pscustomobject]@{
          contractName       = $DocumentState.contractName
          path               = $DocumentState.path
          present            = $true
          valid              = $false
          classification     = 'unsupported-schema'
          reason             = "$($DocumentState.contractName)-invalid-schema-version"
          document           = $document
          actualSchema       = $actualSchema
          actualSchemaVersion = $actualSchemaVersion
          parseError         = $null
        }
      }

      if ($actualMajor -ne $ExpectedSchemaVersionMajor) {
        return [pscustomobject]@{
          contractName       = $DocumentState.contractName
          path               = $DocumentState.path
          present            = $true
          valid              = $false
          classification     = 'unsupported-schema'
          reason             = "$($DocumentState.contractName)-unsupported-schema-version"
          document           = $document
          actualSchema       = $actualSchema
          actualSchemaVersion = $actualSchemaVersion
          parseError         = $null
        }
      }
    }
  }

  return [pscustomobject]@{
    contractName       = $DocumentState.contractName
    path               = $DocumentState.path
    present            = $true
    valid              = $true
    classification     = 'ok'
    reason             = "$($DocumentState.contractName)-ok"
    document           = $document
    actualSchema       = $actualSchema
    actualSchemaVersion = $actualSchemaVersion
    parseError         = $null
  }
}
