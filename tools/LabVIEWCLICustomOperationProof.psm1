Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LabVIEWCustomOperationLogInsights {
  [CmdletBinding(DefaultParameterSetName = 'Path')]
  param(
    [Parameter(ParameterSetName = 'Path')]
    [string[]]$LogPaths,
    [Parameter(ParameterSetName = 'Text')]
    [AllowNull()][string]$Text
  )

  $combinedText = if ($PSCmdlet.ParameterSetName -eq 'Text') {
    [string]($Text ?? '')
  } else {
    $chunks = New-Object System.Collections.Generic.List[string]
    foreach ($pathValue in @($LogPaths)) {
      if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
      try {
        if (Test-Path -LiteralPath $pathValue -PathType Leaf) {
          $chunks.Add((Get-Content -LiteralPath $pathValue -Raw -ErrorAction Stop)) | Out-Null
        }
      } catch {}
    }
    ($chunks -join [Environment]::NewLine)
  }

  $observedLabVIEWPaths = New-Object System.Collections.Generic.List[string]
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($combinedText, 'Using(?:\s+last\s+used)?\s+LabVIEW:\s*"([^"]+)"')) {
    $pathValue = [string]$match.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
    if (-not ($observedLabVIEWPaths.Contains($pathValue))) {
      $observedLabVIEWPaths.Add($pathValue) | Out-Null
    }
  }

  $launchSucceeded = $combinedText -match 'LabVIEW launched successfully'
  $operationCompleted = $combinedText -match 'Operation completed successfully' -or
    $combinedText -match 'completed successfully' -or
    $combinedText -match 'Operation output:'

  return [pscustomobject]@{
    observedLabVIEWPaths = @($observedLabVIEWPaths.ToArray())
    observedLabVIEWPath = if ($observedLabVIEWPaths.Count -gt 0) { $observedLabVIEWPaths[0] } else { $null }
    launchSucceeded = [bool]$launchSucceeded
    operationCompleted = [bool]$operationCompleted
    logLineCount = if ([string]::IsNullOrWhiteSpace($combinedText)) { 0 } else { ($combinedText -split "`r?`n").Count }
  }
}

function Resolve-LabVIEWCustomOperationProofAnalysis {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object[]]$ScenarioResults,
    [AllowNull()][string]$RequestedLabVIEWPath
  )

  $scenarioMap = @{}
  foreach ($scenario in @($ScenarioResults)) {
    if ($null -eq $scenario) { continue }
    $name = [string]$scenario.name
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $scenarioMap[$name] = $scenario
  }

  $defaultHelp = $scenarioMap['default-help']
  $explicitHelp = $scenarioMap['explicit-help']
  $explicitHeadless = $scenarioMap['explicit-headless-run']

  $defaultObserved = if ($defaultHelp -and $defaultHelp.logInsights) { [string]$defaultHelp.logInsights.observedLabVIEWPath } else { $null }
  $explicitObserved = if ($explicitHelp -and $explicitHelp.logInsights) { [string]$explicitHelp.logInsights.observedLabVIEWPath } else { $null }
  if ([string]::IsNullOrWhiteSpace($explicitObserved)) {
    $explicitObserved = [string]$RequestedLabVIEWPath
  }

  $defaultPathDriftObserved = $false
  if (-not [string]::IsNullOrWhiteSpace($defaultObserved) -and -not [string]::IsNullOrWhiteSpace($explicitObserved)) {
    $defaultPathDriftObserved = -not [string]::Equals(
      [System.IO.Path]::GetFullPath($defaultObserved),
      [System.IO.Path]::GetFullPath($explicitObserved),
      [System.StringComparison]::OrdinalIgnoreCase
    )
  }

  $explicitHelpSucceeded = $explicitHelp -and ([string]$explicitHelp.status -eq 'succeeded')
  $explicitHelpTimedOut = $explicitHelp -and [bool]$explicitHelp.timedOut
  $explicitHeadlessTimedOut = $explicitHeadless -and [bool]$explicitHeadless.timedOut
  $headlessInteractiveMismatchObserved = [bool]($explicitHelpSucceeded -and $explicitHeadlessTimedOut)
  $customOperationLoadingObserved = [bool]($explicitHelpTimedOut -and $explicitHeadlessTimedOut)
  $hostPlane32BitConcernObserved = [bool](
    -not [string]::IsNullOrWhiteSpace($RequestedLabVIEWPath) -and
    $RequestedLabVIEWPath -match '(?i)Program Files \(x86\)' -and
    ($explicitHelpTimedOut -or $explicitHeadlessTimedOut)
  )

  $cleanupRequired = $false
  $cleanupSucceeded = $true
  foreach ($scenario in @($ScenarioResults)) {
    if ($null -eq $scenario) { continue }
    $lingeringCount = @($scenario.lingeringProcesses).Count
    $killedCount = @($scenario.cleanup.killedPids).Count
    if ($lingeringCount -gt 0 -or $killedCount -gt 0) {
      $cleanupRequired = $true
    }
    if ($lingeringCount -gt 0) {
      $cleanupSucceeded = $false
    }
  }

  $rootCauseCandidates = New-Object System.Collections.Generic.List[string]
  if ($defaultPathDriftObserved) { $rootCauseCandidates.Add('default-path-drift') | Out-Null }
  if ($customOperationLoadingObserved) { $rootCauseCandidates.Add('custom-operation-loading') | Out-Null }
  if ($headlessInteractiveMismatchObserved) { $rootCauseCandidates.Add('headless-interactive-mismatch') | Out-Null }
  if ($hostPlane32BitConcernObserved) { $rootCauseCandidates.Add('host-plane-32bit-startup') | Out-Null }

  $notes = New-Object System.Collections.Generic.List[string]
  if ($defaultPathDriftObserved) {
    $notes.Add(("Default LabVIEW resolution drifted to '{0}' instead of '{1}'." -f $defaultObserved, $explicitObserved)) | Out-Null
  }
  if ($customOperationLoadingObserved) {
    $notes.Add('Both explicit GetHelp and explicit headless execution timed out, which points to custom-operation loading or host-plane startup rather than a headless-only mismatch.') | Out-Null
  } elseif ($headlessInteractiveMismatchObserved) {
    $notes.Add('Explicit GetHelp succeeded while explicit headless execution timed out, which points to a headless/interactive mismatch.') | Out-Null
  }
  if ($hostPlane32BitConcernObserved) {
    $notes.Add('The explicit proof path used the LabVIEW 2026 32-bit host plane and still timed out, so 32-bit host startup remains a live suspect.') | Out-Null
  }
  if ($cleanupRequired -and $cleanupSucceeded) {
    $notes.Add('The proof required residue cleanup, but the helper removed all newly spawned LabVIEW/LabVIEWCLI processes before exit.') | Out-Null
  } elseif ($cleanupRequired) {
    $notes.Add('The proof required residue cleanup and still left newly spawned LabVIEW/LabVIEWCLI processes running.') | Out-Null
  }

  return [pscustomobject]@{
    defaultPathDriftObserved = [bool]$defaultPathDriftObserved
    defaultObservedLabVIEWPath = $defaultObserved
    explicitObservedLabVIEWPath = $explicitObserved
    explicitHelpTimedOut = [bool]$explicitHelpTimedOut
    explicitHeadlessTimedOut = [bool]$explicitHeadlessTimedOut
    headlessInteractiveMismatchObserved = [bool]$headlessInteractiveMismatchObserved
    customOperationLoadingObserved = [bool]$customOperationLoadingObserved
    hostPlane32BitConcernObserved = [bool]$hostPlane32BitConcernObserved
    cleanupRequired = [bool]$cleanupRequired
    cleanupSucceeded = [bool]$cleanupSucceeded
    rootCauseCandidates = @($rootCauseCandidates.ToArray())
    notes = @($notes.ToArray())
  }
}

Export-ModuleMember -Function Get-LabVIEWCustomOperationLogInsights, Resolve-LabVIEWCustomOperationProofAnalysis
