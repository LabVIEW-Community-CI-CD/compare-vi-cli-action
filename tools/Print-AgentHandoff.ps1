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

function New-WatcherEventsTelemetry {
  param($EventsStatus)

  if (-not $EventsStatus) { return $null }

  $path = if ($EventsStatus.PSObject.Properties['path']) { $EventsStatus.path } else { $null }
  if ([string]::IsNullOrWhiteSpace($path)) { return $null }

  $present = $false
  if ($EventsStatus.PSObject.Properties['exists']) {
    try { $present = [bool]$EventsStatus.exists } catch {}
  } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
    $present = $true
  }

  $count = 0
  if ($EventsStatus.PSObject.Properties['count'] -and $EventsStatus.count -ne $null) {
    try { $count = [int]$EventsStatus.count } catch { $count = 0 }
  }
  if ($count -lt 0) { $count = 0 }

  $schema = if ($EventsStatus.PSObject.Properties['schema'] -and $EventsStatus.schema) {
    [string]$EventsStatus.schema
  } else {
    'comparevi/runtime-event/v1'
  }

  return [ordered]@{
    schema = $schema
    path = $path
    present = $present
    count = $count
    source = if ($EventsStatus.PSObject.Properties['source']) { $EventsStatus.source } else { $null }
    lastEventAt = if ($EventsStatus.PSObject.Properties['lastEventAt']) { $EventsStatus.lastEventAt } else { $null }
    lastPhase = if ($EventsStatus.PSObject.Properties['lastPhase']) { $EventsStatus.lastPhase } else { $null }
    lastLevel = if ($EventsStatus.PSObject.Properties['lastLevel']) { $EventsStatus.lastLevel } else { $null }
  }
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

  $issueDir = Join-Path $RepoRoot 'tests/results/_agent/issue'
  if (-not (Test-Path -LiteralPath $issueDir -PathType Container)) {
    throw "Standing priority snapshots missing under $issueDir. Run 'node tools/npm/run-script.mjs priority:sync'."
  }

  $cachePath = Join-Path $RepoRoot '.agent_priority_cache.json'
  $cacheExists = Test-Path -LiteralPath $cachePath -PathType Leaf
  $cacheJson = $null
  if ($cacheExists) {
    try {
      $cacheJson = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw ("Standing priority cache parse failed: {0}" -f $_.Exception.Message)
    }

  }

  $noStandingPath = Join-Path $issueDir 'no-standing-priority.json'
  $noStanding = $null
  if (Test-Path -LiteralPath $noStandingPath -PathType Leaf) {
    try {
      $noStanding = Get-Content -LiteralPath $noStandingPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw ("Standing priority no-standing report parse failed: {0}" -f $_.Exception.Message)
    }
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

  $cacheState = if ($cacheJson -and $cacheJson.PSObject.Properties['state']) { [string]$cacheJson.state } else { $null }
  $cacheNumber = if ($cacheJson -and $cacheJson.PSObject.Properties['number']) { $cacheJson.number } else { $null }
  $cacheNoStandingReason = if ($cacheJson -and $cacheJson.PSObject.Properties['noStandingReason']) { [string]$cacheJson.noStandingReason } else { $null }
  $noStandingReason = if ($noStanding -and $noStanding.PSObject.Properties['reason']) { [string]$noStanding.reason } else { $null }
  $isQueueEmpty = (
    $null -eq $cacheNumber -and
    $cacheState -eq 'NONE' -and
    ($cacheNoStandingReason -eq 'queue-empty' -or $noStandingReason -eq 'queue-empty')
  )

  if (-not $isQueueEmpty -and -not $cacheExists -and $noStandingReason -eq 'queue-empty') {
    $isQueueEmpty = $true
  }

  if ($isQueueEmpty) {
    if (-not $noStanding) {
      $openIssueCount = if ($cacheJson -and $cacheJson.PSObject.Properties['noStandingOpenIssueCount']) {
        [int]$cacheJson.noStandingOpenIssueCount
      } else {
        0
      }
      $noStanding = [pscustomobject][ordered]@{
        schema = 'standing-priority/no-standing@v1'
        generatedAt = if ($cacheJson -and $cacheJson.PSObject.Properties['cachedAtUtc']) { $cacheJson.cachedAtUtc } else { $null }
        repository = if ($cacheJson -and $cacheJson.PSObject.Properties['repository']) { $cacheJson.repository } else { $null }
        labels = @()
        message = if ($cacheJson -and $cacheJson.PSObject.Properties['lastFetchError']) { $cacheJson.lastFetchError } else { 'Standing-priority queue is empty.' }
        reason = 'queue-empty'
        openIssueCount = $openIssueCount
        failOnMissing = $false
      }
    }

    return [ordered]@{
      mode = 'queue-empty'
      reason = if ($noStanding.PSObject.Properties['reason']) { $noStanding.reason } else { 'queue-empty' }
      openIssueCount = if ($noStanding.PSObject.Properties['openIssueCount']) { [int]$noStanding.openIssueCount } else { 0 }
      cachePath = if ($cacheExists) { $cachePath } else { $null }
      cache = $cacheJson
      snapshotPath = if (Test-Path -LiteralPath $noStandingPath -PathType Leaf) { $noStandingPath } else { $null }
      snapshot = $noStanding
      routerPath = if (Test-Path -LiteralPath $routerPath -PathType Leaf) { $routerPath } else { $null }
      router = $router
    }
  }

  $latestIssue = Get-ChildItem -LiteralPath $issueDir -Filter '*.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -match '^\d+$' } |
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

  $snapshotDigest = $snapshot.PSObject.Properties['digest'] ? $snapshot.digest : $null
  if ([string]::IsNullOrWhiteSpace($snapshotDigest)) {
    throw "Standing priority digest missing. Run 'node tools/npm/run-script.mjs priority:sync'."
  }

  if ($cacheExists) {
    if ($cacheNumber -ne $snapshot.number) {
      throw ("Standing priority mismatch: cache #{0} vs snapshot #{1}. Run 'node tools/npm/run-script.mjs priority:sync'." -f $cacheNumber, $snapshot.number)
    }

    $cacheDigest = $cacheJson.PSObject.Properties['issueDigest'] ? $cacheJson.issueDigest : $null
    if ([string]::IsNullOrWhiteSpace($cacheDigest)) {
      throw "Standing priority digest missing. Run 'node tools/npm/run-script.mjs priority:sync'."
    }
    if ($cacheDigest -ne $snapshotDigest) {
      throw ("Standing priority digest mismatch for issue #{0}. Run 'node tools/npm/run-script.mjs priority:sync'." -f $snapshot.number)
    }
  } else {
    $cacheJson = [pscustomobject][ordered]@{
      number = $snapshot.number
      title = if ($snapshot.PSObject.Properties['title']) { $snapshot.title } else { $null }
      url = if ($snapshot.PSObject.Properties['url']) { $snapshot.url } else { $null }
      state = if ($snapshot.PSObject.Properties['state']) { $snapshot.state } else { $null }
      labels = if ($snapshot.PSObject.Properties['labels']) { @($snapshot.labels) } else { @() }
      assignees = if ($snapshot.PSObject.Properties['assignees']) { @($snapshot.assignees) } else { @() }
      milestone = if ($snapshot.PSObject.Properties['milestone']) { $snapshot.milestone } else { $null }
      commentCount = if ($snapshot.PSObject.Properties['commentCount']) { $snapshot.commentCount } else { $null }
      lastSeenUpdatedAt = if ($snapshot.PSObject.Properties['updatedAt']) { $snapshot.updatedAt } else { $null }
      issueDigest = $snapshotDigest
      bodyDigest = if ($snapshot.PSObject.Properties['bodyDigest']) { $snapshot.bodyDigest } else { $null }
      cachedAtUtc = $null
      lastFetchSource = 'snapshot-only'
      lastFetchError = 'cache-missing'
    }
  }

  return [ordered]@{
    mode = 'issue'
    reason = $null
    openIssueCount = $null
    cachePath = if ($cacheExists) { $cachePath } else { $null }
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

function Get-NonEmptyStringValues {
  param([object]$InputObject)

  $values = @()
  foreach ($entry in @($InputObject)) {
    if ($null -eq $entry) { continue }
    $text = $entry.ToString()
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $values += $text
  }
  return $values
}

function Test-PlaneTransitionRecord {
  param([object]$Transition)

  if ($null -eq $Transition) { return $false }
  foreach ($requiredKey in @('from', 'to', 'action', 'via')) {
    $value = if ($Transition -is [System.Collections.IDictionary]) {
      if ($Transition.Contains($requiredKey)) { $Transition[$requiredKey] } else { $null }
    } elseif ($Transition.PSObject.Properties[$requiredKey]) {
      $Transition.$requiredKey
    } else {
      $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
      return $false
    }
  }
  return $true
}

function Get-HandoffPlaneTransitionSummary {
  param(
    [string]$RepoRoot,
    [string]$ResultsRoot
  )

  $summary = [ordered]@{
    schema = 'agent-handoff/plane-transition-v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    repoRoot = $RepoRoot
    resultsRoot = $ResultsRoot
    status = 'unavailable'
    reason = 'no-source-receipts'
    transitionCount = 0
    transitions = @()
    sources = @()
  }

  $candidateRoots = [System.Collections.Generic.List[string]]::new()
  foreach ($root in @($ResultsRoot, (Join-Path $RepoRoot 'tests/results'))) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $resolved = [System.IO.Path]::GetFullPath($root)
    if (-not $candidateRoots.Contains($resolved)) {
      $candidateRoots.Add($resolved) | Out-Null
    }
  }

  $candidateSpecs = [System.Collections.Generic.List[hashtable]]::new()
  foreach ($root in $candidateRoots) {
    $candidateSpecs.Add(@{ path = Join-Path $root 'origin-upstream-parity.json'; sourceType = 'parity'; label = 'results-root-parity' }) | Out-Null
    $candidateSpecs.Add(@{ path = Join-Path $root '_agent/issue/develop-sync-report.json'; sourceType = 'develop-sync'; label = 'develop-sync-report' }) | Out-Null
    $candidateSpecs.Add(@{ path = Join-Path $root '_agent/issue/origin-upstream-parity.json'; sourceType = 'parity'; label = 'origin-upstream-parity' }) | Out-Null
    $candidateSpecs.Add(@{ path = Join-Path $root '_agent/issue/personal-upstream-parity.json'; sourceType = 'parity'; label = 'personal-upstream-parity' }) | Out-Null
    $candidateSpecs.Add(@{ path = Join-Path $root '_agent/issue/origin-protected-develop-sync.json'; sourceType = 'protected-sync'; label = 'origin-protected-sync' }) | Out-Null
    $candidateSpecs.Add(@{ path = Join-Path $root '_agent/issue/personal-protected-develop-sync.json'; sourceType = 'protected-sync'; label = 'personal-protected-sync' }) | Out-Null
  }

  $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $hadFailure = $false

  foreach ($spec in $candidateSpecs) {
    $candidatePath = [System.IO.Path]::GetFullPath([string]$spec.path)
    if (-not $seenPaths.Add($candidatePath)) {
      continue
    }
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
      continue
    }

    $sourceRecord = [ordered]@{
      path = $candidatePath
      sourceType = $spec.sourceType
      label = $spec.label
      schema = $null
      status = 'ok'
      transitionCount = 0
      error = $null
    }

    try {
      $payload = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json -Depth 40 -ErrorAction Stop
    } catch {
      $sourceRecord.status = 'invalid-json'
      $sourceRecord.error = $_.Exception.Message
      $summary.sources += $sourceRecord
      $hadFailure = $true
      continue
    }

    if ($payload.PSObject.Properties['schema']) {
      $sourceRecord.schema = [string]$payload.schema
    }

    $transitionsForSource = @()
    if ($spec.sourceType -eq 'develop-sync') {
      $actions = if ($payload.PSObject.Properties['actions']) { @($payload.actions) } else { @() }
      foreach ($entry in $actions) {
        $transition = if ($entry.PSObject.Properties['planeTransition']) { $entry.planeTransition } else { $null }
        if (-not (Test-PlaneTransitionRecord -Transition $transition)) {
          continue
        }
        $transitionsForSource += [ordered]@{
          from = [string]$transition.from
          to = [string]$transition.to
          action = [string]$transition.action
          via = [string]$transition.via
          baseRepository = if ($transition.PSObject.Properties['baseRepository']) { [string]$transition.baseRepository } else { $null }
          headRepository = if ($transition.PSObject.Properties['headRepository']) { [string]$transition.headRepository } else { $null }
          sourcePath = $candidatePath
          sourceSchema = $sourceRecord.schema
          sourceType = $spec.sourceType
          sourceLabel = $spec.label
          remote = if ($entry.PSObject.Properties['remote']) { [string]$entry.remote } else { $null }
        }
      }
      if ($actions.Count -gt 0 -and $transitionsForSource.Count -eq 0) {
        $sourceRecord.status = 'missing-plane-transition'
        $sourceRecord.error = 'No valid planeTransition entries were found in develop-sync actions.'
        $hadFailure = $true
      }
    } else {
      $transition = if ($payload.PSObject.Properties['planeTransition']) { $payload.planeTransition } else { $null }
      if (Test-PlaneTransitionRecord -Transition $transition) {
        $transitionsForSource += [ordered]@{
          from = [string]$transition.from
          to = [string]$transition.to
          action = [string]$transition.action
          via = [string]$transition.via
          baseRepository = if ($transition.PSObject.Properties['baseRepository']) { [string]$transition.baseRepository } else { $null }
          headRepository = if ($transition.PSObject.Properties['headRepository']) { [string]$transition.headRepository } else { $null }
          sourcePath = $candidatePath
          sourceSchema = $sourceRecord.schema
          sourceType = $spec.sourceType
          sourceLabel = $spec.label
          remote = $null
        }
      } else {
        $sourceRecord.status = 'missing-plane-transition'
        $sourceRecord.error = 'Source report exists but does not contain a complete planeTransition payload.'
        $hadFailure = $true
      }
    }

    $sourceRecord.transitionCount = $transitionsForSource.Count
    if ($transitionsForSource.Count -gt 0) {
      $summary.transitions += $transitionsForSource
    }
    $summary.sources += $sourceRecord
  }

  $summary.transitionCount = @($summary.transitions).Count
  if (@($summary.sources).Count -eq 0) {
    $summary.status = 'unavailable'
    $summary.reason = 'no-source-receipts'
  } elseif ($hadFailure) {
    $summary.status = 'fail'
    $summary.reason = 'invalid-plane-transition-evidence'
  } elseif ($summary.transitionCount -gt 0) {
    $summary.status = 'ok'
    $summary.reason = $null
  } else {
    $summary.status = 'unavailable'
    $summary.reason = 'no-valid-plane-transitions'
  }

  return $summary
}

function Write-HandoffPlaneTransitionSummary {
  param(
    [string]$RepoRoot,
    [string]$ResultsRoot
  )

  $summary = Get-HandoffPlaneTransitionSummary -RepoRoot $RepoRoot -ResultsRoot $ResultsRoot
  $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
  New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
  $summaryPath = Join-Path $handoffDir 'plane-transition.json'
  ($summary | ConvertTo-Json -Depth 8) | Out-File -FilePath $summaryPath -Encoding utf8

  Write-Host ''
  Write-Host '[Plane Transition Evidence]' -ForegroundColor Cyan
  Write-Host ("  status   : {0}" -f (Format-NullableValue $summary.status))
  Write-Host ("  count    : {0}" -f (Format-NullableValue $summary.transitionCount))
  if ($summary.reason) {
    Write-Host ("  reason   : {0}" -f (Format-NullableValue $summary.reason))
  }
  foreach ($transition in @($summary.transitions | Select-Object -First 5)) {
    $remoteLabel = if ($transition.remote) { " remote=$($transition.remote)" } else { '' }
    Write-Host ("  - {0}->{1} ({2}) via {3}{4}" -f $transition.from, $transition.to, $transition.action, $transition.via, $remoteLabel)
  }

  if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @(
      '### Plane Transition Evidence',
      '',
      ('- Status: {0}' -f (Format-NullableValue $summary.status)),
      ('- Count: {0}' -f (Format-NullableValue $summary.transitionCount))
    )
    if ($summary.reason) {
      $lines += ('- Reason: {0}' -f (Format-NullableValue $summary.reason))
    }
    foreach ($transition in @($summary.transitions | Select-Object -First 5)) {
      $transitionLabel = '{0}->{1} ({2}) via {3}' -f $transition.from, $transition.to, $transition.action, $transition.via
      if ($transition.remote) {
        $transitionLabel = '{0} [remote={1}]' -f $transitionLabel, $transition.remote
      }
      $lines += ('- {0}' -f $transitionLabel)
    }
    ($lines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }

  return $summary
}

function Write-AgentSessionCapsule {
  param(
    [string]$ResultsRoot,
    [psobject]$PlaneTransitionSummary = $null
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
  $headValues = @(Get-NonEmptyStringValues -InputObject $head)
  if ($headValues.Count -gt 0) {
    $headSha = ($headValues[0]).Trim()
    if ($headSha) {
      $gitInfo.head = $headSha
      $gitInfo.shortHead = if ($headSha.Length -gt 12) { $headSha.Substring(0, 12) } else { $headSha }
    }
  }

  $branch = Invoke-Git -Arguments @('rev-parse','--abbrev-ref','HEAD')
  $branchValues = @(Get-NonEmptyStringValues -InputObject $branch)
  if ($branchValues.Count -gt 0) {
    $branchName = ($branchValues[0]).Trim()
    if ($branchName -and $branchName -ne 'HEAD') { $gitInfo.branch = $branchName }
  }

  $statusShort = Invoke-Git -Arguments @('status','--short','--branch')
  $statusShortValues = @(Get-NonEmptyStringValues -InputObject $statusShort)
  if ($statusShortValues.Count -gt 0) {
    $gitInfo.statusShort = ($statusShortValues -join "`n")
  }

  $statusPorcelain = Invoke-Git -Arguments @('status','--porcelain')
  $statusPorcelainValues = @(Get-NonEmptyStringValues -InputObject $statusPorcelain)
  if ($statusPorcelainValues.Count -gt 0) {
    $gitInfo.porcelain = @($statusPorcelainValues | ForEach-Object { $_ })
  }

  $diffStat = Invoke-Git -Arguments @('diff','--stat')
  $diffStatValues = @(Get-NonEmptyStringValues -InputObject $diffStat)
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
    @{ name = 'handoff.dockerReviewLoopSummary'; path = Join-Path $handoffDir 'docker-review-loop-summary.json' },
    @{ name = 'handoff.planeTransition'; path = Join-Path $handoffDir 'plane-transition.json' },
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
  if ($PlaneTransitionSummary) { $capsule.planeTransitions = $PlaneTransitionSummary }

  if ($priorityContext) {
    $topActions = $null
    if ($priorityContext.router -and $priorityContext.router.PSObject.Properties['actions']) {
      $topActions = @($priorityContext.router.actions | Select-Object -First 5 | ForEach-Object { $_.key })
    }

    if ($priorityContext.mode -eq 'queue-empty') {
      $capsule.standingPriority = [ordered]@{
        mode = 'queue-empty'
        reason = $priorityContext.reason
        openIssueCount = $priorityContext.openIssueCount
        summary = [ordered]@{
          schema = if ($priorityContext.snapshot.PSObject.Properties['schema']) { $priorityContext.snapshot.schema } else { $null }
          path = $priorityContext.snapshotPath
          generatedAt = if ($priorityContext.snapshot.PSObject.Properties['generatedAt']) { $priorityContext.snapshot.generatedAt } else { $null }
          message = if ($priorityContext.snapshot.PSObject.Properties['message']) { $priorityContext.snapshot.message } else { $null }
        }
        cache = [ordered]@{
          path = $priorityContext.cachePath
          cachedAtUtc = if ($priorityContext.cache) { $priorityContext.cache.cachedAtUtc } else { $null }
          lastSeenUpdatedAt = if ($priorityContext.cache) { $priorityContext.cache.lastSeenUpdatedAt } else { $null }
          issueDigest = if ($priorityContext.cache) { $priorityContext.cache.issueDigest } else { $null }
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
    } else {
      $capsule.standingPriority = [ordered]@{
        mode = 'issue'
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
    [switch]$RequestAutoTrim,
    [psobject]$PlaneTransitionSummary = $null
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
  $watcherEvents = $null
  if ($status.files -and $status.files.events) {
    $watcherEvents = New-WatcherEventsTelemetry -EventsStatus $status.files.events
    if ($watcherEvents) {
      Write-Host ("  events.present  : {0}" -f (Format-BoolLabel $watcherEvents.present))
      Write-Host ("  events.count    : {0}" -f (Format-NullableValue $watcherEvents.count))
      Write-Host ("  events.path     : {0}" -f (Format-NullableValue $watcherEvents.path))
      if ($watcherEvents.source) {
        Write-Host ("  events.source   : {0}" -f (Format-NullableValue $watcherEvents.source))
      }
      if ($watcherEvents.lastEventAt) {
        $eventDetails = $watcherEvents.lastEventAt
        if ($watcherEvents.lastLevel -or $watcherEvents.lastPhase) {
          $levelPhase = @($watcherEvents.lastLevel, $watcherEvents.lastPhase) | Where-Object { $_ -and $_ -ne '' }
          if ($levelPhase.Count -gt 0) {
            $eventDetails = '{0} ({1})' -f $watcherEvents.lastEventAt, ($levelPhase -join '/')
          }
        }
        Write-Host ("  events.last     : {0}" -f (Format-NullableValue $eventDetails))
      }
    }
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
    events = if ($watcherEvents) { $watcherEvents } else { $null }
    planeTransitions = if ($PlaneTransitionSummary) { $PlaneTransitionSummary } else { $null }
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
    if ($watcherEvents) {
      $summaryLines += "- Events: $(Format-BoolLabel $watcherEvents.present) ($($watcherEvents.count) line(s))"
      $summaryLines += "- Events Path: $($watcherEvents.path)"
      if ($watcherEvents.source) {
        $summaryLines += "- Events Source: $($watcherEvents.source)"
      }
      if ($watcherEvents.lastEventAt) {
        $eventSummary = $watcherEvents.lastEventAt
        if ($watcherEvents.lastLevel -or $watcherEvents.lastPhase) {
          $eventKinds = @($watcherEvents.lastLevel, $watcherEvents.lastPhase) | Where-Object { $_ -and $_ -ne '' }
          if ($eventKinds.Count -gt 0) {
            $eventSummary = '{0} ({1})' -f $watcherEvents.lastEventAt, ($eventKinds -join '/')
          }
        }
        $summaryLines += "- Events Last: $eventSummary"
      }
    }
    if ($PlaneTransitionSummary) {
      $summaryLines += "- Plane Transitions: $(Format-NullableValue $PlaneTransitionSummary.status) ($((Format-NullableValue $PlaneTransitionSummary.transitionCount)))"
      if ($PlaneTransitionSummary.reason) {
        $summaryLines += "- Plane Transition Reason: $(Format-NullableValue $PlaneTransitionSummary.reason)"
      }
    }
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

$entrypointCheck = Join-Path $PSScriptRoot 'Test-AgentHandoffEntryPoint.ps1'
if (Test-Path -LiteralPath $entrypointCheck -PathType Leaf) {
  try {
    & $entrypointCheck -HandoffPath $handoff -ResultsRoot $ResultsRoot -Quiet
  } catch {
    Write-Warning ("Handoff entrypoint contract failed: {0}" -f $_.Exception.Message)
  }
}

try {
  Ensure-StandingPriorityContext -RepoRoot (Resolve-Path '.').Path -ResultsRoot $ResultsRoot | Out-Null
} catch {
  Write-Warning ("Standing priority ensure failed: {0}" -f $_.Exception.Message)
}

try {
  $continuityScript = Join-Path $repoRoot 'tools' 'priority' 'continuity-telemetry.mjs'
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if ($nodeCmd -and (Test-Path -LiteralPath $continuityScript -PathType Leaf)) {
    $continuityRuntimePath = Join-Path $ResultsRoot '_agent/runtime/continuity-telemetry.json'
    $continuityHandoffPath = Join-Path $ResultsRoot '_agent/handoff/continuity-summary.json'
    & $nodeCmd.Source $continuityScript `
      --repo-root $repoRoot `
      --output $continuityRuntimePath `
      --handoff-output $continuityHandoffPath | Out-Host
  }
} catch {
  Write-Warning ("Failed to refresh continuity telemetry: {0}" -f $_.Exception.Message)
}

try {
  $repoGraphTruthScript = Join-Path $repoRoot 'tools' 'priority' 'downstream-repo-graph-truth.mjs'
  $templateVerificationSyncScript = Join-Path $repoRoot 'tools' 'priority' 'sync-template-agent-verification-report.mjs'
  $templatePivotGateScript = Join-Path $repoRoot 'tools' 'priority' 'template-pivot-gate.mjs'
  $monitoringModeScript = Join-Path $repoRoot 'tools' 'priority' 'handoff-monitoring-mode.mjs'
  $releaseSigningReadinessScript = Join-Path $repoRoot 'tools' 'priority' 'release-signing-readiness.mjs'
  $governorSummaryScript = Join-Path $repoRoot 'tools' 'priority' 'autonomous-governor-summary.mjs'
  $governorPortfolioSummaryScript = Join-Path $repoRoot 'tools' 'priority' 'autonomous-governor-portfolio-summary.mjs'
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if ($nodeCmd) {
    $promotionDir = Join-Path $ResultsRoot '_agent/promotion'
    $releaseDir = Join-Path $ResultsRoot '_agent/release'
    $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
    New-Item -ItemType Directory -Force -Path $promotionDir | Out-Null
    New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    $templateVerificationSeedPath = Join-Path $promotionDir 'template-agent-verification-report.json'
    $templateVerificationOverlayPath = Join-Path $promotionDir 'template-agent-verification-report.local.json'
    $templateVerificationSyncPath = Join-Path $promotionDir 'template-agent-verification-sync.json'
    $templatePivotGatePath = Join-Path $promotionDir 'template-pivot-gate-report.json'
    $releaseConductorReportPath = Join-Path $releaseDir 'release-conductor-report.json'
    $releaseSigningReadinessPath = Join-Path $releaseDir 'release-signing-readiness.json'
    $queueEmptyReportPath = Join-Path $repoRoot 'tests/results/_agent/issue/no-standing-priority.json'
    $entrypointStatusPath = Join-Path $ResultsRoot '_agent/handoff/entrypoint-status.json'
    $continuitySummaryPath = Join-Path $ResultsRoot '_agent/handoff/continuity-summary.json'
    $repoGraphTruthPath = Join-Path $handoffDir 'downstream-repo-graph-truth.json'
    $monitoringModePath = Join-Path $handoffDir 'monitoring-mode.json'
    $governorSummaryPath = Join-Path $handoffDir 'autonomous-governor-summary.json'
    $governorPortfolioSummaryPath = Join-Path $handoffDir 'autonomous-governor-portfolio-summary.json'

    if (Test-Path -LiteralPath $repoGraphTruthScript -PathType Leaf) {
      & $nodeCmd.Source $repoGraphTruthScript `
        --repo-root $repoRoot `
        --output $repoGraphTruthPath | Out-Host
    }

    if (Test-Path -LiteralPath $templateVerificationSyncScript -PathType Leaf) {
      & $nodeCmd.Source $templateVerificationSyncScript `
        --repo-root $repoRoot `
        --local-report $templateVerificationSeedPath `
        --local-overlay-report $templateVerificationOverlayPath `
        --output $templateVerificationSyncPath | Out-Host
    }

    if (Test-Path -LiteralPath $templatePivotGateScript -PathType Leaf) {
      & $nodeCmd.Source $templatePivotGateScript `
        --queue-empty-report $queueEmptyReportPath `
        --handoff-entrypoint $entrypointStatusPath `
        --template-agent-verification-report $templateVerificationSeedPath `
        --output $templatePivotGatePath | Out-Host
    }

    if (Test-Path -LiteralPath $monitoringModeScript -PathType Leaf) {
      & $nodeCmd.Source $monitoringModeScript `
        --repo-root $repoRoot `
        --repo-graph-truth $repoGraphTruthPath `
        --queue-empty-report $queueEmptyReportPath `
        --continuity-summary $continuitySummaryPath `
        --template-pivot-gate $templatePivotGatePath `
        --output $monitoringModePath | Out-Host
    }

    if (Test-Path -LiteralPath $releaseSigningReadinessScript -PathType Leaf) {
      & $nodeCmd.Source $releaseSigningReadinessScript `
        --repo-root $repoRoot `
        --release-conductor-report $releaseConductorReportPath `
        --output $releaseSigningReadinessPath | Out-Host
    }

    if (Test-Path -LiteralPath $governorSummaryScript -PathType Leaf) {
      & $nodeCmd.Source $governorSummaryScript `
        --repo-root $repoRoot `
        --queue-empty-report $queueEmptyReportPath `
        --continuity-summary $continuitySummaryPath `
        --monitoring-mode $monitoringModePath `
        --release-signing-readiness $releaseSigningReadinessPath `
        --output $governorSummaryPath | Out-Host
    }

    if (Test-Path -LiteralPath $governorPortfolioSummaryScript -PathType Leaf) {
      & $nodeCmd.Source $governorPortfolioSummaryScript `
        --repo-root $repoRoot `
        --compare-governor-summary $governorSummaryPath `
        --monitoring-mode $monitoringModePath `
        --repo-graph-truth $repoGraphTruthPath `
        --output $governorPortfolioSummaryPath | Out-Host
    }
  }
} catch {
  Write-Warning ("Failed to refresh monitoring-mode handoff state: {0}" -f $_.Exception.Message)
}

try {
  $priorityContext = Ensure-StandingPriorityContext -RepoRoot (Resolve-Path '.').Path -ResultsRoot $ResultsRoot
  if ($priorityContext) {
    Write-Host ''
    Write-Host '[Standing Priority]' -ForegroundColor Cyan
    if ($priorityContext.mode -eq 'queue-empty') {
      $noStanding = $priorityContext.snapshot
      Write-Host '  issue    : none (queue empty)'
      Write-Host ("  reason   : {0}" -f (Format-NullableValue $priorityContext.reason))
      Write-Host ("  open     : {0}" -f (Format-NullableValue $priorityContext.openIssueCount))
      Write-Host ("  message  : {0}" -f (Format-NullableValue $noStanding.message))
      Write-Host ("  merge    : n/a (idle repository)") -ForegroundColor DarkGray

      if ($env:GITHUB_STEP_SUMMARY) {
        $priorityLines = @(
          '### Standing Priority',
          '',
          '- Issue: none (queue empty)',
          ('- Reason: {0}  Open issues: {1}' -f (Format-NullableValue $priorityContext.reason), (Format-NullableValue $priorityContext.openIssueCount)),
          ('- Message: {0}' -f (Format-NullableValue $noStanding.message)),
          '- Merge: n/a (idle repository)'
        )
        ($priorityLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
      }
    } else {
      $issueSnap = $priorityContext.snapshot
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
    }

    $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    $issueSummaryDestination = Join-Path $handoffDir 'issue-summary.json'
    if ($priorityContext.snapshotPath) {
      Copy-Item -LiteralPath $priorityContext.snapshotPath -Destination (Join-Path $handoffDir 'issue-summary.json') -Force
    } elseif ($priorityContext.snapshot) {
      ($priorityContext.snapshot | ConvertTo-Json -Depth 6) | Out-File -FilePath $issueSummaryDestination -Encoding utf8
    }
    if ($priorityContext.routerPath) {
      Copy-Item -LiteralPath $priorityContext.routerPath -Destination (Join-Path $handoffDir 'issue-router.json') -Force
    }
  }
} catch {
  Write-Warning ("Failed to display standing priority summary: {0}" -f $_.Exception.Message)
}

try {
  $continuityPath = Join-Path $ResultsRoot '_agent/handoff/continuity-summary.json'
  if (Test-Path -LiteralPath $continuityPath -PathType Leaf) {
    $continuity = Get-Content -LiteralPath $continuityPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Host ''
    Write-Host '[Continuity]' -ForegroundColor Cyan
    Write-Host ("  status   : {0}" -f (Format-NullableValue $continuity.status))
    Write-Host ("  quiet    : {0}" -f (Format-NullableValue $continuity.continuity.quietPeriod.status))
    Write-Host ("  gap      : {0}s" -f (Format-NullableValue $continuity.continuity.quietPeriod.silenceGapSeconds))
    Write-Host ("  pause    : {0}" -f (Format-BoolLabel $continuity.continuity.quietPeriod.operatorQuietPeriodTreatedAsPause))
    Write-Host ("  context  : {0}" -f (Format-NullableValue $continuity.issueContext.mode))
    if ($continuity.continuity.turnBoundary) {
      Write-Host ("  boundary : {0}" -f (Format-NullableValue $continuity.continuity.turnBoundary.status))
      Write-Host ("  boundary-gap : {0}" -f (Format-BoolLabel $continuity.continuity.turnBoundary.operatorTurnEndWouldCreateIdleGap))
    }
    Write-Host ("  signals  : {0}" -f (Format-NullableValue $continuity.continuity.unattendedSignalCount))
    Write-Host ("  action   : {0}" -f (Format-NullableValue $continuity.continuity.recommendation))

    if ($env:GITHUB_STEP_SUMMARY) {
      $continuityLines = @(
        '### Continuity',
        '',
        ('- Status: {0}' -f (Format-NullableValue $continuity.status)),
        ('- Quiet period: {0}  Gap: {1}s' -f (Format-NullableValue $continuity.continuity.quietPeriod.status), (Format-NullableValue $continuity.continuity.quietPeriod.silenceGapSeconds)),
        ('- Operator quiet treated as pause: {0}' -f (Format-BoolLabel $continuity.continuity.quietPeriod.operatorQuietPeriodTreatedAsPause)),
        ('- Issue context: {0}' -f (Format-NullableValue $continuity.issueContext.mode)),
        ('- Turn boundary: {0}  Idle gap if ended now: {1}' -f (Format-NullableValue $continuity.continuity.turnBoundary.status), (Format-BoolLabel $continuity.continuity.turnBoundary.operatorTurnEndWouldCreateIdleGap)),
        ('- Unattended signals: {0}' -f (Format-NullableValue $continuity.continuity.unattendedSignalCount)),
        ('- Recommended action: {0}' -f (Format-NullableValue $continuity.continuity.recommendation))
      )
      ($continuityLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
} catch {
  Write-Warning ("Failed to display continuity summary: {0}" -f $_.Exception.Message)
}

try {
  $monitoringModePath = Join-Path $ResultsRoot '_agent/handoff/monitoring-mode.json'
  if (Test-Path -LiteralPath $monitoringModePath -PathType Leaf) {
    $monitoring = Get-Content -LiteralPath $monitoringModePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $triggeredWakeConditions = @()
    if ($monitoring.summary.triggeredWakeConditions) {
      $triggeredWakeConditions = @($monitoring.summary.triggeredWakeConditions | Where-Object { $_ })
    }
    Write-Host ''
    Write-Host '[Monitoring Mode]' -ForegroundColor Cyan
    Write-Host ("  status   : {0}" -f (Format-NullableValue $monitoring.summary.status))
    Write-Host ("  action   : {0}" -f (Format-NullableValue $monitoring.summary.futureAgentAction))
    Write-Host ("  queue    : {0}" -f (Format-NullableValue $monitoring.compare.queueState.status))
    Write-Host ("  continuity : {0}" -f (Format-NullableValue $monitoring.compare.continuity.status))
    Write-Host ("  pivot    : {0}" -f (Format-NullableValue $monitoring.compare.pivotGate.status))
    Write-Host ("  template : {0}" -f (Format-NullableValue $monitoring.templateMonitoring.status))
    if ($triggeredWakeConditions.Count -gt 0) {
      Write-Host ("  wake     : {0}" -f ($triggeredWakeConditions -join ', '))
    }

    if ($env:GITHUB_STEP_SUMMARY) {
      $monitoringLines = @(
        '### Monitoring Mode',
        '',
        ('- Status: {0}' -f (Format-NullableValue $monitoring.summary.status)),
        ('- Future-agent action: {0}' -f (Format-NullableValue $monitoring.summary.futureAgentAction)),
        ('- Compare: queue={0} continuity={1} pivot={2}' -f (Format-NullableValue $monitoring.compare.queueState.status), (Format-NullableValue $monitoring.compare.continuity.status), (Format-NullableValue $monitoring.compare.pivotGate.status)),
        ('- Template monitoring: {0}' -f (Format-NullableValue $monitoring.templateMonitoring.status))
      )
      if ($triggeredWakeConditions.Count -gt 0) {
        $monitoringLines += ('- Triggered wake conditions: {0}' -f ($triggeredWakeConditions -join ', '))
      }
      ($monitoringLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
} catch {
  Write-Warning ("Failed to display monitoring-mode summary: {0}" -f $_.Exception.Message)
}

try {
  $governorSummaryPath = Join-Path $ResultsRoot '_agent/handoff/autonomous-governor-summary.json'
  if (Test-Path -LiteralPath $governorSummaryPath -PathType Leaf) {
    $governor = Get-Content -LiteralPath $governorSummaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Host ''
    Write-Host '[Autonomous Governor]' -ForegroundColor Cyan
    Write-Host ("  mode     : {0}" -f (Format-NullableValue $governor.summary.governorMode))
    Write-Host ("  owner    : {0}" -f (Format-NullableValue $governor.summary.currentOwnerRepository))
    Write-Host ("  next     : {0}" -f (Format-NullableValue $governor.summary.nextAction))
    Write-Host ("  signal   : {0}" -f (Format-NullableValue $governor.summary.signalQuality))
    Write-Host ("  queue    : {0}" -f (Format-NullableValue $governor.summary.queueState))
    if ($governor.summary.PSObject.Properties['releaseSigningStatus']) {
      Write-Host ("  signing  : {0}" -f (Format-NullableValue $governor.summary.releaseSigningStatus))
      if ($governor.summary.PSObject.Properties['releaseSigningExternalBlocker'] -and $governor.summary.releaseSigningExternalBlocker) {
        Write-Host ("  blocker  : {0}" -f (Format-NullableValue $governor.summary.releaseSigningExternalBlocker))
      }
      if ($governor.summary.PSObject.Properties['releasePublicationState'] -and $governor.summary.releasePublicationState) {
        Write-Host ("  publish  : {0}" -f (Format-NullableValue $governor.summary.releasePublicationState))
      }
    }
    if ($governor.summary.nextOwnerRepository) {
      Write-Host ("  nextRepo : {0}" -f (Format-NullableValue $governor.summary.nextOwnerRepository))
    }
    if ($governor.summary.PSObject.Properties['queueHandoffStatus'] -and
        $governor.summary.queueHandoffStatus -and
        $governor.summary.queueHandoffStatus -ne 'none') {
      Write-Host ("  queueWait: {0}" -f (Format-NullableValue $governor.summary.queueHandoffStatus))
      Write-Host ("  queueWake: {0}" -f (Format-NullableValue $governor.summary.queueHandoffNextWakeCondition))
      if ($governor.summary.PSObject.Properties['queueAuthoritySource']) {
        Write-Host ("  queueSrc : {0}" -f (Format-NullableValue $governor.summary.queueAuthoritySource))
      }
      if ($governor.summary.PSObject.Properties['queueHandoffPrUrl'] -and $governor.summary.queueHandoffPrUrl) {
        Write-Host ("  pr       : {0}" -f (Format-NullableValue $governor.summary.queueHandoffPrUrl))
      }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
      $governorLines = @(
        '### Autonomous Governor',
        '',
        ('- Mode: {0}' -f (Format-NullableValue $governor.summary.governorMode)),
        ('- Current owner: {0}' -f (Format-NullableValue $governor.summary.currentOwnerRepository)),
        ('- Next action: {0}' -f (Format-NullableValue $governor.summary.nextAction)),
        ('- Signal quality: {0}' -f (Format-NullableValue $governor.summary.signalQuality)),
        ('- Queue state: {0}' -f (Format-NullableValue $governor.summary.queueState))
      )
      if ($governor.summary.PSObject.Properties['releaseSigningStatus']) {
        $governorLines += ('- Release signing: {0}' -f (Format-NullableValue $governor.summary.releaseSigningStatus))
        if ($governor.summary.PSObject.Properties['releaseSigningExternalBlocker'] -and $governor.summary.releaseSigningExternalBlocker) {
          $governorLines += ('- Release blocker: {0}' -f (Format-NullableValue $governor.summary.releaseSigningExternalBlocker))
        }
        if ($governor.summary.PSObject.Properties['releasePublicationState'] -and $governor.summary.releasePublicationState) {
          $governorLines += ('- Release publication: {0}' -f (Format-NullableValue $governor.summary.releasePublicationState))
        }
      }
      if ($governor.summary.nextOwnerRepository) {
        $governorLines += ('- Next owner: {0}' -f (Format-NullableValue $governor.summary.nextOwnerRepository))
      }
      if ($governor.summary.PSObject.Properties['queueHandoffStatus'] -and
          $governor.summary.queueHandoffStatus -and
          $governor.summary.queueHandoffStatus -ne 'none') {
        $governorLines += ('- Queue handoff: {0}' -f (Format-NullableValue $governor.summary.queueHandoffStatus))
        $governorLines += ('- Queue wake: {0}' -f (Format-NullableValue $governor.summary.queueHandoffNextWakeCondition))
        if ($governor.summary.PSObject.Properties['queueAuthoritySource']) {
          $governorLines += ('- Queue source: {0}' -f (Format-NullableValue $governor.summary.queueAuthoritySource))
        }
        if ($governor.summary.PSObject.Properties['queueHandoffPrUrl'] -and $governor.summary.queueHandoffPrUrl) {
          $governorLines += ('- Queue PR: {0}' -f (Format-NullableValue $governor.summary.queueHandoffPrUrl))
        }
      }
      ($governorLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
} catch {
  Write-Warning ("Failed to display autonomous governor summary: {0}" -f $_.Exception.Message)
}

try {
  $governorPortfolioSummaryPath = Join-Path $ResultsRoot '_agent/handoff/autonomous-governor-portfolio-summary.json'
  if (Test-Path -LiteralPath $governorPortfolioSummaryPath -PathType Leaf) {
    $portfolio = Get-Content -LiteralPath $governorPortfolioSummaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Host ''
    Write-Host '[Governor Portfolio]' -ForegroundColor Cyan
    Write-Host ("  mode     : {0}" -f (Format-NullableValue $portfolio.summary.governorMode))
    Write-Host ("  owner    : {0}" -f (Format-NullableValue $portfolio.summary.currentOwnerRepository))
    Write-Host ("  next     : {0}" -f (Format-NullableValue $portfolio.summary.nextAction))
    Write-Host ("  template : {0}" -f (Format-NullableValue $portfolio.summary.templateMonitoringStatus))
    Write-Host ("  proof    : {0}" -f (Format-NullableValue $portfolio.summary.supportedProofStatus))
    if ($portfolio.summary.PSObject.Properties['viHistoryDistributorDependencyStatus']) {
      Write-Host ("  vhist    : {0}" -f (Format-NullableValue $portfolio.summary.viHistoryDistributorDependencyStatus))
      if ($portfolio.summary.PSObject.Properties['viHistoryDistributorDependencyTargetRepository'] -and $portfolio.summary.viHistoryDistributorDependencyTargetRepository) {
        Write-Host ("  vhistRepo: {0}" -f (Format-NullableValue $portfolio.summary.viHistoryDistributorDependencyTargetRepository))
      }
      if ($portfolio.summary.PSObject.Properties['viHistoryDistributorDependencyExternalBlocker'] -and $portfolio.summary.viHistoryDistributorDependencyExternalBlocker) {
        Write-Host ("  vhistBlk : {0}" -f (Format-NullableValue $portfolio.summary.viHistoryDistributorDependencyExternalBlocker))
      }
    }
    if ($portfolio.summary.nextOwnerRepository) {
      Write-Host ("  nextRepo : {0}" -f (Format-NullableValue $portfolio.summary.nextOwnerRepository))
    }
    if ($portfolio.summary.PSObject.Properties['queueHandoffStatus'] -and
        $portfolio.summary.queueHandoffStatus) {
      Write-Host ("  queueWait: {0}" -f (Format-NullableValue $portfolio.summary.queueHandoffStatus))
      Write-Host ("  queueWake: {0}" -f (Format-NullableValue $portfolio.summary.queueHandoffNextWakeCondition))
      if ($portfolio.summary.PSObject.Properties['queueAuthoritySource']) {
        Write-Host ("  queueSrc : {0}" -f (Format-NullableValue $portfolio.summary.queueAuthoritySource))
      }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
      $portfolioLines = @(
        '### Governor Portfolio',
        '',
        ('- Mode: {0}' -f (Format-NullableValue $portfolio.summary.governorMode)),
        ('- Current owner: {0}' -f (Format-NullableValue $portfolio.summary.currentOwnerRepository)),
        ('- Next action: {0}' -f (Format-NullableValue $portfolio.summary.nextAction)),
        ('- Template monitoring: {0}' -f (Format-NullableValue $portfolio.summary.templateMonitoringStatus)),
        ('- Supported proof: {0}' -f (Format-NullableValue $portfolio.summary.supportedProofStatus))
      )
      if ($portfolio.summary.PSObject.Properties['viHistoryDistributorDependencyStatus']) {
        $portfolioLines += ('- VI-history dependency: {0}' -f (Format-NullableValue $portfolio.summary.viHistoryDistributorDependencyStatus))
        if ($portfolio.summary.PSObject.Properties['viHistoryDistributorDependencyTargetRepository'] -and $portfolio.summary.viHistoryDistributorDependencyTargetRepository) {
          $portfolioLines += ('- VI-history target: {0}' -f (Format-NullableValue $portfolio.summary.viHistoryDistributorDependencyTargetRepository))
        }
        if ($portfolio.summary.PSObject.Properties['viHistoryDistributorDependencyExternalBlocker'] -and $portfolio.summary.viHistoryDistributorDependencyExternalBlocker) {
          $portfolioLines += ('- VI-history blocker: {0}' -f (Format-NullableValue $portfolio.summary.viHistoryDistributorDependencyExternalBlocker))
        }
      }
      if ($portfolio.summary.nextOwnerRepository) {
        $portfolioLines += ('- Next owner: {0}' -f (Format-NullableValue $portfolio.summary.nextOwnerRepository))
      }
      if ($portfolio.summary.PSObject.Properties['queueHandoffStatus'] -and
          $portfolio.summary.queueHandoffStatus) {
        $portfolioLines += ('- Queue handoff: {0}' -f (Format-NullableValue $portfolio.summary.queueHandoffStatus))
        $portfolioLines += ('- Queue wake: {0}' -f (Format-NullableValue $portfolio.summary.queueHandoffNextWakeCondition))
        if ($portfolio.summary.PSObject.Properties['queueAuthoritySource']) {
          $portfolioLines += ('- Queue source: {0}' -f (Format-NullableValue $portfolio.summary.queueAuthoritySource))
        }
      }
      ($portfolioLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
} catch {
  Write-Warning ("Failed to display governor portfolio summary: {0}" -f $_.Exception.Message)
}

try {
  $steeringPath = Join-Path $ResultsRoot '_agent/handoff/operator-steering-event.json'
  if (Test-Path -LiteralPath $steeringPath -PathType Leaf) {
    $steering = Get-Content -LiteralPath $steeringPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Host ''
    Write-Host '[Operator Steering]' -ForegroundColor Cyan
    Write-Host ("  steering : {0}" -f (Format-NullableValue $steering.steeringKind))
    Write-Host ("  trigger  : {0}" -f (Format-NullableValue $steering.triggerKind))
    Write-Host ("  issue    : {0}" -f (Format-NullableValue $steering.issueContext.issue))
    Write-Host ("  funding  : {0}" -f (Format-NullableValue $steering.fundingWindow.invoiceTurnId))
    Write-Host ("  boundary : {0}" -f (Format-NullableValue $steering.continuity.turnBoundary.status))
    if ($env:GITHUB_STEP_SUMMARY) {
      $steeringLines = @(
        '### Operator Steering',
        '',
        ('- Steering kind: {0}' -f (Format-NullableValue $steering.steeringKind)),
        ('- Trigger kind: {0}' -f (Format-NullableValue $steering.triggerKind)),
        ('- Issue: {0}' -f (Format-NullableValue $steering.issueContext.issue)),
        ('- Funding window: {0}' -f (Format-NullableValue $steering.fundingWindow.invoiceTurnId)),
        ('- Continuity boundary: {0}' -f (Format-NullableValue $steering.continuity.turnBoundary.status))
      )
      ($steeringLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
} catch {
  Write-Warning ("Failed to display operator steering summary: {0}" -f $_.Exception.Message)
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
  $dockerReviewLoopSummaryPath = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/verification/docker-review-loop-summary.json'
  if (Test-Path -LiteralPath $dockerReviewLoopSummaryPath -PathType Leaf) {
    $dockerReviewLoopSummary = Get-Content -LiteralPath $dockerReviewLoopSummaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    Write-Host ''
    Write-Host '[Docker Review Loop Summary]' -ForegroundColor Cyan
    Write-Host ("  source   : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.authoritativeSource))
    if ($dockerReviewLoopSummary.PSObject.Properties['overall'] -and $dockerReviewLoopSummary.overall) {
      Write-Host ("  status   : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.overall.status))
      if ($dockerReviewLoopSummary.overall.failedCheck) {
        Write-Host ("  failed   : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.overall.failedCheck))
      }
      if ($dockerReviewLoopSummary.overall.message) {
        Write-Host ("  message  : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.overall.message))
      }
      Write-Host ("  exitCode : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.overall.exitCode))
    }
    if ($dockerReviewLoopSummary.PSObject.Properties['git'] -and $dockerReviewLoopSummary.git) {
      Write-Host ("  branch   : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.git.branch))
      Write-Host ("  head     : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.git.headSha))
      Write-Host ("  mergeBase: {0}" -f (Format-NullableValue $dockerReviewLoopSummary.git.upstreamDevelopMergeBase))
      Write-Host ("  dirty    : {0}" -f (Format-BoolLabel $dockerReviewLoopSummary.git.dirtyTracked))
    }
    if ($dockerReviewLoopSummary.PSObject.Properties['requirementsCoverage'] -and $dockerReviewLoopSummary.requirementsCoverage) {
      $coverage = $dockerReviewLoopSummary.requirementsCoverage
      Write-Host ("  reqs     : total={0} covered={1} uncovered={2}" -f (Format-NullableValue $coverage.requirementTotal), (Format-NullableValue $coverage.requirementCovered), (Format-NullableValue $coverage.requirementUncovered))
      if ($coverage.uncoveredRequirementIds -and @($coverage.uncoveredRequirementIds).Count -gt 0) {
        Write-Host ("  uncovered: {0}" -f ((@($coverage.uncoveredRequirementIds) -join ', ')))
      }
      if ($coverage.unknownRequirementIds -and @($coverage.unknownRequirementIds).Count -gt 0) {
        Write-Host ("  unknown  : {0}" -f ((@($coverage.unknownRequirementIds) -join ', ')))
      }
    }
    $handoffDir = Join-Path $ResultsRoot '_agent/handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    $dockerReviewLoopSummaryDest = Join-Path $handoffDir 'docker-review-loop-summary.json'
    $dockerReviewLoopSummarySourceFull = $dockerReviewLoopSummaryPath
    $dockerReviewLoopSummaryDestFull = $dockerReviewLoopSummaryDest
    try { $dockerReviewLoopSummarySourceFull = [System.IO.Path]::GetFullPath($dockerReviewLoopSummaryPath) } catch {}
    try { $dockerReviewLoopSummaryDestFull = [System.IO.Path]::GetFullPath($dockerReviewLoopSummaryDest) } catch {}
    if (-not [string]::Equals($dockerReviewLoopSummarySourceFull, $dockerReviewLoopSummaryDestFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      Copy-Item -LiteralPath $dockerReviewLoopSummaryPath -Destination $dockerReviewLoopSummaryDest -Force
    } else {
      Write-Verbose 'Docker review-loop summary already present at destination; skipping copy.'
    }

    if ($env:GITHUB_STEP_SUMMARY) {
      $dockerReviewLines = @(
        '### Docker Review Loop Summary',
        '',
        ('- Source: {0}' -f (Format-NullableValue $dockerReviewLoopSummary.authoritativeSource))
      )
      if ($dockerReviewLoopSummary.PSObject.Properties['overall'] -and $dockerReviewLoopSummary.overall) {
        $dockerReviewLines += ('- Status: {0}  Failed check: {1}  Exit: {2}' -f (Format-NullableValue $dockerReviewLoopSummary.overall.status), (Format-NullableValue $dockerReviewLoopSummary.overall.failedCheck), (Format-NullableValue $dockerReviewLoopSummary.overall.exitCode))
        if ($dockerReviewLoopSummary.overall.message) {
          $dockerReviewLines += ('- Message: {0}' -f (Format-NullableValue $dockerReviewLoopSummary.overall.message))
        }
      }
      if ($dockerReviewLoopSummary.PSObject.Properties['git'] -and $dockerReviewLoopSummary.git) {
        $dockerReviewLines += ('- Git: branch={0} head={1} mergeBase={2} dirty={3}' -f (Format-NullableValue $dockerReviewLoopSummary.git.branch), (Format-NullableValue $dockerReviewLoopSummary.git.headSha), (Format-NullableValue $dockerReviewLoopSummary.git.upstreamDevelopMergeBase), (Format-BoolLabel $dockerReviewLoopSummary.git.dirtyTracked))
      }
      if ($dockerReviewLoopSummary.PSObject.Properties['requirementsCoverage'] -and $dockerReviewLoopSummary.requirementsCoverage) {
        $coverage = $dockerReviewLoopSummary.requirementsCoverage
        $dockerReviewLines += ('- Requirements: total={0} covered={1} uncovered={2}' -f (Format-NullableValue $coverage.requirementTotal), (Format-NullableValue $coverage.requirementCovered), (Format-NullableValue $coverage.requirementUncovered))
      }
      ($dockerReviewLines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
  }
} catch {
  Write-Warning ("Failed to load Docker review-loop summary: {0}" -f $_.Exception.Message)
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

$planeTransitionSummary = Write-HandoffPlaneTransitionSummary -RepoRoot $repoRoot -ResultsRoot $ResultsRoot
Write-WatcherStatusSummary -ResultsRoot $ResultsRoot -RequestAutoTrim:$AutoTrim -PlaneTransitionSummary $planeTransitionSummary

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

Write-AgentSessionCapsule -ResultsRoot $ResultsRoot -PlaneTransitionSummary $planeTransitionSummary

if ($OpenDashboard) {
  $cli = Join-Path (Resolve-Path '.').Path 'tools/Dev-Dashboard.ps1'
  if (Test-Path -LiteralPath $cli) {
    & $cli -Group $Group -ResultsRoot $ResultsRoot -Html -Json | Out-Null
    Write-Host "Dashboard generated under: $ResultsRoot" -ForegroundColor Cyan
  } else {
    Write-Warning "Dev-Dashboard.ps1 not found at: $cli"
  }
}
