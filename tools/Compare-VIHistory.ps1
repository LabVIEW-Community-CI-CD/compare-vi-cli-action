param(
  [Parameter(Mandatory = $true)][string]$ViName,
  [string]$Branch = 'HEAD',
  [int]$MaxPairs = 20,
  [string]$ResultsDir = 'tests/results/ref-compare-history',
  [string]$LvCompareArgs,
  [string]$InvokeScriptPath,
  [switch]$FailOnDiff,
  [switch]$IncludeIdenticalPairs,
  [ValidateSet('skip','abort')][string]$MissingStrategy = 'skip',
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$IgnoreNonZero
  )

  $result = & git @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  if (-not $IgnoreNonZero -and $exitCode -ne 0) {
    throw "git $($Arguments -join ' ') failed: $result"
  }
  if ($result -is [System.Array]) {
    $lines = @($result)
  } else {
    $lines = ($result -split "`r?`n")
  }
  return @($lines | Where-Object { $_ -ne $null })
}

function Split-ArgString {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  $errors = $null
  $tokens = [System.Management.Automation.PSParser]::Tokenize($Value, [ref]$errors)
  $accepted = @('CommandArgument', 'String', 'Number', 'CommandParameter')
  $list = @()
  foreach ($token in $tokens) {
    if ($accepted -contains $token.Type) { $list += $token.Content }
  }
  return @($list | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ItemCount {
  param($Value)
  if ($null -eq $Value) { return 0 }
  if ($Value -is [System.Collections.IDictionary]) { return $Value.Count }
  if ($Value -is [System.Collections.ICollection]) { return $Value.Count }
  if ($Value -is [string]) { return ([string]::IsNullOrWhiteSpace($Value)) ? 0 : 1 }
  return (@($Value) | Measure-Object).Count
}

function Get-PropertyValue {
  param(
    [object]$InputObject,
    [Parameter(Mandatory = $true)][string]$PropertyName
  )

  if ($null -eq $InputObject) { return $null }

  $psMeta = $InputObject.PSObject
  $prop = $psMeta.Properties[$PropertyName]
  if ($prop) { return $prop.Value }

  if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($PropertyName)) {
    return $InputObject[$PropertyName]
  }

  return $null
}

function Resolve-ViRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$ViName,
    [Parameter(Mandatory = $true)][string[]]$Refs
  )

  $viLeaf = $ViName.Trim()
  if ([string]::IsNullOrWhiteSpace($viLeaf)) { throw "VI name cannot be empty." }
  $viLeafLower = $viLeaf.ToLowerInvariant()
  $refMatches = [ordered]@{}
  $pathLookup = @{}

  foreach ($ref in $Refs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
    $pathsForRef = @()
    $ls = Invoke-Git -Arguments @('ls-tree', '-r', '--name-only', $ref)
    foreach ($entry in @($ls)) {
      if (-not $entry) { continue }
      $leaf = (Split-Path $entry -Leaf)
      if ($leaf -and $leaf.ToLowerInvariant() -eq $viLeafLower) {
        $pathsForRef += $entry
        $lower = $entry.ToLowerInvariant()
        if (-not $pathLookup.ContainsKey($lower)) { $pathLookup[$lower] = $entry }
      }
    }
    if ($pathsForRef.Count -gt 0) { $refMatches[$ref] = $pathsForRef }
  }

  if ($refMatches.Count -eq 0) {
    throw "VI '$ViName' not found in refs: $($Refs -join ', ')"
  }

  $lowerLists = @()
  foreach ($pair in $refMatches.GetEnumerator()) {
    $lowerLists += ,(@($pair.Value | ForEach-Object { $_.ToLowerInvariant() }))
  }

  $commonLower = $lowerLists[0]
  for ($i = 1; $i -lt $lowerLists.Count; $i++) {
    $current = $lowerLists[$i]
    $commonLower = @($commonLower | Where-Object { $current -contains $_ })
  }

  $commonLower = @($commonLower | Select-Object -Unique)
  $commonPaths = @($commonLower | ForEach-Object { $pathLookup[$_] }) | Where-Object { $_ }
  $allLower = @($pathLookup.Keys)
  $allPaths = @($allLower | ForEach-Object { $pathLookup[$_] }) | Where-Object { $_ }

  $pathScore = {
    param([string]$PathValue)
    $score = 0
    if ($PathValue -match '^tmp-commit') { $score += 200 }
    elseif ($PathValue -match '^tmp') { $score += 150 }
    if ($PathValue -match '^tests/') { $score += 100 }
    $depth = (($PathValue -split '/').Count - 1)
    if ($depth -gt 0) { $score += ($depth * 25) }
    $score += [Math]::Min([int]$PathValue.Length, 500) / 10
    return $score
  }

  $candidates = @($commonPaths)
  if ($candidates.Count -eq 0) { $candidates = @($allPaths) }
  if ($candidates.Count -eq 0) {
    throw "Unable to resolve VI path for '$ViName'."
  }

  $ordered = $candidates | Sort-Object @{ Expression = { & $pathScore $_ } }, @{ Expression = { $_ } }
  $chosen = $ordered | Select-Object -First 1
  if (-not $chosen) { throw "Unable to resolve VI path for '$ViName'." }
  if ($candidates.Count -gt 1) {
    Write-Verbose ("[Compare-VIHistory] Multiple candidates for '{0}'; selected '{1}'" -f $ViName, $chosen)
  }
  return $chosen
}

function Get-ViPathOptional {
  param(
    [Parameter(Mandatory = $true)][string]$ViName,
    [Parameter(Mandatory = $true)][string]$Ref
  )
  try {
    return Resolve-ViRelativePath -ViName $ViName -Refs @($Ref)
  } catch {
    return $null
  }
}

$repoRoot = (Get-Location).Path
$compareScript = Join-Path $repoRoot 'tools' 'Compare-RefsToTemp.ps1'
if (-not (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
  throw "Compare-RefsToTemp.ps1 not found at expected path: $compareScript"
}

Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree') > $null

$branchPath = Get-ViPathOptional -ViName $ViName -Ref $Branch
if (-not $branchPath) {
  $message = "VI '$ViName' not found on branch/ref '$Branch'."
  if ($MissingStrategy -eq 'abort') { throw $message }
  Write-Host "$message Nothing to compare."
  exit 0
}
Write-Verbose "Resolved VI path at branch tip: $branchPath"

$logArgs = @('log', '--follow', '--format=%H', $Branch, '--', $branchPath)
$commitList = @(Invoke-Git -Arguments $logArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Write-Verbose ("Commit hashes (newest first): {0}" -f ($commitList -join ', '))
$commitCount = Get-ItemCount $commitList
if (-not $Quiet) { Write-Host "Commit count detected: $commitCount" }
if ($commitCount -lt 2) {
  Write-Host "Only one commit touches $ViName; nothing to compare."
  exit 0
}

if ($MaxPairs -lt 1) { $MaxPairs = 1 }
$targetPairs = $MaxPairs
$desiredCommits = $targetPairs + 1
$commitInfo = @()
$commitsWithVi = @()

foreach ($sha in $commitList) {
  $pathOpt = Get-ViPathOptional -ViName $ViName -Ref $sha
  $info = [pscustomobject]@{
    Commit = $sha
    Path   = $pathOpt
    HasVi  = [bool]$pathOpt
  }
  $commitInfo += $info
  if ($info.HasVi) { $commitsWithVi += $info }
  if ($commitsWithVi.Count -ge $desiredCommits) { break }
}

if ($MissingStrategy -eq 'abort' -and ($commitInfo | Where-Object { -not $_.HasVi }).Count -gt 0) {
  throw "Missing VI '$ViName' detected in commit window (strategy=abort)."
}

if (-not $Quiet) {
  $windowSha = $commitInfo | ForEach-Object { $_.Commit }
  Write-Host ("Evaluated commit window (newest->oldest): {0}" -f ($windowSha -join ', '))
}

$commitsWithViChrono = @($commitsWithVi.Clone())
[array]::Reverse($commitsWithViChrono)
Write-Verbose ("Commits with VI (oldest->newest): {0}" -f ($commitsWithViChrono.Commit -join ', '))

if ($commitsWithViChrono.Count -lt 2) {
  Write-Host "No commit pairs with '$ViName' present; nothing to compare."
  exit 0
}

$commitsWithViChrono = $commitsWithViChrono | Select-Object -First $desiredCommits
$pairs = @()
for ($i = 0; $i -lt $commitsWithViChrono.Count - 1; $i++) {
  $pairs += [pscustomobject]@{
    Index = $i
    RefA  = $commitsWithViChrono[$i].Commit
    PathA = $commitsWithViChrono[$i].Path
    RefB  = $commitsWithViChrono[$i + 1].Commit
    PathB = $commitsWithViChrono[$i + 1].Path
  }
}

$pairCount = Get-ItemCount $pairs
if (-not $Quiet) { Write-Host "Generated pair count: $pairCount" }
if ($pairCount -eq 0) {
  Write-Host "No commit pairs found for $ViName."
  exit 0
}

$commitInfoChrono = @($commitInfo.Clone())
[array]::Reverse($commitInfoChrono)
$missingSegments = @()
$currentSegment = $null
foreach ($info in $commitInfoChrono) {
  if ($info.HasVi) {
    if ($currentSegment) {
      $missingSegments += $currentSegment
      $currentSegment = $null
    }
  } else {
    if (-not $currentSegment) {
      $currentSegment = [ordered]@{
        startCommit = $info.Commit
        count       = 0
      }
    }
    $currentSegment.count++
  }
}
if ($currentSegment) { $missingSegments += $currentSegment }

$commitWindow = $commitInfoChrono | ForEach-Object {
  [ordered]@{
    commit = $_.Commit
    hasVi  = $_.HasVi
    path   = $_.Path
  }
}
$missingSegmentsSummary = $missingSegments | ForEach-Object {
  [ordered]@{
    startCommit = $_.startCommit
    count       = $_.count
  }
}

$resultsRoot = if ([System.IO.Path]::IsPathRooted($ResultsDir)) { $ResultsDir } else { Join-Path $repoRoot $ResultsDir }
New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null

$flagTokens = Split-ArgString -Value $LvCompareArgs
$summaryItems = @()
$hadFailure = $false
$markdownRows = @()
$firstDiffLogged = $false

function Get-BlobIdForPath {
  param(
    [Parameter(Mandatory = $true)][string]$Ref,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $output = Invoke-Git -Arguments @('rev-parse', "$Ref`:$Path") -IgnoreNonZero
  if (-not $output) { return $null }
  $first = ($output | Select-Object -First 1)
  if (-not $first) { return $null }
  return $first.Trim()
}

foreach ($pair in $pairs) {
  $refA = $pair.RefA
  $refB = $pair.RefB
  $index = $pair.Index
  $pairLabel = "{0:D2}-{1:D2}" -f $index, ($index + 1)

  $pathA = $pair.PathA
  $pathB = $pair.PathB
  $blobA = Get-BlobIdForPath -Ref $refA -Path $pathA
  $blobB = Get-BlobIdForPath -Ref $refB -Path $pathB
  $identical = ($blobA -ne $null -and $blobA -eq $blobB)

  if ($identical -and -not $IncludeIdenticalPairs) {
    $summaryItems += [ordered]@{
      refA              = $refA
      refB              = $refB
      pair              = $pairLabel
      pathA             = $pathA
      pathB             = $pathB
      skippedIdentical  = $true
      skippedMissing    = $false
      skipReason        = $null
      diff              = $false
      exitCode          = $null
      summaryJson       = $null
      reportHtml        = $null
      highlights        = @()
      blobA             = $blobA
      blobB             = $blobB
      lvcompare         = $null
    }
    $markdownRows += "| $pairLabel | Skipped (identical) | - | - |"
    continue
  }

  $outName = ('{0}-{1}' -f ($ViName -replace '[^A-Za-z0-9._-]+', '_'), $pairLabel)
  $args = @(
    '-NoLogo', '-NoProfile', '-File', $compareScript,
    '-ViName', $ViName,
    '-RefA', $refA,
    '-RefB', $refB,
    '-ResultsDir', $resultsRoot,
    '-OutName', $outName,
    '-Detailed',
    '-RenderReport',
    '-Quiet:$false'
  )
  if ($InvokeScriptPath) {
    $args += '-InvokeScriptPath'
    $args += $InvokeScriptPath
  }
  if ($flagTokens -and $flagTokens.Length -gt 0) {
    $args += '-LvCompareArgs'
    $args += ($flagTokens -join ' ')
  }
  if ($FailOnDiff) {
    $args += '-FailOnDiff:$true'
  } else {
    $args += '-FailOnDiff:$false'
  }

  if (-not $Quiet) {
    Write-Host "Comparing $ViName for commits $refA -> $refB (pair $pairLabel)..."
  }

  $proc = Start-Process -FilePath 'pwsh' -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
  $exitCode = $proc.ExitCode

  $compareSummaryPath = Join-Path $resultsRoot ("$outName-summary.json")
  $compareReportPath = Join-Path $resultsRoot ("$outName-artifacts")
  $summaryJson = $null
  $cliInfo = $null
  $diffResult = $null
  $highlights = @()
  $reportFile = $null

  if (Test-Path -LiteralPath $compareSummaryPath) {
    $summaryJson = Get-Content -LiteralPath $compareSummaryPath -Raw | ConvertFrom-Json -Depth 8
    $cliInfo = Get-PropertyValue -InputObject $summaryJson -PropertyName 'cli'
    $diffResult = Get-PropertyValue -InputObject $cliInfo -PropertyName 'diff'

    $outInfo = Get-PropertyValue -InputObject $summaryJson -PropertyName 'out'
    $reportFile = Get-PropertyValue -InputObject $outInfo -PropertyName 'reportHtml'
    if (-not $reportFile) {
      $artifactDir = Get-PropertyValue -InputObject $outInfo -PropertyName 'artifactDir'
      if ($artifactDir) {
        $candidateReport = Join-Path $artifactDir 'cli-report.html'
        if (Test-Path -LiteralPath $candidateReport) {
          $reportFile = $candidateReport
        }
      }
    }

    $highlightsValue = Get-PropertyValue -InputObject $cliInfo -PropertyName 'highlights'
    if ($highlightsValue) { $highlights = @($highlightsValue) }
  }

  $diffDetected = [bool]$diffResult
  if ($exitCode -ne 0) {
    if ($diffDetected) {
      if ($FailOnDiff) { $hadFailure = $true }
    } else {
      $hadFailure = $true
    }
  }

  $summaryItems += [ordered]@{
    refA             = $refA
    refB             = $refB
    pair             = $pairLabel
    pathA            = $pathA
    pathB            = $pathB
    skippedIdentical = $false
    skippedMissing   = $false
    skipReason       = $null
    diff             = [bool]$diffResult
    exitCode         = $exitCode
    summaryJson      = $compareSummaryPath
    reportHtml       = $reportFile
    highlights       = $highlights
    blobA            = $blobA
    blobB            = $blobB
    lvcompare        = $cliInfo
  }

  $status = if ($diffResult) { 'Diff' } elseif ($exitCode -eq 0) { 'No diff' } else { "Error ($exitCode)" }
  if ($diffResult -and -not $firstDiffLogged) {
    $status = "$status ⭐"
    $firstDiffLogged = $true
  }
  $highlightText = if (Get-ItemCount $highlights -gt 0) { ($highlights | Select-Object -First 2) -join '; ' } else { '' }
  $mkNotes = if ($highlightText) { $highlightText } elseif ($reportFile) { (Split-Path $reportFile -Leaf) } else { '' }
  $markdownRows += "| $pairLabel | $status | $exitCode | $mkNotes |"
}

$historySummary = [ordered]@{
  schema         = 'vi-history-compare/v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  viName         = $ViName
  branch         = $Branch
  resolvedPath   = $branchPath
  maxPairs       = $MaxPairs
  lvcompareArgs  = $flagTokens
  includeIdentical = [bool]$IncludeIdenticalPairs
  missingStrategy  = $MissingStrategy
  resultsDir     = $resultsRoot
  commitWindow   = $commitWindow
  missingSegments = $missingSegmentsSummary
  pairs          = $summaryItems
}

$summaryPath = Join-Path $resultsRoot 'history-summary.json'
$historySummary | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $summaryPath -Encoding utf8

if (-not $Quiet) {
  Write-Host "History summary written to $summaryPath"
}

if ($env:GITHUB_STEP_SUMMARY) {
  $lines = @(
    '### VI History Compare',
    '',
    "| Pair | Outcome | Exit | Notes |",
    "|------|---------|------|-------|"
  )
  if (Get-ItemCount $markdownRows -gt 0) {
    $lines += $markdownRows
  } else {
    $lines += "| - | - | - | - |"
  }
  if (Get-ItemCount $missingSegmentsSummary -gt 0) {
    $lines += ''
    $lines += '#### Missing segments'
    foreach ($segment in $missingSegmentsSummary) {
      $lines += ("- {0} commit(s) before {1} lacked {2}" -f $segment.count, $segment.startCommit, $ViName)
    }
  }
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($hadFailure) {
  throw "One or more comparisons failed. See $resultsRoot for details."
}
