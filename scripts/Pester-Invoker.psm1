Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step-based Pester invoker (no internal loop).
# Usage:
#   Import-Module ./scripts/Pester-Invoker.psm1
#   $session = New-PesterInvokerSession -ResultsRoot 'tests/results'
#   $res = Invoke-PesterFile -Session $session -File 'tests/Unit.Tests.ps1'
#   Complete-PesterInvokerSession -Session $session -FailedFiles @($res.File)

function Write-InvokerEvent {
  param(
    [Parameter(Mandatory)][string]$Type,
    [hashtable]$Data,
    [Parameter(Mandatory)][string]$LogPath,
    [string]$RunId,
    [string]$Seed
  )
  try {
    $dir = Split-Path -Parent $LogPath
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $payload = [ordered]@{
      timestamp = (Get-Date).ToString('o')
      schema    = 'pester-invoker/v1'
      type      = $Type
    }
    if ($RunId) { $payload.runId = $RunId }
    if ($Seed)  { $payload.seed  = $Seed }
    if ($Data) { foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] } }
    ($payload | ConvertTo-Json -Compress) | Add-Content -Path $LogPath
  } catch { Write-Warning ("[pester-invoker] failed to write crumb: {0}" -f $_.Exception.Message) }
}

function New-FileSlug {
  param([Parameter(Mandatory)][string]$Path)
  $leaf = Split-Path -Leaf $Path
  ($leaf -replace '[^A-Za-z0-9]+','-').Trim('-')
}

function New-PesterInvokerSession {
  [CmdletBinding()]
  param(
    [string]$ResultsRoot = 'tests/results',
    [ValidateSet('soft','strict')][string]$Isolation = 'soft',
    [string]$Seed,
    [string]$RunId
  )

  $root = (Resolve-Path '.').Path
  $resRoot = if ([IO.Path]::IsPathRooted($ResultsRoot)) { $ResultsRoot } else { Join-Path $root $ResultsRoot }
  $logPath = Join-Path $resRoot '_diagnostics' 'pester-invoker.ndjson'
  $rid  = if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N') }
  $seed = if ($Seed) { $Seed } elseif ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { (Get-Date -Format 'yyyyMMddHHmmss') }
  $pesterVersion = (Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()

  Write-InvokerEvent -Type 'plan' -Data ([ordered]@{ pesterVersion=$pesterVersion; isolation=$Isolation }) -LogPath $logPath -RunId $rid -Seed $seed

  [pscustomobject]@{
    Schema      = 'pester-invoker-session/v1'
    RunId       = $rid
    Seed        = $seed
    Isolation   = $Isolation
    ResultsRoot = $resRoot
    LogPath     = $logPath
  }
}

function Invoke-PesterFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][psobject]$Session,
    [string]$TestsPath,
    [Parameter(Mandatory)][string]$File,
    [string]$Category,
    [switch]$EmitIts,
    [int]$MaxSeconds = 0
  )

  $resolvedFile = (Resolve-Path -LiteralPath $File).Path
  $slug = New-FileSlug -Path $resolvedFile
  $resultsDir = Join-Path $Session.ResultsRoot 'pester'
  $resultsDir = Join-Path $resultsDir $slug
  if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
  }
  $resultsXml = Join-Path $resultsDir 'pester-results.xml'

  Write-InvokerEvent -Type 'file-start' -Data @{ file=$resolvedFile; slug=$slug; category=$Category; outDir=$resultsDir } -LogPath $Session.LogPath -RunId $Session.RunId -Seed $Session.Seed

  $timedOut = $false
  $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
  $runspace.Open()
  $stopwatch = [Diagnostics.Stopwatch]::StartNew()
  $resultObject = $null
  try {
    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    $script = {
      param($File,$ResultsXml,[bool]$EmitIts)
      Import-Module Pester -ErrorAction Stop
      $cfg = New-PesterConfiguration
      $cfg.Run.Path = @($File)
      $cfg.Run.Exit = $false
      $cfg.Run.PassThru = $true
      $cfg.Filter.FullName = @()
      $cfg.Output.Verbosity = if ($EmitIts) { 'Detailed' } else { 'Normal' }
      $cfg.TestResult.Enabled = $true
      $cfg.TestResult.OutputPath = $ResultsXml
      $cfg.TestResult.OutputFormat = 'NUnitXml'
      Invoke-Pester -Configuration $cfg
    }
    $handle = $ps.AddScript($script).AddArgument($resolvedFile).AddArgument($resultsXml).AddArgument([bool]$EmitIts).BeginInvoke()
    if ($MaxSeconds -gt 0) {
      if (-not $handle.AsyncWaitHandle.WaitOne($MaxSeconds * 1000)) { $timedOut = $true; $ps.Stop() }
    } else {
      $handle.AsyncWaitHandle.WaitOne() | Out-Null
    }
    if (-not $timedOut) {
      $raw = $ps.EndInvoke($handle)
      $items = @($raw)
      if ($items.Count -gt 0) { $resultObject = $items[-1] }
    }
  } finally {
    try { $runspace.Close() } catch {}
    $stopwatch.Stop()
  }

  $counts = [ordered]@{ passed=0; failed=0; skipped=0; errors=0 }
  if ($resultObject -and $resultObject.PSObject.Properties['PassedCount']) {
    $counts.passed = $resultObject.PassedCount
    $counts.failed = $resultObject.FailedCount
    $counts.skipped= $resultObject.SkippedCount
  } elseif (Test-Path -LiteralPath $resultsXml) {
    try {
      [xml]$xml = Get-Content -LiteralPath $resultsXml -Raw
      $cases = $xml.SelectNodes('//test-case')
      foreach ($case in $cases) {
        switch ($case.result) {
          'Passed'  { $counts.passed++ }
          'Failed'  { $counts.failed++ }
          'Error'   { $counts.errors++ }
          'Skipped' { $counts.skipped++ }
          'Ignored' { $counts.skipped++ }
        }
      }
    } catch { Write-Warning ("[pester-invoker] failed to parse results XML: {0}" -f $_.Exception.Message) }
  }

  $fileEnd = [ordered]@{
    file       = $resolvedFile
    slug       = $slug
    category   = $Category
    durationMs = [int][Math]::Round($stopwatch.Elapsed.TotalMilliseconds)
    counts     = $counts
    artifactDir= $resultsDir
    resultsXml = $resultsXml
    timedOut   = $timedOut
  }
  Write-InvokerEvent -Type 'file-end' -Data $fileEnd -LogPath $Session.LogPath -RunId $Session.RunId -Seed $Session.Seed

  [pscustomobject]@{
    File       = $resolvedFile
    Category   = $Category
    Slug       = $slug
    DurationMs = $fileEnd.durationMs
    TimedOut   = $timedOut
    Counts     = $counts
    ResultsXml = $resultsXml
    ArtifactDir= $resultsDir
  }
}

function Complete-PesterInvokerSession {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][psobject]$Session,
    [string[]]$FailedFiles,
    [psobject[]]$TopSlow
  )
  $summary = [ordered]@{
    failedFiles = @($FailedFiles)
    topSlow     = @($TopSlow)
  }
  Write-InvokerEvent -Type 'summary' -Data $summary -LogPath $Session.LogPath -RunId $Session.RunId -Seed $Session.Seed
  return $Session
}

Export-ModuleMember -Function New-PesterInvokerSession,Invoke-PesterFile,Complete-PesterInvokerSession
