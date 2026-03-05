<#
.SYNOPSIS
  Deterministic driver for LVCompare.exe with capture and optional HTML report.

.DESCRIPTION
  Wraps the repository's capture pipeline to run LVCompare against two VIs with
  stable arguments, explicit LabVIEW selection via -lvpath, and NDJSON crumbs.
  Produces standard artifacts under the chosen OutputDir:
    - lvcompare-capture.json (schema lvcompare-capture-v1)
    - compare-report.<ext> (when reports enabled; html/xml/text)
    - lvcompare-stdout.txt / lvcompare-stderr.txt / lvcompare-exitcode.txt

.PARAMETER BaseVi
  Path to the base VI.

.PARAMETER HeadVi
  Path to the head VI.

.PARAMETER LabVIEWExePath
  Path to the LabVIEW executable handed to LVCompare via -lvpath. Defaults to
  LabVIEW 2025 64-bit canonical path when not provided and env overrides are absent.
  Alias: -LabVIEWPath (legacy).

.PARAMETER LVComparePath
  Optional explicit LVCompare.exe path. Defaults to canonical install or LVCOMPARE_PATH when omitted.

.PARAMETER Flags
  Additional LVCompare flags. When -ReplaceFlags is omitted, the helper also applies
  the bundle defined by -NoiseProfile (default: none, legacy: -noattr -nofp -nofppos -nobd -nobdcosm).

.PARAMETER ReplaceFlags
  Replace default flags entirely with the provided -Flags.

.PARAMETER NoiseProfile
  Chooses which canned LVCompare ignore bundle to apply when -ReplaceFlags is not set.
  Default 'full' adds no suppression; 'legacy' restores the historical ignores
  (-noattr -nofp -nofppos -nobd -nobdcosm).

.PARAMETER OutputDir
  Target directory for artifacts (default: tests/results/single-compare).

.PARAMETER RenderReport
  Emit compare-report.html (default: enabled).

.PARAMETER ReportFormat
  Report format to request (html, xml, text). Defaults to html; non-html formats
  implicitly enable report capture even when -RenderReport is omitted.

.PARAMETER JsonLogPath
  NDJSON crumb log (schema prime-lvcompare-v1 compatible): spawn/result/paths.

.PARAMETER Quiet
  Reduce console noise from the capture script.

.PARAMETER LeakCheck
  After run, record remaining LVCompare/LabVIEW PIDs in a JSON summary.

.PARAMETER LeakJsonPath
  Optional path for leak summary JSON (default tests/results/single-compare/compare-leak.json).

.PARAMETER CaptureScriptPath
  Optional path to an alternate Capture-LVCompare.ps1 implementation (primarily for tests).

.PARAMETER Summary
  When set, prints a concise human-readable outcome and appends to $GITHUB_STEP_SUMMARY when available.

.PARAMETER LeakGraceSeconds
  Optional grace delay before leak check to reduce false positives (default 0.5 seconds).

.PARAMETER TimeoutSeconds
  Optional override for the LVCompare execution timeout (seconds). When omitted,
  defaults apply (300s for LabVIEW CLI captures, unlimited for direct LVCompare
  capture).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$BaseVi,
  [Parameter(Mandatory=$true)][string]$HeadVi,
  [Alias('LabVIEWPath')]
  [string]$LabVIEWExePath,
  [ValidateSet('32','64')][string]$LabVIEWBitness = '64',
  [Alias('LVCompareExePath')]
  [string]$LVComparePath,
  [string[]]$Flags,
  [switch]$ReplaceFlags,
  [switch]$AllowSameLeaf,
  [ValidateSet('full','legacy')]
  [string]$NoiseProfile = 'full',
    [string]$OutputDir = 'tests/results/single-compare',
    [switch]$RenderReport,
[ValidateSet('html','html-single','xml','text')]
[string]$ReportFormat = 'html',
  [string]$JsonLogPath,
  [switch]$Quiet,
  [switch]$LeakCheck,
  [string]$LeakJsonPath,
  [string]$CaptureScriptPath,
  [switch]$Summary,
  [double]$LeakGraceSeconds = 0.5,
  [Nullable[int]]$TimeoutSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Resolve-ReportFormatInfo {
  param([string]$Format)

  $normalized = if ([string]::IsNullOrWhiteSpace($Format)) { 'html' } else { $Format.Trim().ToLowerInvariant() }
  switch ($normalized) {
    'htmlsingle' { $normalized = 'html-single'; break }
    'html-singlefile' { $normalized = 'html-single'; break }
    'htmlsinglefile' { $normalized = 'html-single'; break }
    'single' { $normalized = 'html-single'; break }
    'singlefile' { $normalized = 'html-single'; break }
  }

  switch ($normalized) {
    'html' {
      return [pscustomobject]@{
        normalized = 'html'
        cliType    = 'HTML'
        fileName   = 'compare-report.html'
      }
    }
    'html-single' {
      return [pscustomobject]@{
        normalized = 'html-single'
        cliType    = 'HTMLSingleFile'
        fileName   = 'compare-report.html'
      }
    }
    'xml' {
      return [pscustomobject]@{
        normalized = 'xml'
        cliType    = 'XML'
        fileName   = 'compare-report.xml'
      }
    }
    'text' {
      return [pscustomobject]@{
        normalized = 'text'
        cliType    = 'Text'
        fileName   = 'compare-report.txt'
      }
    }
    default {
      throw "Unsupported report format '$Format'. Supported values: html, html-single, xml, text."
    }
  }
}

if (-not $PSBoundParameters.ContainsKey('ReportFormat')) {
  $envReportFormat = [System.Environment]::GetEnvironmentVariable('COMPAREVI_REPORT_FORMAT','Process')
  if ($envReportFormat) {
    $ReportFormat = (Resolve-ReportFormatInfo -Format $envReportFormat).normalized
  }
}
if (-not $PSBoundParameters.ContainsKey('Flags')) {
  $envFlagsRaw = [System.Environment]::GetEnvironmentVariable('COMPAREVI_LVCOMPARE_FLAGS','Process')
  if ($envFlagsRaw) {
    $Flags = @($envFlagsRaw -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }
}
try { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'VendorTools.psm1') -Force } catch {}
try { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'LabVIEWCli.psm1') -Force } catch {}

$labviewPidTrackerModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'LabVIEWPidTracker.psm1'
$labviewPidTrackerLoaded = $false
$labviewPidTrackerPath = $null
$labviewPidTrackerState = $null
$labviewPidTrackerFinalized = $false
$labviewPidTrackerFinalState = $null

if (Test-Path -LiteralPath $labviewPidTrackerModule -PathType Leaf) {
  try {
    Import-Module $labviewPidTrackerModule -Force
    $labviewPidTrackerLoaded = $true
  } catch {
    Write-Warning ("Invoke-LVCompare: failed to import LabVIEW PID tracker module: {0}" -f $_.Exception.Message)
  }
}

function Initialize-LabVIEWPidTracker {
  if (-not $script:labviewPidTrackerLoaded -or $script:labviewPidTrackerState) { return }
  $script:labviewPidTrackerPath = Join-Path $OutputDir '_agent' 'labview-pid.json'
  try {
    $script:labviewPidTrackerState = Start-LabVIEWPidTracker -TrackerPath $script:labviewPidTrackerPath -Source 'invoke-lvcompare:init'
    if ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Pid'] -and $script:labviewPidTrackerState.Pid) {
      $modeText = if ($script:labviewPidTrackerState.Reused) { 'Reusing existing' } else { 'Tracking detected' }
      Write-Host ("[labview-pid] {0} LabVIEW.exe PID {1}." -f $modeText, $script:labviewPidTrackerState.Pid) -ForegroundColor DarkGray
    }
  } catch {
    Write-Warning ("Invoke-LVCompare: failed to start LabVIEW PID tracker: {0}" -f $_.Exception.Message)
    $script:labviewPidTrackerLoaded = $false
    $script:labviewPidTrackerPath = $null
    $script:labviewPidTrackerState = $null
  }
}

function Finalize-LabVIEWPidTracker {
  param(
    [string]$Status,
    [Nullable[int]]$ExitCode,
    [Nullable[int]]$CompareExitCode,
    [Nullable[int]]$ProcessExitCode,
    [string]$Command,
    [string]$CapturePath,
    [Nullable[bool]]$ReportGenerated,
    [Nullable[bool]]$DiffDetected,
    [string]$Message,
    [string]$Mode,
    [string]$Policy,
    [Nullable[bool]]$AutoCli,
    [Nullable[bool]]$DidCli
  )

  if (-not $script:labviewPidTrackerLoaded -or -not $script:labviewPidTrackerPath -or $script:labviewPidTrackerFinalized) { return }

  $context = [ordered]@{ stage = 'lvcompare:summary' }
  if ($Status) { $context.status = $Status } else { $context.status = 'unknown' }
  if ($PSBoundParameters.ContainsKey('ExitCode') -and $ExitCode -ne $null) { $context.exitCode = [int]$ExitCode }
  if ($PSBoundParameters.ContainsKey('CompareExitCode') -and $CompareExitCode -ne $null) { $context.compareExitCode = [int]$CompareExitCode }
  if ($PSBoundParameters.ContainsKey('ProcessExitCode') -and $ProcessExitCode -ne $null) { $context.processExitCode = [int]$ProcessExitCode }
  if ($PSBoundParameters.ContainsKey('Command') -and $Command) { $context.command = $Command }
  if ($PSBoundParameters.ContainsKey('CapturePath') -and $CapturePath) { $context.capturePath = $CapturePath }
  if ($PSBoundParameters.ContainsKey('ReportGenerated')) { $context.reportGenerated = [bool]$ReportGenerated }
  if ($PSBoundParameters.ContainsKey('DiffDetected')) { $context.diffDetected = [bool]$DiffDetected }
  if ($PSBoundParameters.ContainsKey('Mode') -and $Mode) { $context.mode = $Mode }
  if ($PSBoundParameters.ContainsKey('Policy') -and $Policy) { $context.policy = $Policy }
  if ($PSBoundParameters.ContainsKey('AutoCli')) { $context.autoCli = [bool]$AutoCli }
  if ($PSBoundParameters.ContainsKey('DidCli')) { $context.didCli = [bool]$DidCli }
  if ($PSBoundParameters.ContainsKey('Message') -and $Message) { $context.message = $Message }

  $args = @{ TrackerPath = $script:labviewPidTrackerPath; Source = 'invoke-lvcompare:summary' }
  if ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Pid'] -and $script:labviewPidTrackerState.Pid) {
    $args.Pid = $script:labviewPidTrackerState.Pid
  }
  if ($context) { $args.Context = [pscustomobject]$context }

  try {
    $script:labviewPidTrackerFinalState = Stop-LabVIEWPidTracker @args
  } catch {
    Write-Warning ("Invoke-LVCompare: failed to finalize LabVIEW PID tracker: {0}" -f $_.Exception.Message)
  } finally {
    $script:labviewPidTrackerFinalized = $true
  }
}

function Set-DefaultLabVIEWCliPath {
  param([switch]$ThrowOnMissing)

  $resolver = Get-Command -Name 'Resolve-LabVIEWCliPath' -ErrorAction SilentlyContinue
  if (-not $resolver) {
    try {
      $vendorModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'VendorTools.psm1'
      if (Test-Path -LiteralPath $vendorModule -PathType Leaf) {
        Import-Module $vendorModule -Force | Out-Null
        $resolver = Get-Command -Name 'Resolve-LabVIEWCliPath' -ErrorAction SilentlyContinue
      }
    } catch {}
  }

  if (-not $resolver) {
    if ($ThrowOnMissing) {
      throw 'Resolve-LabVIEWCliPath is unavailable. Import tools/VendorTools.psm1 before calling Set-DefaultLabVIEWCliPath.'
    }
    return $null
  }

  $cliPath = $null
  try { $cliPath = Resolve-LabVIEWCliPath } catch {}
  if (-not $cliPath) {
    if ($ThrowOnMissing) {
      throw 'LabVIEWCLI.exe could not be located. Set LABVIEWCLI_PATH or install the LabVIEW CLI component.'
    }
    return $null
  }

  try {
    if (Test-Path -LiteralPath $cliPath -PathType Leaf) {
      $cliPath = (Resolve-Path -LiteralPath $cliPath -ErrorAction Stop).Path
    }
  } catch {}

  foreach ($name in @('LABVIEWCLI_PATH','LABVIEW_CLI_PATH','LABVIEW_CLI')) {
    try { [System.Environment]::SetEnvironmentVariable($name, $cliPath) } catch {}
  }

  return $cliPath
}

function Write-JsonEvent {
  param([string]$Type,[hashtable]$Data)
  if (-not $JsonLogPath) { return }
  try {
    $dir = Split-Path -Parent $JsonLogPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $payload = [ordered]@{
      timestamp = (Get-Date).ToString('o')
      type      = $Type
      schema    = 'prime-lvcompare-v1'
    }
    if ($Data) { foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] } }
    ($payload | ConvertTo-Json -Compress) | Add-Content -Path $JsonLogPath
  } catch { Write-Warning "Invoke-LVCompare: failed to append event: $($_.Exception.Message)" }
}

function New-DirIfMissing([string]$Path) { if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

function Get-FileProductVersion([string]$Path) {
  if (-not $Path) { return $null }
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)).ProductVersion
  } catch { return $null }
}

function Get-SourceControlBootstrapHint {
  return 'Likely cause: LabVIEW Source Control bootstrap dialog (Error 1025/0x401 in NI_SCC_ConnSrv.lvlib:SCC_ConnSrv RunSCCConnSrv.vi -> SCC_Provider_Startup.vi.ProxyCaller). When LabVIEW starts headless it still loads the configured source control provider; if that provider cannot connect, LabVIEW shows a modal "Source Control" window and blocks LVCompare. Dismiss the dialog or disable Source Control via Tools > Source Control on the runner.'
}

function Get-CliReportFileExtension {
  param([string]$MimeType)
  if (-not $MimeType) { return 'bin' }
  switch -Regex ($MimeType) {
    '^image/png' { return 'png' }
    '^image/jpeg' { return 'jpg' }
    '^image/gif' { return 'gif' }
    '^image/bmp' { return 'bmp' }
    default { return 'bin' }
  }
}

function Get-CliReportArtifacts {
  param(
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$OutputDir
  )

  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { return $null }

  try { $html = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop } catch { return $null }

  $artifactInfo = [ordered]@{}
  try {
    $item = Get-Item -LiteralPath $ReportPath -ErrorAction Stop
    if ($item -and $item.Length -ge 0) { $artifactInfo.reportSizeBytes = [long]$item.Length }
  } catch {}

  $imageMatches = @()
  try {
    $pattern = '<img\b[^>]*\bsrc\s*=\s*"([^"]+)"'
    $imageMatches = [regex]::Matches($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  } catch { $imageMatches = @() }

  if ($imageMatches.Count -eq 0) {
    if ($artifactInfo.Count -gt 0) { return [pscustomobject]$artifactInfo }
    return $null
  }

  $images = @()
  $exportDir = Join-Path $OutputDir 'cli-images'
  $exportDirResolved = $null
  try {
    New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
    $exportDirResolved = (Resolve-Path -LiteralPath $exportDir -ErrorAction Stop).Path
  } catch { $exportDirResolved = $exportDir }

  for ($idx = 0; $idx -lt $imageMatches.Count; $idx++) {
    $srcValue = $imageMatches[$idx].Groups[1].Value
    $entry = [ordered]@{ index = $idx; dataLength = $srcValue.Length }

    $mime = $null
    $base64Data = $null
    if ($srcValue -match '^data:(?<mime>[^;]+);base64,(?<data>.+)$') {
      $mime = $Matches['mime']
      $base64Data = $Matches['data']
      $entry.mimeType = $mime
    } else {
      $entry.source = $srcValue
    }

    if ($base64Data) {
      try {
        $clean = $base64Data -replace '\s', ''
        $bytes = [System.Convert]::FromBase64String($clean)
        if ($bytes) {
          $entry.byteLength = $bytes.Length
          $ext = Get-CliReportFileExtension -MimeType $mime
          $fileName = 'cli-image-{0:D2}.{1}' -f $idx, $ext
          $filePath = Join-Path $exportDir $fileName
          [System.IO.File]::WriteAllBytes($filePath, $bytes)
          try { $entry.savedPath = (Resolve-Path -LiteralPath $filePath -ErrorAction Stop).Path } catch { $entry.savedPath = $filePath }
        }
      } catch {
        $entry.decodeError = $_.Exception.Message
      }
    } else {
      $candidatePath = $null
      try {
        if ([System.IO.Path]::IsPathRooted($srcValue)) {
          $candidatePath = $srcValue
        } else {
          $candidatePath = Join-Path (Split-Path -Parent $ReportPath) $srcValue
        }
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
          $resolvedCandidate = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path
          $entry.resolvedSource = $resolvedCandidate
          $ext = [System.IO.Path]::GetExtension($resolvedCandidate)
          if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.bin' }
          $fileName = 'cli-image-{0:D2}{1}' -f $idx, $ext
          $filePath = Join-Path $exportDir $fileName
          Copy-Item -LiteralPath $resolvedCandidate -Destination $filePath -Force
          try { $entry.savedPath = (Resolve-Path -LiteralPath $filePath -ErrorAction Stop).Path } catch { $entry.savedPath = $filePath }
        }
      } catch {}
    }

    $images += [pscustomobject]$entry
  }

  if ($images.Count -gt 0) {
    $artifactInfo.imageCount = $images.Count
    $artifactInfo.images = $images
    if ($exportDirResolved) { $artifactInfo.exportDir = $exportDirResolved }
  }

  if ($artifactInfo.Count -gt 0) { return [pscustomobject]$artifactInfo }
  return $null
}

function Get-LabVIEWCliOutputMetadata {
  param(
    [string]$StdOut,
    [string]$StdErr
  )

  $meta = [ordered]@{}
  $regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

  if (-not [string]::IsNullOrWhiteSpace($StdOut)) {
    $reportMatch = [System.Text.RegularExpressions.Regex]::Match($StdOut, 'Report\s+Type\s*[:=]\s*(?<val>[^\r\n]+)', $regexOptions)
    if ($reportMatch.Success) { $meta.reportType = $reportMatch.Groups['val'].Value.Trim() }

    $reportPathMatch = [System.Text.RegularExpressions.Regex]::Match($StdOut, 'Report\s+(?:can\s+be\s+found|saved)\s+(?:at|to)\s+(?<val>[^\r\n]+)', $regexOptions)
    if ($reportPathMatch.Success) { $meta.reportPath = $reportPathMatch.Groups['val'].Value.Trim().Trim('"') }

    $statusMatch = [System.Text.RegularExpressions.Regex]::Match($StdOut, '(?:Comparison\s+Status|Status|Result)\s*[:=]\s*(?<val>[^\r\n]+)', $regexOptions)
    if ($statusMatch.Success) { $meta.status = $statusMatch.Groups['val'].Value.Trim() }

    $lines = @($StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -gt 0) {
      $lastLine = $lines[-1]
      if ($lastLine) { $meta.message = $lastLine }
    }
  }

  if (-not $meta.Contains('message') -and -not [string]::IsNullOrWhiteSpace($StdErr)) {
    $errLines = @($StdErr -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($errLines.Count -gt 0) { $meta['message'] = $errLines[-1] }
  }

  if ($meta.Contains('message')) {
    $messageValue = $meta['message']
    if ($messageValue -and $messageValue.Length -gt 512) { $meta['message'] = $messageValue.Substring(0,512) }
  }

  if ($meta.Count -gt 0) { return [pscustomobject]$meta }
  return $null
}

function Invoke-LabVIEWCLICompare {
  param(
    [Parameter(Mandatory)][string]$Base,
    [Parameter(Mandatory)][string]$Head,
    [Parameter(Mandatory)][string]$OutDir,
    [switch]$RenderReport,
    [string[]]$Flags,
    [ValidateSet('html','xml','text')]
    [string]$ReportFormat = 'html',
    [switch]$AllowSameLeaf,
    [Nullable[int]]$TimeoutSeconds
  )

  $stageCleanupRoot = $null
  $baseResolved = (Resolve-Path -LiteralPath $Base -ErrorAction Stop).Path
  $headResolved = (Resolve-Path -LiteralPath $Head -ErrorAction Stop).Path
  $stageAllowSameLeaf = $AllowSameLeaf.IsPresent
  if ($baseResolved -ne $headResolved) {
    $baseLeaf = Split-Path -Leaf $baseResolved
    $headLeaf = Split-Path -Leaf $headResolved
    if ($baseLeaf -and $headLeaf -and [string]::Equals($baseLeaf, $headLeaf, [System.StringComparison]::OrdinalIgnoreCase) -and -not $stageAllowSameLeaf) {
      $stageScript = Join-Path $PSScriptRoot 'Stage-CompareInputs.ps1'
      if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
        throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$baseResolved Head=$headResolved"
      }
      try {
        $stagingInfo = & $stageScript -BaseVi $baseResolved -HeadVi $headResolved
      } catch {
        throw ("Invoke-LabVIEWCLICompare: staging failed -> {0}" -f $_.Exception.Message)
      }
      if (-not $stagingInfo) { throw 'Invoke-LabVIEWCLICompare: Stage-CompareInputs.ps1 returned no staging information.' }
      if ($stagingInfo.Root) { $stageCleanupRoot = $stagingInfo.Root }
      try { $baseResolved = (Resolve-Path -LiteralPath $stagingInfo.Base -ErrorAction Stop).Path } catch { $baseResolved = $stagingInfo.Base }
      try { $headResolved = (Resolve-Path -LiteralPath $stagingInfo.Head -ErrorAction Stop).Path } catch { $headResolved = $stagingInfo.Head }
      if ($stagingInfo.PSObject.Properties['AllowSameLeaf']) {
        $allowSameLeafValue = $false
        try { $allowSameLeafValue = [bool]$stagingInfo.AllowSameLeaf } catch { $allowSameLeafValue = $false }
        if ($allowSameLeafValue) { $stageAllowSameLeaf = $true }
      }
      $baseLeaf = Split-Path -Leaf $baseResolved
      $headLeaf = Split-Path -Leaf $headResolved
    }
    if ($baseLeaf -and $headLeaf -and $baseResolved -ne $headResolved -and [string]::Equals($baseLeaf, $headLeaf, [System.StringComparison]::OrdinalIgnoreCase) -and -not $stageAllowSameLeaf) {
      throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeaf' located in different directories. Rename one copy or provide distinct filenames. Base=$baseResolved Head=$headResolved"
    }
  }
  $Base = $baseResolved
  $Head = $headResolved

  New-DirIfMissing -Path $OutDir
  $reportPath = $null
  $reportInfo = Resolve-ReportFormatInfo -Format $ReportFormat
  $reportFormatEffective = $reportInfo.normalized
  $reportType = $reportInfo.cliType
  $reportFileName = $reportInfo.fileName
  $shouldGenerateReport = $RenderReport.IsPresent -or ($reportFormatEffective -ne 'html')
  if ($shouldGenerateReport) {
    $reportPath = Join-Path $OutDir $reportFileName
  }
  $syntheticReportPath = $false
  if (-not $reportPath) {
    $reportPath = Join-Path $OutDir 'cli-compare-report.html'
    $syntheticReportPath = $true
  }

  $stdoutPath = Join-Path $OutDir 'lvcli-stdout.txt'
  $stderrPath = Join-Path $OutDir 'lvcli-stderr.txt'
  $capPath    = Join-Path $OutDir 'lvcompare-capture.json'

  $invokeParams = @{
    BaseVi = (Resolve-Path -LiteralPath $Base).Path
    HeadVi = (Resolve-Path -LiteralPath $Head).Path
  }
  if ($LabVIEWExePath) {
    $invokeParams.LabVIEWPath = $LabVIEWExePath
  }
  if ($reportPath) {
    $invokeParams.ReportPath = $reportPath
    $invokeParams.ReportType = $reportType
  }

  if ($Flags) {
    $filteredFlags = @()
    for ($i = 0; $i -lt $Flags.Count; $i++) {
      $flagValue = [string]$Flags[$i]
      if ($flagValue -and ($flagValue.Equals('-lvpath', 'InvariantCultureIgnoreCase') -or $flagValue.Equals('-labviewpath', 'InvariantCultureIgnoreCase'))) {
        $i++
        continue
      }
      $filteredFlags += $flagValue
    }
    if ($filteredFlags.Count -gt 0) {
      $invokeParams.Flags = @($filteredFlags)
    }
  }

  if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -gt 0) {
    $invokeParams.TimeoutSeconds = $TimeoutSeconds
  }

  $cliResult = Invoke-LVCreateComparisonReport @invokeParams

  Set-Content -LiteralPath $stdoutPath -Value ($cliResult.stdout ?? '') -Encoding utf8
  Set-Content -LiteralPath $stderrPath -Value ($cliResult.stderr ?? '') -Encoding utf8

  $envBlockOrdered = [ordered]@{
    compareMode   = $env:LVCI_COMPARE_MODE
    comparePolicy = $env:LVCI_COMPARE_POLICY
  }

  $cliPath = $cliResult.cliPath
  $cliInfoOrdered = [ordered]@{
    path          = $cliPath
    reportFormat  = $reportFormatEffective
  }
  $cliVer = Get-FileProductVersion -Path $cliPath
  if ($cliVer) { $cliInfoOrdered.version = $cliVer }
  if ($reportPath) { $cliInfoOrdered.reportPath = $reportPath }
  if ($cliResult.normalizedParams -and $cliResult.normalizedParams.PSObject.Properties.Name -contains 'reportPath' -and $cliResult.normalizedParams.reportPath) {
    $cliInfoOrdered.reportPath = $cliResult.normalizedParams.reportPath
  }
  if ($cliResult.normalizedParams -and $cliResult.normalizedParams.PSObject.Properties.Name -contains 'reportType' -and $cliResult.normalizedParams.reportType) {
    $cliInfoOrdered.reportType = $cliResult.normalizedParams.reportType
  }

  $cliMeta = Get-LabVIEWCliOutputMetadata -StdOut $cliResult.stdout -StdErr $cliResult.stderr
  if ($cliMeta) {
    foreach ($name in @('reportType','reportPath','status','message')) {
      if ($cliMeta.PSObject.Properties.Name -contains $name -and $cliMeta.$name) {
        $cliInfoOrdered[$name] = $cliMeta.$name
      }
    }
  }

  if ($cliResult -and $cliResult.PSObject.Properties['skipped'] -and $cliResult.skipped) {
    $cliInfoOrdered.skipped = $true
    if ($cliResult.PSObject.Properties['skipReason'] -and $cliResult.skipReason) {
      $cliInfoOrdered.skipReason = [string]$cliResult.skipReason
    }
  }

  $artifactPath = $null
  if ($cliInfoOrdered.Contains('reportPath') -and $cliInfoOrdered['reportPath']) {
    $artifactPath = $cliInfoOrdered['reportPath']
  } elseif ($reportPath -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    $artifactPath = $reportPath
  }
  if ($artifactPath) {
    try {
      $artifacts = Get-CliReportArtifacts -ReportPath $artifactPath -OutputDir $OutDir
      if ($artifacts) { $cliInfoOrdered.artifacts = $artifacts }
    } catch {}
  }

  if ($syntheticReportPath -and -not $shouldGenerateReport) {
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
      if ($cliInfoOrdered.Contains('reportPath')) {
        $cliInfoOrdered.Remove('reportPath')
      }
    }
  }

  $cliInfoObject = [pscustomobject]$cliInfoOrdered
  $envBlockOrdered.cli = $cliInfoObject
  $envBlock = [pscustomobject]$envBlockOrdered

  $capture = [pscustomobject]@{
    schema    = 'lvcompare-capture-v1'
    timestamp = ([DateTime]::UtcNow.ToString('o'))
    base      = (Resolve-Path -LiteralPath $Base).Path
    head      = (Resolve-Path -LiteralPath $Head).Path
    cliPath   = $cliResult.cliPath
    args      = @($cliResult.args)
    exitCode  = [int]$cliResult.exitCode
    seconds   = [Math]::Round([double]$cliResult.elapsedSeconds, 6)
    stdoutLen = ($cliResult.stdout ?? '').Length
    stderrLen = ($cliResult.stderr ?? '').Length
    command   = $cliResult.command
    stdout    = $null
    stderr    = $null
  }
  $capture | Add-Member -NotePropertyName environment -NotePropertyValue $envBlock -Force
  $capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capPath -Encoding utf8

  $resultObject = [pscustomobject]@{
    ExitCode   = [int]$cliResult.exitCode
    Seconds    = [double]$cliResult.elapsedSeconds
    CapturePath= $capPath
    ReportPath = if ((Test-Path -LiteralPath $reportPath -PathType Leaf)) { $reportPath } elseif ($cliInfoOrdered.Contains('reportPath')) { $cliInfoOrdered['reportPath'] } else { $null }
    Command    = $cliResult.command
  }

  if ($syntheticReportPath -and -not $shouldGenerateReport -and -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    $reportPath = $null
  }

  if ($stageCleanupRoot) {
    try {
      if (Test-Path -LiteralPath $stageCleanupRoot -PathType Container) {
        Remove-Item -LiteralPath $stageCleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }

  return $resultObject
}

$repoRoot = (Resolve-Path '.').Path
New-DirIfMissing -Path $OutputDir
Initialize-LabVIEWPidTracker
Set-DefaultLabVIEWCliPath

$originalBaseVi = $BaseVi
$originalHeadVi = $HeadVi
$stageCleanupRoot = $null

try {

# Resolve LabVIEW path (prefer explicit/env LABVIEW_PATH; fallback to 2025 canonical by bitness)
if (-not $LabVIEWExePath) {
  if ($env:LABVIEW_PATH) { $LabVIEWExePath = $env:LABVIEW_PATH }
}
if (-not $LabVIEWExePath) {
  $parent = if ($LabVIEWBitness -eq '32') { ${env:ProgramFiles(x86)} } else { ${env:ProgramFiles} }
  if ($parent) { $LabVIEWExePath = Join-Path $parent 'National Instruments\LabVIEW 2025\LabVIEW.exe' }
}
if (-not $LabVIEWExePath -or -not (Test-Path -LiteralPath $LabVIEWExePath -PathType Leaf)) {
  $expectedParent = if ($LabVIEWBitness -eq '32') { ${env:ProgramFiles(x86)} } else { ${env:ProgramFiles} }
  $expected = if ($expectedParent) { Join-Path $expectedParent 'National Instruments\LabVIEW 2025\LabVIEW.exe' } else { '(unknown ProgramFiles)' }
  $labviewPathMessage = "Invoke-LVCompare: LabVIEWExePath could not be resolved. Set LABVIEW_PATH or pass -LabVIEWExePath. Expected canonical for bitness {0}: {1}" -f $LabVIEWBitness, $expected
  Write-Error $labviewPathMessage
  Finalize-LabVIEWPidTracker -Status 'error' -ExitCode 2 -ProcessExitCode 2 -Message $labviewPathMessage
  exit 2
}

$labviewSccEnabled = $false
$labviewIniPath = $null
try { $labviewIniPath = Get-LabVIEWIniPath -LabVIEWExePath $LabVIEWExePath } catch {}
if ($labviewIniPath) {
  try {
    $sccUseValue = Get-LabVIEWIniValue -LabVIEWIniPath $labviewIniPath -Key 'SCCUseInLabVIEW'
    $sccProviderValue = Get-LabVIEWIniValue -LabVIEWIniPath $labviewIniPath -Key 'SCCProviderIsActive'
    $sccUseEnabled = ($sccUseValue -and ($sccUseValue.Trim() -ieq 'True'))
    $sccProviderEnabled = ($sccProviderValue -and ($sccProviderValue.Trim() -ieq 'True'))
    if ($sccUseEnabled -or $sccProviderEnabled) { $labviewSccEnabled = $true }
  } catch {}
}
if ($labviewSccEnabled) {
  $hint = Get-SourceControlBootstrapHint
  $message = "Invoke-LVCompare: LabVIEW source control is enabled in '$labviewIniPath'. Disable Source Control in LabVIEW (Tools -> Options -> Source Control) or set SCCUseInLabVIEW=False before running headless comparisons."
  if ($hint -and $message -notmatch 'SCC_ConnSrv') { $message = "$message; $hint" }
  Write-Warning $message
  Write-JsonEvent 'error' @{ stage='preflight'; message=$message }
  Finalize-LabVIEWPidTracker -Status 'error' -ExitCode 2 -ProcessExitCode 2 -Message $message
  exit 2
}

  # Compose flags list: -lvpath then normalization flags
$defaultFlags = switch ($NoiseProfile) {
  'legacy' { @('-noattr','-nofp','-nofppos','-nobd','-nobdcosm') }
  default  { @() }
}
$effectiveFlags = @()
if ($LabVIEWExePath) { $effectiveFlags += @('-lvpath', $LabVIEWExePath) }
if ($ReplaceFlags.IsPresent) {
  if ($Flags) { $effectiveFlags += $Flags }
} else {
  $effectiveFlags += $defaultFlags
  if ($Flags) { $effectiveFlags += $Flags }
}

$baseNameOriginal = Split-Path -Path $BaseVi -Leaf
$headNameOriginal = Split-Path -Path $HeadVi -Leaf
$sameNameOriginal = [string]::Equals($baseNameOriginal, $headNameOriginal, [System.StringComparison]::OrdinalIgnoreCase)

$baseResolvedForStage = $null
$headResolvedForStage = $null
try { $baseResolvedForStage = (Resolve-Path -LiteralPath $BaseVi -ErrorAction Stop).Path } catch {}
try { $headResolvedForStage = (Resolve-Path -LiteralPath $HeadVi -ErrorAction Stop).Path } catch {}
$stageAllowSameLeafOuter = $AllowSameLeaf.IsPresent
if ($baseResolvedForStage -and $headResolvedForStage -and $baseResolvedForStage -ne $headResolvedForStage) {
  $baseLeafStage = Split-Path -Leaf $baseResolvedForStage
  $headLeafStage = Split-Path -Leaf $headResolvedForStage
  if ($baseLeafStage -and $headLeafStage -and [string]::Equals($baseLeafStage, $headLeafStage, [System.StringComparison]::OrdinalIgnoreCase)) {
    $stageScript = Join-Path $PSScriptRoot 'Stage-CompareInputs.ps1'
    if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
      throw "LVCompare limitation: Cannot compare two VIs sharing the same filename '$baseLeafStage' located in different directories. Rename one copy or provide distinct filenames. Base=$baseResolvedForStage Head=$headResolvedForStage"
    }
    try {
      $stagingInfo = & $stageScript -BaseVi $baseResolvedForStage -HeadVi $headResolvedForStage
    } catch {
      throw ("Invoke-LVCompare: staging failed -> {0}" -f $_.Exception.Message)
    }
    if (-not $stagingInfo) { throw 'Invoke-LVCompare: Stage-CompareInputs.ps1 returned no staging information.' }
    if ($stagingInfo.Root) { $stageCleanupRoot = $stagingInfo.Root }
    try { $BaseVi = (Resolve-Path -LiteralPath $stagingInfo.Base -ErrorAction Stop).Path } catch { $BaseVi = $stagingInfo.Base }
    try { $HeadVi = (Resolve-Path -LiteralPath $stagingInfo.Head -ErrorAction Stop).Path } catch { $HeadVi = $stagingInfo.Head }
    if ($stagingInfo.PSObject.Properties['AllowSameLeaf']) {
      $allowSameLeafValueOuter = $false
      try { $allowSameLeafValueOuter = [bool]$stagingInfo.AllowSameLeaf } catch { $allowSameLeafValueOuter = $false }
      if ($allowSameLeafValueOuter) { $stageAllowSameLeafOuter = $true }
    }
  }
}

$baseName = Split-Path -Path $BaseVi -Leaf
$headName = Split-Path -Path $HeadVi -Leaf
$sameName = [string]::Equals($baseName, $headName, [System.StringComparison]::OrdinalIgnoreCase)

$reportInfo = Resolve-ReportFormatInfo -Format $ReportFormat
$reportFormatEffective = $reportInfo.normalized
$reportFileName = $reportInfo.fileName

 $policy = $env:LVCI_COMPARE_POLICY
 if ([string]::IsNullOrWhiteSpace($policy)) { $policy = 'cli-only' }
 $mode   = $env:LVCI_COMPARE_MODE
 if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'labview-cli' }
 $autoCli = $false
 if ($sameNameOriginal -and $policy -ne 'lv-only') {
   $autoCli = $true
   if ($mode -ne 'labview-cli') { $mode = 'labview-cli' }
 }

Write-JsonEvent 'plan' @{
  base      = $BaseVi
  head      = $HeadVi
  baseOriginal = $originalBaseVi
  headOriginal = $originalHeadVi
  staged    = [bool]($stageCleanupRoot)
  sameNameOriginal = $sameNameOriginal
  lvpath    = $LabVIEWExePath
  lvcompare = $LVComparePath
  flags     = ($effectiveFlags -join ' ')
  out       = $OutputDir
  report    = $RenderReport.IsPresent
  reportFormat = $reportFormatEffective
  policy    = $policy
  mode      = $mode
  sameName  = $sameName
  autoCli   = $autoCli
}

 # Decide execution path based on compare policy/mode
 $didCli = $false
if (-not $CaptureScriptPath -and (($policy -eq 'cli-only') -or $autoCli -or ($mode -eq 'labview-cli' -and $policy -ne 'lv-only'))) {
  try {
   $cliParams = @{
     Base         = $BaseVi
     Head         = $HeadVi
     OutDir       = $OutputDir
     RenderReport = $RenderReport.IsPresent
     Flags        = $effectiveFlags
     ReportFormat = $ReportFormat
   }
   if ($stageAllowSameLeafOuter) { $cliParams.AllowSameLeaf = $true }
   if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -gt 0) {
     $cliParams.TimeoutSeconds = [int]$TimeoutSeconds
   }
   $cliRes = Invoke-LabVIEWCLICompare @cliParams
    if (-not $cliRes) { throw 'LabVIEW CLI compare returned no result payload.' }
    $reportAvailable = $false
    if ($cliRes -and $cliRes.PSObject.Properties['ReportPath'] -and $cliRes.ReportPath) {
      try { $reportAvailable = Test-Path -LiteralPath $cliRes.ReportPath -PathType Leaf } catch { $reportAvailable = $false }
    }
    Write-JsonEvent 'result' @{ exitCode=$cliRes.ExitCode; seconds=$cliRes.Seconds; command=$cliRes.Command; report=$reportAvailable }
    $didCli = $true
   } catch {
     Write-JsonEvent 'error' @{ stage='cli-capture'; message=$_.Exception.Message }
     if ($policy -eq 'cli-only') {
       Finalize-LabVIEWPidTracker -Status 'error' -ExitCode 2 -ProcessExitCode 2 -Message $_.Exception.Message -Mode $mode -Policy $policy -AutoCli $autoCli -DidCli $true
       throw
     }
   }
 }

 if (-not $didCli) {
   # Fallback to LVCompare capture path
   if ($CaptureScriptPath) { $captureScript = $CaptureScriptPath } else { $captureScript = Join-Path $repoRoot 'scripts' 'Capture-LVCompare.ps1' }
  if (-not (Test-Path -LiteralPath $captureScript -PathType Leaf)) { throw "Capture-LVCompare.ps1 not found at $captureScript" }
  try {
  $captureParams = @{
      Base         = $BaseVi
      Head         = $HeadVi
      LvArgs       = $effectiveFlags
      RenderReport = $RenderReport.IsPresent
      OutputDir    = $OutputDir
      Quiet        = $Quiet.IsPresent
    }
  if (-not $LVComparePath) { try { $LVComparePath = Resolve-LVComparePath } catch {} }
  if ($LVComparePath) { $captureParams.LvComparePath = $LVComparePath }
  if ($stageAllowSameLeafOuter) { $captureParams.AllowSameLeaf = $true }
  if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -gt 0) {
    $captureParams.TimeoutSeconds = [int]$TimeoutSeconds
  }
  & $captureScript @captureParams
  } catch {
   $message = $_.Exception.Message
   if ($_.Exception -is [System.Management.Automation.PropertyNotFoundException] -and $message -match "property 'Count'") {
     $hint = Get-SourceControlBootstrapHint
     if ($message -notmatch 'SCC_ConnSrv') { $message = "$message; $hint" }
   }
   Write-JsonEvent 'error' @{ stage='capture'; message=$message }
   Write-Warning ("Invoke-LVCompare: capture failure -> {0}" -f $message)
   if ($_.InvocationInfo) { Write-Warning $_.InvocationInfo.PositionMessage }
   Finalize-LabVIEWPidTracker -Status 'error' -ExitCode 2 -ProcessExitCode 2 -Message $message -Mode $mode -Policy $policy -AutoCli $autoCli -DidCli $didCli
   throw (New-Object System.Management.Automation.RuntimeException($message, $_.Exception))
  }
}

# Read capture JSON to surface exit code and command
$capPath = Join-Path $OutputDir 'lvcompare-capture.json'
if (-not (Test-Path -LiteralPath $capPath -PathType Leaf)) {
  $missingMessage = 'missing capture json'
  $hint = Get-SourceControlBootstrapHint
  if ($missingMessage -notmatch 'SCC_ConnSrv') { $missingMessage = "$missingMessage; $hint" }
  Write-JsonEvent 'error' @{ stage='post'; message=$missingMessage }
  Finalize-LabVIEWPidTracker -Status 'error' -ExitCode 2 -ProcessExitCode 2 -Message $missingMessage -Mode $mode -Policy $policy -AutoCli $autoCli -DidCli $didCli
  Write-Error $missingMessage
  exit 2
}
$cap = Get-Content -LiteralPath $capPath -Raw | ConvertFrom-Json
if (-not $cap) {
  $parseMessage = 'unable to parse capture json'
  $hint = Get-SourceControlBootstrapHint
  if ($parseMessage -notmatch 'SCC_ConnSrv') { $parseMessage = "$parseMessage; $hint" }
  Write-JsonEvent 'error' @{ stage='post'; message=$parseMessage }
  Finalize-LabVIEWPidTracker -Status 'error' -ExitCode 2 -ProcessExitCode 2 -Message $parseMessage -Mode $mode -Policy $policy -AutoCli $autoCli -DidCli $didCli
  Write-Error $parseMessage
  exit 2
}

$exitCode = [int]$cap.exitCode
$duration = [double]$cap.seconds
$reportPath = Join-Path $OutputDir $reportFileName
$reportExists = Test-Path -LiteralPath $reportPath -PathType Leaf
Write-JsonEvent 'result' @{ exitCode=$exitCode; seconds=$duration; command=$cap.command; report=$reportExists; reportFormat=$reportFormatEffective }

$trackerStatus = switch ($exitCode) {
  1 { 'diff' }
  0 { 'ok' }
  default { 'error' }
}
Finalize-LabVIEWPidTracker -Status $trackerStatus -ExitCode $exitCode -CompareExitCode $exitCode -ProcessExitCode $exitCode -Command $cap.command -CapturePath $capPath -ReportGenerated $reportExists -DiffDetected ($exitCode -eq 1) -Mode $mode -Policy $policy -AutoCli $autoCli -DidCli $didCli

function Stop-LeakedLabVIEW {
  param(
    [string]$LabVIEWExePath,
    [string]$Context
  )
  $existing = @()
  try { $existing = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue) } catch {}
  if ($existing.Count -eq 0) { return $false }

  Write-JsonEvent 'info' @{
    stage   = 'post-compare'
    action  = 'close-labview'
    context = $Context
    pids    = @($existing.Id)
  }

  $closeSucceeded = $false
  $params = @{}
  if ($LabVIEWExePath) { $params.labviewPath = $LabVIEWExePath }

  try {
    $result = Invoke-LVOperation -Operation 'CloseLabVIEW' -Params $params
    if ($result -and $result.PSObject.Properties['exitCode'] -and $result.exitCode -eq 0) {
      $closeSucceeded = $true
    }
  } catch {
    Write-Warning ("Invoke-LVCompare: CloseLabVIEW provider call failed ({0}). Falling back to Close-LabVIEW.ps1." -f $_.Exception.Message)
  }

  if (-not $closeSucceeded) {
    $closeScript = Join-Path $repoRoot 'tools' 'Close-LabVIEW.ps1'
    if (Test-Path -LiteralPath $closeScript -PathType Leaf) {
      $scriptArgs = @()
      if ($LabVIEWExePath) {
        $scriptArgs += '-LabVIEWExePath'
        $scriptArgs += $LabVIEWExePath
      }
      try {
        & pwsh '-NoLogo' '-NoProfile' '-File' $closeScript @scriptArgs
        $closeSucceeded = $true
      } catch {
        Write-Warning ("Invoke-LVCompare: Close-LabVIEW.ps1 fallback failed: {0}" -f $_.Exception.Message)
      }
    } else {
      Write-Warning ("Invoke-LVCompare: Close-LabVIEW.ps1 fallback unavailable at {0}" -f $closeScript)
    }
  }

  Start-Sleep -Milliseconds 250
  $remaining = @()
  try { $remaining = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue) } catch {}
  if ($remaining.Count -gt 0) {
    Write-Warning ("Invoke-LVCompare: LabVIEW.exe still running after close attempt (PIDs: {0}). Forcing termination." -f ($remaining.Id -join ','))
    try {
      Stop-Process -Id $remaining.Id -Force -ErrorAction Stop
      Start-Sleep -Milliseconds 250
      $remaining = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
    } catch {
      Write-Warning ("Invoke-LVCompare: Stop-Process failed: {0}" -f $_.Exception.Message)
    }
  }
  if ($remaining.Count -gt 0) {
    Write-Warning ("Invoke-LVCompare: LabVIEW.exe remains after forced termination attempt (PIDs: {0})." -f ($remaining.Id -join ','))
    return $false
  }
  return $closeSucceeded
}

function Get-LeakProcessMetadata {
  param([int[]]$ProcessIds)
  $details = @()
  foreach ($processId in $ProcessIds) {
    if ($processId -le 0) { continue }
    $record = [ordered]@{
      pid = $processId
      name = $null
      commandLine = $null
      executablePath = $null
      creationDate = $null
      creationDateRaw = $null
      creationDateError = $null
      error = $null
    }
    try {
      $proc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
      if ($proc) {
        $record.name = $proc.Name
        $record.commandLine = $proc.CommandLine
        $record.executablePath = $proc.ExecutablePath
        if ($proc.CreationDate) {
          $record.creationDateRaw = $proc.CreationDate
          try {
            $record.creationDate = [System.Management.ManagementDateTimeConverter]::ToDateTime($proc.CreationDate).ToString('o')
          } catch {
            $record.creationDateError = $_.Exception.Message
          }
        }
      }
    } catch {
      $record.error = $_.Exception.Message
    }
    $details += [pscustomobject]$record
  }
  return $details
}

Stop-LeakedLabVIEW -LabVIEWExePath $LabVIEWExePath -Context 'post-summary'

if ($LeakCheck) {
  if (-not $LeakJsonPath) { $LeakJsonPath = Join-Path $OutputDir 'compare-leak.json' }
  if ($LeakGraceSeconds -gt 0) { Start-Sleep -Seconds $LeakGraceSeconds }
  $lvcomparePids = @(); $labviewPids = @()
  try { $lvcomparePids = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
  try { $labviewPids   = @(Get-Process -Name 'LabVIEW'   -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
  $lvcompareDetails = if ($lvcomparePids.Count -gt 0) { Get-LeakProcessMetadata -ProcessIds $lvcomparePids } else { @() }
  $labviewDetails   = if ($labviewPids.Count -gt 0) { Get-LeakProcessMetadata -ProcessIds $labviewPids } else { @() }
  $leak = [ordered]@{
    schema = 'prime-lvcompare-leak/v1'
    at     = (Get-Date).ToString('o')
    lvcompare = @{
      remaining = $lvcomparePids
      count     = ($lvcomparePids|Measure-Object).Count
      details   = $lvcompareDetails
    }
    labview   = @{
      remaining = $labviewPids
      count     = ($labviewPids|Measure-Object).Count
      details   = $labviewDetails
    }
  }
  $dir = Split-Path -Parent $LeakJsonPath; if ($dir -and -not (Test-Path $dir)) { New-DirIfMissing -Path $dir }
  $leak | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LeakJsonPath -Encoding utf8
  Write-JsonEvent 'leak-check' @{ lvcompareCount=$leak.lvcompare.count; labviewCount=$leak.labview.count; path=$LeakJsonPath; lvcomparePids=$lvcomparePids; labviewPids=$labviewPids }
}

if ($Summary) {
  $line = "Compare Outcome: exit=$exitCode diff=$([bool]($exitCode -eq 1)) seconds=$duration"
  Write-Host $line -ForegroundColor Yellow
  if ($labviewPidTrackerPath) {
    Write-Host ("LabVIEW PID Tracker recorded at {0}" -f $labviewPidTrackerPath) -ForegroundColor DarkGray
  }
  if ($env:GITHUB_STEP_SUMMARY) {
    try {
      $lines = @('## Compare Outcome')
      $lines += ("- Exit: {0}" -f $exitCode)
      $lines += ("- Diff: {0}" -f ([bool]($exitCode -eq 1)))
      $lines += ("- Duration: {0}s" -f $duration)
      $lines += ("- Capture: {0}" -f $capPath)
      $lines += ("- Report: {0}" -f $reportExists)
      if ($labviewPidTrackerPath) {
        $lines += ("- LabVIEW PID Tracker: {0}" -f $labviewPidTrackerPath)
        if ($labviewPidTrackerFinalState -and $labviewPidTrackerFinalState.PSObject.Properties['Context'] -and $labviewPidTrackerFinalState.Context) {
          $trackerContext = $labviewPidTrackerFinalState.Context
          if ($trackerContext.PSObject.Properties['status'] -and $trackerContext.status) {
            $lines += ("  - Status: {0}" -f $trackerContext.status)
          }
          if ($trackerContext.PSObject.Properties['compareExitCode'] -and $trackerContext.compareExitCode -ne $null) {
            $lines += ("  - Compare Exit Code: {0}" -f $trackerContext.compareExitCode)
          }
        }
      }
      Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n") -Encoding utf8
    } catch { Write-Warning ("Invoke-LVCompare: failed step summary append: {0}" -f $_.Exception.Message) }
  }
}

exit $exitCode
} finally {
  if ($stageCleanupRoot) {
    try {
      if (Test-Path -LiteralPath $stageCleanupRoot -PathType Container) {
        Remove-Item -LiteralPath $stageCleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
}
