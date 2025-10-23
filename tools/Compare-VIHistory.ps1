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

  [string[]]$Mode = @('default'),
  [switch]$FailFast,
  [switch]$FailOnDiff,

  [string]$ResultsDir = 'tests/results/ref-compare/history',
  [string]$OutPrefix,
  [string]$ManifestPath,
  [switch]$Detailed,
  [switch]$RenderReport,
  [ValidateSet('html','xml','text')]
  [string]$ReportFormat = 'html',
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
    if ($messages -and $messages.Count -gt 0) {
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

$modeDefinitions = @{
  'default'       = @{ slug = 'default'; flags = @('-nobd','-noattr','-nofp','-nofppos','-nobdcosm') }
  'attributes'    = @{ slug = 'attributes'; flags = @('-nobd','-nofp','-nofppos','-nobdcosm') }
  'front-panel'   = @{ slug = 'front-panel'; flags = @('-nobd','-noattr','-nobdcosm') }
  'block-diagram' = @{ slug = 'block-diagram'; flags = @('-nobd','-noattr','-nofp','-nofppos') }
  'all'           = @{ slug = 'all'; flags = @() }
  'custom'        = @{ slug = 'custom'; flags = $null }
}

function Resolve-ModeSpec {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $token = $Value.Trim().ToLowerInvariant()
  if (-not $modeDefinitions.ContainsKey($token)) {
    $allowed = [string]::Join(', ', $modeDefinitions.Keys)
    throw ("Unknown mode '{0}'. Allowed modes: {1}" -f $Value, $allowed)
  }
  $def = $modeDefinitions[$token]
  return [pscustomobject]@{
    Name = $token
    Slug = $def.slug
    PresetFlags = if ($def.flags -ne $null) { @($def.flags) } else { $null }
  }
}

function Build-CustomFlags {
  param(
    [bool]$ForceNoBd,
    [bool]$FlagNoAttr,
    [bool]$FlagNoFp,
    [bool]$FlagNoFpPos,
    [bool]$FlagNoBdCosm,
    [string]$AdditionalFlags,
    [string]$LvCompareArgs
  )
  $flags = New-Object System.Collections.Generic.List[string]
  if ($ForceNoBd)    { $flags.Add('-nobd') }
  if ($FlagNoAttr)   { $flags.Add('-noattr') }
  if ($FlagNoFp)     { $flags.Add('-nofp') }
  if ($FlagNoFpPos)  { $flags.Add('-nofppos') }
  if ($FlagNoBdCosm) { $flags.Add('-nobdcosm') }

  foreach ($token in @(Split-ArgString -Value $AdditionalFlags)) {
    $flags.Add($token)
  }
  foreach ($token in @(Split-ArgString -Value $LvCompareArgs)) {
    $flags.Add($token)
  }

  $unique = New-Object System.Collections.Generic.List[string]
  foreach ($flag in $flags) {
    if (-not [string]::IsNullOrWhiteSpace($flag) -and -not $unique.Contains($flag)) {
      $unique.Add($flag)
    }
  }
  return @($unique)
}

function Expand-ModeTokens {
  param([string[]]$Values)
  $tokens = New-Object System.Collections.Generic.List[string]
  if ($Values) {
    foreach ($item in $Values) {
      if ([string]::IsNullOrWhiteSpace($item)) { continue }
      foreach ($piece in ($item -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $tokens.Add($piece.Trim())
      }
    }
  }
  if ($tokens.Count -eq 0) {
    $tokens.Add('default')
  }
  return @($tokens.ToArray())
}

function Build-FlagBundle {
  param(
    [pscustomobject]$ModeSpec,
    [bool]$ReplaceFlags,
    [string]$AdditionalFlags,
    [string]$LvCompareArgs,
    [bool]$ForceNoBd,
    [bool]$FlagNoAttr,
    [bool]$FlagNoFp,
    [bool]$FlagNoFpPos,
    [bool]$FlagNoBdCosm
  )

  $flags = New-Object System.Collections.Generic.List[string]
  if ($ModeSpec.PresetFlags -ne $null) {
    foreach ($flag in @($ModeSpec.PresetFlags)) {
      if (-not [string]::IsNullOrWhiteSpace($flag)) {
        $flags.Add($flag)
      }
    }
  } else {
    foreach ($flag in @(Build-CustomFlags -ForceNoBd:$ForceNoBd -FlagNoAttr:$FlagNoAttr -FlagNoFp:$FlagNoFp -FlagNoFpPos:$FlagNoFpPos -FlagNoBdCosm:$FlagNoBdCosm -AdditionalFlags:$AdditionalFlags -LvCompareArgs:$LvCompareArgs)) {
      if (-not [string]::IsNullOrWhiteSpace($flag)) {
        $flags.Add($flag)
      }
    }
  }
  if ($ModeSpec.Name -eq 'all') {
    $flags.Clear()
  }

  if ($ReplaceFlags -and $LvCompareArgs) {
    $flags.Clear()
    foreach ($token in @(Split-ArgString -Value $LvCompareArgs)) {
      if (-not [string]::IsNullOrWhiteSpace($token)) {
        $flags.Add($token)
      }
    }
  } else {
    if (-not $ReplaceFlags -and -not [string]::IsNullOrWhiteSpace($AdditionalFlags)) {
      foreach ($token in @(Split-ArgString -Value $AdditionalFlags)) {
        if (-not [string]::IsNullOrWhiteSpace($token)) {
          $flags.Add($token)
        }
      }
    }
    if ($LvCompareArgs) {
      foreach ($token in @(Split-ArgString -Value $LvCompareArgs)) {
        if (-not [string]::IsNullOrWhiteSpace($token)) {
          $flags.Add($token)
        }
      }
    }
  }

  $unique = New-Object System.Collections.Generic.List[string]
  foreach ($flag in $flags) {
    if (-not [string]::IsNullOrWhiteSpace($flag) -and -not $unique.Contains($flag)) {
      $unique.Add($flag)
    }
  }
  return @($unique.ToArray())
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
  Write-Verbose ("Ensure-FileExistsAtRef Ref={0} Path={1}" -f $Ref, $Path)
  try {
    $refToken = $Ref.ToLowerInvariant()
  } catch { $refToken = $Ref }
  if ($refToken -and $modeDefinitions.ContainsKey($refToken)) { return }
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

  return $null
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


$modeTokens = Expand-ModeTokens -Values $Mode
$modeSpecs = @()
$modeSeen = @{}
foreach ($tokenRaw in $modeTokens) {
  $spec = Resolve-ModeSpec -Value $tokenRaw
  if ($spec -and -not $modeSeen.ContainsKey($spec.Name)) {
    $modeSpecs += $spec
    $modeSeen[$spec.Name] = $true
  }
}
if ($modeSpecs.Count -eq 0) {
  throw 'No valid comparison modes resolved.'
}

$reportFormatEffective = if ($ReportFormat) { $ReportFormat.ToLowerInvariant() } else { 'html' }

$requestedStartRef = $startRef
Write-Verbose ("StartRef before resolve: {0}" -f $startRef)
$resolvedStartRef = Resolve-CommitWithChange -StartRef $startRef -Path $targetRel -HeadRef 'HEAD'
if (-not $resolvedStartRef) {
  throw ("Unable to locate a commit near {0} that modifies '{1}'." -f $startRef, $targetRel)
}
if ($resolvedStartRef -ne $startRef) {
  Write-Verbose ("Adjusted start ref from {0} to {1} to locate a change in {2}" -f (Get-ShortSha $startRef 12), (Get-ShortSha $resolvedStartRef 12), $targetRel)
  $startRef = $resolvedStartRef
}

$resultsRoot = if ([System.IO.Path]::IsPathRooted($ResultsDir)) { $ResultsDir } else { Join-Path $repoRoot $ResultsDir }
New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
$resultsRootResolved = (Resolve-Path -LiteralPath $resultsRoot).Path

$aggregateManifestPath = if ($ManifestPath) {
  if ([System.IO.Path]::IsPathRooted($ManifestPath)) { $ManifestPath } else { Join-Path $repoRoot $ManifestPath }
} else {
  Join-Path $resultsRoot 'manifest.json'
}

Write-Verbose ("StartRef before ensure: {0}; Target: {1}" -f $startRef, $targetRel)
Ensure-FileExistsAtRef -Ref $startRef -Path $targetRel
if ($endRef) { Ensure-FileExistsAtRef -Ref $endRef -Path $targetRel }

$revArgs = @('rev-list','--first-parent',$startRef)
if ($MaxPairs -gt 0) {
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

$outPrefixToken = if ($OutPrefix) { $OutPrefix } else { $targetLeaf -replace '[^A-Za-z0-9._-]+','_' }
if ([string]::IsNullOrWhiteSpace($outPrefixToken)) { $outPrefixToken = 'vi-history' }

$modeNames = @($modeSpecs | ForEach-Object { $_.Name })
$summaryLines = @('### VI Compare History','')
$summaryLines += "- Target: $targetRel"
if ($requestedStartRef -ne $startRef) {
  $summaryLines += "- Requested start ref: $requestedStartRef"
  $summaryLines += "- Resolved start ref: $startRef"
} else {
  $summaryLines += "- Start ref: $startRef"
}
if ($endRef) { $summaryLines += "- End ref: $endRef" }
$summaryLines += "- Modes: $($modeNames -join ', ')"
$summaryLines += "- Report format: $reportFormatEffective"

$aggregate = [ordered]@{
  schema      = 'vi-compare/history-suite@v1'
  generatedAt = (Get-Date).ToString('o')
  targetPath  = $targetRel
  requestedStartRef = $requestedStartRef
  startRef    = $startRef
  endRef      = $endRef
  maxPairs    = $MaxPairs
  failFast    = [bool]$FailFast.IsPresent
  failOnDiff  = [bool]$FailOnDiff.IsPresent
  reportFormat = $reportFormatEffective
  resultsDir  = $resultsRootResolved
  modes       = @()
  stats       = [ordered]@{
    modes     = $modeSpecs.Count
    processed = 0
    diffs     = 0
    errors    = 0
    missing   = 0
  }
  status      = 'pending'
}

$totalProcessed = 0
$totalDiffs = 0
$totalErrors = 0
$totalMissing = 0

foreach ($modeSpec in $modeSpecs) {
  $modeName = $modeSpec.Name
  $modeSlug = $modeSpec.Slug
  $modeFlags = Build-FlagBundle -ModeSpec $modeSpec -ReplaceFlags:$ReplaceFlags.IsPresent -AdditionalFlags $AdditionalFlags -LvCompareArgs $LvCompareArgs -ForceNoBd:$ForceNoBd -FlagNoAttr:$FlagNoAttr -FlagNoFp:$FlagNoFp -FlagNoFpPos:$FlagNoFpPos -FlagNoBdCosm:$FlagNoBdCosm
  if (-not $modeFlags) { $modeFlags = @() }
  $mf = if ($modeFlags -and $modeFlags.Count -gt 0) { $modeFlags -join ' ' } else { '(empty)' }
  Write-Verbose ("Mode {0} flags: {1}" -f $modeName, $mf)

  $modeResultsRoot = Join-Path $resultsRoot $modeSlug
  New-Item -ItemType Directory -Path $modeResultsRoot -Force | Out-Null
  $modeResultsResolved = (Resolve-Path -LiteralPath $modeResultsRoot).Path
  $modeManifestPath = Join-Path $modeResultsRoot 'manifest.json'

  $modeManifest = [ordered]@{
    schema      = 'vi-compare/history@v1'
    generatedAt = (Get-Date).ToString('o')
    targetPath  = $targetRel
    requestedStartRef = $requestedStartRef
    startRef    = $startRef
    endRef      = $endRef
    maxPairs    = $MaxPairs
    failFast    = [bool]$FailFast.IsPresent
    failOnDiff  = [bool]$FailOnDiff.IsPresent
    mode        = $modeName
    slug        = $modeSlug
    reportFormat = $reportFormatEffective
    flags       = $modeFlags
    resultsDir  = $modeResultsResolved
    comparisons = @()
    stats       = [ordered]@{
      processed      = 0
      diffs          = 0
      lastDiffIndex  = $null
      lastDiffCommit = $null
      stopReason     = $null
      errors         = 0
      missing        = 0
    }
    status      = 'pending'
  }

  $processed = 0
  $diffCount = 0
  $missingCount = 0
  $errorCount = 0
  $lastDiffIndex = $null
  $lastDiffCommit = $null
  $stopReason = $null

  for ($i = 0; $i -lt $commitList.Count; $i++) {
    $headCommit = $commitList[$i].Trim()
    if (-not $headCommit) { continue }
    if ($endRef -and [string]::Equals($headCommit, $endRef, [System.StringComparison]::OrdinalIgnoreCase)) {
      $stopReason = 'reached-end-ref'
      break
    }

    $parentExpr = ('{0}^' -f $headCommit)
    $parentRaw = Invoke-Git -Arguments @('rev-parse', $parentExpr) -Quiet
    $parentCommit = ($parentRaw -split "`n")[0].Trim()
    if (-not $parentCommit) {
      $stopReason = 'reached-root'
      break
    }

    if ($endRef -and [string]::Equals($parentCommit, $endRef, [System.StringComparison]::OrdinalIgnoreCase)) {
      $terminateAfter = $true
    } else {
      $terminateAfter = $false
    }

    $index = $processed + 1
    if ($MaxPairs -gt 0 -and $index -gt $MaxPairs) {
      $stopReason = 'max-pairs'
      break
    }

    Write-Verbose ("[{0}] Comparing {1} -> {2} (mode: {3})" -f $index, (Get-ShortSha $parentCommit 7), (Get-ShortSha $headCommit 7), $modeName)

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
      outName      = "{0}-{1}" -f $outPrefixToken, $index.ToString('D3')
      mode         = $modeName
      slug         = $modeSlug
      reportFormat = $reportFormatEffective
    }

    try {
      $headExists = Test-FileExistsAtRef -Ref $headCommit -Path $targetRel
      if (-not $headExists) {
        $missingCount++
        $comparisonRecord.result = [ordered]@{
          status  = 'missing-head'
          message = ("Target '{0}' not present at {1}" -f $targetRel, $headCommit)
        }
        $modeManifest.comparisons += [pscustomobject]$comparisonRecord
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
        $modeManifest.comparisons += [pscustomobject]$comparisonRecord
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
      '-ResultsDir', $modeResultsResolved,
      '-OutName', $comparisonRecord.outName,
      '-ReportFormat', $reportFormatEffective,
      '-Quiet'
    )
      if ($Detailed.IsPresent) { $compareArgs += '-Detailed' }
      if ($RenderReport.IsPresent -or $reportFormatEffective -eq 'html') { $compareArgs += '-RenderReport' }
      if ($FailOnDiff.IsPresent) { $compareArgs += '-FailOnDiff' }
      if ($modeFlags -and $modeFlags.Count -gt 0) {
        $compareArgs += '-LvCompareArgs'
        $compareArgs += ($modeFlags -join ' ')
      }
    if (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
      $compareArgs += '-InvokeScriptPath'
      $compareArgs += $InvokeScriptPath
    }
    if ($KeepArtifactsOnNoDiff.IsPresent) {
      $compareArgs += '-KeepArtifactsOnNoDiff'
    }
    $pwshResult = Invoke-Pwsh -Arguments $compareArgs
    if ($pwshResult.ExitCode -ne 0) {
      $msg = "Compare-RefsToTemp.ps1 exited with code {0}" -f $pwshResult.ExitCode
      if ($pwshResult.StdErr) { $msg = "$msg`n$($pwshResult.StdErr.Trim())" }
      if ($pwshResult.StdOut) { $msg = "$msg`n$($pwshResult.StdOut.Trim())" }
      throw $msg
    }

      $summaryPath = Join-Path $modeResultsResolved ("{0}-summary.json" -f $comparisonRecord.outName)
      $execPath = Join-Path $modeResultsResolved ("{0}-exec.json" -f $comparisonRecord.outName)
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
      if ($summaryJson.cli.PSObject.Properties['reportFormat']) {
        $comparisonRecord.reportFormat = $summaryJson.cli.reportFormat
      }
      $outNode = $summaryJson.out
      if ($outNode -and $outNode.PSObject.Properties['reportHtml'] -and $outNode.reportHtml) {
        $comparisonRecord.result.reportHtml = $outNode.reportHtml
      }
      if ($outNode -and $outNode.PSObject.Properties['reportPath'] -and $outNode.reportPath) {
        $comparisonRecord.result.reportPath = $outNode.reportPath
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
          $modeManifest.comparisons += [pscustomobject]$comparisonRecord
          break
        }
      }

      $modeManifest.comparisons += [pscustomobject]$comparisonRecord
    }
    catch {
      $comparisonRecord.error = $_.Exception.Message
      $modeManifest.comparisons += [pscustomobject]$comparisonRecord
      $errorCount++
      $stopReason = if ($stopReason) { $stopReason } else { 'error' }
      $modeManifest.status = 'failed'
      $modeManifest.stats.errors = $errorCount
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

  $modeManifest.stats.processed = $processed
  $modeManifest.stats.diffs = $diffCount
  $modeManifest.stats.lastDiffIndex = $lastDiffIndex
  $modeManifest.stats.lastDiffCommit = $lastDiffCommit
  $modeManifest.stats.stopReason = $stopReason
  $modeManifest.stats.errors = $errorCount
  $modeManifest.stats.missing = $missingCount

  if ($errorCount -gt 0) {
    $modeManifest.status = 'failed'
  } elseif ($diffCount -gt 0 -and $FailOnDiff.IsPresent) {
    $modeManifest.status = 'failed'
  } else {
    $modeManifest.status = 'ok'
  }

  $modeManifest | ConvertTo-Json -Depth 8 | Out-File -FilePath $modeManifestPath -Encoding utf8
  $modeManifestResolved = (Resolve-Path -LiteralPath $modeManifestPath).Path

  $summaryLines += ''
  $summaryLines += "#### Mode: $modeName"
  $summaryLines += "- Results dir: $modeResultsResolved"
  $flagsDisplay = if ($modeFlags -and $modeFlags.Count -gt 0) { $modeFlags -join ' ' } else { '(none)' }
  $summaryLines += "- Flags: $flagsDisplay"
  $summaryLines += "- Pairs processed: $processed"
  $summaryLines += "- Diffs detected: $diffCount"
  $summaryLines += "- Missing pairs: $missingCount"
  $summaryLines += "- Stop reason: $stopReason"
  if ($lastDiffIndex) {
    $summaryLines += "  - Last diff index: $lastDiffIndex"
    if ($lastDiffCommit) {
      $summaryLines += "  - Last diff commit: $(Get-ShortSha -Value $lastDiffCommit -Length 12)"
    }
  }

  $aggregate.modes += [pscustomobject]@{
    name         = $modeName
    slug         = $modeSlug
    reportFormat = $modeManifest.reportFormat
    flags        = @($modeFlags)
    manifestPath = $modeManifestResolved
    resultsDir   = $modeResultsResolved
    stats        = $modeManifest.stats
    status       = $modeManifest.status
  }

  $totalProcessed += $processed
  $totalDiffs += $diffCount
  $totalErrors += $errorCount
  $totalMissing += $missingCount
}

if ($aggregate.modes.Count -eq 0) {
  throw 'No comparison modes executed.'
}

$aggregate.stats.processed = $totalProcessed
$aggregate.stats.diffs = $totalDiffs
$aggregate.stats.errors = $totalErrors
$aggregate.stats.missing = $totalMissing
$aggregate.status = if ($aggregate.modes | Where-Object { $_.status -eq 'failed' }) { 'failed' } else { 'ok' }

$aggregate | ConvertTo-Json -Depth 8 | Out-File -FilePath $aggregateManifestPath -Encoding utf8
$aggregateManifestResolved = (Resolve-Path -LiteralPath $aggregateManifestPath).Path

Write-StepSummary -Lines $summaryLines -DestPath $StepSummaryPath
Write-GitHubOutput -Key 'manifest-path' -Value $aggregateManifestResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'results-dir' -Value $resultsRootResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'mode-count' -Value $aggregate.modes.Count -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'total-processed' -Value $totalProcessed -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'total-diffs' -Value $totalDiffs -DestPath $GitHubOutputPath
$aggregateStopReason = if ($aggregate.status -eq 'ok') { 'complete' } else { 'failed' }
Write-GitHubOutput -Key 'stop-reason' -Value $aggregateStopReason -DestPath $GitHubOutputPath

$modeManifestSummary = $aggregate.modes | ForEach-Object {
  [ordered]@{
    mode      = $_.name
    slug      = $_.slug
    manifest  = $_.manifestPath
    resultsDir= $_.resultsDir
    processed = $_.stats.processed
    diffs     = $_.stats.diffs
    status    = $_.status
  }
}
Write-GitHubOutput -Key 'mode-manifests-json' -Value ((ConvertTo-Json $modeManifestSummary -Depth 4 -Compress)) -DestPath $GitHubOutputPath

Write-Host ("VI compare history suite complete. Aggregate manifest: {0}" -f $aggregateManifestResolved)

if ($FailOnDiff.IsPresent -and $totalDiffs -gt 0) {
  throw ("Differences detected across {0} comparison(s)" -f $totalDiffs)
}
