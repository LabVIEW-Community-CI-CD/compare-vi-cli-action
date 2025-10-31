param(
  [Parameter(Mandatory = $true)]
  [Alias('ViName')]
  [string]$TargetPath,

  [Alias('Branch')]
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
  [switch]$Quiet,

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

Set-Variable -Name repoRoot -Scope Script -Value $null

try {
  $vendorModule = Join-Path (Split-Path -Parent $PSCommandPath) 'VendorTools.psm1'
  if (Test-Path -LiteralPath $vendorModule -PathType Leaf) {
    Import-Module $vendorModule -Force
  }
} catch {}

try {
  $categoryModule = Join-Path (Split-Path -Parent $PSCommandPath) 'VICategoryBuckets.psm1'
  if (Test-Path -LiteralPath $categoryModule -PathType Leaf) {
    Import-Module $categoryModule -Force
  }
} catch {}

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
  'default'       = @{ slug = 'default'; flags = $null }
  'attributes'    = @{ slug = 'attributes'; flags = $null }
  'front-panel'   = @{ slug = 'front-panel'; flags = $null }
  'block-diagram' = @{ slug = 'block-diagram'; flags = $null }
  'all'           = @{ slug = 'all'; flags = $null }
  'full'          = @{ slug = 'full'; flags = $null }
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

function Get-ComparisonCategories {
  param(
    [string[]]$Highlights,
    [bool]$HasDiff
  )

  $categories = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  function Add-Category {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if ($seen.Add($Name)) {
      [void]$categories.Add($Name)
    }
  }

  foreach ($highlight in @($Highlights | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $text = $highlight.ToLowerInvariant()
    if ($text -match 'block diagram') { Add-Category 'block-diagram' }
    if ($text -match 'front panel' -or $text -match 'control changes') { Add-Category 'front-panel' }
    if ($text -match 'vi attribute' -or $text -match 'attributes:') { Add-Category 'attributes' }
    if ($text -match 'connector' -or $text -match 'terminal') { Add-Category 'connector-pane' }
    if ($text -match 'cosmetic') { Add-Category 'cosmetic' }
    if ($text -match 'window') { Add-Category 'front-panel' }
  }

  if ($HasDiff -and $categories.Count -eq 0) {
    Add-Category 'unspecified'
  }

  return @($categories.ToArray())
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
  if ($ModeSpec.Name -in @('all','full')) {
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
  if ($repoRoot) {
    $psi.WorkingDirectory = $repoRoot
  }
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
  if ($repoRoot) {
    $psi.WorkingDirectory = $repoRoot
  }
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

$labVIEWIniPath = $null
try {
  $labVIEWIniPath = Get-LabVIEWIniPath
} catch {}
if ($labVIEWIniPath) {
  try {
    $sccUseValue = Get-LabVIEWIniValue -LabVIEWIniPath $labVIEWIniPath -Key 'SCCUseInLabVIEW'
    $sccProviderValue = Get-LabVIEWIniValue -LabVIEWIniPath $labVIEWIniPath -Key 'SCCProviderIsActive'
    $sccEnabled = ($sccUseValue -eq 'True') -or ($sccProviderValue -eq 'True')
    if ($sccEnabled) {
      Write-Warning ("LabVIEW source control is enabled in '{0}'. Headless comparisons may emit SCC startup warnings. Disable Source Control in LabVIEW (Tools -> Options -> Source Control) or set SCCUseInLabVIEW=FALSE for automation runs." -f $labVIEWIniPath)
    }
  } catch {}
}

$repoRoot = Resolve-RepoRoot
try {
  $repoRoot = [System.IO.Path]::GetFullPath($repoRoot)
} catch {}

if ([string]::IsNullOrWhiteSpace($TargetPath)) {
  throw 'TargetPath cannot be empty.'
}

$targetFullPath = $TargetPath
try {
  if (-not [System.IO.Path]::IsPathRooted($targetFullPath)) {
    $targetFullPath = Join-Path $repoRoot $targetFullPath
  }
  $targetFullPath = [System.IO.Path]::GetFullPath($targetFullPath)
} catch {
  throw ("Unable to resolve TargetPath '{0}': {1}" -f $TargetPath, $_.Exception.Message)
}

if (-not (Test-Path -LiteralPath $targetFullPath -PathType Leaf)) {
  Write-Verbose ("TargetPath '{0}' not found on disk; continuing with git history refs." -f $targetFullPath)
}

$targetRel = $targetFullPath
try {
  if ($repoRoot) {
    $rootNormalized = [System.IO.Path]::GetFullPath($repoRoot)
    $rootPrefix = $rootNormalized.TrimEnd('\','/')
    if ($rootPrefix.Length -gt 0) {
      $rootPrefix = $rootPrefix + [System.IO.Path]::DirectorySeparatorChar
    }
    if ($targetFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $targetRel = $targetFullPath.Substring($rootPrefix.Length).TrimStart('\','/')
    }
  }
} catch {}
$targetRel = ($targetRel -replace '\\','/').Trim('/')
if ([string]::IsNullOrWhiteSpace($targetRel)) {
  throw ("TargetPath '{0}' could not be normalized relative to repository root '{1}'." -f $TargetPath, $repoRoot)
}
Write-Verbose ("Normalized target path: {0}" -f $targetRel)
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
  Write-Warning ("Unable to locate a commit near {0} that modifies '{1}'. Using the provided start ref." -f $startRef, $targetRel)
  $resolvedStartRef = $startRef
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

$compareScript = $null
$scriptsOverride = $env:COMPAREVI_SCRIPTS_ROOT
if (-not [string]::IsNullOrWhiteSpace($scriptsOverride)) {
  $overrideCandidate = Join-Path $scriptsOverride 'Compare-RefsToTemp.ps1'
  if (Test-Path -LiteralPath $overrideCandidate -PathType Leaf) {
    $compareScript = $overrideCandidate
  }
}

if (-not $compareScript) {
  $compareScript = Join-Path $repoRoot 'tools' 'Compare-RefsToTemp.ps1'
}
if (-not (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
  throw ("Compare script not found: {0}" -f $compareScript)
}

$outPrefixToken = if ($OutPrefix) { $OutPrefix } else { $targetLeaf -replace '[^A-Za-z0-9._-]+','_' }
if ([string]::IsNullOrWhiteSpace($outPrefixToken)) { $outPrefixToken = 'vi-history' }

$modeNames = @($modeSpecs | ForEach-Object { $_.Name })
$stepSummaryDest = if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $StepSummaryPath
} elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
  $env:GITHUB_STEP_SUMMARY
} else {
  $null
}
$hasStepSummary = -not [string]::IsNullOrWhiteSpace($stepSummaryDest)
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
    categoryCounts = [ordered]@{}
    bucketCounts   = [ordered]@{}
  }
  status      = 'pending'
}

$totalProcessed = 0
$totalDiffs = 0
$totalErrors = 0
$totalMissing = 0
$modeSummaryRows = New-Object System.Collections.Generic.List[object]
$diffHighlights = New-Object System.Collections.Generic.List[string]
$aggregateCategoryCounts = $aggregate.stats.categoryCounts
$aggregateBucketCounts = $aggregate.stats.bucketCounts

foreach ($modeSpec in $modeSpecs) {
  $modeName = $modeSpec.Name
  $modeSlug = $modeSpec.Slug
  $modeForceNoBd = $ForceNoBd
  $modeFlagNoAttr = $FlagNoAttr
  $modeFlagNoFp = $FlagNoFp
  $modeFlagNoFpPos = $FlagNoFpPos
  $modeFlagNoBdCosm = $FlagNoBdCosm

  switch ($modeName) {
    'attributes' {
      $modeFlagNoAttr = $false
    }
    'front-panel' {
      $modeFlagNoFp = $false
      $modeFlagNoFpPos = $false
    }
    'block-diagram' {
      $modeFlagNoBdCosm = $false
    }
    'all' {
      $modeForceNoBd = $false
      $modeFlagNoAttr = $false
      $modeFlagNoFp = $false
      $modeFlagNoFpPos = $false
      $modeFlagNoBdCosm = $false
    }
    'full' {
      $modeForceNoBd = $false
      $modeFlagNoAttr = $false
      $modeFlagNoFp = $false
      $modeFlagNoFpPos = $false
      $modeFlagNoBdCosm = $false
    }
  }

  $modeFlagsRaw = Build-FlagBundle -ModeSpec $modeSpec -ReplaceFlags:$ReplaceFlags.IsPresent -AdditionalFlags $AdditionalFlags -LvCompareArgs $LvCompareArgs -ForceNoBd:$modeForceNoBd -FlagNoAttr:$modeFlagNoAttr -FlagNoFp:$modeFlagNoFp -FlagNoFpPos:$modeFlagNoFpPos -FlagNoBdCosm:$modeFlagNoBdCosm
  $modeFlags = @($modeFlagsRaw | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $mf = if ($modeFlags.Count -gt 0) { $modeFlags -join ' ' } else { '(empty)' }
  Write-Verbose ("Mode {0} flags: {1}" -f $modeName, $mf)

  $modeResultsRoot = Join-Path $resultsRoot $modeSlug
  New-Item -ItemType Directory -Path $modeResultsRoot -Force | Out-Null
  $modeResultsResolved = (Resolve-Path -LiteralPath $modeResultsRoot).Path
  $modeResultsRelative = $null
  if ($modeResultsResolved) {
    try {
      $modeResultsRelative = [System.IO.Path]::GetRelativePath($repoRoot, $modeResultsResolved)
    } catch {
      $modeResultsRelative = $modeResultsResolved
    }
  }
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
      categoryCounts = [ordered]@{}
      bucketCounts   = [ordered]@{}
    }
    status      = 'pending'
  }

  $modeCategoryCounts = $modeManifest.stats.categoryCounts
  $modeBucketCounts = $modeManifest.stats.bucketCounts

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

    $summaryPath = Join-Path $modeResultsResolved ("{0}-summary.json" -f $comparisonRecord.outName)
    $execPath    = Join-Path $modeResultsResolved ("{0}-exec.json" -f $comparisonRecord.outName)
    $summaryJson = $null
    $summaryPreExisting = $false
    if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
      try {
        $summaryJson = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 8
        $summaryPreExisting = $true
      } catch {
        $summaryJson = $null
        $summaryPreExisting = $false
      }
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

      if (-not $summaryPreExisting) {
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
        $compareArgs += '-ReplaceFlags'
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
          if ($pwshResult.ExitCode -eq 1) {
            Write-Verbose 'Compare-RefsToTemp reported exit code 1 (diff detected); continuing.'
          } else {
            $msg = "Compare-RefsToTemp.ps1 exited with code {0}" -f $pwshResult.ExitCode
            if ($pwshResult.StdErr) { $msg = "$msg`n$($pwshResult.StdErr.Trim())" }
            if ($pwshResult.StdOut) { $msg = "$msg`n$($pwshResult.StdOut.Trim())" }
            throw $msg
          }
        }
      }

      if (-not $summaryJson) {
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
          throw ("Summary not found at {0}" -f $summaryPath)
        }
        $summaryJson = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 8
      }

      $diff = [bool]$summaryJson.cli.diff
      $comparisonRecord.result = [ordered]@{
        summaryPath = (Resolve-Path -LiteralPath $summaryPath).Path
        execPath    = if (Test-Path -LiteralPath $execPath) { (Resolve-Path -LiteralPath $execPath).Path } else { $null }
        diff        = $diff
        exitCode    = $summaryJson.cli.exitCode
        duration_s  = $summaryJson.cli.duration_s
        command     = $summaryJson.cli.command
      }
      $highlights = @()
      if ($summaryJson.cli -and $summaryJson.cli.PSObject.Properties['highlights'] -and $summaryJson.cli.highlights) {
        $highlights += @($summaryJson.cli.highlights | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
      if ($summaryJson.cli -and $summaryJson.cli.PSObject.Properties['includedAttributes'] -and $summaryJson.cli.includedAttributes) {
        $includedNames = @()
        foreach ($attr in @($summaryJson.cli.includedAttributes)) {
          if (-not $attr) { continue }
          $name = $attr.name
          if ([string]::IsNullOrWhiteSpace($name)) { continue }
          $state = $null
          if ($attr.PSObject.Properties['included']) {
            if ([bool]$attr.included) { $state = 'included' } else { $state = 'excluded' }
          }
          if ($state -eq 'included' -or -not $state) {
            $includedNames += [string]$name
          }
        }
        if ($includedNames.Count -gt 0) {
          $highlights += ("Attributes: {0}" -f ([string]::Join(', ', ($includedNames | Select-Object -Unique))))
        }
      }
      if ($highlights.Count -gt 0) {
        $comparisonRecord.result.highlights = @($highlights | Select-Object -Unique)
      }
      $categories = @(
        Get-ComparisonCategories -Highlights $highlights -HasDiff:$diff |
          Select-Object -Unique
      )
      if ($categories -and $categories.Count -gt 0) {
        $comparisonRecord.result.categories = $categories
        $categoryInfo = Get-VICategoryBuckets -Names $categories
        if ($categoryInfo -and $categoryInfo.Details) {
          $comparisonRecord.result.categoryDetails = $categoryInfo.Details
        }
        if ($categoryInfo -and $categoryInfo.BucketSlugs) {
          $comparisonRecord.result.categoryBuckets = $categoryInfo.BucketSlugs
        }
        if ($categoryInfo -and $categoryInfo.BucketDetails) {
          $comparisonRecord.result.categoryBucketDetails = $categoryInfo.BucketDetails
        }
        foreach ($category in $categories) {
          $categoryKey = [string]$category
          if ([string]::IsNullOrWhiteSpace($categoryKey)) { continue }
          if (-not $modeCategoryCounts.Contains($categoryKey)) {
            $modeCategoryCounts[$categoryKey] = 0
          }
          $modeCategoryCounts[$categoryKey]++
        }
        if ($categoryInfo -and $categoryInfo.BucketSlugs) {
          foreach ($bucketSlug in $categoryInfo.BucketSlugs) {
            $bucketKey = [string]$bucketSlug
            if ([string]::IsNullOrWhiteSpace($bucketKey)) { continue }
            if (-not $modeBucketCounts.Contains($bucketKey)) {
              $modeBucketCounts[$bucketKey] = 0
            }
            $modeBucketCounts[$bucketKey]++
          }
        }
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

  $sortedModeCategories = [ordered]@{}
  foreach ($categoryName in ($modeCategoryCounts.Keys | Sort-Object)) {
    $sortedModeCategories[$categoryName] = [int]$modeCategoryCounts[$categoryName]
  }
  $modeManifest.stats.categoryCounts = $sortedModeCategories
  $modeCategoryCounts = $sortedModeCategories

  $modeManifest | ConvertTo-Json -Depth 8 | Out-File -FilePath $modeManifestPath -Encoding utf8
  $modeManifestResolved = (Resolve-Path -LiteralPath $modeManifestPath).Path

  if (-not $hasStepSummary) {
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
  }

  $modeSummaryRows.Add([pscustomobject]@{
    Mode           = $modeName
    Slug           = $modeSlug
    Flags          = @($modeFlags)
    Processed      = $processed
    Diffs          = $diffCount
    Missing        = $missingCount
    LastDiffIndex  = $lastDiffIndex
    LastDiffCommit = $lastDiffCommit
    ManifestPath   = $modeManifestResolved
    ResultsDir     = $modeResultsResolved
    ResultsRelative= $modeResultsRelative
  })

  if ($diffCount -gt 0) {
    $diffPlural = if ($diffCount -eq 1) { '' } else { 's' }
    $highlight = "{0}: {1} diff{2}" -f $modeName, $diffCount, $diffPlural
    if ($lastDiffIndex) {
      $highlight += (" (last #{0}" -f $lastDiffIndex)
      if ($lastDiffCommit) {
        $highlight += (" @{0}" -f (Get-ShortSha -Value $lastDiffCommit -Length 12))
      }
      $highlight += ')'
    }
    $diffHighlights.Add($highlight)
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
  foreach ($categoryKey in $modeCategoryCounts.Keys) {
    $countValue = $modeCategoryCounts[$categoryKey]
    if ($null -eq $countValue) { continue }
    $categoryName = [string]$categoryKey
    if ([string]::IsNullOrWhiteSpace($categoryName)) { continue }
    if (-not $aggregateCategoryCounts.Contains($categoryName)) {
      $aggregateCategoryCounts[$categoryName] = 0
    }
    $aggregateCategoryCounts[$categoryName] += [int]$countValue
  }
  foreach ($bucketKey in $modeBucketCounts.Keys) {
    $bucketValue = $modeBucketCounts[$bucketKey]
    if ($null -eq $bucketValue) { continue }
    $bucketName = [string]$bucketKey
    if ([string]::IsNullOrWhiteSpace($bucketName)) { continue }
    if (-not $aggregateBucketCounts.Contains($bucketName)) {
      $aggregateBucketCounts[$bucketName] = 0
    }
    $aggregateBucketCounts[$bucketName] += [int]$bucketValue
  }

  $totalProcessed += $processed
  $totalDiffs += $diffCount
  $totalErrors += $errorCount
  $totalMissing += $missingCount
}

$summaryLines += ''
$summaryLines += "- Total processed pairs: $totalProcessed"
$summaryLines += "- Total diffs: $totalDiffs"
$summaryLines += "- Total missing pairs: $totalMissing"

$sortedAggregateCategories = [ordered]@{}
foreach ($categoryName in ($aggregateCategoryCounts.Keys | Sort-Object)) {
  $sortedAggregateCategories[$categoryName] = [int]$aggregateCategoryCounts[$categoryName]
}
$aggregate.stats.categoryCounts = $sortedAggregateCategories
$aggregateCategoryCounts = $sortedAggregateCategories

$sortedAggregateBuckets = [ordered]@{}
foreach ($bucketName in ($aggregateBucketCounts.Keys | Sort-Object)) {
  $sortedAggregateBuckets[$bucketName] = [int]$aggregateBucketCounts[$bucketName]
}
$aggregate.stats.bucketCounts = $sortedAggregateBuckets
$aggregateBucketCounts = $sortedAggregateBuckets
if ($aggregateCategoryCounts.Count -gt 0) {
  $categorySummaryParts = New-Object System.Collections.Generic.List[string]
  foreach ($categoryKey in $aggregateCategoryCounts.Keys) {
    $countValue = $aggregateCategoryCounts[$categoryKey]
    $displayName = $categoryKey
    if (-not [string]::IsNullOrWhiteSpace($categoryKey)) {
      switch ($categoryKey) {
        'block-diagram' { $displayName = 'block diagram' }
        'front-panel'   { $displayName = 'front panel' }
        'attributes'    { $displayName = 'attributes' }
        'connector-pane'{ $displayName = 'connector pane' }
        'cosmetic'      { $displayName = 'cosmetic' }
        'unspecified'   { $displayName = 'unspecified' }
      }
    }
    $categorySummaryParts.Add(("{0} ({1})" -f $displayName, $countValue)) | Out-Null
  }
  if ($categorySummaryParts.Count -gt 0) {
    $summaryLines += "- Category counts: $($categorySummaryParts -join ', ')"
  }
}
$bucketSummaryParts = New-Object System.Collections.Generic.List[string]
foreach ($bucketKey in $aggregateBucketCounts.Keys) {
  $bucketCount = $aggregateBucketCounts[$bucketKey]
  $bucketLabel = $bucketKey
  $bucketMeta = Get-VIBucketMetadata -BucketSlug $bucketKey
  if ($bucketMeta) {
    $bucketLabel = $bucketMeta.label
    switch ($bucketMeta.classification) {
      'noise'   { $bucketLabel = '{0} (noise)' -f $bucketLabel }
      'neutral' { $bucketLabel = '{0} (neutral)' -f $bucketLabel }
    }
  }
  $bucketSummaryParts.Add(("{0} ({1})" -f $bucketLabel, $bucketCount)) | Out-Null
}
if ($bucketSummaryParts.Count -gt 0) {
  $summaryLines += "- Bucket counts: $($bucketSummaryParts -join ', ')"
} else {
  $summaryLines += "- Bucket counts: none"
}

if ($hasStepSummary -and $modeSummaryRows.Count -gt 0) {
  $summaryLines += ''
  $summaryLines += '#### Mode Summary'
  $summaryLines += ''
  $summaryLines += '| Mode | Processed | Diffs | Missing | Last Diff | Manifest |'
  $summaryLines += '| --- | ---: | ---: | ---: | --- | --- |'
  foreach ($row in $modeSummaryRows) {
    $lastDiffCell = '-'
    if ($row.Diffs -gt 0) {
      if ($row.LastDiffIndex) {
        $lastDiffCell = "#$($row.LastDiffIndex)"
        if ($row.LastDiffCommit) {
          $lastDiffCell += " @$(Get-ShortSha -Value $row.LastDiffCommit -Length 12)"
        }
      } else {
        $lastDiffCell = 'diff detected'
      }
    }
    $manifestLeaf = if ($row.ManifestPath) { [System.IO.Path]::GetFileName($row.ManifestPath) } else { $null }
    $manifestCell = if ($manifestLeaf) { "``$manifestLeaf``" } else { 'n/a' }
    $summaryLines += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $row.Mode, $row.Processed, $row.Diffs, $row.Missing, $lastDiffCell, $manifestCell)
  }
    if ($totalDiffs -gt 0) {
      $summaryLines += ''
      $summaryLines += '> Diff artifacts are available under the `vi-compare-diff-artifacts` upload.'
    }

    $summaryLines += ''
    $summaryLines += '#### Mode Outputs'
    $summaryLines += ''
    $summaryLines += '| Mode | Flags | Results Dir | Manifest |'
    $summaryLines += '| --- | --- | --- | --- |'
    foreach ($row in $modeSummaryRows) {
      $flagCell = '_none_'
      if ($row.Flags) {
        $flagEntries = @()
        foreach ($flag in @($row.Flags)) {
          if ([string]::IsNullOrWhiteSpace($flag)) { continue }
          $flagEntries += ("``{0}``" -f $flag)
        }
        if ($flagEntries.Count -gt 0) {
          $flagCell = $flagEntries -join '<br>'
        }
      }

      $resultsRelative = $row.ResultsRelative
      if ([string]::IsNullOrWhiteSpace($resultsRelative)) {
        $resultsRelative = $row.ResultsDir
      }
      $resultsCell = if ($resultsRelative) {
        $resultsNormalized = $resultsRelative.Replace('\','/')
        ("``{0}``" -f $resultsNormalized)
      } else {
        'n/a'
      }

      $manifestLeaf = if ($row.ManifestPath) { [System.IO.Path]::GetFileName($row.ManifestPath) } else { $null }
      $manifestCell = if ($manifestLeaf) {
        "``$manifestLeaf``"
      } elseif ($row.ManifestPath) {
        "``$($row.ManifestPath)``"
      } else {
        'n/a'
      }

      $summaryLines += ('| {0} | {1} | {2} | {3} |' -f $row.Mode, $flagCell, $resultsCell, $manifestCell)
    }
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
Write-GitHubOutput -Key 'target-path' -Value $targetRel -DestPath $GitHubOutputPath
if ($aggregateCategoryCounts.Count -gt 0) {
  $categoryJson = ConvertTo-Json $aggregateCategoryCounts -Depth 4 -Compress
  Write-GitHubOutput -Key 'category-counts-json' -Value $categoryJson -DestPath $GitHubOutputPath
}
if ($aggregateBucketCounts.Count -gt 0) {
  $bucketJson = ConvertTo-Json $aggregateBucketCounts -Depth 4 -Compress
} else {
  $bucketJson = '{}'
}
Write-GitHubOutput -Key 'bucket-counts-json' -Value $bucketJson -DestPath $GitHubOutputPath

$modeManifestSummary = $aggregate.modes | ForEach-Object {
  [ordered]@{
    mode      = $_.name
    slug      = $_.slug
    manifest  = $_.manifestPath
    resultsDir= $_.resultsDir
    flags     = $_.flags
    processed = $_.stats.processed
    diffs     = $_.stats.diffs
    missing   = $_.stats.missing
    lastDiffIndex = $_.stats.lastDiffIndex
    lastDiffCommit = $_.stats.lastDiffCommit
    stopReason = $_.stats.stopReason
    status    = $_.status
  }
}
Write-GitHubOutput -Key 'mode-manifests-json' -Value ((ConvertTo-Json $modeManifestSummary -Depth 4 -Compress)) -DestPath $GitHubOutputPath

$modeNameBuffer = New-Object System.Collections.Generic.List[string]
$flagSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($modeEntry in $aggregate.modes) {
  if ($modeEntry.name) { $modeNameBuffer.Add([string]$modeEntry.name) }
  foreach ($flagValue in @($modeEntry.flags)) {
    if ([string]::IsNullOrWhiteSpace($flagValue)) { continue }
    [void]$flagSet.Add($flagValue.Trim())
  }
}
if ($modeNameBuffer.Count -gt 0) {
  $modeListValue = ($modeNameBuffer | Sort-Object -Unique) -join ', '
Write-GitHubOutput -Key 'mode-list' -Value $modeListValue -DestPath $GitHubOutputPath
}
$flagArray = [System.Linq.Enumerable]::ToArray($flagSet)
if ($flagArray -and $flagArray.Count -gt 0) {
  $flagListValue = ($flagArray | Sort-Object) -join ', '
  Write-GitHubOutput -Key 'flag-list' -Value $flagListValue -DestPath $GitHubOutputPath
} else {
  Write-GitHubOutput -Key 'flag-list' -Value 'none' -DestPath $GitHubOutputPath
}

$historyReportMarkdownPath = Join-Path $resultsRootResolved 'history-report.md'
$historyReportHtmlPath = if ($ReportFormat -eq 'html') {
  Join-Path $resultsRootResolved 'history-report.html'
} else {
  $null
}
$rendererScript = Join-Path (Split-Path -Parent $PSCommandPath) 'Render-VIHistoryReport.ps1'
$renderSucceeded = $false
if (Test-Path -LiteralPath $rendererScript -PathType Leaf) {
  $rendererArgs = @{
    ManifestPath       = $aggregateManifestResolved
    HistoryContextPath = Join-Path $resultsRootResolved 'history-context.json'
    OutputDir          = $resultsRootResolved
    MarkdownPath       = $historyReportMarkdownPath
    GitHubOutputPath   = $GitHubOutputPath
    StepSummaryPath    = $StepSummaryPath
  }
  if ($historyReportHtmlPath) {
    $rendererArgs['EmitHtml'] = $true
    $rendererArgs['HtmlPath'] = $historyReportHtmlPath
  }
  try {
    & $rendererScript @rendererArgs | Out-Null
    $renderSucceeded = $true
  } catch {
    Write-Warning ("Failed to render VI history report: {0}" -f $_.Exception.Message)
  }
} else {
  Write-Warning ("VI history renderer script not found at {0}" -f $rendererScript)
}

if (-not $renderSucceeded) {
  try {
    $fallbackLines = @(
      '# VI history report'
      ''
      ('Target: `{0}`' -f ($targetRel ?? 'unknown'))
      ('Manifest: `{0}`' -f ($aggregateManifestResolved ?? 'unknown'))
      ''
      '## Commit pairs'
      ''
      '<sub>n/a - n/a</sub>'
      ''
      '| Pair | **diff** | Report |'
      '| --- | --- | --- |'
      '| n/a | n/a | [report](./) |'
      ''
      '## Attribute coverage'
      ''
      '_History renderer unavailable; see manifest for details._'
    )
    [System.IO.File]::WriteAllText(
      $historyReportMarkdownPath,
      ($fallbackLines -join [Environment]::NewLine),
      [System.Text.Encoding]::UTF8
    )
    if ($historyReportHtmlPath) {
      $fallbackHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>VI History Report (fallback)</title>
</head>
<body>
  <article>
    <h1>VI history report</h1>
    <p>History renderer unavailable; see manifest: <code>$([System.Net.WebUtility]::HtmlEncode($aggregateManifestResolved))</code></p>
    <section>
      <h2>Commit pairs</h2>
      <p><sub>n/a - n/a</sub></p>
      <table>
        <thead><tr><th>Pair</th><th>Diff</th><th>Report</th></tr></thead>
        <tbody><tr><td>n/a</td><td>pending</td><td><code>n/a</code></td></tr></tbody>
      </table>
    </section>
    <section>
      <h2>Attribute coverage</h2>
      <p>History renderer unavailable.</p>
    </section>
  </article>
</body>
</html>
"@
      [System.IO.File]::WriteAllText($historyReportHtmlPath, $fallbackHtml, [System.Text.Encoding]::UTF8)
    }
  } catch {
    Write-Warning ("Failed to create fallback VI history report: {0}" -f $_.Exception.Message)
  }
}

if (Test-Path -LiteralPath $historyReportMarkdownPath -PathType Leaf) {
  $historyReportMarkdownResolved = (Resolve-Path -LiteralPath $historyReportMarkdownPath).Path
  Write-GitHubOutput -Key 'history-report-md' -Value $historyReportMarkdownResolved -DestPath $GitHubOutputPath
}
if ($historyReportHtmlPath -and (Test-Path -LiteralPath $historyReportHtmlPath -PathType Leaf)) {
  $historyReportHtmlResolved = (Resolve-Path -LiteralPath $historyReportHtmlPath).Path
  Write-GitHubOutput -Key 'history-report-html' -Value $historyReportHtmlResolved -DestPath $GitHubOutputPath
}

Write-Host ("VI compare history suite complete. Aggregate manifest: {0}" -f $aggregateManifestResolved)

if ($hasStepSummary -and $totalDiffs -gt 0) {
  $diffSummaryText = if ($diffHighlights.Count -gt 0) {
    $diffHighlights -join '; '
  } else {
    $diffSuffix = if ($totalDiffs -eq 1) { '' } else { 's' }
    "$totalDiffs diff$diffSuffix detected"
  }
  Write-Host ("::warning::LVCompare detected differences ({0}). Review the 'vi-compare-diff-artifacts' artifact for details." -f $diffSummaryText)
}

if ($FailOnDiff.IsPresent -and $totalDiffs -gt 0) {
  throw ("Differences detected across {0} comparison(s)" -f $totalDiffs)
}

