Set-StrictMode -Version Latest

function Get-PesterFailurePropertyValue {
  param(
    $InputObject,
    [string[]]$PropertyNames
  )

  if (-not $InputObject) { return $null }

  foreach ($name in $PropertyNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }

    if ($InputObject -is [hashtable]) {
      if ($InputObject.ContainsKey($name)) { return $InputObject[$name] }
      continue
    }

    $prop = $InputObject.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
  }

  return $null
}

function Set-PesterFailureObjectProperty {
  param(
    [Parameter(Mandatory = $true)]$InputObject,
    [Parameter(Mandatory = $true)][string]$Name,
    $Value
  )

  $property = $InputObject.PSObject.Properties[$Name]
  if ($property) {
    $property.Value = $Value
  } else {
    Add-Member -InputObject $InputObject -Name $Name -MemberType NoteProperty -Value $Value
  }
}

function Get-PesterFailureEntries {
  param($FailurePayload)

  if (-not $FailurePayload) { return @() }

  $resultsProp = Get-PesterFailurePropertyValue -InputObject $FailurePayload -PropertyNames @('results')
  if ($null -ne $resultsProp) {
    return @($resultsProp)
  }

  if ((Get-PesterFailurePropertyValue -InputObject $FailurePayload -PropertyNames @('name','Name')) -or
      (Get-PesterFailurePropertyValue -InputObject $FailurePayload -PropertyNames @('result','Result'))) {
    return @($FailurePayload)
  }

  if ($FailurePayload -is [System.Array] -or ($FailurePayload -is [System.Collections.IEnumerable] -and $FailurePayload -isnot [string])) {
    return @($FailurePayload)
  }

  return @()
}

function ConvertTo-PesterFailureEntry {
  param($Entry)

  if (-not $Entry) { return $null }

  $nameValue = [string](Get-PesterFailurePropertyValue -InputObject $Entry -PropertyNames @('name','Name'))
  $resultValue = [string](Get-PesterFailurePropertyValue -InputObject $Entry -PropertyNames @('result','Result'))
  if ([string]::IsNullOrWhiteSpace($resultValue)) {
    $resultValue = 'Failed'
  }

  $durationSeconds = Get-PesterFailurePropertyValue -InputObject $Entry -PropertyNames @('duration','Duration')
  $durationMilliseconds = Get-PesterFailurePropertyValue -InputObject $Entry -PropertyNames @('duration_ms','DurationMs','durationMilliseconds')
  if ($null -eq $durationSeconds -and $null -ne $durationMilliseconds -and "$durationMilliseconds" -match '^-?\d+(\.\d+)?$') {
    $durationSeconds = [math]::Round(([double]$durationMilliseconds / 1000), 6)
  }
  if ($null -eq $durationMilliseconds -and $null -ne $durationSeconds -and "$durationSeconds" -match '^-?\d+(\.\d+)?$') {
    $durationMilliseconds = [math]::Round(([double]$durationSeconds * 1000), 2)
  }

  $pathValue = [string](Get-PesterFailurePropertyValue -InputObject $Entry -PropertyNames @('path','Path'))
  $fileValue = [string](Get-PesterFailurePropertyValue -InputObject $Entry -PropertyNames @('file','File'))
  if ([string]::IsNullOrWhiteSpace($fileValue) -and -not [string]::IsNullOrWhiteSpace($pathValue)) {
    $fileValue = $pathValue
  }
  if ([string]::IsNullOrWhiteSpace($pathValue) -and -not [string]::IsNullOrWhiteSpace($fileValue)) {
    $pathValue = $fileValue
  }

  $lineValue = Get-PesterFailurePropertyValue -InputObject $Entry -PropertyNames @('line','Line')
  $messageValue = [string](Get-PesterFailurePropertyValue -InputObject $Entry -PropertyNames @('message','Message'))
  if ([string]::IsNullOrWhiteSpace($nameValue)) {
    if (-not [string]::IsNullOrWhiteSpace($pathValue)) {
      $nameValue = $pathValue
    } elseif (-not [string]::IsNullOrWhiteSpace($messageValue)) {
      $nameValue = $messageValue
    } else {
      $nameValue = 'Failure'
    }
  }

  return [pscustomobject]@{
    name        = $nameValue
    result      = $resultValue
    duration    = $durationSeconds
    duration_ms = $durationMilliseconds
    path        = $pathValue
    file        = $fileValue
    line        = $lineValue
    message     = $messageValue
  }
}

function Get-PesterFailureSummaryCounts {
  param($Summary)

  $total = Get-PesterFailurePropertyValue -InputObject $Summary -PropertyNames @('total','Total')
  $failed = Get-PesterFailurePropertyValue -InputObject $Summary -PropertyNames @('failed','Failed')
  $errors = Get-PesterFailurePropertyValue -InputObject $Summary -PropertyNames @('errors','Errors')
  $skipped = Get-PesterFailurePropertyValue -InputObject $Summary -PropertyNames @('skipped','Skipped')

  return [pscustomobject]@{
    total   = if ($null -ne $total -and "$total" -match '^-?\d+$') { [int]$total } else { 0 }
    failed  = if ($null -ne $failed -and "$failed" -match '^-?\d+$') { [int]$failed } else { 0 }
    errors  = if ($null -ne $errors -and "$errors" -match '^-?\d+$') { [int]$errors } else { 0 }
    skipped = if ($null -ne $skipped -and "$skipped" -match '^-?\d+$') { [int]$skipped } else { 0 }
  }
}

function Read-PesterFailurePayloadFile {
  param([Parameter(Mandatory = $true)][string]$PathValue)

  if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
    return [pscustomobject]@{
      present     = $false
      parseStatus = 'missing'
      payload     = $null
      parseError  = $null
    }
  }

  try {
    $payload = Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json -ErrorAction Stop
    return [pscustomobject]@{
      present     = $true
      parseStatus = 'parsed'
      payload     = $payload
      parseError  = $null
    }
  } catch {
    return [pscustomobject]@{
      present     = $true
      parseStatus = 'unparseable'
      payload     = $null
      parseError  = [string]$_.Exception.Message
    }
  }
}

function Resolve-PesterFailureUnavailableReason {
  param(
    $Summary,
    [string]$ParseStatus = 'parsed'
  )

  $summaryReason = [string](Get-PesterFailurePropertyValue -InputObject $Summary -PropertyNames @('failureDetailsReason'))
  if (-not [string]::IsNullOrWhiteSpace($summaryReason)) {
    return $summaryReason
  }

  $resultsXmlStatus = [string](Get-PesterFailurePropertyValue -InputObject $Summary -PropertyNames @('resultsXmlStatus'))
  $executionPostprocessStatus = [string](Get-PesterFailurePropertyValue -InputObject $Summary -PropertyNames @('executionPostprocessStatus'))
  if ($executionPostprocessStatus -eq 'results-xml-truncated' -or $resultsXmlStatus -like 'truncated*') {
    return 'results-xml-truncated'
  }
  if ($executionPostprocessStatus -eq 'invalid-results-xml' -or $resultsXmlStatus -like 'invalid*') {
    return 'invalid-results-xml'
  }
  if ($executionPostprocessStatus -eq 'missing-results-xml' -or $resultsXmlStatus -eq 'missing') {
    return 'missing-results-xml'
  }
  if ($ParseStatus -eq 'unparseable') {
    return 'failure-payload-unparseable'
  }

  return 'failure-details-unavailable'
}

function Get-PesterFailureDetailState {
  param(
    $FailurePayload,
    $Summary
  )

  $counts = Get-PesterFailureSummaryCounts -Summary $Summary
  $entries = @(Get-PesterFailureEntries -FailurePayload $FailurePayload | ForEach-Object { ConvertTo-PesterFailureEntry -Entry $_ } | Where-Object { $null -ne $_ })
  $detailStatus = [string](Get-PesterFailurePropertyValue -InputObject $FailurePayload -PropertyNames @('detailStatus'))
  $unavailableReason = [string](Get-PesterFailurePropertyValue -InputObject $FailurePayload -PropertyNames @('unavailableReason'))

  if ([string]::IsNullOrWhiteSpace($detailStatus)) {
    if ($entries.Count -gt 0) {
      $detailStatus = 'available'
    } elseif (($counts.failed + $counts.errors) -gt 0) {
      $detailStatus = 'unavailable'
    } else {
      $detailStatus = 'not-applicable'
    }
  }

  if ($detailStatus -eq 'unavailable' -and [string]::IsNullOrWhiteSpace($unavailableReason)) {
    $unavailableReason = Resolve-PesterFailureUnavailableReason -Summary $Summary
  }

  return [pscustomobject]@{
    detailStatus      = $detailStatus
    unavailableReason = $unavailableReason
    detailCount       = $entries.Count
    entries           = @($entries)
    summaryCounts     = $counts
  }
}

function ConvertTo-PesterFailurePayload {
  param(
    $FailurePayload,
    $Summary,
    [string]$SchemaVersion = '1.1.0',
    [string]$ParseStatus = 'parsed',
    [string]$ParseError
  )

  $state = Get-PesterFailureDetailState -FailurePayload $FailurePayload -Summary $Summary
  $payload = [ordered]@{
    schema         = 'pester-failures@v2'
    schemaVersion  = $SchemaVersion
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    detailStatus   = $state.detailStatus
    detailCount    = [int]$state.detailCount
    summary        = [ordered]@{
      total   = [int]$state.summaryCounts.total
      failed  = [int]$state.summaryCounts.failed
      errors  = [int]$state.summaryCounts.errors
      skipped = [int]$state.summaryCounts.skipped
    }
    results        = @($state.entries)
  }

  if ($state.detailStatus -eq 'unavailable' -and -not [string]::IsNullOrWhiteSpace($state.unavailableReason)) {
    $payload['unavailableReason'] = $state.unavailableReason
  }
  if ($ParseStatus -eq 'unparseable' -and -not [string]::IsNullOrWhiteSpace($ParseError)) {
    $payload['sourceParseStatus'] = $ParseStatus
    $payload['sourceParseError'] = $ParseError
  }

  return [pscustomobject]$payload
}

function Update-PesterSummaryWithFailurePayload {
  param(
    [Parameter(Mandatory = $true)]$SummaryObject,
    [Parameter(Mandatory = $true)]$FailurePayload
  )

  $state = Get-PesterFailureDetailState -FailurePayload $FailurePayload -Summary $SummaryObject
  Set-PesterFailureObjectProperty -InputObject $SummaryObject -Name 'failureDetailsStatus' -Value $state.detailStatus
  Set-PesterFailureObjectProperty -InputObject $SummaryObject -Name 'failureDetailsCount' -Value ([int]$state.detailCount)
  if ($state.detailStatus -eq 'unavailable' -and -not [string]::IsNullOrWhiteSpace($state.unavailableReason)) {
    Set-PesterFailureObjectProperty -InputObject $SummaryObject -Name 'failureDetailsReason' -Value $state.unavailableReason
  } elseif ($SummaryObject.PSObject.Properties['failureDetailsReason']) {
    $SummaryObject.PSObject.Properties.Remove('failureDetailsReason')
  }
  if ($FailurePayload.PSObject.Properties['schemaVersion']) {
    Set-PesterFailureObjectProperty -InputObject $SummaryObject -Name 'failureDetailsSchemaVersion' -Value ([string]$FailurePayload.schemaVersion)
  }
}

function Sync-PesterFailurePayload {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)]$SummaryObject,
    [string]$SchemaVersion = '1.1.0'
  )

  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
  }

  $pathValue = Join-Path $Directory 'pester-failures.json'
  $existing = Read-PesterFailurePayloadFile -PathValue $pathValue
  $payload = ConvertTo-PesterFailurePayload -FailurePayload $existing.payload -Summary $SummaryObject -SchemaVersion $SchemaVersion -ParseStatus $existing.parseStatus -ParseError $existing.parseError
  $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pathValue -Encoding UTF8
  Update-PesterSummaryWithFailurePayload -SummaryObject $SummaryObject -FailurePayload $payload
  return $payload
}

function Write-PesterFailurePayload {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)]$SummaryObject,
    [AllowNull()]
    [AllowEmptyCollection()]
    [object]$FailureEntries,
    [string]$SchemaVersion = '1.1.0'
  )

  $directory = Split-Path -Parent $PathValue
  if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  $payload = ConvertTo-PesterFailurePayload -FailurePayload $FailureEntries -Summary $SummaryObject -SchemaVersion $SchemaVersion
  $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PathValue -Encoding UTF8
  return $payload
}
