#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$CasesPath = 'tests/cli-compare/cases.json',
  [string]$ResultsRoot = 'tests/results/compare-cli',
  [string]$LabVIEWCliPath,
  [switch]$PromptScaffold,
  [switch]$OpenReport,
  [switch]$AllowDiff,
  [switch]$DryRun,
  [string]$Filter,
  [string]$DefaultBase = 'VI1.vi',
  [string]$DefaultHead = 'VI2.vi'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$QUEUE_SCHEMA   = 'cli-compare-queue/v1'
$SUMMARY_SCHEMA = 'cli-compare-queue-summary/v1'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not [System.IO.Path]::IsPathRooted($DefaultBase)) {
  $DefaultBase = Join-Path $RepoRoot $DefaultBase
}
if (-not [System.IO.Path]::IsPathRooted($DefaultHead)) {
  $DefaultHead = Join-Path $RepoRoot $DefaultHead
}

function New-Dir([string]$Path){ if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Resolve-PathSafe([string]$Path){ try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { return $Path } }
function Resolve-CasePath([string]$Path){
  if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path $RepoRoot $Path)
}
function Sanitize-Token([string]$Value){ if (-not $Value) { return 'case' } return ($Value -replace '[^A-Za-z0-9_-]','-') }

function Get-OptionalPropertyValue {
  param(
    $Object,
    [string]$Name
  )
  if ($null -eq $Object -or -not $Name) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  if ($Object.PSObject -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
  return $null
}

function Get-CaseArray($Cases){
  return @($Cases)
}

function New-Queue {
  [ordered]@{
    schema      = $QUEUE_SCHEMA
    generatedAt = (Get-Date).ToString('o')
    updatedAt   = (Get-Date).ToString('o')
    cases       = @()
  }
}

function Normalize-QueueCase {
  param($Case,[int]$Index)

  $ordered = [ordered]@{}
  $ordered.id   = if ($Case.id) { [string]$Case.id } else { [string]::Format('case-{0:D3}',$Index) }
  $ordered.name = if ($Case.name) { [string]$Case.name } else { $ordered.id }

  $ordered.base = [string]$Case.base
  $ordered.head = [string]$Case.head
  if (-not $ordered.base -or -not $ordered.head) { throw "Case '$($ordered.id)' missing base/head values." }

  $tags = @()
  if ($Case.tags) {
    if ($Case.tags -is [string]) {
      $tags = $Case.tags.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
    } elseif ($Case.tags -is [System.Collections.IEnumerable]) {
      $tags = @($Case.tags | ForEach-Object { [string]$_ })
    }
  }
  $ordered.tags = ($tags | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

  $expectedNode = $null
  if ($Case -is [hashtable]) {
    if ($Case.ContainsKey('expected')) { $expectedNode = $Case['expected'] }
  } elseif ($Case.PSObject -and ($Case.PSObject.Properties.Name -contains 'expected')) {
    $expectedNode = $Case.expected
  }

  $expected = [ordered]@{}
  $diffRaw = $null
  if ($expectedNode) { $diffRaw = $expectedNode.diff }
  if ($diffRaw -is [bool]) { $diffRaw = if ($diffRaw) { 'true' } else { 'false' } }
  elseif ($diffRaw) { $diffRaw = $diffRaw.ToString().ToLowerInvariant() }
  if ($diffRaw -notin @('true','false','unknown')) { $diffRaw = 'false' }
  $expected.diff = $diffRaw

  $exitCodes = @()
  $exitRaw = $null
  if ($expectedNode) {
    if ($expectedNode -is [hashtable]) {
      if ($expectedNode.ContainsKey('exitCodes')) { $exitRaw = $expectedNode['exitCodes'] }
    } elseif ($expectedNode.PSObject -and ($expectedNode.PSObject.Properties.Name -contains 'exitCodes')) {
      $exitRaw = $expectedNode.exitCodes
    }
  }
  if ($exitRaw -is [System.Collections.IEnumerable] -and -not ($exitRaw -is [string])) {
    $exitCodes = @($exitRaw | ForEach-Object { try { [int]$_ } catch { } })
  } elseif ($exitRaw -is [string]) {
    foreach ($piece in $exitRaw.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)) {
      $trim = $piece.Trim()
      if ([int]::TryParse($trim, [ref]([int]$null))) { $exitCodes += [int]$trim }
    }
  }
  $expected.exitCodes = ($exitCodes | Where-Object { $_ -ne $null })
  $ordered.expected = $expected

  $cliOrdered = [ordered]@{}
  $cli = $null
  if ($Case -is [hashtable] -and $Case.ContainsKey('cli')) { $cli = $Case['cli'] }
  elseif ($Case.PSObject -and ($Case.PSObject.Properties.Name -contains 'cli')) { $cli = $Case.cli }

  if ($cli) {
    $formatValue = $null
    $extraArgsValue = $null
    if ($cli -is [hashtable]) {
      if ($cli.ContainsKey('format')) { $formatValue = $cli['format'] }
      if ($cli.ContainsKey('extraArgs')) { $extraArgsValue = $cli['extraArgs'] }
    } elseif ($cli.PSObject) {
      if ($cli.PSObject.Properties['format']) { $formatValue = $cli.format }
      if ($cli.PSObject.Properties['extraArgs']) { $extraArgsValue = $cli.extraArgs }
    }

    if ($formatValue) { $cliOrdered.format = [string]$formatValue }
    if ($extraArgsValue) {
      if ($extraArgsValue -is [string]) {
        $cliOrdered.extraArgs = @($extraArgsValue.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
      } elseif ($extraArgsValue -is [System.Collections.IEnumerable]) {
        $cliOrdered.extraArgs = @($extraArgsValue | ForEach-Object { [string]$_ })
      }
    }
  }
  if ((@($cliOrdered.Keys)).Length -gt 0) { $ordered.cli = $cliOrdered }

  $overridesOrdered = [ordered]@{}
  $overridesNode = $null
  if ($Case -is [hashtable] -and $Case.ContainsKey('overrides')) { $overridesNode = $Case['overrides'] }
  elseif ($Case.PSObject -and ($Case.PSObject.Properties.Name -contains 'overrides')) { $overridesNode = $Case.overrides }

  if ($overridesNode) {
    $cliPathValue = $null
    if ($overridesNode -is [hashtable]) {
      if ($overridesNode.ContainsKey('labviewCliPath')) { $cliPathValue = $overridesNode['labviewCliPath'] }
    } elseif ($overridesNode.PSObject -and $overridesNode.PSObject.Properties['labviewCliPath']) {
      $cliPathValue = $overridesNode.labviewCliPath
    }
    if ($cliPathValue) { $overridesOrdered.labviewCliPath = [string]$cliPathValue }
  }
  if ((@($overridesOrdered.Keys)).Length -gt 0) { $ordered.overrides = $overridesOrdered }

  $ordered.notes = if ($Case.notes) { [string]$Case.notes } else { '' }
  $disabledVal = $false
  if ($Case -is [hashtable]) {
    if ($Case.ContainsKey('disabled')) { $disabledVal = [bool]$Case['disabled'] }
  } elseif ($Case.PSObject -and ($Case.PSObject.Properties.Name -contains 'disabled')) {
    $disabledVal = [bool]$Case.disabled
  }
  $ordered.disabled = $disabledVal

  return $ordered
}

function Normalize-Queue {
  param($Queue)

  if (-not $Queue) { return (New-Queue) }

  $rawCases = @()
  if ($Queue -is [System.Collections.IEnumerable] -and -not ($Queue -is [hashtable]) -and -not ($Queue -is [pscustomobject])) {
    $rawCases = @($Queue)
    $Queue = New-Queue
  } elseif ($Queue.PSObject.Properties.Name -contains 'cases') {
    $rawCases = @($Queue.cases)
  } else {
    $rawCases = @($Queue)
    $Queue = New-Queue
  }

  $normalized = New-Queue
  foreach ($prop in $Queue.PSObject.Properties) {
    if ($prop.Name -in @('schema','cases')) { continue }
    $normalized[$prop.Name] = $prop.Value
  }

  $seen = New-Object System.Collections.Generic.HashSet[string]
  $casesOut = @()
  $rawArray = @($rawCases)
  for ($idx = 0; $idx -lt $rawArray.Length; $idx++) {
    $c = Normalize-QueueCase -Case $rawArray[$idx] -Index ($idx + 1)
    $baseId = $c.id
    $uniqueId = $baseId
    $suffix = 1
    while ($seen.Contains($uniqueId.ToLowerInvariant())) {
      $suffix++
      $uniqueId = "{0}-{1}" -f $baseId,$suffix
    }
    $seen.Add($uniqueId.ToLowerInvariant()) | Out-Null
    $c.id = $uniqueId
    $casesOut += $c
  }

  $normalized.cases = $casesOut
  if (-not $normalized.generatedAt) { $normalized.generatedAt = (Get-Date).ToString('o') }
  if (-not $normalized.updatedAt)  { $normalized.updatedAt  = $normalized.generatedAt }

  return $normalized
}

function Load-Queue([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (New-Queue) }
  try {
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-Warning "Unable to parse $Path, starting fresh. $_"
    return (New-Queue)
  }
  Normalize-Queue -Queue $json
}

function Save-Queue([hashtable]$Queue,[string]$Path){
  $Queue.updatedAt = (Get-Date).ToString('o')
  ($Queue | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $Path -Encoding utf8
  Write-Host ("Queue saved to {0}" -f (Resolve-PathSafe $Path)) -ForegroundColor Green
}

function Prompt-ExpectedDiff{
  param([string]$Default='false')
  $ans = Read-Host "Expected diff? (true/false/unknown) [$Default]"
  if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
  $val = $ans.Trim().ToLowerInvariant()
  if ($val -notin @('true','false','unknown')) { return $Default }
  return $val
}

function Prompt-ExitCodes([string]$Default){
  $ans = Read-Host "Expected exit codes (comma-separated, blank for $Default)"
  if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
  $codes = @()
  foreach ($part in $ans.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)) {
    if ([int]::TryParse($part.Trim(), [ref]([int]$null))) {
      $codes += [int]$part.Trim()
    }
  }
  if ((@($codes)).Length -gt 0) { return ($codes -join ',') }
  return $Default
}

function Add-CasesInteractive([ref]$Queue,[string]$CasesPath,[string]$DefaultBase,[string]$DefaultHead){
  Write-Host ("Scaffold CLI compare cases (Enter defaults or type 'done' to finish).") -ForegroundColor Cyan
  $added = @()
  while ($true) {
    $basePromptDefault = Resolve-CasePath $DefaultBase
    $headPromptDefault = Resolve-CasePath $DefaultHead

    $baseInput = Read-Host ("Base VI path [Enter=$basePromptDefault, 'done' to finish]")
    if ([string]::IsNullOrWhiteSpace($baseInput)) {
      $base = $basePromptDefault
    } elseif ($baseInput.Trim().ToLowerInvariant() -eq 'done') {
      break
    } else {
      $base = Resolve-CasePath $baseInput.Trim()
    }

    $headInput = Read-Host ("Head VI path [Enter=$headPromptDefault]")
    if ([string]::IsNullOrWhiteSpace($headInput)) {
      $head = $headPromptDefault
    } else {
      $head = Resolve-CasePath $headInput.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($head)) {
      Write-Host 'Head required; skipping entry.' -ForegroundColor Yellow
      continue
    }

    $nextIndex = (@($Queue.Value.cases)).Length + (@($added)).Length + 1
    $baseLeaf = [System.IO.Path]::GetFileNameWithoutExtension($base)
    $headLeaf = [System.IO.Path]::GetFileNameWithoutExtension($head)
    $slugCandidate = $null
    if ($baseLeaf -or $headLeaf) {
      $slugCandidate = Sanitize-Token ("{0}-{1}" -f ($baseLeaf ?? 'base'), ($headLeaf ?? 'head'))
      if ([string]::IsNullOrWhiteSpace($slugCandidate) -or $slugCandidate -eq 'case') { $slugCandidate = $null }
    }
    if (-not $slugCandidate) { $slugCandidate = [string]::Format('case-{0:D3}',$nextIndex) }
    $autoId = $slugCandidate.ToLowerInvariant()
    $idInput = Read-Host "Case id [$autoId]"
    $candidateId = if ([string]::IsNullOrWhiteSpace($idInput)) { $autoId } else { Sanitize-Token $idInput.Trim().ToLowerInvariant() }

    $existingIds = @()
    foreach ($existing in $Queue.Value.cases) {
      if ($existing -and $existing.id) { $existingIds += [string]$existing.id }
    }
    foreach ($existing in $added) {
      if ($existing -and $existing.id) { $existingIds += [string]$existing.id }
    }
    $uniqueId = $candidateId
    $suffix = 1
    while ($existingIds -contains $uniqueId) {
      $suffix++
      $uniqueId = "{0}-{1}" -f $candidateId,$suffix
    }

    $nameInput = Read-Host "Name [$uniqueId]"
    $name = if ([string]::IsNullOrWhiteSpace($nameInput)) { $uniqueId } else { $nameInput.Trim() }

    $tagsInput = Read-Host 'Tags (comma-separated, optional)'
    $tags = @()
    if ($tagsInput) {
      $tags = $tagsInput.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() }
    }

    $expectedDiff = Prompt-ExpectedDiff
    $defaultExit = if ($expectedDiff -eq 'true') { '1' } elseif ($expectedDiff -eq 'false') { '0' } else { '' }
    $exitCodesInput = Prompt-ExitCodes $defaultExit

    $cliFormatInput = Read-Host 'CLI report format (XML/HTML/TXT/DOCX, blank=XML)'
    $extraArgsInput = Read-Host 'CLI extra args (space-separated, optional)'
    $cliOverride = Read-Host 'Override LabVIEWCLI.exe path (optional)'
    $notes = Read-Host 'Notes (optional)'

    $raw = [ordered]@{
      id   = $uniqueId
      name = $name
      base = $base
      head = $head
      tags = $tags
      expected = [ordered]@{
        diff = $expectedDiff
        exitCodes = $exitCodesInput
      }
      cli = [ordered]@{
        format    = $cliFormatInput
        extraArgs = $extraArgsInput
      }
      overrides = [ordered]@{ labviewCliPath = $cliOverride }
      notes = $notes
    }

    $added += (Normalize-QueueCase -Case $raw -Index $nextIndex)
  }

  if ((@($added)).Length -eq 0) { Write-Host 'No cases added.' -ForegroundColor Yellow; return }

  foreach ($case in $added) { $Queue.Value.cases += $case }
  $Queue.Value = Normalize-Queue -Queue $Queue.Value
  Save-Queue -Queue $Queue.Value -Path $CasesPath
}

function Show-Cases([array]$Cases){
  Write-Host ''
  Write-Host 'Queued CLI compare cases:' -ForegroundColor Cyan
  $list = Get-CaseArray $Cases
  for ($i = 0; $i -lt $list.Length; $i++) {
    $case = $list[$i]
    $tagStr = if ($case.tags -and (@($case.tags)).Length -gt 0) { $case.tags -join ',' } else { '-' }
    $expectedDiff = $case.expected.diff
    $disabled = if ($case.disabled) { ' (disabled)' } else { '' }
    Write-Host ("[{0}] id={1} name={2} diff={3} tags={4}{5}" -f ($i+1), $case.id, $case.name, $expectedDiff, $tagStr, $disabled)
  }
  Write-Host ''
}

function Get-IndicesForToken([string]$Token,[array]$Cases){
  $token = $Token.Trim()
  if (-not $token) { return @() }
  $list = Get-CaseArray $Cases
  $max = $list.Length

  if ($token -match '^(\d+)-(\d+)$') {
    $start = [int]$Matches[1]; $end = [int]$Matches[2]
    if ($start -lt 1) { $start = 1 }
    if ($end -gt $max) { $end = $max }
    if ($end -lt $start) { return @() }
    return $start..$end
  }
  if ($token -match '^(\d+)$') {
    $idx = [int]$Matches[1]
    if ($idx -ge 1 -and $idx -le $max) { return @($idx) }
    return @()
  }
  if ($token -eq 'all') { return 1..$max }

  if ($token -like 'id:*') {
    $idTerm = $token.Substring(3)
    return @(for ($i=0; $i -lt $list.Length; $i++) {
      if ([string]::Equals($list[$i].id, $idTerm, [System.StringComparison]::OrdinalIgnoreCase)) { $i+1 }
    })
  }
  if ($token -like 'name:*') {
    $nameTerm = $token.Substring(5)
    return @(for ($i=0; $i -lt $list.Length; $i++) {
      if ($list[$i].name -and $list[$i].name.ToLowerInvariant().Contains($nameTerm.ToLowerInvariant())) { $i+1 }
    })
  }
  if ($token -like 'tag:*') {
    $tagTerm = $token.Substring(4)
    return @(for ($i=0; $i -lt $list.Length; $i++) {
      if ($list[$i].tags | Where-Object { $_.ToLowerInvariant() -eq $tagTerm.ToLowerInvariant() }) { $i+1 }
    })
  }

  return @(for ($i=0; $i -lt $list.Length; $i++) {
    if ($list[$i].id -and $list[$i].id.ToLowerInvariant() -eq $token.ToLowerInvariant()) { $i+1 }
  })
}

function Parse-Selection([string]$Selection,[array]$Cases){
  if ([string]::IsNullOrWhiteSpace($Selection)) { return @() }
  $list = Get-CaseArray $Cases
  $parts = $Selection.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
  $includeSets = @()
  $excludeSets = @()
  foreach ($rawPart in $parts) {
    $part = $rawPart.Trim()
    if (-not $part) { continue }
    $negate = $false
    if ($part.StartsWith('!')) { $negate = $true; $part = $part.Substring(1) }
    $indices = Get-IndicesForToken -Token $part -Cases $Cases
    if ($negate) { $excludeSets += ,$indices } else { $includeSets += ,$indices }
  }

  $resultSet = New-Object System.Collections.Generic.HashSet[int]
  if ((@($includeSets)).Length -eq 0) {
    foreach ($i in 1..$list.Length) { $resultSet.Add($i) | Out-Null }
  } else {
    foreach ($set in $includeSets) { foreach ($i in $set) { $resultSet.Add($i) | Out-Null } }
  }
  foreach ($set in $excludeSets) { foreach ($i in $set) { $resultSet.Remove($i) | Out-Null } }

  ,(@($resultSet) | Sort-Object)
}

function Write-SummaryFile([array]$Entries,[int[]]$Selected,[hashtable]$Queue,[string]$ResultsRoot,[bool]$HadFailure,[string]$CasesPath,[string]$Filter){
  $file = Join-Path $ResultsRoot 'queue-summary.json'
  New-Dir (Split-Path -Parent $file)
  $payload = [ordered]@{
    schema      = $SUMMARY_SCHEMA
    generatedAt = (Get-Date).ToString('o')
    casesPath   = Resolve-PathSafe $CasesPath
    resultsRoot = Resolve-PathSafe $ResultsRoot
    selection   = [ordered]@{ filter = $Filter; indexes = $Selected }
    cases       = $Entries
    success     = (-not $HadFailure)
  }
  ($payload | ConvertTo-Json -Depth 8) | Out-File -LiteralPath $file -Encoding utf8
  Write-Host ("Summary written to {0}" -f (Resolve-PathSafe $file)) -ForegroundColor Green
}

# --- Load / scaffold queue -------------------------------------------------

New-Dir (Split-Path -Parent $CasesPath)
New-Dir $ResultsRoot

$queue = Load-Queue -Path $CasesPath
$existingCases = Get-CaseArray $queue.cases
if ($PromptScaffold -or (@($existingCases)).Length -eq 0) {
  $queueRef = [ref]$queue
  Add-CasesInteractive -Queue $queueRef -CasesPath $CasesPath -DefaultBase $DefaultBase -DefaultHead $DefaultHead
  $queue = $queueRef.Value
}

$queue.cases = Get-CaseArray $queue.cases

if (-not $queue.cases -or (Get-CaseArray $queue.cases).Length -eq 0) { throw 'The CLI compare queue is empty.' }

Show-Cases -Cases $queue.cases

$selectedIdxs = @()
if ($Filter) {
  $selectedIdxs = Parse-Selection -Selection $Filter -Cases $queue.cases
if (-not $selectedIdxs -or (@($selectedIdxs)).Length -eq 0) { throw "Filter '$Filter' matched no cases." }
  Write-Host ("Filter '{0}' resolved to cases {1}" -f $Filter, ($selectedIdxs -join ',')) -ForegroundColor Cyan
} else {
  Write-Host 'Select cases (supports indexes, ranges, tag:<name>, name:<term>, id:<value>, !tag:<name> to exclude). Example: 1,3-4,tag:smoke' -ForegroundColor DarkGray
  $selectionInput = Read-Host 'Selection'
  $selectedIdxs = Parse-Selection -Selection $selectionInput -Cases $queue.cases
if (-not $selectedIdxs -or (@($selectedIdxs)).Length -eq 0) { throw 'Nothing selected.' }
}

$selectedIdxs = $selectedIdxs | Sort-Object

if ($DryRun) {
  Write-Host 'Dry-run mode: skipping LabVIEW CLI execution; emitting selection summary only.' -ForegroundColor Yellow
}

. (Join-Path $PSScriptRoot '..' 'scripts' 'CompareVI.ps1')

$failures = $false
$summaryEntries = @()

foreach ($idx in $selectedIdxs) {
  $case = $queue.cases[$idx-1]
  $entry = [ordered]@{
    index = $idx
    id    = $case.id
    name  = $case.name
    tags  = $case.tags
    base  = Resolve-PathSafe $case.base
    head  = Resolve-PathSafe $case.head
    expectedDiff      = $case.expected.diff
    expectedExitCodes = $case.expected.exitCodes
    status            = 'pending'
    notes             = ''
  }

  if ($case.disabled) {
    $entry.status = 'skipped'
    $entry.notes  = 'disabled'
    $summaryEntries += $entry
    Write-Host ("Skipping case {0} ({1}) - marked disabled." -f $case.id, $case.name) -ForegroundColor Yellow
    continue
  }

  $baseAbs = Resolve-PathSafe $case.base
  $headAbs = Resolve-PathSafe $case.head

  $token = Sanitize-Token $case.id
  $nunitPath = Join-Path $ResultsRoot ([string]::Format('results-nunit-{0}-{1}.xml',$idx,$token))
  $execPath  = Join-Path $ResultsRoot ([string]::Format('compare-exec-{0}-{1}.json',$idx,$token))
  $entry.nunit = $nunitPath
  $entry.exec  = $execPath

  $caseCli = Get-OptionalPropertyValue -Object $case -Name 'cli'
  $caseOverrides = Get-OptionalPropertyValue -Object $case -Name 'overrides'
  $cliFormat = Get-OptionalPropertyValue -Object $caseCli -Name 'format'
  $cliExtraArgs = Get-OptionalPropertyValue -Object $caseCli -Name 'extraArgs'
  $overrideLabViewCli = Get-OptionalPropertyValue -Object $caseOverrides -Name 'labviewCliPath'

  if ($DryRun) {
    $entry.validator = 'skipped'
    $entry.notes = 'dry-run (execution skipped)'
    $summaryEntries += $entry
    Write-Host ("Dry-run: case {0} ({1}) queued without execution." -f $case.id, $case.name) -ForegroundColor DarkYellow
    continue
  }

  $prevEnv = @{
    FORMAT = $env:LVCI_CLI_FORMAT
    EXTRA  = $env:LVCI_CLI_EXTRA_ARGS
    CLI    = $env:LABVIEW_CLI_PATH
  }

  try {
    $format = if ($cliFormat) { [string]$cliFormat } elseif ($env:LVCI_CLI_FORMAT) { $env:LVCI_CLI_FORMAT } else { 'XML' }
    $env:LVCI_CLI_FORMAT = $format

    if ($cliExtraArgs) {
      $extraVector = @()
      if ($cliExtraArgs -is [string]) {
        $extraVector = @($cliExtraArgs.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries))
      } elseif ($cliExtraArgs -is [System.Collections.IEnumerable]) {
        $extraVector = @($cliExtraArgs | ForEach-Object { [string]$_ })
      }
      if ($extraVector) {
        $env:LVCI_CLI_EXTRA_ARGS = ($extraVector -join ' ')
      } elseif ($prevEnv.EXTRA) {
        $env:LVCI_CLI_EXTRA_ARGS = $prevEnv.EXTRA
      } else {
        Remove-Item Env:LVCI_CLI_EXTRA_ARGS -ErrorAction SilentlyContinue
      }
    } elseif ($prevEnv.EXTRA) {
      $env:LVCI_CLI_EXTRA_ARGS = $prevEnv.EXTRA
    } else {
      Remove-Item Env:LVCI_CLI_EXTRA_ARGS -ErrorAction SilentlyContinue
    }

    if ($overrideLabViewCli) {
      $env:LABVIEW_CLI_PATH = Resolve-PathSafe $overrideLabViewCli
    } elseif ($LabVIEWCliPath) {
      $env:LABVIEW_CLI_PATH = Resolve-PathSafe $LabVIEWCliPath
    } elseif ($prevEnv.CLI) {
      $env:LABVIEW_CLI_PATH = $prevEnv.CLI
    } else {
      Remove-Item Env:LABVIEW_CLI_PATH -ErrorAction SilentlyContinue
    }

    $env:LVCI_CLI_NUNIT_PATH = $nunitPath

    $result = $null
    $validatorStatus = 'skipped'
    $validatorMessage = ''
    try {
      $result = Invoke-CompareVI -Base $baseAbs -Head $headAbs -FailOnDiff:$false -CompareExecJsonPath $execPath
      try {
        pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Assert-NUnitSuccess.ps1') -ResultsPath $nunitPath -Context ("Case {0}" -f $case.id) | Out-Null
        $validatorStatus = 'passed'
      } catch {
        $validatorStatus = 'failed'
        $validatorMessage = $_.Exception.Message
      }
    } catch {
      $entry.status = 'error'
      $entry.notes  = $_.Exception.Message
      $summaryEntries += $entry
      $failures = $true
      continue
    }

    $diff = $false
    $diffUnknown = $false
    if ($result.PSObject.Properties.Name -contains 'Diff') { $diff = [bool]$result.Diff }
    if ($result.PSObject.Properties.Name -contains 'DiffUnknown') { $diffUnknown = [bool]$result.DiffUnknown }
    $exitCode = if ($result.ExitCode -is [int]) { [int]$result.ExitCode } else { 0 }
    $reportPath = if ($result.PSObject.Properties.Name -contains 'ReportPath') { $result.ReportPath } else { $null }

    $entry.exitCode     = $exitCode
    $entry.diff         = $diff
    $entry.diffUnknown  = $diffUnknown
    $entry.validator    = $validatorStatus
    if ($validatorMessage) { $entry.validatorMessage = $validatorMessage }
    if ($reportPath) { $entry.report = Resolve-PathSafe $reportPath }

    $casePass = $true
    $notes = @()

    switch ($case.expected.diff) {
      'true' {
        if (-not $diff -and -not $AllowDiff) { $casePass = $false; $notes += 'expected diff but diff=false' }
        if ($validatorStatus -ne 'failed') {
          if ($AllowDiff) { $notes += 'expected diff but validator passed (ignored)' } else { $casePass = $false; $notes += 'expected diff but validator passed' }
        }
      }
      'false' {
        if ($diff) {
          if ($AllowDiff) { $notes += 'diff detected (ignored via AllowDiff)' } else { $casePass = $false; $notes += 'unexpected diff detected' }
        }
        if ($validatorStatus -ne 'passed') {
          if ($AllowDiff -and $validatorStatus -eq 'failed' -and ($validatorMessage -match 'Differences detected')) {
            $notes += 'validator diff failure ignored via AllowDiff'
          } else {
            $casePass = $false; $notes += "validator status: $validatorStatus ($validatorMessage)"
          }
        }
      }
      'unknown' {
        if ($validatorStatus -eq 'failed') {
          if ($AllowDiff -and ($validatorMessage -match 'Differences detected')) {
            $notes += 'validator diff failure ignored via AllowDiff'
          } else {
            $casePass = $false; $notes += "validator status: $validatorStatus ($validatorMessage)"
          }
        }
      }
    }

    if ($diffUnknown -and $case.expected.diff -ne 'unknown') {
      $casePass = $false
      $notes += 'diff status unknown'
    }

    if ($case.expected.exitCodes -and (@($case.expected.exitCodes)).Length -gt 0) {
      if (-not ($case.expected.exitCodes -contains $exitCode)) {
        $casePass = $false
        $notes += "exit code $exitCode not in expected set [$($case.expected.exitCodes -join ',')]"
      }
    }

    if ($OpenReport -and $reportPath -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
      Write-Host ("Report: {0}" -f (Resolve-PathSafe $reportPath)) -ForegroundColor DarkCyan
    }

    $entry.status = if ($casePass) { 'passed' } else { 'failed' }
    if ((@($notes)).Length -gt 0) { $entry.notes = ($notes -join '; ') }

    if (-not $casePass) { $failures = $true }

  } finally {
    if ($prevEnv.FORMAT) { $env:LVCI_CLI_FORMAT = $prevEnv.FORMAT } else { Remove-Item Env:LVCI_CLI_FORMAT -ErrorAction SilentlyContinue }
    if ($prevEnv.EXTRA)  { $env:LVCI_CLI_EXTRA_ARGS = $prevEnv.EXTRA } else { Remove-Item Env:LVCI_CLI_EXTRA_ARGS -ErrorAction SilentlyContinue }
    if ($prevEnv.CLI)    { $env:LABVIEW_CLI_PATH = $prevEnv.CLI } else { Remove-Item Env:LABVIEW_CLI_PATH -ErrorAction SilentlyContinue }
    Remove-Item Env:LVCI_CLI_NUNIT_PATH -ErrorAction SilentlyContinue
  }

  $summaryEntries += $entry
}

Write-Host ''
Write-Host 'CLI Compare run summary:' -ForegroundColor Cyan
foreach ($row in $summaryEntries) {
  $indexVal = Get-OptionalPropertyValue -Object $row -Name 'index'
  $idVal = Get-OptionalPropertyValue -Object $row -Name 'id'
  $statusVal = Get-OptionalPropertyValue -Object $row -Name 'status'
  $exitVal = Get-OptionalPropertyValue -Object $row -Name 'exitCode'
  $diffVal = Get-OptionalPropertyValue -Object $row -Name 'diff'
  $nunitVal = Get-OptionalPropertyValue -Object $row -Name 'nunit'
  Write-Host ("- case={0} id={1} status={2} exit={3} diff={4} nunit={5}" -f $indexVal, $idVal, $statusVal, ($exitVal ?? '-'), ($diffVal ?? '-'), ($nunitVal ?? '-'))
}

Write-SummaryFile -Entries $summaryEntries -Selected $selectedIdxs -Queue $queue -ResultsRoot $ResultsRoot -HadFailure $failures -CasesPath $CasesPath -Filter $Filter

if ($failures) { exit 1 } else { exit 0 }
