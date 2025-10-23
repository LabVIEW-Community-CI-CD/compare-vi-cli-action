param(
  [Parameter(Mandatory = $true)]
  [string]$TargetPath,

  [string]$StartRef = 'HEAD',
  [string]$EndRef,
  [int]$MaxPairs,

  [bool]$FlagNoAttr = $true,
  [bool]$FlagNoFp = $true,
  [bool]$FlagNoFpPos = $true,
  [bool]$FlagNoBdCosm = $true,
  [bool]$ForceNoBd = $true,
  [string]$AdditionalFlags,
  [string]$LvCompareArgs,
  [switch]$ReplaceFlags,

  [ValidateSet('default','attributes','front-panel','block-diagram','all','custom')]
  [string]$Mode = 'default',
  [switch]$FailFast,
  [switch]$FailOnDiff,

  [string]$ResultsDir = 'tests/results/ref-compare/history',
  [string]$OutPrefix,
  [string]$ManifestPath,
  [switch]$Detailed,
  [switch]$RenderReport,
  [switch]$KeepArtifactsOnNoDiff,
  [string]$InvokeScriptPath,

  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Split-ArgString {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  $errors = $null
  $tokens = [System.Management.Automation.PSParser]::Tokenize($Value, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    $messages = @($errors | ForEach-Object { $_.Message.Trim() } | Where-Object { $_ })
    if ($messages.Count -gt 0) {
      throw ("Failed to parse argument string '{0}': {1}" -f $Value, ($messages -join '; '))
    }
  }
  $accepted = @('CommandArgument','String','Number','CommandParameter')
  $list = @()
  foreach ($token in $tokens) {
    if ($accepted -contains $token.Type) { $list += $token.Content }
  }
  return @($list | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$Quiet
  )
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'git'
  foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  if ($proc.ExitCode -ne 0) {
    $msg = "git {0} failed with exit code {1}" -f ($Arguments -join ' '), $proc.ExitCode
    if ($stderr) { $msg = "$msg`n$stderr" }
    throw $msg
  }
  if (-not $Quiet -and $stderr) { Write-Verbose $stderr }
  return $stdout
}

function Invoke-Pwsh {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'pwsh'
  foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $repoRoot
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  [pscustomobject]@{
    ExitCode = $proc.ExitCode
    StdOut   = $stdout
    StdErr   = $stderr
  }
}

function Ensure-FileExistsAtRef {
  param(
    [Parameter(Mandatory = $true)][string]$Ref,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $expr = "{0}:{1}" -f $Ref, $Path
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'git'
  foreach ($arg in @('cat-file','-e', $expr)) { [void]$psi.ArgumentList.Add($arg) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $proc.WaitForExit()
  if ($proc.ExitCode -ne 0) {
    throw ("Target '{0}' not present at {1}" -f $Path, $Ref)
  }
}

function Test-FileExistsAtRef {
  param(
    [Parameter(Mandatory = $true)][string]$Ref,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $expr = "{0}:{1}" -f $Ref, $Path
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'git'
  foreach ($arg in @('cat-file','-e', $expr)) { [void]$psi.ArgumentList.Add($arg) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $proc.WaitForExit()
  return ($proc.ExitCode -eq 0)
}

function Test-CommitTouchesPath {
  param(
    [Parameter(Mandatory = $true)][string]$Commit,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $result = Invoke-Git -Arguments @('diff-tree','--no-commit-id','--name-only','-r',$Commit,'--',$Path) -Quiet
  return -not [string]::IsNullOrWhiteSpace($result)
}

function Test-IsAncestor {
  param(
    [Parameter(Mandatory = $true)][string]$Ancestor,
    [Parameter(Mandatory = $true)][string]$Descendant
  )
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'git'
  foreach ($arg in @('merge-base','--is-ancestor', $Ancestor, $Descendant)) { [void]$psi.ArgumentList.Add($arg) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $proc.WaitForExit()
  if ($proc.ExitCode -eq 0) { return $true }
  if ($proc.ExitCode -eq 1) { return $false }
  $stderr = $proc.StandardError.ReadToEnd()
  throw ("git merge-base --is-ancestor failed: {0}" -f $stderr)
}

function Resolve-CommitWithChange {
  param(
    [Parameter(Mandatory = $true)][string]$StartRef,
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$HeadRef = 'HEAD'
  )

  if (Test-CommitTouchesPath -Commit $StartRef -Path $Path) {
    return $StartRef
  }

  $upRaw = Invoke-Git -Arguments @('rev-list','--first-parent',"$StartRef..$HeadRef",'--',$Path) -Quiet
  $upList = @($upRaw -split "`n" | Where-Object { $_ })
  if ($upList.Count -gt 0) {
    for ($i = $upList.Count - 1; $i -ge 0; $i--) {
      $commit = $upList[$i]
      if (Test-IsAncestor -Ancestor $StartRef -Descendant $commit) {
        return $commit
      }
    }
  }

  $downRaw = Invoke-Git -Arguments @('rev-list','--first-parent',$StartRef,'--',$Path) -Quiet
  $downList = @($downRaw -split "`n" | Where-Object { $_ })
  if ($downList.Count -gt 0) {
    foreach ($commit in $downList) {
      if (Test-CommitTouchesPath -Commit $commit -Path $Path) {
        return $commit
      }
    }
  }

  return $StartRef
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Value,
    [string]$DestPath
  )
  $dest = if ($DestPath) { $DestPath } elseif ($env:GITHUB_OUTPUT) { $env:GITHUB_OUTPUT } else { $null }
  if (-not $dest) { return }
  $Value = $Value -replace "`r","" -replace "`n","`n"
  "$Key=$Value" | Out-File -FilePath $dest -Encoding utf8 -Append
}

function Write-StepSummary {
  param(
    [Parameter(Mandatory = $true)][object[]]$Lines,
    [string]$DestPath
  )
  $dest = if ($DestPath) { $DestPath } elseif ($env:GITHUB_STEP_SUMMARY) { $env:GITHUB_STEP_SUMMARY } else { $null }
  if (-not $dest) { return }
  $stringLines = @()
  foreach ($line in $Lines) {
    if ($line -eq $null) { $stringLines += '' } else { $stringLines += [string]$line }
  }
  $stringLines -join "`n" | Out-File -FilePath $dest -Encoding utf8 -Append
}

function Get-ShortSha {
  param(
    [string]$Value,
    [int]$Length = 12
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
  if ($Value.Length -le $Length) { return $Value }
  return $Value.Substring(0, $Length)
}

try { Invoke-Git -Arguments @('--version') -Quiet | Out-Null } catch { throw 'git must be available on PATH.' }

$repoRoot = (Get-Location).Path

$targetRel = ($TargetPath -replace '\\','/').Trim('/')
if ([string]::IsNullOrWhiteSpace($targetRel)) { throw 'TargetPath cannot be empty.' }
$targetLeaf = Split-Path $targetRel -Leaf
if ([string]::IsNullOrWhiteSpace($targetLeaf)) { $targetLeaf = 'vi' }

$startRef = if ([string]::IsNullOrWhiteSpace($StartRef)) { 'HEAD' } else { $StartRef.Trim() }
if ([string]::IsNullOrWhiteSpace($startRef)) { $startRef = 'HEAD' }
$endRef = if ([string]::IsNullOrWhiteSpace($EndRef)) { $null } else { $EndRef.Trim() }

if (-not $Mode) { $Mode = 'default' }
$modeEffective = $Mode.ToLowerInvariant()

$requestedStartRef = $startRef
$resolvedStartRef = Resolve-CommitWithChange -StartRef $startRef -Path $targetRel -HeadRef 'HEAD'
if (-not $resolvedStartRef) {
  throw ("Unable to locate a commit near {0} that modifies '{1}'." -f $startRef, $targetRel)
}
if ($resolvedStartRef -ne $startRef) {
  Write-Host ("[Compare-VIHistory] Adjusted start ref from {0} to {1} to locate a change in {2}" -f (Get-ShortSha $startRef 12), (Get-ShortSha $resolvedStartRef 12), $targetRel)
  $startRef = $resolvedStartRef
}

# Build flag list
$flagTokens = @()
$includeBdIgnore = $ForceNoBd
$includeAttrIgnore = $FlagNoAttr
$includeFpIgnore = $FlagNoFp
$includeFpPosIgnore = $FlagNoFpPos
$includeBdCosmIgnore = $FlagNoBdCosm

switch ($modeEffective) {
  'attributes'   { $includeAttrIgnore = $false }
  'front-panel'  {
    $includeFpIgnore = $false
    $includeFpPosIgnore = $false
  }
  'block-diagram' { $includeBdCosmIgnore = $false }
  'all' {
    $includeBdIgnore = $false
    $includeAttrIgnore = $false
    $includeFpIgnore = $false
    $includeFpPosIgnore = $false
    $includeBdCosmIgnore = $false
  }
  default { }
}

if ($includeBdIgnore) { $flagTokens += '-nobd' }
if ($includeAttrIgnore) { $flagTokens += '-noattr' }
if ($includeFpIgnore) { $flagTokens += '-nofp' }
if ($includeFpPosIgnore) { $flagTokens += '-nofppos' }
if ($includeBdCosmIgnore) { $flagTokens += '-nobdcosm' }

if (-not $ReplaceFlags -and -not [string]::IsNullOrWhiteSpace($AdditionalFlags)) {
  $flagTokens += Split-ArgString -Value $AdditionalFlags
}

if ($ReplaceFlags -and $LvCompareArgs) {
  $flagTokens = Split-ArgString -Value $LvCompareArgs
} elseif ($LvCompareArgs) {
  $flagTokens += Split-ArgString -Value $LvCompareArgs
}

$resultsRoot = if ([System.IO.Path]::IsPathRooted($ResultsDir)) { $ResultsDir } else { Join-Path $repoRoot $ResultsDir }
New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

$manifestPathResolved = if ($ManifestPath) {
  if ([System.IO.Path]::IsPathRooted($ManifestPath)) { $ManifestPath } else { Join-Path $repoRoot $ManifestPath }
} else {
  Join-Path $resultsRoot 'manifest.json'
}

$outPrefixToken = if ($OutPrefix) { $OutPrefix } else { $targetLeaf -replace '[^A-Za-z0-9._-]+','_' }
if ([string]::IsNullOrWhiteSpace($outPrefixToken)) { $outPrefixToken = 'vi-history' }

$manifest = [ordered]@{
  schema      = 'vi-compare/history@v1'
  generatedAt = (Get-Date).ToString('o')
  targetPath  = $targetRel
  requestedStartRef = $requestedStartRef
  startRef    = $startRef
  endRef      = $endRef
  maxPairs    = $MaxPairs
  failFast    = [bool]$FailFast.IsPresent
  failOnDiff  = [bool]$FailOnDiff.IsPresent
  mode        = $modeEffective
  flags       = $flagTokens
  resultsDir  = $resultsRoot
  comparisons = @()
  stats       = [ordered]@{
    processed        = 0
    diffs            = 0
    lastDiffIndex    = $null
    lastDiffCommit   = $null
    stopReason       = $null
    errors           = 0
    missing          = 0
  }
  status      = 'pending'
}

Ensure-FileExistsAtRef -Ref $startRef -Path $targetRel
if ($endRef) { Ensure-FileExistsAtRef -Ref $endRef -Path $targetRel }

$revArgs = @('rev-list','--first-parent',$startRef)
if ($MaxPairs -gt 0) {
  # Need parent for each pair; request +1 commits to ensure parent retrieval.
  $revArgs += ("--max-count={0}" -f ([int]($MaxPairs + 5)))
}
$revArgs += '--'
$revArgs += $targetRel
$revListRaw = Invoke-Git -Arguments $revArgs -Quiet
$commitList = @($revListRaw -split "`n" | Where-Object { $_ })
if ($commitList.Count -eq 0) {
  throw ("No commits found for {0} reachable from {1}" -f $targetRel, $startRef)
}

$compareScript = Join-Path $repoRoot 'tools' 'Compare-RefsToTemp.ps1'
if (-not (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
  throw ("Compare script not found: {0}" -f $compareScript)
}

$summaryLines = @('### VI Compare History','')
$summaryLines += "- Target: $targetRel"
if ($requestedStartRef -ne $startRef) {
  $summaryLines += "- Requested start ref: $requestedStartRef"
  $summaryLines += "- Resolved start ref: $startRef"
} else {
  $summaryLines += "- Start ref: $startRef"
}
if ($endRef) { $summaryLines += "- End ref: $endRef" }
$summaryLines += "- Mode: $modeEffective"

$processed = 0
$diffCount = 0
$lastDiffIndex = $null
$lastDiffCommit = $null
$stopReason = $null
$errorCount = 0
$missingCount = 0

for ($i = 0; $i -lt $commitList.Count; $i++) {
  $headCommit = $commitList[$i].Trim()
  if (-not $headCommit) { continue }
  if ($endRef -and [string]::Equals($headCommit, $endRef, [System.StringComparison]::OrdinalIgnoreCase)) {
    $stopReason = 'reached-end-ref'
    break
  }
  $parentExpr = ('{0}^' -f $headCommit)
  $parentCommit = Invoke-Git -Arguments @('rev-parse', $parentExpr) -Quiet
  $parentCommit = ($parentCommit -split "`n")[0].Trim()
  if (-not $parentCommit) {
    $stopReason = 'reached-root'
    break
  }
  if ($endRef -and [string]::Equals($parentCommit, $endRef, [System.StringComparison]::OrdinalIgnoreCase)) {
    # Include comparison against endRef and then stop.
    $terminateAfter = $true
  } else {
    $terminateAfter = $false
  }

  $index = $processed + 1
  if ($MaxPairs -gt 0 -and $index -gt $MaxPairs) {
    $stopReason = 'max-pairs'
    break
  }

  Write-Host ("[{0}] Comparing {1} -> {2}" -f $index, (Get-ShortSha $parentCommit 7), (Get-ShortSha $headCommit 7))

  $comparisonRecord = [ordered]@{
    index   = $index
    head    = @{
      ref   = $headCommit
      short = Get-ShortSha -Value $headCommit -Length 12
    }
    base    = @{
      ref   = $parentCommit
      short = Get-ShortSha -Value $parentCommit -Length 12
    }
    outName = "{0}-{1}" -f $outPrefixToken, $index.ToString('D3')
    mode    = $modeEffective
  }

  try {
    $headExists = Test-FileExistsAtRef -Ref $headCommit -Path $targetRel
    if (-not $headExists) {
      $missingCount++
      $comparisonRecord.result = [ordered]@{
        status  = 'missing-head'
        message = ("Target '{0}' not present at {1}" -f $targetRel, $headCommit)
      }
      $manifest.comparisons += [pscustomobject]$comparisonRecord
      $stopReason = 'missing-head'
      break
    }
    $baseExists = Test-FileExistsAtRef -Ref $parentCommit -Path $targetRel
    if (-not $baseExists) {
      $missingCount++
      $comparisonRecord.result = [ordered]@{
        status  = 'missing-base'
        message = ("Target '{0}' not present at {1}" -f $targetRel, $parentCommit)
      }
      $processed++
      $manifest.comparisons += [pscustomobject]$comparisonRecord
      if ($terminateAfter) {
        $stopReason = 'reached-end-ref'
        break
      }
      continue
    }

    $compareArgs = @(
      '-NoLogo','-NoProfile','-File', $compareScript,
      '-Path', $targetRel,
      '-RefA', $parentCommit,
      '-RefB', $headCommit,
      '-ResultsDir', $resultsRoot,
      '-OutName', $comparisonRecord.outName,
      '-Quiet'
    )
    if ($Detailed.IsPresent -or $RenderReport.IsPresent) {
      $compareArgs += '-Detailed'
      $compareArgs += '-RenderReport'
    }
    if ($FailOnDiff.IsPresent) { $compareArgs += '-FailOnDiff' }
    if ($flagTokens.Count -gt 0) {
      $compareArgs += '-LvCompareArgs'
      $compareArgs += ($flagTokens -join ' ')
    }
    if (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
      $compareArgs += '-InvokeScriptPath'
      $compareArgs += $InvokeScriptPath
    }

    $pwshResult = Invoke-Pwsh -Arguments $compareArgs
    if ($pwshResult.ExitCode -ne 0) {
      $msg = "Compare-RefsToTemp.ps1 exited with code {0}" -f $pwshResult.ExitCode
      if ($pwshResult.StdErr) { $msg = "$msg`n$($pwshResult.StdErr.Trim())" }
      if ($pwshResult.StdOut) { $msg = "$msg`n$($pwshResult.StdOut.Trim())" }
      throw $msg
    }

    $summaryPath = Join-Path $resultsRoot ("{0}-summary.json" -f $comparisonRecord.outName)
    $execPath = Join-Path $resultsRoot ("{0}-exec.json" -f $comparisonRecord.outName)
    if (-not (Test-Path -LiteralPath $summaryPath)) {
      throw ("Summary not found at {0}" -f $summaryPath)
    }
    $summaryJson = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 8

    $diff = [bool]$summaryJson.cli.diff
    $comparisonRecord.result = [ordered]@{
      summaryPath = (Resolve-Path -LiteralPath $summaryPath).Path
      execPath    = if (Test-Path -LiteralPath $execPath) { (Resolve-Path -LiteralPath $execPath).Path } else { $null }
      diff        = $diff
      exitCode    = $summaryJson.cli.exitCode
      duration_s  = $summaryJson.cli.duration_s
      command     = $summaryJson.cli.command
    }
    $outNode = $summaryJson.out
    if ($outNode -and $outNode.PSObject.Properties['reportHtml'] -and $outNode.reportHtml) {
      $comparisonRecord.result.reportHtml = $outNode.reportHtml
    }
    if ($outNode -and $outNode.PSObject.Properties['artifactDir'] -and $outNode.artifactDir) {
      $artifactDir = $outNode.artifactDir
      if (-not $diff -and -not $KeepArtifactsOnNoDiff.IsPresent) {
        if (Test-Path -LiteralPath $artifactDir) {
          Remove-Item -LiteralPath $artifactDir -Recurse -Force -ErrorAction SilentlyContinue
        }
      } elseif (Test-Path -LiteralPath $artifactDir) {
        $comparisonRecord.result.artifactDir = (Resolve-Path -LiteralPath $artifactDir).Path
      }
    }
    if ($summaryJson.cli -and $summaryJson.cli.PSObject.Properties['highlights'] -and $summaryJson.cli.highlights) {
      $comparisonRecord.result.highlights = $summaryJson.cli.highlights
    }

    $processed++
    if ($diff) {
      $diffCount++
      $lastDiffIndex = $index
      $lastDiffCommit = $headCommit
      if ($FailFast.IsPresent) {
        $stopReason = 'fail-fast-diff'
        $manifest.comparisons += [pscustomobject]$comparisonRecord
        break
      }
    }

    $manifest.comparisons += [pscustomobject]$comparisonRecord
  }
  catch {
    $comparisonRecord.error = $_.Exception.Message
    $manifest.comparisons += [pscustomobject]$comparisonRecord
    $errorCount++
    $stopReason = if ($stopReason) { $stopReason } else { 'error' }
    $manifest.status = 'failed'
    $manifest.stats.errors = $errorCount
    throw
  }

  if ($terminateAfter) {
    $stopReason = 'reached-end-ref'
    break
  }
}

if (-not $stopReason) {
  if ($processed -eq 0) {
    $stopReason = 'no-pairs'
  } elseif ($errorCount -gt 0) {
    $stopReason = 'error'
  } else {
    $stopReason = 'complete'
  }
}

$manifest.stats.processed = $processed
$manifest.stats.diffs = $diffCount
$manifest.stats.lastDiffIndex = $lastDiffIndex
$manifest.stats.lastDiffCommit = $lastDiffCommit
$manifest.stats.stopReason = $stopReason
$manifest.stats.errors = $errorCount
$manifest.stats.missing = $missingCount

if ($errorCount -gt 0) {
  $manifest.status = 'failed'
} else {
  $manifest.status = 'ok'
}

$manifest | ConvertTo-Json -Depth 8 | Out-File -FilePath $manifestPathResolved -Encoding utf8

$summaryLines += "- Pairs processed: $processed"
$summaryLines += "- Diffs detected: $diffCount"
$summaryLines += "- Missing pairs: $missingCount"
$summaryLines += "- Stop reason: $stopReason"
if ($lastDiffIndex) {
  $summaryLines += ""
  $summaryLines += "#### Last diff"
  $summaryLines += "- Index: $lastDiffIndex"
  $summaryLines += "- Commit: $(Get-ShortSha -Value $lastDiffCommit -Length 12)"
}

Write-StepSummary -Lines $summaryLines -DestPath $StepSummaryPath
Write-GitHubOutput -Key 'manifest-path' -Value $manifestPathResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'results-dir' -Value $resultsRoot -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'processed-count' -Value $processed -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'diff-count' -Value $diffCount -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'stop-reason' -Value $stopReason -DestPath $GitHubOutputPath

Write-Host ("VI compare history complete. Manifest: {0}" -f $manifestPathResolved)

if ($FailOnDiff.IsPresent -and $diffCount -gt 0) {
  throw ("Differences detected across {0} comparison(s)" -f $diffCount)
}
