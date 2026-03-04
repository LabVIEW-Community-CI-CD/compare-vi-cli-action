[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RootPath,
  [switch]$WriteStepSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FirstValue {
  param(
    [Parameter(Mandatory = $true)]
    [object]$InputObject,
    [Parameter(Mandatory = $true)]
    [string[]]$PropertyNames,
    [AllowNull()][object]$DefaultValue = $null
  )

  foreach ($name in $PropertyNames) {
    if ($InputObject.PSObject.Properties.Name -contains $name) {
      $value = $InputObject.$name
      if ($null -ne $value -and [string]$value -ne '') {
        return $value
      }
    }
  }

  return $DefaultValue
}

if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
  throw "RootPath not found: $RootPath"
}

$summaryFiles = @(Get-ChildItem -Path $RootPath -Filter 'scenario-summary.json' -Recurse -File -ErrorAction SilentlyContinue)
$normalizedCount = 0
$legacyDetectedCount = 0
$updatedFiles = [System.Collections.Generic.List[string]]::new()

foreach ($file in $summaryFiles) {
  $payload = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 20
  $legacyDetected = $false

  $fieldMap = @(
    @{ target = 'os'; aliases = @('os', 'osLabel', 'platform') },
    @{ target = 'scenario'; aliases = @('scenario', 'scenarioId') },
    @{ target = 'flags'; aliases = @('flags', 'compareFlags') },
    @{ target = 'status'; aliases = @('status', 'captureStatus') },
    @{ target = 'gateOutcome'; aliases = @('gateOutcome', 'gate', 'policyOutcome') },
    @{ target = 'resultClass'; aliases = @('resultClass', 'result', 'classification') },
    @{ target = 'compareExit'; aliases = @('compareExit', 'compareExitCode', 'exitCode') },
    @{ target = 'reportExists'; aliases = @('reportExists', 'hasReport') }
  )

  foreach ($item in $fieldMap) {
    $target = [string]$item.target
    $aliases = @($item.aliases | ForEach-Object { [string]$_ })
    $resolved = Resolve-FirstValue -InputObject $payload -PropertyNames $aliases
    if ($null -eq $resolved) {
      continue
    }

    if ($payload.PSObject.Properties.Name -notcontains $target) {
      $payload | Add-Member -MemberType NoteProperty -Name $target -Value $resolved
      $normalizedCount++
      $legacyDetected = $true
      continue
    }

    $currentValue = $payload.$target
    if ($null -eq $currentValue -or [string]$currentValue -eq '') {
      $payload.$target = $resolved
      $normalizedCount++
      $legacyDetected = $true
    }
  }

  if ($legacyDetected) {
    if ($payload.PSObject.Properties.Name -notcontains 'schema') {
      $payload | Add-Member -MemberType NoteProperty -Name schema -Value 'release-vi-history-review/scenario@v1'
    }
    if ($payload.PSObject.Properties.Name -notcontains 'generatedAt') {
      $payload | Add-Member -MemberType NoteProperty -Name generatedAt -Value ((Get-Date).ToUniversalTime().ToString('o'))
    }

    $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file.FullName -Encoding utf8
    $legacyDetectedCount++
    $updatedFiles.Add($file.FullName) | Out-Null
  }
}

$result = [ordered]@{
  schema = 'release-vi-history/normalization@v1'
  rootPath = $RootPath
  scannedCount = $summaryFiles.Count
  updatedFileCount = $legacyDetectedCount
  normalizedFieldCount = $normalizedCount
  updatedFiles = @($updatedFiles)
}

if ($WriteStepSummary -and $env:GITHUB_STEP_SUMMARY) {
  @(
    '### Release VI History Summary Normalization',
    '',
    "- Scanned summaries: $($summaryFiles.Count)",
    "- Updated files: $legacyDetectedCount",
    "- Normalized fields: $normalizedCount"
  ) -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

$result | ConvertTo-Json -Depth 20 | Write-Output