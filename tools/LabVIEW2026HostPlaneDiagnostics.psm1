Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-OptionalExistingPath {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ''
  }

  try {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      return (Resolve-Path -LiteralPath $Path).Path
    }
  } catch {}

  return ''
}

function Convert-ToPathString {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ''
  }
  return $Value.Trim()
}

function Get-HostPlaneIssues {
  param(
    [bool]$HasLabVIEW,
    [bool]$HasCli,
    [bool]$HasCompare
  )

  $issues = New-Object System.Collections.Generic.List[string]
  if (-not $HasLabVIEW) {
    $issues.Add('labview-exe-missing') | Out-Null
  }
  if (-not $HasCli) {
    $issues.Add('labview-cli-missing') | Out-Null
  }
  if (-not $HasCompare) {
    $issues.Add('lvcompare-missing') | Out-Null
  }
  return @($issues.ToArray())
}

function Get-HostPlaneStatus {
  param(
    [bool]$HasLabVIEW,
    [bool]$HasCli,
    [bool]$HasCompare
  )

  if ($HasLabVIEW -and $HasCli -and $HasCompare) {
    return 'ready'
  }
  if ($HasLabVIEW -or $HasCli -or $HasCompare) {
    return 'partial'
  }
  return 'missing'
}

function Get-HostNativeShadowPlanePolicy {
  return [pscustomobject][ordered]@{
    plane = 'native-labview-2026-32'
    role = 'acceleration-surface'
    authoritative = $false
    executionMode = 'manual-opt-in'
    hostedCiAllowed = $false
    promotionPrerequisites = @(
      'docker-desktop/linux-container-2026',
      'docker-desktop/windows-container-2026'
    )
  }
}

function New-LabVIEW2026HostPlaneRecord {
  param(
    [Parameter(Mandatory)][string]$Plane,
    [Parameter(Mandatory)][string]$Architecture,
    [AllowNull()][string]$RequestedLabVIEWPath = '',
    [AllowNull()][string]$RequestedCliPath = '',
    [AllowNull()][string]$RequestedComparePath = ''
  )

  $requestedExe = Convert-ToPathString $RequestedLabVIEWPath
  $requestedCli = Convert-ToPathString $RequestedCliPath
  $requestedCompare = Convert-ToPathString $RequestedComparePath
  $resolvedExe = Resolve-OptionalExistingPath -Path $requestedExe
  $resolvedCli = Resolve-OptionalExistingPath -Path $requestedCli
  $resolvedCompare = Resolve-OptionalExistingPath -Path $requestedCompare
  $hasExe = -not [string]::IsNullOrWhiteSpace($resolvedExe)
  $hasCli = -not [string]::IsNullOrWhiteSpace($resolvedCli)
  $hasCompare = -not [string]::IsNullOrWhiteSpace($resolvedCompare)

  return [pscustomobject][ordered]@{
    plane = $Plane
    operatorLabel = $Plane
    architecture = $Architecture
    requestedLabVIEWPath = $requestedExe
    requestedCliPath = $requestedCli
    requestedComparePath = $requestedCompare
    labviewPath = $resolvedExe
    cliPath = $resolvedCli
    comparePath = $resolvedCompare
    labviewPresent = $hasExe
    cliPresent = $hasCli
    comparePresent = $hasCompare
    status = Get-HostPlaneStatus -HasLabVIEW:$hasExe -HasCli:$hasCli -HasCompare:$hasCompare
    issues = @(Get-HostPlaneIssues -HasLabVIEW:$hasExe -HasCli:$hasCli -HasCompare:$hasCompare)
  }
}

function Get-LabVIEW2026HostPlaneReport {
  [CmdletBinding()]
  param(
    [AllowNull()][string]$LabVIEW64Path = '',
    [AllowNull()][string]$LabVIEW32Path = '',
    [AllowNull()][string]$LabVIEWCli64Path = '',
    [AllowNull()][string]$LabVIEWCli32Path = '',
    [AllowNull()][string]$LVComparePath = ''
  )

  $native64 = New-LabVIEW2026HostPlaneRecord `
    -Plane 'native-labview-2026-64' `
    -Architecture '64-bit' `
    -RequestedLabVIEWPath $LabVIEW64Path `
    -RequestedCliPath $LabVIEWCli64Path `
    -RequestedComparePath $LVComparePath

  $native32 = New-LabVIEW2026HostPlaneRecord `
    -Plane 'native-labview-2026-32' `
    -Architecture '32-bit' `
    -RequestedLabVIEWPath $LabVIEW32Path `
    -RequestedCliPath $LabVIEWCli32Path `
    -RequestedComparePath $LVComparePath

  $nativeParallelReady = ($native64.status -eq 'ready') -and ($native32.status -eq 'ready')
  $candidateParallelPairs = New-Object System.Collections.Generic.List[object]
  if ($native64.status -eq 'ready') {
    $candidateParallelPairs.Add([pscustomobject][ordered]@{
        left = 'docker-desktop/windows-container-2026'
        right = 'native-labview-2026-64'
      }) | Out-Null
  }
  if ($nativeParallelReady) {
    $candidateParallelPairs.Add([pscustomobject][ordered]@{
        left = 'native-labview-2026-64'
        right = 'native-labview-2026-32'
      }) | Out-Null
  }
  $sharedCliAcrossNativePlanes = `
    (-not [string]::IsNullOrWhiteSpace([string]$native64.cliPath)) -and `
    ([string]::Equals([string]$native64.cliPath, [string]$native32.cliPath, [System.StringComparison]::OrdinalIgnoreCase))
  $shadowPolicy = Get-HostNativeShadowPlanePolicy

  return [pscustomobject][ordered]@{
    schema = 'labview-2026-host-plane-report@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    host = [ordered]@{
      os = if ($IsWindows) { 'windows' } else { 'non-windows' }
      computerName = [Environment]::MachineName
    }
    runner = [ordered]@{
      hostIsRunner = $true
      runnerName = if ([string]::IsNullOrWhiteSpace($env:RUNNER_NAME)) { [Environment]::MachineName } else { $env:RUNNER_NAME }
      githubActions = [bool](-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS))
    }
    docker = [ordered]@{
      operatorLabels = @(
        'linux-docker-fast-loop',
        'windows-docker-fast-loop',
        'dual-docker-fast-loop'
      )
    }
    policy = [ordered]@{
      authoritativePlanes = @(
        'docker-desktop/linux-container-2026',
        'docker-desktop/windows-container-2026'
      )
      hostNativeShadowPlane = $shadowPolicy
    }
    native = [ordered]@{
      parallelLabVIEWSupported = $nativeParallelReady
      sharedCliAcrossNativePlanes = $sharedCliAcrossNativePlanes
      recommendedParallelPlanes = if ($nativeParallelReady) {
        @('native-labview-2026-64', 'native-labview-2026-32')
      } else {
        @()
      }
      planes = [ordered]@{
        x64 = $native64
        x32 = $native32
      }
    }
    executionPolicy = [ordered]@{
      mutuallyExclusivePairs = [ordered]@{
        pairs = @(
          [pscustomobject][ordered]@{
            left = 'docker-desktop/linux-container-2026'
            right = 'docker-desktop/windows-container-2026'
          }
        )
      }
      provenParallelPairs = [ordered]@{
        pairs = @(
          [pscustomobject][ordered]@{
            left = 'docker-desktop/windows-container-2026'
            right = 'native-labview-2026-64'
          },
          [pscustomobject][ordered]@{
            left = 'native-labview-2026-64'
            right = 'native-labview-2026-32'
          }
        )
      }
      candidateParallelPairs = [ordered]@{
        pairs = @($candidateParallelPairs.ToArray())
      }
    }
  }
}

function Write-LabVIEW2026HostPlaneConsole {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()]$Report
  )

  foreach ($planeKey in @('x64', 'x32')) {
    $plane = $Report.native.planes.$planeKey
    if ($null -eq $plane) {
      continue
    }
    $operatorLabel = ''
    if ($plane.PSObject.Properties['operatorLabel']) {
      $operatorLabel = [string]$plane.operatorLabel
    }
    if ([string]::IsNullOrWhiteSpace($operatorLabel) -and $plane.PSObject.Properties['plane']) {
      $operatorLabel = [string]$plane.plane
    }
    if ([string]::IsNullOrWhiteSpace($operatorLabel)) {
      $operatorLabel = switch ($planeKey) {
        'x64' { 'native-labview-2026-64' }
        'x32' { 'native-labview-2026-32' }
        default { 'native-labview-2026' }
      }
    }
    $status = if ($plane.PSObject.Properties['status']) { [string]$plane.status } else { 'unknown' }
    $labviewPath = if ($plane.PSObject.Properties['labviewPath']) { [string]$plane.labviewPath } else { '' }
    $cliPath = if ($plane.PSObject.Properties['cliPath']) { [string]$plane.cliPath } else { '' }
    $comparePath = if ($plane.PSObject.Properties['comparePath']) { [string]$plane.comparePath } else { '' }

    $line = "[{0}][host-plane] status={1} exe={2} cli={3} compare={4}" -f `
      $operatorLabel, `
      $status, `
      ($(if ([string]::IsNullOrWhiteSpace($labviewPath)) { '-' } else { $labviewPath })), `
      ($(if ([string]::IsNullOrWhiteSpace($cliPath)) { '-' } else { $cliPath })), `
      ($(if ([string]::IsNullOrWhiteSpace($comparePath)) { '-' } else { $comparePath }))

    $color = switch ($status) {
      'ready' { 'Green' }
      'partial' { 'Yellow' }
      default { 'Red' }
    }
    Write-Host $line -ForegroundColor $color
  }

  Write-Host (
    "[host-plane-split][runner] hostIsRunner={0} runnerName={1} githubActions={2}" -f `
    [bool]$Report.runner.hostIsRunner, `
    [string]$Report.runner.runnerName, `
    [bool]$Report.runner.githubActions
  ) -ForegroundColor DarkCyan

  $candidatePairs = @(
    @($Report.executionPolicy.candidateParallelPairs.pairs) |
      ForEach-Object { "{0}+{1}" -f [string]$_.left, [string]$_.right }
  ) -join ','
  if ([string]::IsNullOrWhiteSpace($candidatePairs)) {
    $candidatePairs = '-'
  }

  $exclusivePairs = @(
    @($Report.executionPolicy.mutuallyExclusivePairs.pairs) |
      ForEach-Object { "{0}<->{1}" -f [string]$_.left, [string]$_.right }
  ) -join ','
  if ([string]::IsNullOrWhiteSpace($exclusivePairs)) {
    $exclusivePairs = '-'
  }

  Write-Host (
    "[host-plane-split][concurrency] nativeParallelLabVIEWSupported={0} mutuallyExclusivePairs={1} candidateParallelPairs={2}" -f `
    [bool]$Report.native.parallelLabVIEWSupported, `
    $exclusivePairs, `
    $candidatePairs
  ) -ForegroundColor Cyan
}

Export-ModuleMember -Function Get-LabVIEW2026HostPlaneReport, Write-LabVIEW2026HostPlaneConsole
