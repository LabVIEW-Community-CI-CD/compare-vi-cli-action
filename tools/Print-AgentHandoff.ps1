[CmdletBinding()]
param(
  [switch]$ApplyToggles,
  [switch]$OpenDashboard,
  [switch]$AutoTrim,
  [string]$Group = 'pester-selfhosted',
  [string]$ResultsRoot = (Join-Path (Resolve-Path '.').Path 'tests/results')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HandoffFirstLine = $null
$script:StandingPriorityContext = $null
try {
  $repoRoot = (Split-Path -Parent $PSScriptRoot)
  $handoffPath = Join-Path $repoRoot 'AGENT_HANDOFF.txt'
  if (Test-Path -LiteralPath $handoffPath) {
    $script:HandoffFirstLine = Get-Content -LiteralPath $handoffPath -First 1 -ErrorAction SilentlyContinue
  }
} catch {}

function Format-NullableValue {
  param($Value)
  if ($null -eq $Value) { return 'n/a' }
  if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return 'n/a' }
  return $Value
}

function Format-BoolLabel {
  param([object]$Value)
  if ($Value -eq $true) { return 'true' }
  if ($Value -eq $false) { return 'false' }
  return 'unknown'
}

function Get-RogueLVStatus {
  param(
    [string]$RepoRoot,
    [int]$LookBackSeconds = 900
  )

  if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path '.').Path
  }

  $detectScript = Join-Path $RepoRoot 'tools' 'Detect-RogueLV.ps1'
  if (-not (Test-Path -LiteralPath $detectScript -PathType Leaf)) {
    return $null
  }

  $args = @(
    '-NoLogo', '-NoProfile',
    '-File', $detectScript,
    '-LookBackSeconds', [int][math]::Abs($LookBackSeconds),
    '-Quiet'
  )

  try {
    $raw = & pwsh @args
  } catch {
    Write-Warning ("Failed to invoke Detect-RogueLV.ps1: {0}" -f $_.Exception.Message)
    return $null
  }

  $joined = ($raw | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
  $trimmed = $joined.Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    return $null
  }

  try {
    return $trimmed | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Warning ("Failed to parse Detect-RogueLV output: {0}" -f $_.Exception.Message)
    return $null
  }
}

function Write-RogueLVSummary {
  param(
    [string]$RepoRoot,
    [string]$ResultsRoot,
    [int]$LookBackSeconds = 900
  )

  $status = Get-RogueLVStatus -RepoRoot $RepoRoot -LookBackSeconds $LookBackSeconds
  if (-not $status) {
    return $null
  }

  $liveLvCompare = @()
  $liveLabVIEW = @()
  $noticedLvCompare = @()
  $noticedLabVIEW = @()
  $rogueLvCompare = @()
  $rogueLabVIEW = @()

  if ($status.PSObject.Properties['live']) {
    if ($status.live.PSObject.Properties['lvcompare']) { $liveLvCompare = @($status.live.lvcompare) }
    if ($status.live.PSObject.Properties['labview'])   { $liveLabVIEW = @($status.live.labview) }
  }
  if ($status.PSObject.Properties['noticed']) {
    if ($status.noticed.PSObject.Properties['lvcompare']) { $noticedLvCompare = @($status.noticed.lvcompare) }
    if ($status.noticed.PSObject.Properties['labview'])   { $noticedLabVIEW = @($status.noticed.labview) }
  }
  if ($status.PSObject.Properties['rogue']) {
    if ($status.rogue.PSObject.Properties['lvcompare']) { $rogueLvCompare = @($status.rogue.lvcompare) }
    if ($status.rogue.PSObject.Properties['labview'])   { $rogueLabVIEW = @($status.rogue.labview) }
  }

  $lookback = if ($status.PSObject.Properties['lookbackSeconds']) { [int]$status.lookbackSeconds } else { $LookBackSeconds }
  $schema = if ($status.PSObject.Properties['schema']) { $status.schema } else { 'unknown' }

  $liveLvCompareLabel = if ($liveLvCompare.Count -gt 0) { $liveLvCompare -join ',' } else { '(none)' }
  $liveLabViewLabel = if ($liveLabVIEW.Count -gt 0) { $liveLabVIEW -join ',' } else { '(none)' }
  $noticedLvCompareLabel = if ($noticedLvCompare.Count -gt 0) { $noticedLvCompare -join ',' } else { '(none)' }
  $noticedLabViewLabel = if ($noticedLabVIEW.Count -gt 0) { $noticedLabVIEW -join ',' } else { '(none)' }
  $rogueLvCompareLabel = if ($rogueLvCompare.Count -gt 0) { $rogueLvCompare -join ',' } else { '(none)' }
  $rogueLabViewLabel = if ($rogueLabVIEW.Count -gt 0) { $rogueLabVIEW -join ',' } else { '(none)' }

  Write-Host ''
  Write-Host '[Rogue LV Status]' -ForegroundColor Cyan
  Write-Host ("  schema   : {0}" -f (Format-NullableValue $schema))
  Write-Host ("  lookback : {0}s" -f $lookback)
  Write-Host ("  live     : LVCompare={0}  LabVIEW={1}" -f (Format-NullableValue $liveLvCompareLabel), (Format-NullableValue $liveLabViewLabel))
  Write-Host ("  noticed  : LVCompare={0}  LabVIEW={1}" -f (Format-NullableValue $noticedLvCompareLabel), (Format-NullableValue $noticedLabViewLabel))
  Write-Host ("  rogue    : LVCompare={0}  LabVIEW={1}" -f (Format-NullableValue $rogueLvCompareLabel), (Format-NullableValue $rogueLabViewLabel))

  $liveDetails = @()
  if ($status.PSObject.Properties['liveDetails']) {
    if ($status.liveDetails.PSObject.Properties['lvcompare']) {
      foreach ($entry in @($status.liveDetails.lvcompare)) {
        if ($null -eq $entry) { continue }
        $liveDetails += [pscustomobject]@{
          kind = 'LVCompare'
          pid  = $entry.PSObject.Properties['pid'] ? $entry.pid : $null
          commandLine = $entry.PSObject.Properties['commandLine'] ? $entry.commandLine : $null
        }
      }
    }
    if ($status.liveDetails.PSObject.Properties['labview']) {
      foreach ($entry in @($status.liveDetails.labview)) {
        if ($null -eq $entry) { continue }
        $liveDetails += [pscustomobject]@{
          kind = 'LabVIEW'
          pid  = $entry.PSObject.Properties['pid'] ? $entry.pid : $null
          commandLine = $entry.PSObject.Properties['commandLine'] ? $entry.commandLine : $null
        }
      }
    }
  }

  if ($liveDetails.Count -gt 0) {
    foreach ($detail in $liveDetails | Sort-Object kind,pid) {
      $pidLabel = if ($detail.pid) { $detail.pid } else { '(unknown)' }
      $cmdLabel = if ($detail.commandLine) { $detail.commandLine } else { '(no command line)' }
      Write-Host ("  - {0} PID {1}: {2}" -f $detail.kind, $pidLabel, $cmdLabel)
    }
  }

  if ($ResultsRoot) {
    try {
      $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
      New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
      $status | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $handoffDir 'rogue-summary.json') -Encoding utf8
    } catch {
      Write-Warning ("Failed to persist rogue summary: {0}" -f $_.Exception.Message)
    }
  }

  if ($env:GITHUB_STEP_SUMMARY) {
    $summaryLines = @(
      '### Rogue LV Summary',
      '',
      ('- Lookback: {0}s' -f $lookback),
      ('- Live: LVCompare={0}  LabVIEW={1}' -f $liveLvCompareLabel, $liveLabViewLabel),
      ('- Rogue: LVCompare={0}  LabVIEW={1}' -f $rogueLvCompareLabel, $rogueLabViewLabel)
    )
    if ($liveDetails.Count -gt 0) {
      $summaryLines += ''
      $summaryLines += '| kind | pid | command |'
      $summaryLines += '| --- | --- | --- |'
      foreach ($detail in $liveDetails | Sort-Object kind,pid) {
        $summaryLines += ('| {0} | {1} | {2} |' -f $detail.kind, (Format-NullableValue $detail.pid), (Format-NullableValue $detail.commandLine))
      }
    }
    ($summaryLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }

  return $status
}
function Get-StandingPriorityContext {
  param(
    [string]$RepoRoot,
    [string]$ResultsRoot
  )

  if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path '.').Path
  }

  $cachePath = Join-Path $RepoRoot '.agent_priority_cache.json'
  if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
    throw "Standing priority cache not found at $cachePath. Run 'node tools/npm/run-script.mjs priority:sync'."
  }

  try {
    $cacheJson = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw ("Standing priority cache parse failed: {0}" -f $_.Exception.Message)
  }

  $issueDir = Join-Path $RepoRoot 'tests/results/_agent/issue'
  if (-not (Test-Path -LiteralPath $issueDir -PathType Container)) {
    throw "Standing priority snapshots missing under $issueDir. Run 'node tools/npm/run-script.mjs priority:sync'."
  }

  $latestIssue = Get-ChildItem -LiteralPath $issueDir -Filter '*.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike 'router.json' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $latestIssue) {
    throw "Standing priority snapshot not found in $issueDir. Run 'node tools/npm/run-script.mjs priority:sync'."
  }

  try {
    $snapshot = Get-Content -LiteralPath $latestIssue.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw ("Standing priority snapshot parse failed: {0}" -f $_.Exception.Message)
  }

  if ($null -eq $snapshot.number) {
    throw "Standing priority snapshot missing issue number. Run 'node tools/npm/run-script.mjs priority:sync'."
  }

  $cacheNumber = $cacheJson.PSObject.Properties['number'] ? $cacheJson.number : $null
  if ($cacheNumber -ne $snapshot.number) {
    throw ("Standing priority mismatch: cache #{0} vs snapshot #{1}. Run 'node tools/npm/run-script.mjs priority:sync'." -f $cacheNumber, $snapshot.number)
  }

  $cacheDigest = $cacheJson.PSObject.Properties['issueDigest'] ? $cacheJson.issueDigest : $null
  $snapshotDigest = $snapshot.PSObject.Properties['digest'] ? $snapshot.digest : $null
  if ([string]::IsNullOrWhiteSpace($cacheDigest) -or [string]::IsNullOrWhiteSpace($snapshotDigest)) {
    throw "Standing priority digest missing. Run 'node tools/npm/run-script.mjs priority:sync'."
  }
  if ($cacheDigest -ne $snapshotDigest) {
    throw ("Standing priority digest mismatch for issue #{0}. Run 'node tools/npm/run-script.mjs priority:sync'." -f $snapshot.number)
  }

  $routerPath = Join-Path $issueDir 'router.json'
  $router = $null
  if (Test-Path -LiteralPath $routerPath -PathType Leaf) {
    try {
      $router = Get-Content -LiteralPath $routerPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
      $router = $null
    }
  }

  return [ordered]@{
    cachePath = $cachePath
    cache = $cacheJson
    snapshotPath = $latestIssue.FullName
    snapshot = $snapshot
    routerPath = if (Test-Path -LiteralPath $routerPath -PathType Leaf) { $routerPath } else { $null }
    router = $router
  }
}

function Invoke-StandingPrioritySync {
  param([string]$RepoRoot)

  if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path '.').Path
  }

  $priorityScript = Join-Path $RepoRoot 'tools' 'priority' 'sync-standing-priority.mjs'
  $nodeCmd = $null
  try {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  } catch {}

  if ($nodeCmd -and (Test-Path -LiteralPath $priorityScript -PathType Leaf)) {
    & $nodeCmd.Source $priorityScript | Out-Host
    return $true
  }

  Write-Host '::notice::Standing priority sync skipped (node or script missing).'
  return $false
}

function Ensure-StandingPriorityContext {
  param(
    [string]$RepoRoot,
    [string]$ResultsRoot
  )

  if ($script:StandingPriorityContext) { return $script:StandingPriorityContext }

  if (-not $RepoRoot) { $RepoRoot = (Resolve-Path '.').Path }

  try {
    $ctx = Get-StandingPriorityContext -RepoRoot $RepoRoot -ResultsRoot $ResultsRoot
    $script:StandingPriorityContext = $ctx
    return $ctx
  } catch {
    $initialError = $_
    $synced = Invoke-StandingPrioritySync -RepoRoot $RepoRoot
    if (-not $synced) { throw $initialError }
    $ctx = Get-StandingPriorityContext -RepoRoot $RepoRoot -ResultsRoot $ResultsRoot
    $script:StandingPriorityContext = $ctx
    return $ctx
  }
}

$script:GitExecutable = $null
function Get-GitExecutable {
  if ($script:GitExecutable) { return $script:GitExecutable }
  try {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) {
      $script:GitExecutable = $cmd.Source
      return $script:GitExecutable
    }
  } catch {}
  return $null
}

function Invoke-Git {
  param(
    [Parameter(Mandatory)][string[]]$Arguments
  )

  $gitExe = Get-GitExecutable
  if (-not $gitExe) { return $null }
  try {
    $output = & $gitExe @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return @($output)
  } catch {
    return $null
  }
}

function Write-AgentSessionCapsule {
  param(
    [string]$ResultsRoot
  )

  $repoRoot = (Resolve-Path '.').Path
  $sessionsRoot = Join-Path $ResultsRoot '_agent/sessions'
  try {
    New-Item -ItemType Directory -Force -Path $sessionsRoot | Out-Null
  } catch {
    Write-Warning ("Failed to create sessions directory {0}: {1}" -f $sessionsRoot, $_.Exception.Message)
    return
  }

  $now = [DateTimeOffset]::UtcNow
  $timestamp = $now.ToString('yyyyMMddTHHmmssfffZ')

  $gitInfo = [ordered]@{}
  $head = Invoke-Git -Arguments @('rev-parse','--verify','HEAD')
  $headValues = @($head)
  if ($headValues.Count -gt 0) {
    $headSha = ($headValues[0]).Trim()
    if ($headSha) {
      $gitInfo.head = $headSha
      $gitInfo.shortHead = if ($headSha.Length -gt 12) { $headSha.Substring(0, 12) } else { $headSha }
    }
  }

  $branch = Invoke-Git -Arguments @('rev-parse','--abbrev-ref','HEAD')
  $branchValues = @($branch)
  if ($branchValues.Count -gt 0) {
    $branchName = ($branchValues[0]).Trim()
    if ($branchName -and $branchName -ne 'HEAD') { $gitInfo.branch = $branchName }
  }

  $statusShort = Invoke-Git -Arguments @('status','--short','--branch')
  $statusShortValues = @($statusShort)
  if ($statusShortValues.Count -gt 0) {
    $gitInfo.statusShort = ($statusShortValues -join "`n")
  }

  $statusPorcelain = Invoke-Git -Arguments @('status','--porcelain')
  $statusPorcelainValues = @($statusPorcelain)
  if ($statusPorcelainValues.Count -gt 0) {
    $gitInfo.porcelain = @($statusPorcelainValues | ForEach-Object { $_ })
  }

  $diffStat = Invoke-Git -Arguments @('diff','--stat')
  $diffStatValues = @($diffStat)
  if ($diffStatValues.Count -gt 0) {
    $gitInfo.diffStat = ($diffStatValues -join "`n")
  }

  if ($gitInfo.Count -eq 0) { $gitInfo = $null }

  $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
  $artifactCandidates = @(
    @{ name = 'handoff.testSummary'; path = Join-Path $handoffDir 'test-summary.json' },
    @{ name = 'handoff.hookSummary'; path = Join-Path $handoffDir 'hook-summary.json' },
    @{ name = 'handoff.watcherTelemetry'; path = Join-Path $handoffDir 'watcher-telemetry.json' },
    @{ name = 'handoff.releaseSummary'; path = Join-Path $handoffDir 'release-summary.json' },
    @{ name = 'handoff.issueSummary'; path = Join-Path $handoffDir 'issue-summary.json' },
    @{ name = 'handoff.router'; path = Join-Path $handoffDir 'issue-router.json' },
    @{ name = 'handoff.localStatus'; path = Join-Path $handoffDir 'local-status.txt' },
    @{ name = 'handoff.localDiff'; path = Join-Path $handoffDir 'local-diff.txt' },
    @{ name = 'handoff.branch'; path = Join-Path $handoffDir 'branch.txt' },
    @{ name = 'handoff.headSha'; path = Join-Path $handoffDir 'head-sha.txt' }
  )

  $artifacts = @()
  foreach ($candidate in $artifactCandidates) {
    $artifactPath = $candidate.path
    $exists = $false
    $size = $null
    $lastWrite = $null
    if ($artifactPath -and (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
      $exists = $true
      $info = Get-Item -LiteralPath $artifactPath -ErrorAction SilentlyContinue
      if ($info) {
        $size = $info.Length
        $lastWrite = $info.LastWriteTimeUtc.ToString('o')
      }
    }
    $artifacts += [ordered]@{
      name = $candidate.name
      path = $artifactPath
      exists = $exists
      size = $size
      lastWriteUtc = $lastWrite
    }
  }

  $envKeys = @(
    'LV_SUPPRESS_UI',
    'LV_NO_ACTIVATE',
    'LV_CURSOR_RESTORE',
    'LV_IDLE_WAIT_SECONDS',
    'LV_IDLE_MAX_WAIT_SECONDS',
    'LVCI_COMPARE_MODE',
    'LVCI_COMPARE_POLICY',
    'LABVIEWCLI_PATH',
    'LABVIEW_CLI_PATH',
    'LABVIEW_CLI'
  )
  $environment = [ordered]@{}
  foreach ($key in $envKeys) {
    $environment[$key] = [System.Environment]::GetEnvironmentVariable($key)
  }

  $priorityContext = Ensure-StandingPriorityContext -RepoRoot $repoRoot -ResultsRoot $ResultsRoot

  $capsule = [ordered]@{
    schema = 'agent-handoff/session@v1'
    generatedAt = $now.ToString('o')
    sessionId = ('session-{0}' -f $timestamp)
    workspace = $repoRoot
    results = [ordered]@{
      root = $ResultsRoot
      handoffDir = $handoffDir
      sessionsDir = $sessionsRoot
    }
    artifacts = $artifacts
    environment = $environment
  }

  if ($gitInfo) { $capsule.git = $gitInfo }

  if ($priorityContext) {
    $topActions = $null
    if ($priorityContext.router -and $priorityContext.router.PSObject.Properties['actions']) {
      $topActions = @($priorityContext.router.actions | Select-Object -First 5 | ForEach-Object { $_.key })
    }

    $capsule.standingPriority = [ordered]@{
      issue = [ordered]@{
        number = $priorityContext.snapshot.number
        title = $priorityContext.snapshot.title
        state = $priorityContext.snapshot.state
        updatedAt = $priorityContext.snapshot.updatedAt
        digest = $priorityContext.snapshot.digest
        path = $priorityContext.snapshotPath
      }
      cache = [ordered]@{
        path = $priorityContext.cachePath
        cachedAtUtc = $priorityContext.cache.cachedAtUtc
        lastSeenUpdatedAt = $priorityContext.cache.lastSeenUpdatedAt
        issueDigest = $priorityContext.cache.issueDigest
      }
      router = if ($priorityContext.routerPath) {
        [ordered]@{
          path = $priorityContext.routerPath
          topActions = $topActions
        }
      } else {
        $null
      }
    }
  }

  $fileBase = $capsule.sessionId
  if ($gitInfo -and $gitInfo.shortHead) {
    $fileBase = '{0}-{1}' -f $fileBase, $gitInfo.shortHead
  }
  $targetPath = Join-Path $sessionsRoot ("{0}.json" -f $fileBase)
  $suffix = 1
  while (Test-Path -LiteralPath $targetPath -PathType Leaf) {
    $targetPath = Join-Path $sessionsRoot ("{0}-{1:D2}.json" -f $fileBase, $suffix)
    $suffix++
  }

  try {
    ($capsule | ConvertTo-Json -Depth 6) | Out-File -FilePath $targetPath -Encoding utf8
    Write-Host ''
    Write-Host '[Session Capsule]' -ForegroundColor Cyan
    Write-Host ("  sessionId : {0}" -f $capsule.sessionId)
    Write-Host ("  path      : {0}" -f $targetPath)
  } catch {
    Write-Warning ("Failed to write session capsule: {0}" -f $_.Exception.Message)
  }
}

function Write-HookSummaries {
  param([string]$ResultsRoot)

  $hooksDir = Join-Path $ResultsRoot '_hooks'
  Write-Host ''
  Write-Host '[Hook Summaries]' -ForegroundColor Cyan
  if (-not (Test-Path -LiteralPath $hooksDir -PathType Container)) {
    Write-Host '  (no hook summaries found)'
    return @()
  }

  $files = Get-ChildItem -LiteralPath $hooksDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
  if (-not $files) {
    Write-Host '  (no hook summaries found)'
    return @()
  }

  $latest = @{}
  foreach ($file in $files) {
    try {
      $summary = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
      continue
    }
    if (-not $summary) { continue }
    $hookName = if ($summary.PSObject.Properties['hook']) { $summary.hook } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
    if (-not $hookName) { continue }
    if (-not $latest.ContainsKey($hookName)) {
      $latest[$hookName] = [ordered]@{
        hook = $hookName
        file = $file.FullName
        status = $summary.status
        exitCode = $summary.exitCode
        timestamp = $summary.timestamp
        plane = if ($summary.environment) { $summary.environment.plane } else { $null }
        enforcement = if ($summary.environment) { $summary.environment.enforcement } else { $null }
      }
    }
  }

  if ($latest.Count -eq 0) {
    Write-Host '  (no hook summaries found)'
    return @()
  }

  foreach ($entry in ($latest.Keys | Sort-Object)) {
    $info = $latest[$entry]
    Write-Host ("  hook        : {0}" -f $info.hook)
    Write-Host ("    status    : {0}" -f (Format-NullableValue $info.status))
    Write-Host ("    exitCode  : {0}" -f (Format-NullableValue $info.exitCode))
    Write-Host ("    plane     : {0}" -f (Format-NullableValue $info.plane))
    Write-Host ("    enforce   : {0}" -f (Format-NullableValue $info.enforcement))
    Write-Host ("    timestamp : {0}" -f (Format-NullableValue $info.timestamp))
    Write-Host ("    file      : {0}" -f $info.file)
  }

  return ($latest.Values | Sort-Object hook)
}

function Write-WatcherStatusSummary {
  param(
    [string]$ResultsRoot,
    [switch]$RequestAutoTrim
  )

  $repoRoot = (Resolve-Path '.').Path
  $watcherCli = Join-Path $repoRoot 'tools/Dev-WatcherManager.ps1'
  if (-not (Test-Path -LiteralPath $watcherCli)) {
    Write-Warning "Dev-WatcherManager.ps1 not found: $watcherCli"
    return
  }

  try {
    # Prefer in-process invocation to avoid nested pwsh; capture information stream just in case
    $statusJson = & $watcherCli -Status -ResultsDir $ResultsRoot 6>&1
    if (-not $statusJson) {
      # Fallback to spawning pwsh to capture host output if needed
      $statusJson = & pwsh -NoLogo -NoProfile -File $watcherCli -Status -ResultsDir $ResultsRoot
    }
  } catch {
    Write-Warning ("Failed to gather watcher status: {0}" -f $_.Exception.Message)
    return
  }

  if (-not $statusJson) {
    Write-Warning 'Watcher status command returned no output.'
    return
  }

  try {
    $status = $statusJson | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Warning ("Watcher status parse failed: {0}" -f $_.Exception.Message)
    return
  }

  $autoTrimRequested = $RequestAutoTrim.IsPresent -or ($env:HANDOFF_AUTOTRIM -and ($env:HANDOFF_AUTOTRIM -match '^(1|true|yes)$'))
  $autoTrimExecuted = $false
  $autoTrimOutput = @()

  if ($autoTrimRequested) {
    $shouldTrim = $true
    if ($status) {
      if ($status.PSObject.Properties['needsTrim']) {
        $shouldTrim = [bool]$status.needsTrim
      } elseif ($status.PSObject.Properties['autoTrim'] -and $status.autoTrim) {
        # If eligibility is known, honor it
        if ($status.autoTrim.PSObject.Properties['eligible']) {
          $shouldTrim = [bool]$status.autoTrim.eligible
        }
      }
    }
    if ($shouldTrim) {
      try {
        # Capture both success and information streams
        $autoTrimOutput = & $watcherCli -AutoTrim -ResultsDir $ResultsRoot 6>&1
        if ($autoTrimOutput -match 'Trimmed watcher logs') { $autoTrimExecuted = $true }
      } catch {
        Write-Warning ("Auto-trim failed: {0}" -f $_.Exception.Message)
      }
      try {
        $statusJson = & $watcherCli -Status -ResultsDir $ResultsRoot 6>&1
        if (-not $statusJson) {
          $statusJson = & pwsh -NoLogo -NoProfile -File $watcherCli -Status -ResultsDir $ResultsRoot
        }
        if ($statusJson) { $status = $statusJson | ConvertFrom-Json -ErrorAction Stop }
      } catch {
        Write-Warning ("Failed to refresh watcher status after auto-trim: {0}" -f $_.Exception.Message)
      }
    } else {
      $autoTrimExecuted = $false
      $autoTrimOutput = @('Auto-trim skipped (not needed).')
    }
  }

  $autoTrim = $null
  if ($status -and $status.PSObject.Properties['autoTrim']) {
    $autoTrim = $status.autoTrim
  }

  Write-Host ''
  Write-Host '[Watcher Status]' -ForegroundColor Cyan
  Write-Host ("  resultsDir      : {0}" -f (Format-NullableValue $ResultsRoot))
  Write-Host ("  state           : {0}" -f (Format-NullableValue $status.state))
  Write-Host ("  alive           : {0}" -f (Format-BoolLabel $status.alive))
  Write-Host ("  verifiedProcess : {0}" -f (Format-BoolLabel $status.verifiedProcess))
  if ($status.verificationReason) {
    Write-Host ("    reason        : {0}" -f $status.verificationReason)
  }
  Write-Host ("  heartbeatFresh  : {0}" -f (Format-BoolLabel $status.heartbeatFresh))
  if ($status.heartbeatReason) {
    Write-Host ("    reason        : {0}" -f $status.heartbeatReason)
  }
  Write-Host ("  lastHeartbeatAt : {0}" -f (Format-NullableValue $status.lastHeartbeatAt))
  $heartbeatAgeLabel = if ($null -ne $status.heartbeatAgeSeconds) { $status.heartbeatAgeSeconds } else { 'n/a' }
  Write-Host ("  heartbeatAgeSec : {0}" -f $heartbeatAgeLabel)
  Write-Host ("  lastActivityAt  : {0}" -f (Format-NullableValue $status.lastActivityAt))
  Write-Host ("  lastProgressAt  : {0}" -f (Format-NullableValue $status.lastProgressAt))
  if ($status.files -and $status.files.status) {
    $statusExists = if ($status.files.status.exists) { 'present' } else { 'missing' }
    Write-Host ("  status.json     : {0}" -f $statusExists)
  }
  if ($status.files -and $status.files.heartbeat) {
    $hbExists = if ($status.files.heartbeat.exists) { 'present' } else { 'missing' }
    Write-Host ("  heartbeat.json  : {0}" -f $hbExists)
  }
  if ($autoTrim) {
    Write-Host ("  autoTrim.eligible           : {0}" -f (Format-BoolLabel $autoTrim.eligible))
    Write-Host ("  autoTrim.cooldownSeconds    : {0}" -f (Format-NullableValue $autoTrim.cooldownSeconds))
    Write-Host ("  autoTrim.cooldownRemaining  : {0}" -f (Format-NullableValue $autoTrim.cooldownRemainingSeconds))
    Write-Host ("  autoTrim.nextEligibleAt     : {0}" -f (Format-NullableValue $autoTrim.nextEligibleAt))
    Write-Host ("  autoTrim.lastTrimAt         : {0}" -f (Format-NullableValue $autoTrim.lastTrimAt))
    Write-Host ("  autoTrim.lastTrimKind       : {0}" -f (Format-NullableValue $autoTrim.lastTrimKind))
    Write-Host ("  autoTrim.lastTrimBytes      : {0}" -f (Format-NullableValue $autoTrim.lastTrimBytes))
    Write-Host ("  autoTrim.trimCount          : {0}" -f (Format-NullableValue $autoTrim.trimCount))
    Write-Host ("  autoTrim.autoTrimCount      : {0}" -f (Format-NullableValue $autoTrim.autoTrimCount))
    Write-Host ("  autoTrim.manualTrimCount    : {0}" -f (Format-NullableValue $autoTrim.manualTrimCount))
  }
  Write-Host ("  needsTrim       : {0}" -f (Format-BoolLabel $status.needsTrim))
  if ($status.needsTrim) {
    Write-Host '    hint          : node tools/npm/run-script.mjs dev:watcher:trim' -ForegroundColor Yellow
    if ($status.files -and $status.files.out -and $status.files.out.path) {
      Write-Host ("    out           : {0}" -f $status.files.out.path)
    }
    if ($status.files -and $status.files.err -and $status.files.err.path) {
      Write-Host ("    err           : {0}" -f $status.files.err.path)
    }
  }

  if ($autoTrimRequested) {
    $autoTrimStatusLabel = if ($autoTrimExecuted) { 'executed' } else { 'not executed' }
    Write-Host ("  auto-trim       : {0}" -f $autoTrimStatusLabel)
    # Normalize output records (InformationRecord vs string) and print non-empty lines
    $lines = @()
    foreach ($rec in $autoTrimOutput) {
      if ($null -eq $rec) { continue }
      if ($rec -is [System.Management.Automation.InformationRecord]) {
        $lines += [string]$rec.MessageData
      } else {
        $lines += [string]$rec
      }
    }
    foreach ($line in ($lines | Where-Object { $_ -and $_.Trim().Length -gt 0 })) {
      Write-Host ("    > {0}" -f $line.Trim())
    }
  }

  # Emit a compact JSON telemetry object for automation consumers and write step summary if available
  $telemetry = [ordered]@{
    schema = 'agent-handoff/watcher-telemetry-v1'
    timestamp = (Get-Date).ToString('o')
    resultsDir = $ResultsRoot
    state = $status.state
    alive = $status.alive
    verifiedProcess = $status.verifiedProcess
    heartbeatFresh = $status.heartbeatFresh
    heartbeatReason = $status.heartbeatReason
    lastHeartbeatAt = $status.lastHeartbeatAt
    heartbeatAgeSeconds = $status.heartbeatAgeSeconds
    needsTrim = $status.needsTrim
    autoTrimExecuted = $autoTrimExecuted
    outPath = if ($status.files -and $status.files.out) { $status.files.out.path } else { $null }
    errPath = if ($status.files -and $status.files.err) { $status.files.err.path } else { $null }
    autoTrim = if ($autoTrim) {
      [ordered]@{
        eligible = $autoTrim.eligible
        cooldownSeconds = $autoTrim.cooldownSeconds
        cooldownRemainingSeconds = $autoTrim.cooldownRemainingSeconds
        nextEligibleAt = $autoTrim.nextEligibleAt
        lastTrimAt = $autoTrim.lastTrimAt
        lastTrimKind = $autoTrim.lastTrimKind
        lastTrimBytes = $autoTrim.lastTrimBytes
        trimCount = $autoTrim.trimCount
        autoTrimCount = $autoTrim.autoTrimCount
        manualTrimCount = $autoTrim.manualTrimCount
      }
    } else {
      $null
    }
  }
  $telemetryJson = ($telemetry | ConvertTo-Json -Depth 4)
  Write-Host ''
  Write-Host '[Watcher Telemetry JSON]'
  Write-Host $telemetryJson

  try {
    $outDir = Join-Path $ResultsRoot '_agent/handoff'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $telemetryPath = Join-Path $outDir 'watcher-telemetry.json'
    $telemetryJson | Out-File -FilePath $telemetryPath -Encoding utf8
  } catch {}

  if ($env:GITHUB_STEP_SUMMARY) {
    $summaryLines = @()
    $summaryLines += '### Handoff — Watcher Status'
    $summaryLines += "- State: $($status.state)"
    $summaryLines += "- Alive: $(Format-BoolLabel $status.alive)"
    $summaryLines += "- Verified: $(Format-BoolLabel $status.verifiedProcess)"
    $summaryLines += "- Heartbeat Fresh: $(Format-BoolLabel $status.heartbeatFresh)"
    if ($status.heartbeatReason) { $summaryLines += "- Heartbeat Reason: $($status.heartbeatReason)" }
    if ($status.lastHeartbeatAt) { $summaryLines += "- Last Heartbeat: $($status.lastHeartbeatAt) (~$heartbeatAgeLabel s)" }
    if ($autoTrim) {
      $summaryLines += "- Auto-Trim Eligible: $(Format-BoolLabel $autoTrim.eligible)"
      if ($autoTrim.cooldownRemainingSeconds) {
        $summaryLines += "- Auto-Trim Cooldown Remaining: $(Format-NullableValue $autoTrim.cooldownRemainingSeconds)s"
      }
      if ($autoTrim.nextEligibleAt) {
        $summaryLines += "- Auto-Trim Next Eligible: $(Format-NullableValue $autoTrim.nextEligibleAt)"
      }
      if ($autoTrim.lastTrimAt) {
        $summaryLines += "- Auto-Trim Last Trim: $(Format-NullableValue $autoTrim.lastTrimAt) ($((Format-NullableValue $autoTrim.lastTrimKind)))"
      }
    }
    $summaryLines += "- Needs Trim: $(Format-BoolLabel $status.needsTrim)"
    if ($autoTrimRequested) {
      $summaryLines += if ($autoTrimExecuted) { '- Auto-Trim: executed' } else { '- Auto-Trim: not executed' }
    }
    ($summaryLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }
}

$handoff = Join-Path (Resolve-Path '.').Path 'AGENT_HANDOFF.txt'
if (-not (Test-Path -LiteralPath $handoff)) { throw "Handoff file not found: $handoff" }

if ($ApplyToggles) {
  $env:LV_SUPPRESS_UI = '1'
  $env:LV_NO_ACTIVATE = '1'
  $env:LV_CURSOR_RESTORE = '1'
  $env:LV_IDLE_WAIT_SECONDS = '2'
  $env:LV_IDLE_MAX_WAIT_SECONDS = '5'
  if (-not $env:WATCH_RESULTS_DIR) {
    # Use repo-relative path to satisfy tests and downstream watchers
    $env:WATCH_RESULTS_DIR = 'tests/results/_watch'
  }
}

$handoffLines = Get-Content -LiteralPath $handoff -ErrorAction Stop
if ($script:HandoffFirstLine -and $handoffLines.Count -gt 0) {
  if (-not [string]::Equals($script:HandoffFirstLine, $handoffLines[0], [System.StringComparison]::Ordinal)) {
    Write-Warning ("Handoff heading mismatch. Expected '{0}', found '{1}'." -f $script:HandoffFirstLine, $handoffLines[0])
  }
}
$handoffLines | ForEach-Object { Write-Output $_ }

try {
  Ensure-StandingPriorityContext -RepoRoot (Resolve-Path '.').Path -ResultsRoot $ResultsRoot | Out-Null
} catch {
  Write-Warning ("Standing priority ensure failed: {0}" -f $_.Exception.Message)
}

try {
  $priorityContext = Ensure-StandingPriorityContext -RepoRoot (Resolve-Path '.').Path -ResultsRoot $ResultsRoot
  if ($priorityContext) {
    $issueSnap = $priorityContext.snapshot
    Write-Host ''
    Write-Host '[Standing Priority]' -ForegroundColor Cyan
    Write-Host ("  issue    : #{0}" -f (Format-NullableValue $issueSnap.number))
    Write-Host ("  title    : {0}" -f (Format-NullableValue $issueSnap.title))
    Write-Host ("  state    : {0}" -f (Format-NullableValue $issueSnap.state))
    Write-Host ("  updated  : {0}" -f (Format-NullableValue $issueSnap.updatedAt))
    Write-Host ("  digest   : {0}" -f (Format-NullableValue $issueSnap.digest))
    Write-Host ("  merge    : use Squash and Merge (linear history required)") -ForegroundColor DarkGray

    if ($env:GITHUB_STEP_SUMMARY) {
      $priorityLines = @(
        '### Standing Priority',
        '',
        ('- Issue: #{0} - {1}' -f (Format-NullableValue $issueSnap.number), (Format-NullableValue $issueSnap.title)),
        ('- State: {0}  Updated: {1}' -f (Format-NullableValue $issueSnap.state), (Format-NullableValue $issueSnap.updatedAt)),
        ('- Digest: `{0}`' -f (Format-NullableValue $issueSnap.digest)),
        '- Merge: Use Squash and Merge (linear history required)'
      )
      ($priorityLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    if ($priorityContext.snapshotPath) {
      Copy-Item -LiteralPath $priorityContext.snapshotPath -Destination (Join-Path $handoffDir 'issue-summary.json') -Force
    }
    if ($priorityContext.routerPath) {
      Copy-Item -LiteralPath $priorityContext.routerPath -Destination (Join-Path $handoffDir 'issue-router.json') -Force
    }
  }
} catch {
  Write-Warning ("Failed to display standing priority summary: {0}" -f $_.Exception.Message)
}

try {
  $releasePath = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/handoff/release-summary.json'
  if (Test-Path -LiteralPath $releasePath -PathType Leaf) {
    $release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Host ''
    Write-Host '[SemVer Status]' -ForegroundColor Cyan
    Write-Host ("  version : {0}" -f (Format-NullableValue $release.version))
    Write-Host ("  valid   : {0}" -f (Format-BoolLabel $release.valid))
    if ($release.issues) {
      foreach ($issue in $release.issues) {
        Write-Host ("    issue : {0}" -f $issue)
      }
    }
    $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    $releaseDest = Join-Path $handoffDir 'release-summary.json'
    $releaseSourceFull = $releasePath
    $releaseDestFull = $releaseDest
    try { $releaseSourceFull = [System.IO.Path]::GetFullPath($releasePath) } catch {}
    try { $releaseDestFull = [System.IO.Path]::GetFullPath($releaseDest) } catch {}
    if (-not [string]::Equals($releaseSourceFull, $releaseDestFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      Copy-Item -LiteralPath $releasePath -Destination $releaseDest -Force
    } else {
      Write-Verbose 'Release summary already present at destination; skipping copy.'
    }
    if ($env:GITHUB_STEP_SUMMARY) {
      $releaseLines = @(
        '### SemVer Status',
        '',
        ('- Version: {0}' -f (Format-NullableValue $release.version)),
        ('- Valid: {0}' -f (Format-BoolLabel $release.valid))
      )
      if ($release.issues -and $release.issues.Count -gt 0) {
        foreach ($issue in $release.issues) {
          $releaseLines += ('  - {0}' -f $issue)
        }
      }
      ($releaseLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
} catch {
  Write-Warning ("Failed to load SemVer summary: {0}" -f $_.Exception.Message)
}

try {
  $testSummaryPath = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/handoff/test-summary.json'
  if (Test-Path -LiteralPath $testSummaryPath -PathType Leaf) {
    $testSummaryRaw = Get-Content -LiteralPath $testSummaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $testEntries = @()
    $statusLabel = 'unknown'
    $generatedAt = $null
    $notes = @()
    $total = 0

    if ($testSummaryRaw -is [System.Array]) {
      $testEntries = @($testSummaryRaw)
      $total = $testEntries.Count
      $statusLabel = if (@($testEntries | Where-Object { $_.exitCode -ne 0 }).Count -gt 0) { 'failed' } else { 'passed' }
    } elseif ($testSummaryRaw -is [psobject]) {
      $resultsProp = $testSummaryRaw.PSObject.Properties['results']
      if ($resultsProp) {
        $testEntries = @($resultsProp.Value)
        $statusProp = $testSummaryRaw.PSObject.Properties['status']
        $statusLabel = if ($statusProp) { $statusProp.Value } else { 'unknown' }
        $generatedProp = $testSummaryRaw.PSObject.Properties['generatedAt']
        if ($generatedProp) { $generatedAt = $generatedProp.Value }
        $totalProp = $testSummaryRaw.PSObject.Properties['total']
        $total = if ($totalProp) { $totalProp.Value } else { $testEntries.Count }
        $notesProp = $testSummaryRaw.PSObject.Properties['notes']
        if ($notesProp -and $notesProp.Value) { $notes = @($notesProp.Value) }
      }
    }

    $failureEntries = @($testEntries | Where-Object { $_.exitCode -ne 0 })
    $failureCount = $failureEntries.Count

    Write-Host ''
    Write-Host '[Test Results]' -ForegroundColor Cyan
    Write-Host ("  status   : {0}" -f (Format-NullableValue $statusLabel))
    Write-Host ("  total    : {0}" -f $total)
    Write-Host ("  failures : {0}" -f $failureCount)
    if ($generatedAt) {
      Write-Host ("  generated: {0}" -f (Format-NullableValue $generatedAt))
    }
    if ($notes -and $notes.Count -gt 0) {
      foreach ($note in $notes) {
        Write-Host ("  note     : {0}" -f (Format-NullableValue $note))
      }
    }
    foreach ($entry in $testEntries) {
      Write-Host ("  {0} => exit {1}" -f ($entry.command ?? '(unknown)'), (Format-NullableValue $entry.exitCode))
    }

    if ($env:GITHUB_STEP_SUMMARY) {
      $testLines = @(
        '### Test Results',
        '',
        ('- Status: {0}' -f (Format-NullableValue $statusLabel)),
        ('- Total: {0}  Failures: {1}' -f $total, $failureCount)
      )
      if ($generatedAt) {
        $testLines += ('- Generated: {0}' -f (Format-NullableValue $generatedAt))
      }
      if ($notes -and $notes.Count -gt 0) {
        foreach ($note in $notes) {
          $testLines += ('  - Note: {0}' -f (Format-NullableValue $note))
        }
      }
      $testLines += ''
      $testLines += '| command | exit |'
      $testLines += '| --- | --- |'
      foreach ($entry in $testEntries) {
        $testLines += ('| {0} | {1} |' -f ($entry.command ?? '(unknown)'), (Format-NullableValue $entry.exitCode))
      }
      ($testLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
} catch {
  Write-Warning ("Failed to read test summary: {0}" -f $_.Exception.Message)
}

Write-WatcherStatusSummary -ResultsRoot $ResultsRoot -RequestAutoTrim:$AutoTrim

try {
  Write-RogueLVSummary -RepoRoot $repoRoot -ResultsRoot $ResultsRoot | Out-Null
} catch {
  Write-Warning ("Failed to emit rogue LV summary: {0}" -f $_.Exception.Message)
}

$hookSummaries = Write-HookSummaries -ResultsRoot $ResultsRoot
if ($hookSummaries -and $hookSummaries.Count -gt 0) {
  if ($env:GITHUB_STEP_SUMMARY) {
    $hookSummaryLines = @('### Hook Summaries','','| hook | status | plane | enforcement | exit | timestamp |','| --- | --- | --- | --- | --- | --- |')
    foreach ($hook in $hookSummaries) {
      $hookSummaryLines += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $hook.hook, (Format-NullableValue $hook.status), (Format-NullableValue $hook.plane), (Format-NullableValue $hook.enforcement), (Format-NullableValue $hook.exitCode), (Format-NullableValue $hook.timestamp))
    }
    ($hookSummaryLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }

  $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
  New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
  ($hookSummaries | ConvertTo-Json -Depth 4) | Out-File -FilePath (Join-Path $handoffDir 'hook-summary.json') -Encoding utf8
}

Write-AgentSessionCapsule -ResultsRoot $ResultsRoot

if ($OpenDashboard) {
  $cli = Join-Path (Resolve-Path '.').Path 'tools/Dev-Dashboard.ps1'
  if (Test-Path -LiteralPath $cli) {
    & $cli -Group $Group -ResultsRoot $ResultsRoot -Html -Json | Out-Null
    Write-Host "Dashboard generated under: $ResultsRoot" -ForegroundColor Cyan
  } else {
    Write-Warning "Dev-Dashboard.ps1 not found at: $cli"
  }
}
