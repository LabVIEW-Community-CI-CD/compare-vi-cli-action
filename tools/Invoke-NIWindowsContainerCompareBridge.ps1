#Requires -Version 7.0

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BaseVi,
  [Parameter(Mandatory = $true)][string]$HeadVi,
  [Alias('LabVIEWPath')][string]$LabVIEWExePath,
  [ValidateSet('32', '64')][string]$LabVIEWBitness = '64',
  [string]$LVComparePath,
  [string[]]$Flags,
  [switch]$ReplaceFlags,
  [switch]$AllowSameLeaf,
  [ValidateSet('full', 'legacy')][string]$NoiseProfile = 'full',
  [string]$OutputDir = 'tests/results/single-compare',
  [switch]$RenderReport,
  [ValidateSet('html', 'xml', 'text')][string]$ReportFormat = 'html',
  [string]$JsonLogPath,
  [switch]$Quiet,
  [switch]$LeakCheck,
  [string]$LeakJsonPath,
  [string]$CaptureScriptPath,
  [switch]$Summary,
  [double]$LeakGraceSeconds = 0.5,
  [Nullable[int]]$TimeoutSeconds,
  [string]$Image = $env:COMPAREVI_NI_WINDOWS_IMAGE,
  [string]$ContainerLabVIEWPath = $env:COMPAREVI_NI_WINDOWS_LABVIEW_PATH,
  [string]$ContainerCliPath = $env:COMPAREVI_NI_WINDOWS_CLI_PATH,
  [string]$ComparePolicy = $env:COMPAREVI_NI_WINDOWS_COMPARE_POLICY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Resolve-ReportInfo {
  param([Parameter(Mandatory)][string]$Format)
  switch ($Format.ToLowerInvariant()) {
    'xml' {
      return [pscustomobject]@{
        ReportType = 'xml'
        FileName = 'compare-report.xml'
      }
    }
    'text' {
      return [pscustomobject]@{
        ReportType = 'text'
        FileName = 'compare-report.txt'
      }
    }
    default {
      return [pscustomobject]@{
        ReportType = 'html'
        FileName = 'compare-report.html'
      }
    }
  }
}

function Write-TextArtifact {
  param(
    [Parameter(Mandatory)][string]$Path,
    [AllowNull()][string]$Content
  )

  $dir = Split-Path -Parent $Path
  if ($dir) {
    Ensure-Directory -Path $dir
  }
  Set-Content -LiteralPath $Path -Value ($Content ?? '') -Encoding utf8
}

function Add-NdjsonArtifact {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Payload
  )

  $dir = Split-Path -Parent $Path
  if ($dir) {
    Ensure-Directory -Path $dir
  }

  ($Payload | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Path -Encoding utf8
}

function Copy-OrWriteArtifact {
  param(
    [AllowNull()][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestinationPath,
    [AllowNull()][string]$FallbackContent = ''
  )

  if (-not [string]::IsNullOrWhiteSpace($SourcePath) -and (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    return
  }

  Write-TextArtifact -Path $DestinationPath -Content $FallbackContent
}

function Resolve-LabVIEWVersionHint {
  param(
    [AllowNull()][string]$LabVIEWPath,
    [AllowNull()][string]$Image
  )

  if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
    $match = [regex]::Match($LabVIEWPath, 'LabVIEW\s+(?<year>\d{4})', 'IgnoreCase')
    if ($match.Success) {
      return $match.Groups['year'].Value
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($Image)) {
    $match = [regex]::Match($Image, 'labview:(?<year>\d{4})q(?<quarter>[1-4])', 'IgnoreCase')
    if ($match.Success) {
      return ('{0} q{1}' -f $match.Groups['year'].Value, $match.Groups['quarter'].Value)
    }
  }

  return $null
}

function New-FallbackCapture {
  param(
    [Parameter(Mandatory)][int]$ExitCode,
    [AllowNull()][string]$Message,
    [Parameter(Mandatory)][string]$ImageValue,
    [Parameter(Mandatory)][string]$ReportPathValue,
    [Parameter(Mandatory)][string]$LabVIEWPathValue
  )

  return [pscustomobject]@{
    schema = 'ni-windows-container-compare/v1'
    status = 'preflight-error'
    classification = 'preflight-error'
    exitCode = $ExitCode
    timedOut = $false
    image = $ImageValue
    reportPath = $ReportPathValue
    labviewPath = $LabVIEWPathValue
    command = ('Run-NIWindowsContainerCompare.ps1 -Image "{0}" -ReportPath "{1}"' -f $ImageValue, $ReportPathValue)
    message = $Message
    resultClass = 'failure-preflight'
    isDiff = $false
    gateOutcome = 'fail'
    failureClass = 'preflight'
    reportAnalysis = [ordered]@{
      reportPathExtracted = ''
      diffImageCount = 0
      hasDiffEvidence = $false
    }
    containerArtifacts = [ordered]@{
      exportDir = ''
      copiedPaths = @()
      copyStatus = 'not-attempted'
    }
  }
}

function Get-OptionalSourceCaptureText {
  param(
    [Parameter(Mandatory)]$SourceCapture,
    [Parameter(Mandatory)][string]$PropertyName
  )

  if (-not $SourceCapture.PSObject.Properties[$PropertyName]) {
    return $null
  }

  $value = [string]$SourceCapture.$PropertyName
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $null
  }

  return $value
}

function Resolve-TranslatedCommand {
  param(
    [Parameter(Mandatory)]$SourceCapture,
    [Parameter(Mandatory)][string]$EffectiveImage,
    [Parameter(Mandatory)][string]$BaseViPath,
    [Parameter(Mandatory)][string]$HeadViPath,
    [Parameter(Mandatory)][string]$NormalizedReportFormat,
    [Parameter(Mandatory)][string]$ResolvedReportPath
  )

  $sourceCommand = Get-OptionalSourceCaptureText -SourceCapture $SourceCapture -PropertyName 'command'
  if ($sourceCommand) {
    return $sourceCommand
  }

  return (
    'Run-NIWindowsContainerCompare.ps1 -Image "{0}" -BaseVi "{1}" -HeadVi "{2}" -ReportType "{3}" -ReportPath "{4}"' -f
    $EffectiveImage,
    $BaseViPath,
    $HeadViPath,
    $NormalizedReportFormat,
    $ResolvedReportPath
  )
}

function Convert-ToTranslatedCapture {
  param(
    [Parameter(Mandatory)]$SourceCapture,
    [Parameter(Mandatory)][string]$BaseViPath,
    [Parameter(Mandatory)][string]$HeadViPath,
    [AllowNull()][string[]]$EffectiveFlags,
    [Parameter(Mandatory)][string]$EffectiveComparePolicy,
    [Parameter(Mandatory)][string]$EffectiveCliPath,
    [Parameter(Mandatory)][string]$EffectiveImage,
    [Parameter(Mandatory)][string]$EffectiveLabVIEWPath,
    [AllowNull()][string]$LabVIEWVersion,
    [Parameter(Mandatory)][string]$ResolvedReportPath,
    [Parameter(Mandatory)][string]$NormalizedReportFormat,
    [Parameter(Mandatory)][double]$ElapsedSeconds,
    [Parameter(Mandatory)][string]$NiCapturePath,
    [Parameter(Mandatory)][string]$Bitness
  )

  $isDiff = $false
  if ($SourceCapture.PSObject.Properties['isDiff']) {
    $isDiff = [bool]$SourceCapture.isDiff
  } elseif ($SourceCapture.PSObject.Properties['status']) {
    $isDiff = [string]::Equals([string]$SourceCapture.status, 'diff', [System.StringComparison]::OrdinalIgnoreCase)
  } elseif ($SourceCapture.PSObject.Properties['exitCode']) {
    $isDiff = ([int]$SourceCapture.exitCode -eq 1)
  }

  $artifacts = [ordered]@{}
  if (
    $SourceCapture.PSObject.Properties['reportAnalysis'] -and
    $SourceCapture.reportAnalysis -and
    $SourceCapture.reportAnalysis.PSObject.Properties['diffImageCount']
  ) {
    $artifacts['imageCount'] = [int]$SourceCapture.reportAnalysis.diffImageCount
  }
  if (
    $SourceCapture.PSObject.Properties['containerArtifacts'] -and
    $SourceCapture.containerArtifacts -and
    $SourceCapture.containerArtifacts.PSObject.Properties['exportDir'] -and
    $SourceCapture.containerArtifacts.exportDir
  ) {
    $artifacts['exportDir'] = [string]$SourceCapture.containerArtifacts.exportDir
  }
  if ((Test-Path -LiteralPath $ResolvedReportPath -PathType Leaf)) {
    try {
      $artifacts['reportSizeBytes'] = [int64](Get-Item -LiteralPath $ResolvedReportPath).Length
    } catch {}
  }

  $cliNode = [ordered]@{
    path       = $EffectiveCliPath
    reportType = $NormalizedReportFormat
    reportPath = $ResolvedReportPath
  }
  $cliStatus = Get-OptionalSourceCaptureText -SourceCapture $SourceCapture -PropertyName 'status'
  if ($cliStatus) {
    $cliNode['status'] = $cliStatus
  }
  $cliMessage = Get-OptionalSourceCaptureText -SourceCapture $SourceCapture -PropertyName 'message'
  if ($cliMessage) {
    $cliNode['message'] = $cliMessage
  }
  if ($artifacts.Count -gt 0) {
    $cliNode['artifacts'] = $artifacts
  }

  return [ordered]@{
    schema = 'lvcompare-capture-v1'
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
    base = $BaseViPath
    head = $HeadViPath
    cliPath = $EffectiveCliPath
    args = @($EffectiveFlags)
    exitCode = [int]$SourceCapture.exitCode
    seconds = [math]::Round($ElapsedSeconds, 3)
    stdoutLen = 0
    stderrLen = 0
    command = Resolve-TranslatedCommand `
      -SourceCapture $SourceCapture `
      -EffectiveImage $EffectiveImage `
      -BaseViPath $BaseViPath `
      -HeadViPath $HeadViPath `
      -NormalizedReportFormat $NormalizedReportFormat `
      -ResolvedReportPath $ResolvedReportPath
    diff = [bool]$isDiff
    labviewExePath = $EffectiveLabVIEWPath
    labviewBitness = $Bitness
    environment = [ordered]@{
      comparePolicy = $EffectiveComparePolicy
      cli = $cliNode
      container = [ordered]@{
        image = $EffectiveImage
        labviewPath = $EffectiveLabVIEWPath
        labviewVersion = $LabVIEWVersion
        sourceCapturePath = $NiCapturePath
      }
    }
  }
}

$runnerScript = Join-Path $PSScriptRoot 'Run-NIWindowsContainerCompare.ps1'
if (-not (Test-Path -LiteralPath $runnerScript -PathType Leaf)) {
  throw "Run-NIWindowsContainerCompare.ps1 not found at '$runnerScript'."
}

$outputDirResolved = Resolve-AbsolutePath -Path $OutputDir
Ensure-Directory -Path $outputDirResolved

$reportInfo = Resolve-ReportInfo -Format $ReportFormat
$reportPath = Join-Path $outputDirResolved $reportInfo.FileName
$niCapturePath = Join-Path $outputDirResolved 'ni-windows-container-capture.json'
$niStdOutPath = Join-Path $outputDirResolved 'ni-windows-container-stdout.txt'
$niStdErrPath = Join-Path $outputDirResolved 'ni-windows-container-stderr.txt'
$lvStdOutPath = Join-Path $outputDirResolved 'lvcompare-stdout.txt'
$lvStdErrPath = Join-Path $outputDirResolved 'lvcompare-stderr.txt'
$lvExitPath = Join-Path $outputDirResolved 'lvcompare-exitcode.txt'
$lvCapturePath = Join-Path $outputDirResolved 'lvcompare-capture.json'

$effectiveImage = if ([string]::IsNullOrWhiteSpace($Image)) {
  'nationalinstruments/labview:2026q1-windows'
} else {
  $Image.Trim()
}
$effectiveLabVIEWPath = if ([string]::IsNullOrWhiteSpace($ContainerLabVIEWPath)) {
  'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
} else {
  $ContainerLabVIEWPath.Trim()
}
$effectiveCliPath = if ([string]::IsNullOrWhiteSpace($ContainerCliPath)) {
  'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
} else {
  $ContainerCliPath.Trim()
}
$effectiveComparePolicy = if ([string]::IsNullOrWhiteSpace($ComparePolicy)) {
  'cli-only'
} else {
  $ComparePolicy.Trim()
}
$effectiveFlags = [string[]]@()
if ($Flags) {
  $effectiveFlags = @($Flags | ForEach-Object { [string]$_ })
}
$labviewVersion = Resolve-LabVIEWVersionHint -LabVIEWPath $effectiveLabVIEWPath -Image $effectiveImage

$previousPolicy = [Environment]::GetEnvironmentVariable('LVCI_COMPARE_POLICY', 'Process')
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$exitCode = 0
$niCapture = $null

try {
  [Environment]::SetEnvironmentVariable('LVCI_COMPARE_POLICY', $effectiveComparePolicy, 'Process')

  $runnerParams = @{
    BaseVi = $BaseVi
    HeadVi = $HeadVi
    Image = $effectiveImage
    ReportPath = $reportPath
    ReportType = $reportInfo.ReportType
    LabVIEWPath = $effectiveLabVIEWPath
    PassThru = $true
  }
  if ($effectiveFlags.Count -gt 0) {
    $runnerParams['Flags'] = $effectiveFlags
  }
  if ($TimeoutSeconds -and $TimeoutSeconds -gt 0) {
    $runnerParams['TimeoutSeconds'] = [int]$TimeoutSeconds
  }

  $niCapture = & $runnerScript @runnerParams
  $lastExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
  $exitCode = if ($lastExit) { [int]$lastExit.Value } else { 0 }
} catch {
  $lastExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
  $exitCode = if ($lastExit -and [int]$lastExit.Value -ne 0) { [int]$lastExit.Value } else { 2 }
  $niCapture = New-FallbackCapture `
    -ExitCode $exitCode `
    -Message $_.Exception.Message `
    -ImageValue $effectiveImage `
    -ReportPathValue $reportPath `
    -LabVIEWPathValue $effectiveLabVIEWPath
} finally {
  [Environment]::SetEnvironmentVariable('LVCI_COMPARE_POLICY', $previousPolicy, 'Process')
  $stopwatch.Stop()
}

if (-not $niCapture -and (Test-Path -LiteralPath $niCapturePath -PathType Leaf)) {
  $niCapture = Get-Content -LiteralPath $niCapturePath -Raw | ConvertFrom-Json -Depth 10
}
if (-not $niCapture) {
  $niCapture = New-FallbackCapture `
    -ExitCode $exitCode `
    -Message 'NI Windows container capture was not produced.' `
    -ImageValue $effectiveImage `
    -ReportPathValue $reportPath `
    -LabVIEWPathValue $effectiveLabVIEWPath
}

Copy-OrWriteArtifact -SourcePath $niStdOutPath -DestinationPath $lvStdOutPath
Copy-OrWriteArtifact -SourcePath $niStdErrPath -DestinationPath $lvStdErrPath
Write-TextArtifact -Path $lvExitPath -Content ([string]$exitCode)

$translatedCapture = Convert-ToTranslatedCapture `
  -SourceCapture $niCapture `
  -BaseViPath $BaseVi `
  -HeadViPath $HeadVi `
  -EffectiveFlags $effectiveFlags `
  -EffectiveComparePolicy $effectiveComparePolicy `
  -EffectiveCliPath $effectiveCliPath `
  -EffectiveImage $effectiveImage `
  -EffectiveLabVIEWPath $effectiveLabVIEWPath `
  -LabVIEWVersion $labviewVersion `
  -ResolvedReportPath $reportPath `
  -NormalizedReportFormat $ReportFormat.ToLowerInvariant() `
  -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds `
  -NiCapturePath $niCapturePath `
  -Bitness $LabVIEWBitness
$translatedCapture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $lvCapturePath -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($JsonLogPath)) {
  $logPathResolved = Resolve-AbsolutePath -Path $JsonLogPath
  $logEntry = [ordered]@{
    timestamp   = (Get-Date).ToUniversalTime().ToString('o')
    type        = 'result'
    schema      = 'prime-lvcompare-v1'
    exitCode    = $exitCode
    reportPath  = $reportPath
    capturePath = $lvCapturePath
    image       = $effectiveImage
  }
  Add-NdjsonArtifact -Path $logPathResolved -Payload $logEntry
}

if ($Summary.IsPresent) {
  $summaryText = if ($exitCode -eq 1) { 'diff' } elseif ($exitCode -eq 0) { 'match' } else { 'error' }
  Write-Host ("[ni-container-bridge] {0} report={1}" -f $summaryText, $reportPath)
}

exit $exitCode
