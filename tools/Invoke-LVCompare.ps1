<#
.SYNOPSIS
  Deterministic driver for LVCompare.exe with capture and optional HTML report.

.DESCRIPTION
  Wraps the repository's capture pipeline to run LVCompare against two VIs with
  stable arguments, explicit LabVIEW selection via -lvpath, and NDJSON crumbs.
  Produces standard artifacts under the chosen OutputDir:
    - lvcompare-capture.json (schema lvcompare-capture-v1)
    - compare-report.html (when -RenderReport)
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
  Additional LVCompare flags. Defaults to -nobdcosm -nofppos -noattr unless
  -ReplaceFlags is used.

.PARAMETER ReplaceFlags
  Replace default flags entirely with the provided -Flags.

.PARAMETER OutputDir
  Target directory for artifacts (default: tests/results/single-compare).

.PARAMETER RenderReport
  Emit compare-report.html (default: enabled).

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
  [string]$OutputDir = 'tests/results/single-compare',
  [switch]$RenderReport,
  [string]$JsonLogPath,
  [switch]$Quiet,
  [switch]$LeakCheck,
  [string]$LeakJsonPath,
  [string]$CaptureScriptPath,
  [switch]$Summary,
  [double]$LeakGraceSeconds = 0.5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
    [string[]]$Flags
  )

  New-DirIfMissing -Path $OutDir
  $reportPath = $null
  if ($RenderReport.IsPresent) {
    $reportPath = Join-Path $OutDir 'cli-report.html'
  }

  $stdoutPath = Join-Path $OutDir 'lvcli-stdout.txt'
  $stderrPath = Join-Path $OutDir 'lvcli-stderr.txt'
  $capPath    = Join-Path $OutDir 'lvcompare-capture.json'

  $invokeParams = @{
    BaseVi = (Resolve-Path -LiteralPath $Base).Path
    HeadVi = (Resolve-Path -LiteralPath $Head).Path
  }
  if ($reportPath) {
    $invokeParams.ReportPath = $reportPath
    $invokeParams.ReportType = 'HTMLSingleFile'
  }

  if ($Flags) {
    $invokeParams.Flags = @($Flags)
  }

  $cliResult = Invoke-LVCreateComparisonReport @invokeParams

  Set-Content -LiteralPath $stdoutPath -Value ($cliResult.stdout ?? '') -Encoding utf8
  Set-Content -LiteralPath $stderrPath -Value ($cliResult.stderr ?? '') -Encoding utf8

  $envBlockOrdered = [ordered]@{
    compareMode   = $env:LVCI_COMPARE_MODE
    comparePolicy = $env:LVCI_COMPARE_POLICY
  }

  $cliPath = $cliResult.cliPath
  $cliInfoOrdered = [ordered]@{ path = $cliPath }
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

  return [pscustomobject]@{
    ExitCode   = [int]$cliResult.exitCode
    Seconds    = [double]$cliResult.elapsedSeconds
    CapturePath= $capPath
    ReportPath = if ($reportPath) { $reportPath } else { $cliInfoOrdered['reportPath'] }
    Command    = $cliResult.command
  }
}

$repoRoot = (Resolve-Path '.').Path
New-DirIfMissing -Path $OutputDir
Initialize-LabVIEWPidTracker
Set-DefaultLabVIEWCliPath

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

# Compose flags list: -lvpath then normalization flags
$defaultFlags = @('-nobdcosm','-nofppos','-noattr')
$effectiveFlags = @()
if ($LabVIEWExePath) { $effectiveFlags += @('-lvpath', $LabVIEWExePath) }
if ($ReplaceFlags.IsPresent) {
  if ($Flags) { $effectiveFlags += $Flags }
} else {
  $effectiveFlags += $defaultFlags
  if ($Flags) { $effectiveFlags += $Flags }
}

$baseName = Split-Path -Path $BaseVi -Leaf
$headName = Split-Path -Path $HeadVi -Leaf
$sameName = [string]::Equals($baseName, $headName, [System.StringComparison]::OrdinalIgnoreCase)

 $policy = $env:LVCI_COMPARE_POLICY
 if ([string]::IsNullOrWhiteSpace($policy)) { $policy = 'cli-only' }
 $mode   = $env:LVCI_COMPARE_MODE
 if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'labview-cli' }
 $autoCli = $false
 if ($sameName -and $policy -ne 'lv-only') {
   $autoCli = $true
   if ($mode -ne 'labview-cli') { $mode = 'labview-cli' }
 }

Write-JsonEvent 'plan' @{
  base      = $BaseVi
  head      = $HeadVi
  lvpath    = $LabVIEWExePath
  lvcompare = $LVComparePath
  flags     = ($effectiveFlags -join ' ')
  out       = $OutputDir
  report    = $RenderReport.IsPresent
  policy    = $policy
  mode      = $mode
  sameName  = $sameName
  autoCli   = $autoCli
}

 # Decide execution path based on compare policy/mode
 $didCli = $false
 if (($policy -eq 'cli-only') -or $autoCli -or ($mode -eq 'labview-cli' -and $policy -ne 'lv-only')) {
   try {
     $cliRes = Invoke-LabVIEWCLICompare -Base $BaseVi -Head $HeadVi -OutDir $OutputDir -RenderReport:$RenderReport.IsPresent -Flags $effectiveFlags
     Write-JsonEvent 'result' @{ exitCode=$cliRes.ExitCode; seconds=$cliRes.Seconds; command=$cliRes.Command; report=(Test-Path $cliRes.ReportPath) }
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
$reportPath = Join-Path $OutputDir 'compare-report.html'
$reportExists = Test-Path -LiteralPath $reportPath -PathType Leaf
Write-JsonEvent 'result' @{ exitCode=$exitCode; seconds=$duration; command=$cap.command; report=$reportExists }

$trackerStatus = switch ($exitCode) {
  1 { 'diff' }
  0 { 'ok' }
  default { 'error' }
}
Finalize-LabVIEWPidTracker -Status $trackerStatus -ExitCode $exitCode -CompareExitCode $exitCode -ProcessExitCode $exitCode -Command $cap.command -CapturePath $capPath -ReportGenerated $reportExists -DiffDetected ($exitCode -eq 1) -Mode $mode -Policy $policy -AutoCli $autoCli -DidCli $didCli

if ($LeakCheck) {
  if (-not $LeakJsonPath) { $LeakJsonPath = Join-Path $OutputDir 'compare-leak.json' }
  if ($LeakGraceSeconds -gt 0) { Start-Sleep -Seconds $LeakGraceSeconds }
  $lvcomparePids = @(); $labviewPids = @()
  try { $lvcomparePids = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
  try { $labviewPids   = @(Get-Process -Name 'LabVIEW'   -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
  $leak = [ordered]@{
    schema = 'prime-lvcompare-leak/v1'
    at     = (Get-Date).ToString('o')
    lvcompare = @{ remaining=$lvcomparePids; count=($lvcomparePids|Measure-Object).Count }
    labview   = @{ remaining=$labviewPids;   count=($labviewPids  |Measure-Object).Count }
  }
  $dir = Split-Path -Parent $LeakJsonPath; if ($dir -and -not (Test-Path $dir)) { New-DirIfMissing -Path $dir }
  $leak | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LeakJsonPath -Encoding utf8
  Write-JsonEvent 'leak-check' @{ lvcompareCount=$leak.lvcompare.count; labviewCount=$leak.labview.count; path=$LeakJsonPath }
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

