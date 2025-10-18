param(
  [string]$SearchDir = '.',
  [string]$OutJson = 'compare-outcome.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { $resolvedDir = (Resolve-Path -LiteralPath $SearchDir -ErrorAction Stop).Path } catch { $resolvedDir = $SearchDir }

$capturePath = @(Get-ChildItem -Path $resolvedDir -Recurse -Include lvcompare-capture.json -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName) | Sort-Object -Descending | Select-Object -First 1
$execPath    = @(Get-ChildItem -Path $resolvedDir -Recurse -Include compare-exec.json    -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName) | Sort-Object -Descending | Select-Object -First 1

$summaryLines = @('### Compare Outcome','')

$payload = [ordered]@{
  source      = 'missing'
  file        = $null
  diff        = $null
  exitCode    = $null
  durationMs  = $null
  cliPath     = $null
  command     = $null
  stdoutPath  = $null
  stdoutLen   = $null
  stderrPath  = $null
  stderrLen   = $null
  reportPath  = $null
  cliArtifacts= $null
  captureJson = $capturePath
  capture     = [ordered]@{ status = 'missing'; reason = 'no_capture_json'; path = $capturePath }
  compareExec = [ordered]@{ status = 'missing'; reason = 'no_exec_json'; path = $execPath }
}

if ($capturePath -and (Test-Path -LiteralPath $capturePath)) {
  try {
    $cap = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 6
    $payload.capture.status = 'ok'
    $payload.capture.reason = $null
    $payload.source = 'capture'
    $payload.file = $capturePath
    if ($cap.exitCode -ne $null) { $payload.exitCode = [int]$cap.exitCode }
    if ($cap.command) { $payload.command = [string]$cap.command }
    if ($cap.cliPath) { $payload.cliPath = [string]$cap.cliPath }
    if ($cap.seconds -ne $null) { $payload.durationMs = [math]::Round([double]$cap.seconds * 1000,3) }
    if ($payload.exitCode -ne $null) { $payload.diff = ($payload.exitCode -eq 1) }
    if ($cap.stdoutLen -ne $null) { $payload.stdoutLen = [int]$cap.stdoutLen }
    if ($cap.stderrLen -ne $null) { $payload.stderrLen = [int]$cap.stderrLen }
    $capDir = Split-Path -Parent $capturePath
    $stdoutCandidate = Join-Path $capDir 'lvcompare-stdout.txt'
    if (Test-Path -LiteralPath $stdoutCandidate) { $payload.stdoutPath = $stdoutCandidate }
    $stderrCandidate = Join-Path $capDir 'lvcompare-stderr.txt'
    if (Test-Path -LiteralPath $stderrCandidate) { $payload.stderrPath = $stderrCandidate }
    $reportCandidate = Join-Path $capDir 'compare-report.html'
    if (Test-Path -LiteralPath $reportCandidate) { $payload.reportPath = $reportCandidate }
    $cliArtifacts = $null
    $capEnv = $null
    if ($cap.PSObject.Properties['environment']) { $capEnv = $cap.environment }
    if ($capEnv -and $capEnv.PSObject.Properties['cli']) {
      $capCli = $capEnv.cli
      if ($capCli -and $capCli.PSObject.Properties['artifacts']) { $cliArtifacts = $capCli.artifacts }
    }
    if ($cliArtifacts) {
      $artifactSummary = [ordered]@{}
      if ($cliArtifacts.PSObject.Properties.Name -contains 'reportSizeBytes' -and $cliArtifacts.reportSizeBytes -ne $null) {
        $artifactSummary.reportSizeBytes = [long]$cliArtifacts.reportSizeBytes
      }
      if ($cliArtifacts.PSObject.Properties.Name -contains 'imageCount' -and $cliArtifacts.imageCount -ne $null) {
        $artifactSummary.imageCount = [int]$cliArtifacts.imageCount
      }
      if ($cliArtifacts.PSObject.Properties.Name -contains 'exportDir' -and $cliArtifacts.exportDir) {
        $artifactSummary.exportDir = [string]$cliArtifacts.exportDir
      }
      if ($cliArtifacts.PSObject.Properties.Name -contains 'images' -and $cliArtifacts.images) {
        $imagesSummary = @()
        foreach ($img in @($cliArtifacts.images)) {
          if (-not $img) { continue }
          $imagesSummary += [ordered]@{
            index      = if ($img.PSObject.Properties.Name -contains 'index') { $img.index } else { $null }
            mimeType   = if ($img.PSObject.Properties.Name -contains 'mimeType') { $img.mimeType } else { $null }
            byteLength = if ($img.PSObject.Properties.Name -contains 'byteLength') { $img.byteLength } else { $null }
            savedPath  = if ($img.PSObject.Properties.Name -contains 'savedPath') { $img.savedPath } else { $null }
          }
        }
        if ($imagesSummary.Count -gt 0) { $artifactSummary.images = $imagesSummary }
      }
      if ($artifactSummary.Count -gt 0) {
        $payload.capture.artifacts = $artifactSummary
        $payload.cliArtifacts = $artifactSummary
      }
    }
  } catch {
    $payload.capture.status = 'error'
    $payload.capture.reason = $_.Exception.Message
  }
}

if ($execPath -and (Test-Path -LiteralPath $execPath)) {
  try {
    $exec = Get-Content -LiteralPath $execPath -Raw | ConvertFrom-Json -Depth 6
    $payload.compareExec.status = 'ok'
    $payload.compareExec.reason = $null
    $payload.compareExec.path = $execPath
    if ($exec.exitCode -ne $null) { $payload.compareExec.exitCode = [int]$exec.exitCode }
    if ($exec.diff -ne $null) { $payload.compareExec.diff = [bool]$exec.diff }
    if ($payload.source -eq 'compare-exec') {
      $payload.file = $execPath
      $payload.exitCode = $payload.compareExec.exitCode
      $payload.diff = $payload.compareExec.diff
      if ($exec.PSObject.Properties.Name -contains 'durationMs') {
        $payload.durationMs = [double]$exec.durationMs
      } elseif ($exec.PSObject.Properties.Name -contains 'duration_s') {
        $payload.durationMs = [math]::Round([double]$exec.duration_s * 1000,3)
      }
      if ($exec.cliPath) { $payload.cliPath = [string]$exec.cliPath }
      if ($exec.command) { $payload.command = [string]$exec.command }
    } elseif ($payload.source -eq 'capture') {
      # enrich capture-based payload with exec details when available
      if ($payload.exitCode -eq $null -and $exec.exitCode -ne $null) { $payload.exitCode = [int]$exec.exitCode }
      if ($payload.diff -eq $null -and $exec.diff -ne $null) { $payload.diff = [bool]$exec.diff }
      if ($payload.durationMs -eq $null) {
        if ($exec.PSObject.Properties.Name -contains 'durationMs') { $payload.durationMs = [double]$exec.durationMs }
        elseif ($exec.PSObject.Properties.Name -contains 'duration_s') { $payload.durationMs = [math]::Round([double]$exec.duration_s * 1000,3) }
      }
    } else {
      $payload.source = 'compare-exec'
      $payload.file = $execPath
      $payload.exitCode = $payload.compareExec.exitCode
      $payload.diff = $payload.compareExec.diff
      if ($exec.cliPath) { $payload.cliPath = [string]$exec.cliPath }
      if ($exec.command) { $payload.command = [string]$exec.command }
      if ($exec.PSObject.Properties.Name -contains 'durationMs') { $payload.durationMs = [double]$exec.durationMs }
      elseif ($exec.PSObject.Properties.Name -contains 'duration_s') { $payload.durationMs = [math]::Round([double]$exec.duration_s * 1000,3) }
    }
  } catch {
    $payload.compareExec.status = 'error'
    $payload.compareExec.reason = $_.Exception.Message
  }
}

if ($payload.source -eq 'missing' -and -not $capturePath -and -not $execPath) {
  $summaryLines += ('- No compare artifacts found under: {0}' -f $resolvedDir)
} else {
  if ($payload.file) { $summaryLines += ('- File: {0}' -f $payload.file) }
  if ($payload.diff -ne $null) { $summaryLines += ('- diff: {0}' -f $payload.diff) }
  if ($payload.exitCode -ne $null) { $summaryLines += ('- exitCode: {0}' -f $payload.exitCode) }
  if ($payload.durationMs -ne $null) { $summaryLines += ('- durationMs: {0}' -f $payload.durationMs) }
  if ($payload.cliPath) { $summaryLines += ('- cliPath: {0}' -f $payload.cliPath) }
  if ($payload.command) { $summaryLines += ('- command: {0}' -f $payload.command) }
  if ($payload.cliArtifacts) {
    if ($payload.cliArtifacts.reportSizeBytes -ne $null) {
      $summaryLines += ('- CLI report size: {0} bytes' -f $payload.cliArtifacts.reportSizeBytes)
    }
    if ($payload.cliArtifacts.imageCount -ne $null) {
      if ($payload.cliArtifacts.exportDir) {
        $summaryLines += ('- CLI images: {0} (export: {1})' -f $payload.cliArtifacts.imageCount, $payload.cliArtifacts.exportDir)
      } else {
        $summaryLines += ('- CLI images: {0}' -f $payload.cliArtifacts.imageCount)
      }
    }
  }
}

$payload | ConvertTo-Json -Depth 8 | Out-File -FilePath $OutJson -Encoding utf8

if ($env:GITHUB_STEP_SUMMARY) {
  $summaryLines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
