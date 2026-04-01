Set-StrictMode -Version Latest

function ConvertTo-PesterPathHygienePortablePath {
  param([string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }
  return ($PathValue -replace '\\', '/')
}

function Get-PesterPathHygieneRisks {
  param([string]$PathValue)

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return @()
  }

  $normalized = ConvertTo-PesterPathHygienePortablePath -PathValue $PathValue
  $rules = @(
    [ordered]@{
      id = 'onedrive-managed-root'
      pattern = '(?i)(^|[\\/])OneDrive(?:[\\/]|$|[\s-])'
      message = 'Path appears to live under a OneDrive-managed root.'
    }
    [ordered]@{
      id = 'dropbox-managed-root'
      pattern = '(?i)(^|[\\/])Dropbox([\\/]|$)'
      message = 'Path appears to live under a Dropbox-managed root.'
    }
    [ordered]@{
      id = 'google-drive-managed-root'
      pattern = '(?i)(^|[\\/])Google Drive([\\/]|$)'
      message = 'Path appears to live under a Google Drive-managed root.'
    }
    [ordered]@{
      id = 'icloud-drive-managed-root'
      pattern = '(?i)(^|[\\/])iCloud Drive([\\/]|$)'
      message = 'Path appears to live under an iCloud Drive-managed root.'
    }
  )

  $risks = New-Object System.Collections.Generic.List[object]
  foreach ($rule in $rules) {
    if ($normalized -match $rule.pattern) {
      $risks.Add([pscustomobject]@{
        id = [string]$rule.id
        path = $normalized
        message = [string]$rule.message
      }) | Out-Null
    }
  }

  return @($risks.ToArray())
}

function Resolve-PesterPathHygienePlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$ResultsPath,
    [Parameter(Mandatory = $true)][string]$SessionLockRoot,
    [ValidateSet('auto', 'relocate', 'block', 'off')]
    [string]$Mode = 'auto',
    [string]$SafeRoot
  )

  $requestedResultsPath = [System.IO.Path]::GetFullPath($ResultsPath)
  $requestedSessionLockRoot = [System.IO.Path]::GetFullPath($SessionLockRoot)

  $risks = New-Object System.Collections.Generic.List[object]
  foreach ($risk in (Get-PesterPathHygieneRisks -PathValue $requestedResultsPath)) {
    $risks.Add([pscustomobject]@{
      target = 'results'
      id = $risk.id
      path = $risk.path
      message = $risk.message
    }) | Out-Null
  }
  foreach ($risk in (Get-PesterPathHygieneRisks -PathValue $requestedSessionLockRoot)) {
    $risks.Add([pscustomobject]@{
      target = 'session-lock'
      id = $risk.id
      path = $risk.path
      message = $risk.message
    }) | Out-Null
  }

  if ($Mode -eq 'off' -or $risks.Count -eq 0) {
    return [pscustomobject]@{
      mode = $Mode
      status = 'clean'
      requestedResultsPath = $requestedResultsPath
      effectiveResultsPath = $requestedResultsPath
      requestedSessionLockRoot = $requestedSessionLockRoot
      effectiveSessionLockRoot = $requestedSessionLockRoot
      receiptRoot = $requestedResultsPath
      safeRoot = $null
      risks = @($risks.ToArray())
    }
  }

  $resolvedSafeRoot = if ([string]::IsNullOrWhiteSpace($SafeRoot)) {
    Join-Path ([System.IO.Path]::GetTempPath()) ("compare-vi-cli-action-local-" + [Guid]::NewGuid().ToString('N'))
  } else {
    [System.IO.Path]::GetFullPath($SafeRoot)
  }
  $safeRootRisks = @(Get-PesterPathHygieneRisks -PathValue $resolvedSafeRoot)
  if ($safeRootRisks.Count -gt 0) {
    return [pscustomobject]@{
      mode = $Mode
      status = 'path-hygiene-blocked'
      requestedResultsPath = $requestedResultsPath
      effectiveResultsPath = $null
      requestedSessionLockRoot = $requestedSessionLockRoot
      effectiveSessionLockRoot = $null
      receiptRoot = $null
      safeRoot = $resolvedSafeRoot
      risks = @($risks.ToArray() + @(
        [pscustomobject]@{
          target = 'safe-root'
          id = 'unsafe-safe-root'
          path = ConvertTo-PesterPathHygienePortablePath -PathValue $resolvedSafeRoot
          message = 'Configured safe root is itself under a managed or synchronized path.'
        }
      ))
    }
  }

  $action = if ($Mode -eq 'block') { 'block' } else { 'relocate' }
  if ($action -eq 'block') {
    return [pscustomobject]@{
      mode = $Mode
      status = 'path-hygiene-blocked'
      requestedResultsPath = $requestedResultsPath
      effectiveResultsPath = Join-Path $resolvedSafeRoot 'blocked-results'
      requestedSessionLockRoot = $requestedSessionLockRoot
      effectiveSessionLockRoot = Join-Path $resolvedSafeRoot 'blocked-session-lock'
      receiptRoot = Join-Path $resolvedSafeRoot 'blocked-results'
      safeRoot = $resolvedSafeRoot
      risks = @($risks.ToArray())
    }
  }

  return [pscustomobject]@{
    mode = $Mode
    status = 'relocated'
    requestedResultsPath = $requestedResultsPath
    effectiveResultsPath = Join-Path $resolvedSafeRoot 'results'
    requestedSessionLockRoot = $requestedSessionLockRoot
    effectiveSessionLockRoot = Join-Path $resolvedSafeRoot 'session-lock'
    receiptRoot = Join-Path $resolvedSafeRoot 'results'
    safeRoot = $resolvedSafeRoot
    risks = @($risks.ToArray())
  }
}
