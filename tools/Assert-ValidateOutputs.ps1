[CmdletBinding()]
param(
  [string]$ResultsRoot = 'tests/results',
  [switch]$RequireDerivedEnv = $true,
  [switch]$RequireSessionIndex = $true,
  [switch]$RequireFixtureSummary = $true,
  [switch]$RequireDeltaJson = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$issues = @()

function Add-Issue {
  param([string]$Message)
  $script:issues += "- $Message"
}

function Assert-PathExists {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Description,
    [switch]$ExpectJson,
    [string]$ExpectedSchema
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-Issue "$Description missing ($Path)"
    return $null
  }

  $item = Get-Item -LiteralPath $Path
  if ($item.Length -le 0) {
    Add-Issue "$Description empty ($Path)"
    return $null
  }

  Write-Host ("Found: {0}" -f $Description)

  if ($ExpectJson) {
    try {
      $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
      Add-Issue "$Description invalid JSON ($Path): $($_.Exception.Message)"
      return $null
    }

    if ($ExpectedSchema) {
      $actual = [string]$json.schema
      if (-not $actual) {
        Add-Issue "$Description JSON missing schema property (expected '$ExpectedSchema') ($Path)"
      } elseif ($actual -ne $ExpectedSchema) {
        Add-Issue ("{0} JSON schema '{1}' does not match expected '{2}' ({3})" -f $Description, $actual, $ExpectedSchema, $Path)
      }
    }

    return $json
  }

  return $item
}

$fixtureValidation = Assert-PathExists -Path 'fixture-validation.json' -Description 'Fixture validation JSON' -ExpectJson

if ($RequireDeltaJson -and (Test-Path -LiteralPath 'fixture-validation-delta.json' -PathType Leaf)) {
  Assert-PathExists -Path 'fixture-validation-delta.json' -Description 'Fixture validation delta JSON' -ExpectJson
}

if ($RequireFixtureSummary) {
  $summaryItem = Assert-PathExists -Path 'fixture-summary.md' -Description 'Fixture summary markdown'
  if ($summaryItem) {
    $content = Get-Content -LiteralPath $summaryItem.FullName -Raw
    if (-not $content.Trim()) {
      Add-Issue "Fixture summary markdown contains no content ($($summaryItem.FullName))"
    }
  }
}

if ($RequireDerivedEnv) {
  $derivedPath = Join-Path $ResultsRoot '_agent/derived-env.json'
  $derived = Assert-PathExists -Path $derivedPath -Description 'Derived environment snapshot JSON' -ExpectJson
  if ($derived) {
    $propCount = @($derived.PSObject.Properties.Name).Count
    if ($propCount -eq 0) {
      Add-Issue "Derived environment JSON has no top-level properties ($derivedPath)"
    }
  }
}

if ($RequireSessionIndex) {
  $sessionPath = Join-Path $ResultsRoot '_validate-sessionindex/session-index.json'
  $session = Assert-PathExists -Path $sessionPath -Description 'Session index JSON' -ExpectJson
  if ($session) {
    $schemaValue = [string]$session.schema
    if (-not $schemaValue) {
      Add-Issue "Session index JSON missing schema property ($sessionPath)"
    }
  }
}

if ($fixtureValidation) {
  $schemaValue = $null
  if ($fixtureValidation.PSObject.Properties['schema']) {
    $schemaValue = [string]$fixtureValidation.schema
  }
  switch ($schemaValue) {
    'fixture-manifest-v1' {
      $items = $fixtureValidation.items
      if (-not $items -or @($items).Count -eq 0) {
        Add-Issue "Fixture validation JSON contains no items (fixture-validation.json)"
      }
    }
    'fixture-validation-summary-v1' {
      if (-not $fixtureValidation.ok) {
        Add-Issue "Fixture validation summary reported failure (fixture-validation.json)"
      }
      if (-not $fixtureValidation.summaryCounts) {
        Add-Issue "Fixture validation summary missing counts (fixture-validation.json)"
      }
      $checkedCount = 0
      if ($fixtureValidation.PSObject.Properties['checked']) {
        $checkedCount = @($fixtureValidation.checked).Count
      }
      if ($fixtureValidation.fixtureCount -ne $checkedCount) {
        Add-Issue "Fixture validation summary count mismatch (fixtureCount=$($fixtureValidation.fixtureCount) checked=$checkedCount)"
      }
    }
    { $_ -eq $null -and $fixtureValidation.PSObject.Properties['ok'] } {
      if (-not $fixtureValidation.ok) {
        Add-Issue "Fixture validation summary reported failure (fixture-validation.json)"
      }
    }
    { $_ -eq $null } {
      Add-Issue "Fixture validation JSON missing expected structure (fixture-validation.json)"
    }
    default {
      Add-Issue "Fixture validation JSON reported unexpected schema '$schemaValue' (fixture-validation.json)"
    }
  }
}

if ($issues.Count -gt 0) {
  $msg = (@('Validate outputs check failed:') + $issues) -join [Environment]::NewLine
  Write-Error $msg
  exit 2
}

Write-Host 'All expected Validate artifacts are present and sane.'
