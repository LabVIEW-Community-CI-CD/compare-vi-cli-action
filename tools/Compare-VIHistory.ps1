param(
  [Parameter(Mandatory = $true)]
  [Alias('ViName')]
  [string]$TargetPath,

  [Alias('Branch')]
  [string]$StartRef = 'HEAD',
  [string]$EndRef,
  [int]$MaxPairs,
  [string]$SourceBranchRef,
  [Nullable[int]]$MaxBranchCommits,
  [int]$MaxSignalPairs = 2,
  [ValidateSet('include','collapse','skip')]
  [string]$NoisePolicy = 'collapse',

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
  [Nullable[int]]$CompareTimeoutSeconds,

  [string]$GitHubOutputPath,
  [string]$StepSummaryPath,

  [switch]$IncludeMergeParents
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Variable -Name repoRoot -Scope Script -Value $null
$script:CommitParentCache = @{}
$script:MergeBaseCache = @{}

$maxPairsRequested = $PSBoundParameters.ContainsKey('MaxPairs') -and $MaxPairs -gt 0
$maxSignalBudget = if ($MaxSignalPairs -gt 0) { [int]$MaxSignalPairs } else { $null }
$signalBudgetRequested = $maxSignalBudget -ne $null
$noisePolicyEffective = if ($NoisePolicy) { $NoisePolicy.ToLowerInvariant() } else { 'collapse' }

if ($noisePolicyEffective -notin @('include','collapse','skip')) {
  throw ("Unsupported noise policy '{0}'." -f $NoisePolicy)
}

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
  'default' = @{
    slug         = 'default'
    presetFlags  = $null
    adjustments  = @{}
  }
  'attributes' = @{
    slug         = 'attributes'
    presetFlags  = $null
    adjustments  = @{
      FlagNoAttr = $false
    }
  }
  'front-panel' = @{
    slug         = 'front-panel'
    presetFlags  = $null
    adjustments  = @{
      FlagNoFp    = $false
      FlagNoFpPos = $false
    }
  }
  'block-diagram' = @{
    slug         = 'block-diagram'
    presetFlags  = $null
    adjustments  = @{
      ForceNoBd    = $false
      FlagNoBdCosm = $false
    }
  }
  'full' = @{
    slug         = 'full'
    presetFlags  = $null
    adjustments  = @{
      ForceNoBd    = $false
      FlagNoAttr   = $false
      FlagNoFp     = $false
      FlagNoFpPos  = $false
      FlagNoBdCosm = $false
    }
  }
  'custom' = @{
    slug         = 'custom'
    presetFlags  = $null
    adjustments  = @{}
  }
}

$modeAliases = @{
  'all' = 'full'
}

function Resolve-ModeSpec {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $tokenOriginal = $Value.Trim()
  $token = $tokenOriginal.ToLowerInvariant()
  $usedAlias = $false
  if ($modeAliases.ContainsKey($token)) {
    $token = $modeAliases[$token]
    $usedAlias = $true
  }
  if (-not $modeDefinitions.ContainsKey($token)) {
    $allowed = [string]::Join(', ', $modeDefinitions.Keys)
    throw ("Unknown mode '{0}'. Allowed modes: {1}" -f $Value, $allowed)
  }
  $def = $modeDefinitions[$token]
  if ($usedAlias) {
    Write-Warning ("Mode '{0}' is deprecated; using '{1}' instead." -f $tokenOriginal, $token)
  }
  return [pscustomobject]@{
    Name = $token
    Slug = $def.slug
    PresetFlags = if ($def.presetFlags -ne $null) { @($def.presetFlags) } else { $null }
    Adjustments = if ($def.adjustments) { $def.adjustments } else { @{} }
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

function Parse-ReportDiffHeadings {
  param([string]$Html)

  $headings = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrWhiteSpace($Html)) { return @() }

  $regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
                  [System.Text.RegularExpressions.RegexOptions]::Singleline

  $patterns = @(
    '<summary\b[^>]*class="[^"]*\bdifference-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</summary>',
    '<summary\b[^>]*class="[^"]*\bvi-difference-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</summary>',
    '<summary\b[^>]*class="[^"]*\bdifference-cosmetic-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</summary>',
    '<h[1-6]\b[^>]*class="[^"]*\bdifference-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</h[1-6]>',
    '<details\b[^>]*data-diff-(?:category|heading)="(?<text>[^"]+)"[^>]*>'
  )

  foreach ($pattern in $patterns) {
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, $regexOptions)) {
      $raw = $match.Groups['text'].Value
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $decoded = [System.Net.WebUtility]::HtmlDecode($raw.Trim())
      $decoded = ($decoded -replace '^\s*\d+[\.\)]\s*', '')
      if ([string]::IsNullOrWhiteSpace($decoded)) { continue }
      if (-not $headings.Contains($decoded)) {
        $headings.Add($decoded) | Out-Null
      }
    }
  }

  return @($headings.ToArray())
}

function Parse-ReportDiffDetails {
  param([string]$Html)

  $details = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrWhiteSpace($Html)) { return @() }

  $pattern = '<li\s+class="[^"]*\bdiff-detail(?:-cosmetic)?\b[^"]*">\s*(?<text>.*?)\s*</li>'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
    $raw = $match.Groups['text'].Value
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $decoded = [System.Net.WebUtility]::HtmlDecode($raw.Trim())
    if ($decoded) {
      $details.Add($decoded) | Out-Null
    }
  }

  return @($details.ToArray())
}

function Infer-ComparisonCategoriesFromReportDetails {
  param([System.Collections.IEnumerable]$Details)

  $inferred = New-Object System.Collections.Generic.List[string]
  if (-not $Details) { return @() }

  function Add-Category {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if (-not $inferred.Contains($Name)) {
      $inferred.Add($Name) | Out-Null
    }
  }

  foreach ($detail in $Details) {
    if ([string]::IsNullOrWhiteSpace($detail)) { continue }
    $token = $detail.ToLowerInvariant()

    $hasBlockDiagram = $token -match 'block diagram'
    $hasFrontPanel   = $token -match 'front panel'
    $hasConnector    = $token -match 'connector pane'
    $hasWindow       = $token -match 'window'
    $hasIcon         = $token -match 'icon'
    $hasAttribute    = $token -match 'vi attribute' -or $token -match 'attributes'
    $hasCosmetic     = $token -match 'cosmetic'

    if ($hasBlockDiagram) {
      if ($hasCosmetic) {
        Add-Category 'Block Diagram Cosmetic'
      } elseif ($token -match 'functional') {
        Add-Category 'Block Diagram Functional'
      } else {
        Add-Category 'Block Diagram'
      }
    } elseif ($hasCosmetic) {
      Add-Category 'Cosmetic'
    }

    if ($hasConnector) {
      Add-Category 'Connector Pane'
    }

    if ($hasFrontPanel -or $token -match 'control' -or $token -match 'indicator' -or $token -match 'terminal') {
      Add-Category 'Front Panel'
    }

    if ($hasWindow -or $token -match 'position/size' -or $token -match 'window size' -or $token -match 'panel position') {
      Add-Category 'Front Panel Position/Size'
    }

    if ($hasIcon -or $hasAttribute -or $token -match 'documentation' -or $token -match 'execution') {
      if ($hasIcon) { Add-Category 'Icon' }
      Add-Category 'VI Attribute'
    }
  }

  return @($inferred.ToArray())
}

function Get-ComparisonCategoriesFromReport {
  param([string]$ReportPath)

  $empty = [pscustomobject]@{
    categories            = @()
    headings              = @()
    details               = @()
    categoryDetails       = @()
    categoryBuckets       = @()
    categoryBucketDetails = @()
  }

  if ([string]::IsNullOrWhiteSpace($ReportPath)) { return $empty }
  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { return $empty }

  try {
    $html = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop
  } catch {
    return $empty
  }

  $headings = @(Parse-ReportDiffHeadings -Html $html)
  $details = @(Parse-ReportDiffDetails -Html $html)
  $categories = New-Object System.Collections.Generic.List[string]

  foreach ($heading in $headings) {
    if ([string]::IsNullOrWhiteSpace($heading)) { continue }
    $primary = $heading
    $splitIdx = $heading.IndexOf(' - ')
    if ($splitIdx -gt 0) {
      $primary = $heading.Substring(0, $splitIdx)
    }
    $primary = $primary.Trim()
    if ([string]::IsNullOrWhiteSpace($primary)) { continue }
    if (-not $categories.Contains($primary)) {
      $categories.Add($primary) | Out-Null
    }
  }

  $hasBlockDiagramCosmetic = $false
  $patternCosmeticHeading = '<summary\s+class="[^"]*\bdifference-cosmetic-heading\b[^"]*"\s*>'
  if ([System.Text.RegularExpressions.Regex]::IsMatch($html, $patternCosmeticHeading, 'IgnoreCase')) {
    $hasBlockDiagramCosmetic = $true
  } else {
    $patternCosmeticDetail = '<li\s+class="[^"]*\bdiff-detail-cosmetic\b[^"]*"\s*>'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($html, $patternCosmeticDetail, 'IgnoreCase')) {
      $hasBlockDiagramCosmetic = $true
    }
  }
  if ($hasBlockDiagramCosmetic -and -not $categories.Contains('Block Diagram Cosmetic')) {
    $categories.Add('Block Diagram Cosmetic') | Out-Null
  }

  if ($categories.Count -eq 0 -and $details.Count -gt 0) {
    foreach ($name in @(Infer-ComparisonCategoriesFromReportDetails -Details $details)) {
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      if (-not $categories.Contains($name)) {
        $categories.Add($name) | Out-Null
      }
    }
  }

  $categoryDetails = @()
  $categoryBuckets = @()
  $categoryBucketDetails = @()
  if ($categories.Count -gt 0) {
    $categoryInfo = Get-VICategoryBuckets -Names @($categories.ToArray())
    if ($categoryInfo) {
      if ($categoryInfo.Details) { $categoryDetails = @($categoryInfo.Details) }
      if ($categoryInfo.BucketSlugs) { $categoryBuckets = @($categoryInfo.BucketSlugs) }
      if ($categoryInfo.BucketDetails) { $categoryBucketDetails = @($categoryInfo.BucketDetails) }
    }
  }

  return [pscustomobject]@{
    categories            = @($categories.ToArray())
    headings              = $headings
    details               = $details
    categoryDetails       = $categoryDetails
    categoryBuckets       = $categoryBuckets
    categoryBucketDetails = $categoryBucketDetails
  }
}

function Get-ComparisonClassification {
  param(
    $CategoryDetails,
    [bool]$HasDiff
  )
  if (-not $HasDiff) { return 'match' }
  if (-not $CategoryDetails) { return 'unknown' }

  if ($CategoryDetails -isnot [System.Collections.IEnumerable] -or $CategoryDetails -is [string]) {
    $CategoryDetails = @($CategoryDetails)
  }

  $hasSignal = $false
  $hasOther  = $false
  foreach ($detail in $CategoryDetails) {
    if (-not $detail) { continue }
    $classification = $null
    if ($detail.PSObject.Properties['classification']) {
      $classification = [string]$detail.classification
    }
    if ([string]::IsNullOrWhiteSpace($classification)) { continue }
    $normalized = $classification.Trim().ToLowerInvariant()
    if ($normalized -eq 'signal') {
      $hasSignal = $true
    } elseif ($normalized -eq 'noise' -or $normalized -eq 'neutral') {
      $hasOther = $true
    }
  }
  if ($hasSignal) { return 'signal' }
  if ($hasOther)  { return 'noise' }
  return 'unknown'
}

function Get-ComparisonCategoryDisplayName {
  param([string]$Name)

  if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }

  try {
    $meta = Get-VICategoryMetadata -Name $Name
    if ($meta -and -not [string]::IsNullOrWhiteSpace($meta.label)) {
      return [string]$meta.label
    }
  } catch {}

  return $Name
}

function Update-TallyFromDetails {
  param(
    [System.Collections.IDictionary]$Target,
    $Details,
    [System.Func[object,string]]$Selector
  )
  if (-not $Target -or -not $Details) { return }
  if ($Details -isnot [System.Collections.IEnumerable] -or $Details -is [string]) {
    $Details = @($Details)
  }
  foreach ($detail in $Details) {
    if (-not $detail) { continue }
    $key = $null
    if ($Selector) {
      $key = $Selector.Invoke($detail)
    } elseif ($detail.PSObject.Properties['slug']) {
      $key = [string]$detail.slug
    }
    if ([string]::IsNullOrWhiteSpace($key) -and $detail.PSObject.Properties['label']) {
      $key = [string]$detail.label
    }
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    if (-not $Target.Contains($key)) {
      $Target[$key] = 0
    }
    try { $Target[$key] = [int]$Target[$key] + 1 } catch { $Target[$key]++ }
  }
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
  if ($ModeSpec.Name -eq 'full') {
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

function Invoke-ProcessCapture {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo
  )

  $proc = [System.Diagnostics.Process]::Start($StartInfo)
  if ($null -eq $proc) {
    throw ("Failed to start process: {0}" -f $StartInfo.FileName)
  }

  try {
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
    $proc.WaitForExit()

    return [pscustomobject]@{
      ExitCode = $proc.ExitCode
      StdOut   = $stdoutTask.Result
      StdErr   = $stderrTask.Result
    }
  } finally {
    $proc.Dispose()
  }
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
  $result = Invoke-ProcessCapture -StartInfo $psi
  if ($result.ExitCode -ne 0) {
    $msg = "git {0} failed with exit code {1}" -f ($Arguments -join ' '), $result.ExitCode
    if ($result.StdErr) { $msg = "$msg`n$($result.StdErr)" }
    throw $msg
  }
  if (-not $Quiet -and $result.StdErr) { Write-Verbose $result.StdErr }
  return $result.StdOut
}

function Invoke-Pwsh {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [hashtable]$Environment
  )
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'pwsh'
  foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $repoRoot
  if ($Environment) {
    foreach ($entry in $Environment.GetEnumerator()) {
      if ([string]::IsNullOrWhiteSpace([string]$entry.Key)) { continue }
      if ($null -eq $entry.Value) {
        [void]$psi.Environment.Remove([string]$entry.Key)
      } else {
        $psi.Environment[[string]$entry.Key] = [string]$entry.Value
      }
    }
  }
  return (Invoke-ProcessCapture -StartInfo $psi)
}

function Get-ExecDiffEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$ExecPath
  )
  if (-not (Test-Path -LiteralPath $ExecPath -PathType Leaf)) {
    return $false
  }
  try {
    $execData = Get-Content -LiteralPath $ExecPath -Raw | ConvertFrom-Json -Depth 8
    if ($execData -and $execData.PSObject.Properties['diff']) {
      return [bool]$execData.diff
    }
  } catch {}
  return $false
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
  $result = Invoke-ProcessCapture -StartInfo $psi
  if ($result.ExitCode -ne 0) {
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
  if ($script:repoRoot) {
    try { $psi.WorkingDirectory = $script:repoRoot } catch {}
  }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $result = Invoke-ProcessCapture -StartInfo $psi
  return ($result.ExitCode -eq 0)
}

function Test-CommitTouchesPath {
  param(
    [Parameter(Mandatory = $true)][string]$Commit,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $result = Invoke-Git -Arguments @('diff-tree','--root','-m','--no-commit-id','--name-only','-r',$Commit,'--',$Path) -Quiet
  return -not [string]::IsNullOrWhiteSpace($result)
}

function Get-CommitParents {
  param(
    [Parameter(Mandatory = $true)][string]$Commit
  )

  if ([string]::IsNullOrWhiteSpace($Commit)) { return @() }

  if ($script:CommitParentCache.ContainsKey($Commit)) {
    return $script:CommitParentCache[$Commit]
  }

  $parents = @()
  try {
    $raw = Invoke-Git -Arguments @('cat-file','commit',$Commit) -Quiet
  } catch {
    $script:CommitParentCache[$Commit] = $parents
    return $parents
  }

  foreach ($rawLine in ($raw -split "`n")) {
    $line = $rawLine.Trim()
    if (-not $line) { break }
    if ($line.StartsWith('parent ')) {
      $parentSha = $line.Substring(7).Trim()
      if (-not [string]::IsNullOrWhiteSpace($parentSha)) {
        $parents += $parentSha
      }
    }
  }

  $script:CommitParentCache[$Commit] = $parents
  return $parents
}

function Get-MergeBase {
  param(
    [Parameter(Mandatory = $true)][string]$CommitA,
    [Parameter(Mandatory = $true)][string]$CommitB
  )

  if ([string]::IsNullOrWhiteSpace($CommitA) -or [string]::IsNullOrWhiteSpace($CommitB)) {
    return $null
  }

  $key = "{0}::{1}" -f $CommitA, $CommitB
  if ($script:MergeBaseCache.ContainsKey($key)) {
    return $script:MergeBaseCache[$key]
  }

  $reverseKey = "{0}::{1}" -f $CommitB, $CommitA
  if ($script:MergeBaseCache.ContainsKey($reverseKey)) {
    return $script:MergeBaseCache[$reverseKey]
  }

  try {
    $raw = Invoke-Git -Arguments @('merge-base','--',$CommitA,$CommitB) -Quiet
    $value = ($raw -split "`n")[0].Trim()
  } catch {
    $value = $null
  }

  $script:MergeBaseCache[$key] = $value
  $script:MergeBaseCache[$reverseKey] = $value
  return $value
}

function Get-BranchCommitSequence {
  param(
    [Parameter(Mandatory = $true)][string]$BranchHead,
    [string]$ExcludeRef,
    [Parameter(Mandatory = $true)][string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($BranchHead)) { return @() }

  $args = @('rev-list',$BranchHead)
  if ($ExcludeRef) {
    $args += ('^{0}' -f $ExcludeRef)
  }
  $args += '--'
  $args += $Path

  try {
    $raw = Invoke-Git -Arguments $args -Quiet
  } catch {
    return @()
  }

  return @($raw -split "`n" | Where-Object { $_ })
}

function Get-MergeParentPlan {
  param(
    [Parameter(Mandatory = $true)][string]$MergeCommit,
    [Parameter(Mandatory = $true)][string]$FirstParent,
    [Parameter(Mandatory = $true)][string]$BranchParent,
    [Parameter(Mandatory = $true)][int]$ParentIndex,
    [Parameter(Mandatory = $true)][int]$ParentCount,
    [Parameter(Mandatory = $true)][string]$TargetRel,
    [string]$EndRef,
    [switch]$IncludeMergeParents,
    [string]$RootMerge,
    [System.Collections.Generic.HashSet[string]]$SeenBranches
  )

  if (-not $SeenBranches) {
    $SeenBranches = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  }
  if (-not $RootMerge) { $RootMerge = $MergeCommit }

  $branchKey = "{0}|{1}|{2}" -f $MergeCommit, $BranchParent, $ParentIndex
  if (-not $SeenBranches.Add($branchKey)) {
    return @()
  }

  $plan = New-Object System.Collections.Generic.List[object]

  $mergeBase = Get-MergeBase -CommitA $BranchParent -CommitB $FirstParent

  $branchCommitsRaw = Get-BranchCommitSequence -BranchHead $BranchParent -ExcludeRef $mergeBase -Path $TargetRel
  $branchList = New-Object System.Collections.Generic.List[string]
  foreach ($commit in $branchCommitsRaw) {
    $trimmed = $commit.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
      [void]$branchList.Add($trimmed)
    }
  }
  if ($branchList.Count -gt 1) {
    $branchList.Reverse()
  }

  for ($i = 0; $i -lt $branchList.Count; $i++) {
    $commit = $branchList[$i]
    $parents = @(Get-CommitParents -Commit $commit)
    $baseCommit = if ($parents.Count -gt 0) { $parents[0] } else { $mergeBase }
    if ([string]::IsNullOrWhiteSpace($baseCommit)) { continue }

    $depth = $branchList.Count - $i
    $lineage = [ordered]@{
      type        = 'merge-branch'
      parentIndex = $ParentIndex
      parentCount = $ParentCount
      mergeCommit = $MergeCommit
      rootMerge   = $RootMerge
      branchHead  = $BranchParent
      depth       = $depth
    }

    $stopAfter = $EndRef -and [string]::Equals($baseCommit, $EndRef, [System.StringComparison]::OrdinalIgnoreCase)
    $plan.Add([ordered]@{
      Head            = $commit
      Base            = $baseCommit
      Lineage         = $lineage
      StopAfter       = [bool]$stopAfter
      StopAfterReason = if ($stopAfter) { 'reached-end-ref' } else { $null }
    }) | Out-Null

    if ($IncludeMergeParents.IsPresent -and $parents.Count -gt 1) {
      for ($sub = 1; $sub -lt $parents.Count; $sub++) {
        $altParent = $parents[$sub]
        if ([string]::IsNullOrWhiteSpace($altParent)) { continue }
        $nested = Get-MergeParentPlan -MergeCommit $commit -FirstParent $baseCommit -BranchParent $altParent -ParentIndex ($sub + 1) -ParentCount $parents.Count -TargetRel $TargetRel -EndRef $EndRef -IncludeMergeParents:$IncludeMergeParents.IsPresent -RootMerge $RootMerge -SeenBranches $SeenBranches
        foreach ($subSpec in $nested) {
          $plan.Add($subSpec) | Out-Null
        }
      }
    }
  }

  $mergeStopAfter = $EndRef -and [string]::Equals($BranchParent, $EndRef, [System.StringComparison]::OrdinalIgnoreCase)
  $plan.Add([ordered]@{
    Head            = $MergeCommit
    Base            = $BranchParent
    Lineage         = [ordered]@{
      type        = 'merge-parent'
      parentIndex = $ParentIndex
      parentCount = $ParentCount
      mergeCommit = $MergeCommit
      rootMerge   = $RootMerge
      branchHead  = $BranchParent
      depth       = 0
    }
    StopAfter       = [bool]$mergeStopAfter
    StopAfterReason = if ($mergeStopAfter) { 'reached-end-ref' } else { $null }
  }) | Out-Null

  return $plan.ToArray()
}

function Build-ComparisonPlan {
  param(
    [Parameter(Mandatory = $true)][string[]]$MainlineCommits,
    [Parameter(Mandatory = $true)][string]$TargetRel,
    [string]$EndRef,
    [switch]$IncludeMergeParents
  )

  $mainlineSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $mainlineList = New-Object System.Collections.Generic.List[string]
  foreach ($entry in $MainlineCommits) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    $trimmed = $entry.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    if ($mainlineSet.Add($trimmed)) {
      $mainlineList.Add($trimmed)
    }
  }

  for ($index = 0; $index -lt $mainlineList.Count; $index++) {
    $currentCommit = $mainlineList[$index]
    $parentsForCurrent = @(Get-CommitParents -Commit $currentCommit)
    if (-not $parentsForCurrent -or $parentsForCurrent.Count -eq 0) { continue }
    $firstParentForCurrent = $parentsForCurrent[0]
    if ([string]::IsNullOrWhiteSpace($firstParentForCurrent)) { continue }
    if ($mainlineSet.Add($firstParentForCurrent)) {
      $mainlineList.Add($firstParentForCurrent)
    }
    if ($EndRef -and [string]::Equals($firstParentForCurrent, $EndRef, [System.StringComparison]::OrdinalIgnoreCase)) {
      break
    }
  }

  $plan = New-Object System.Collections.Generic.List[object]
  $addedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $seenBranches = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  $terminalHint = $null

  function Add-Spec {
    param([object]$Spec, [System.Collections.Generic.HashSet[string]]$KeySet, [System.Collections.Generic.List[object]]$PlanList)
    if (-not $Spec) { return }
    if ([string]::IsNullOrWhiteSpace($Spec.Head) -or [string]::IsNullOrWhiteSpace($Spec.Base)) { return }

    $lineage = $Spec.Lineage
    $parentIndexKey = if ($lineage -and $lineage.PSObject.Properties['parentIndex']) { [int]$lineage.parentIndex } else { 0 }
    $mergeCommitKey = if ($lineage -and $lineage.PSObject.Properties['mergeCommit']) { [string]$lineage.mergeCommit } else { '' }
    $depthKey = if ($lineage -and $lineage.PSObject.Properties['depth']) { [int]$lineage.depth } else { 0 }
    $key = "{0}|{1}|{2}|{3}|{4}" -f $Spec.Head, $Spec.Base, $parentIndexKey, $mergeCommitKey, $depthKey
    if (-not $KeySet.Add($key)) { return }
    $PlanList.Add([pscustomobject]$Spec) | Out-Null
  }

  foreach ($rawHead in $mainlineList) {
    $head = $rawHead.Trim()
    if (-not $head) { continue }

    if ($EndRef -and [string]::Equals($head, $EndRef, [System.StringComparison]::OrdinalIgnoreCase)) {
      $terminalHint = 'reached-end-ref'
      break
    }

    $parents = @(Get-CommitParents -Commit $head)
    if ($parents.Count -eq 0) {
      $terminalHint = 'reached-root'
      break
    }

    $parentCount = $parents.Count
    $firstParent = $parents[0]

    $stopAfter = $EndRef -and [string]::Equals($firstParent, $EndRef, [System.StringComparison]::OrdinalIgnoreCase)
    $spec = [ordered]@{
      Head            = $head
      Base            = $firstParent
      Lineage         = [ordered]@{
        type        = 'mainline'
        parentIndex = 1
        parentCount = $parentCount
        mergeCommit = $head
        rootMerge   = $head
        depth       = 0
      }
      StopAfter       = [bool]$stopAfter
      StopAfterReason = if ($stopAfter) { 'reached-end-ref' } else { $null }
    }
    Add-Spec -Spec $spec -KeySet $addedKeys -PlanList $plan

    if ($IncludeMergeParents.IsPresent -and $parents.Count -gt 1) {
      for ($pi = 1; $pi -lt $parents.Count; $pi++) {
        $branchParent = $parents[$pi]
        if ([string]::IsNullOrWhiteSpace($branchParent)) { continue }
        $branchSpecs = Get-MergeParentPlan -MergeCommit $head -FirstParent $firstParent -BranchParent $branchParent -ParentIndex ($pi + 1) -ParentCount $parentCount -TargetRel $TargetRel -EndRef $EndRef -IncludeMergeParents:$IncludeMergeParents.IsPresent -RootMerge $head -SeenBranches $seenBranches
        foreach ($branchSpec in $branchSpecs) {
          Add-Spec -Spec $branchSpec -KeySet $addedKeys -PlanList $plan
        }
      }
    }

    if ($stopAfter) { break }
  }

  return [ordered]@{
    Plan         = $plan.ToArray()
    TerminalHint = $terminalHint
  }
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
  $result = Invoke-ProcessCapture -StartInfo $psi
  if ($result.ExitCode -eq 0) { return $true }
  if ($result.ExitCode -eq 1) { return $false }
  throw ("git merge-base --is-ancestor failed: {0}" -f $result.StdErr)
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

function Get-SourceBranchBudget {
  param(
    [Parameter(Mandatory = $true)][string]$BranchRef,
    [Parameter(Mandatory = $true)][int]$MaxCommitCount
  )

  $normalizedBranchRef = if ([string]::IsNullOrWhiteSpace($BranchRef)) { '' } else { $BranchRef.Trim() }
  $result = [ordered]@{
    sourceBranchRef = $normalizedBranchRef
    baselineRef = $null
    maxCommitCount = [int]$MaxCommitCount
    commitCount = $null
    status = 'pending'
    reason = 'not-evaluated'
  }

  if ([string]::IsNullOrWhiteSpace($normalizedBranchRef)) {
    $result.status = 'invalid'
    $result.reason = 'branch-ref-empty'
    return [pscustomobject]$result
  }

  if ($normalizedBranchRef.StartsWith('-')) {
    $result.status = 'invalid'
    $result.reason = 'branch-ref-invalid-format'
    return [pscustomobject]$result
  }

  $branchResolveSpec = '{0}^{{commit}}' -f $normalizedBranchRef
  $branchCommitRef = $null
  try {
    $branchCommitRaw = Invoke-Git -Arguments @('rev-parse', '--verify', '--end-of-options', $branchResolveSpec) -Quiet
    $branchCommitRef = [string]($branchCommitRaw | Select-Object -Last 1)
    if ($null -ne $branchCommitRef) {
      $branchCommitRef = $branchCommitRef.Trim()
    }
  } catch {
    $result.status = 'invalid'
    $result.reason = 'branch-ref-not-found'
    return [pscustomobject]$result
  }

  $baselineRef = $null
  $baselineCommitRef = $null
  try {
    $baselineCommitRaw = Invoke-Git -Arguments @('rev-parse', '--verify', '--end-of-options', 'develop^{commit}') -Quiet
    $baselineCommitRef = [string]($baselineCommitRaw | Select-Object -Last 1)
    if ($null -ne $baselineCommitRef) {
      $baselineCommitRef = $baselineCommitRef.Trim()
    }
    $baselineRef = 'develop'
  } catch {
    $baselineRef = $null
    $baselineCommitRef = $null
  }
  $result.baselineRef = $baselineRef

  $countArguments = @('rev-list', '--count', '--first-parent')
  if ($baselineCommitRef) {
    if ([string]::Equals($branchCommitRef, $baselineCommitRef, [System.StringComparison]::OrdinalIgnoreCase)) {
      $countArguments += ('{0}..{0}' -f $baselineCommitRef)
    } else {
      $countArguments += ('{0}..{1}' -f $baselineCommitRef, $branchCommitRef)
    }
  } else {
    $countArguments += $branchCommitRef
  }

  try {
    $countRaw = Invoke-Git -Arguments $countArguments -Quiet
  } catch {
    $result.status = 'error'
    $result.reason = 'commit-count-query-failed'
    return [pscustomobject]$result
  }

  $countText = (($countRaw -split "`n")[0]).Trim()
  $countValue = 0
  if (-not [int]::TryParse($countText, [ref]$countValue)) {
    $result.status = 'error'
    $result.reason = 'commit-count-parse-failed'
    return [pscustomobject]$result
  }

  $result.commitCount = [int]$countValue
  if ($countValue -gt $MaxCommitCount) {
    $result.status = 'blocked'
    $result.reason = 'commit-limit-exceeded'
  } else {
    $result.status = 'ok'
    $result.reason = 'within-limit'
  }

  return [pscustomobject]$result
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
$sourceBranchBudget = $null
$sourceBranchRefEffective = if ([string]::IsNullOrWhiteSpace($SourceBranchRef)) { $startRef } else { $SourceBranchRef.Trim() }


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
$branchCommitBudgetRequested = $PSBoundParameters.ContainsKey('MaxBranchCommits') -and $null -ne $MaxBranchCommits -and $MaxBranchCommits -gt 0
if ($branchCommitBudgetRequested) {
  $sourceBranchBudget = Get-SourceBranchBudget -BranchRef $sourceBranchRefEffective -MaxCommitCount ([int]$MaxBranchCommits)
  if ([string]::Equals($sourceBranchBudget.status, 'blocked', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("VI history source branch '{0}' exceeds the commit safeguard ({1} > {2}). Narrow the branch or raise -MaxBranchCommits." -f $sourceBranchBudget.sourceBranchRef, $sourceBranchBudget.commitCount, $sourceBranchBudget.maxCommitCount)
  }
  if (-not [string]::Equals($sourceBranchBudget.status, 'ok', [System.StringComparison]::OrdinalIgnoreCase)) {
    $reasonText = switch ([string]$sourceBranchBudget.reason) {
      'branch-ref-empty' { 'branch ref was empty' }
      'branch-ref-not-found' { 'branch ref was not found' }
      'commit-count-query-failed' { 'commit count query failed' }
      'commit-count-parse-failed' { 'commit count could not be parsed' }
      default { [string]$sourceBranchBudget.reason }
    }
    throw ("Unable to evaluate VI history source branch commit budget for '{0}' ({1}). Specify a valid branch via -SourceBranchRef or choose a branch-like -StartRef." -f $sourceBranchBudget.sourceBranchRef, $reasonText)
  }
}
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
if ($maxPairsRequested) {
  $revArgs += ("--max-count={0}" -f ([int]($MaxPairs + 5)))
}
$revArgs += '--'
$revArgs += $targetRel
$revListRaw = Invoke-Git -Arguments $revArgs -Quiet
$commitList = @($revListRaw -split "`n" | Where-Object { $_ })
Write-Verbose ("Commit list count: {0}" -f $commitList.Count)
$planResult = Build-ComparisonPlan -MainlineCommits $commitList -TargetRel $targetRel -EndRef $endRef -IncludeMergeParents:$IncludeMergeParents.IsPresent
$comparisonPlan = @()
$planTerminalHint = $null
if ($planResult) {
  if ($planResult.PSObject.Properties['Plan'] -and $planResult.Plan) {
    $comparisonPlan = [object[]]$planResult.Plan
  }
  if ($planResult.PSObject.Properties['TerminalHint'] -and $planResult.TerminalHint) {
    $planTerminalHint = $planResult.TerminalHint
  }
}

if ($commitList.Count -eq 0) {
  throw ("No commits found for {0} reachable from {1}" -f $targetRel, $startRef)
}

$planEntries = @()
if ($null -ne $comparisonPlan) {
  if ($comparisonPlan -is [System.Array]) {
    if ($comparisonPlan.Length -gt 0) {
      $planEntries = [object[]]$comparisonPlan
    }
  } else {
    $planEntries = @($comparisonPlan)
  }
}
$planEntriesCount = ($planEntries | Measure-Object).Count
if ($planEntriesCount -eq 0) {
  $fallbackPlan = New-Object System.Collections.Generic.List[object]
  foreach ($rawHead in $commitList) {
    $head = $rawHead.Trim()
    if (-not $head) { continue }

    if ($endRef -and [string]::Equals($head, $endRef, [System.StringComparison]::OrdinalIgnoreCase)) {
      if (-not $planTerminalHint) { $planTerminalHint = 'reached-end-ref' }
      break
    }

    $parentExpr = ('{0}^' -f $head)
    $parentRaw = $null
    try { $parentRaw = Invoke-Git -Arguments @('rev-parse', $parentExpr) -Quiet } catch { $parentRaw = $null }
    $baseCommit = ($parentRaw -split "`n")[0].Trim()
    if (-not $baseCommit) {
      if (-not $planTerminalHint) { $planTerminalHint = 'reached-root' }
      break
    }

    $stopAfter = $endRef -and [string]::Equals($baseCommit, $endRef, [System.StringComparison]::OrdinalIgnoreCase)
    $fallbackPlan.Add([pscustomobject]@{
      Head            = $head
      Base            = $baseCommit
      Lineage         = [ordered]@{
        type        = 'mainline'
        parentIndex = 1
        parentCount = 1
        mergeCommit = $head
        rootMerge   = $head
        depth       = 0
      }
      StopAfter       = [bool]$stopAfter
      StopAfterReason = if ($stopAfter) { 'reached-end-ref' } else { $null }
    }) | Out-Null

    if ($stopAfter) { break }
  }
  Write-Verbose ("Fallback plan entries: {0}" -f $fallbackPlan.Count)
  $planEntries = $fallbackPlan.ToArray()
  $planEntriesCount = ($planEntries | Measure-Object).Count
}
Write-Verbose ("Comparison plan entries: {0}" -f $planEntriesCount)

$compareScript = $null
$scriptsOverride = $env:COMPAREVI_SCRIPTS_ROOT
if (-not [string]::IsNullOrWhiteSpace($scriptsOverride)) {
  if (Test-Path -LiteralPath $scriptsOverride -PathType Leaf) {
    $compareScript = $scriptsOverride
  } else {
    $overrideCandidates = @(
      (Join-Path $scriptsOverride 'Compare-RefsToTemp.ps1'),
      (Join-Path (Join-Path $scriptsOverride 'tools') 'Compare-RefsToTemp.ps1')
    )
    foreach ($candidate in $overrideCandidates) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $compareScript = $candidate
        break
      }
    }
  }
}

if (-not $compareScript) {
  $compareScript = Join-Path $repoRoot 'tools' 'Compare-RefsToTemp.ps1'
}
if (-not (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
  $envScriptsRoot = $env:COMPAREVI_SCRIPTS_ROOT
  if ($envScriptsRoot) {
    try {
      $envScriptsRoot = [System.IO.Path]::GetFullPath($envScriptsRoot)
    } catch {
      $envScriptsRoot = $null
    }
  }
  if ($envScriptsRoot) {
    $candidate = Join-Path $envScriptsRoot 'Compare-RefsToTemp.ps1'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $compareScript = $candidate
    }
  }
}
if (-not (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
  throw ("Compare script not found: {0}" -f $compareScript)
}

$outPrefixToken = if ($OutPrefix) { $OutPrefix } else { $targetLeaf -replace '[^A-Za-z0-9._-]+','_' }
if ([string]::IsNullOrWhiteSpace($outPrefixToken)) { $outPrefixToken = 'vi-history' }

$modeNames = @($modeSpecs | ForEach-Object { $_.Name })
$requestedModeListValue = if ($modeNames.Count -gt 0) { $modeNames -join ', ' } else { 'none' }
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
if ($sourceBranchBudget) {
  $summaryLines += "- Source branch: $($sourceBranchBudget.sourceBranchRef)"
  $budgetDisplay = if ($null -ne $sourceBranchBudget.commitCount) {
    '{0} / {1}' -f $sourceBranchBudget.commitCount, $sourceBranchBudget.maxCommitCount
  } else {
    'n/a / {0}' -f $sourceBranchBudget.maxCommitCount
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$sourceBranchBudget.baselineRef)) {
    $summaryLines += "- Source branch budget: $budgetDisplay (baseline: $($sourceBranchBudget.baselineRef))"
  } else {
    $summaryLines += "- Source branch budget: $budgetDisplay"
  }
}
if ($endRef) { $summaryLines += "- End ref: $endRef" }
$summaryLines += "- Requested modes: $requestedModeListValue"
$summaryLines += "- Report format: $reportFormatEffective"
$signalBudgetDisplay = if ($maxSignalBudget) { $maxSignalBudget } else { 'unlimited' }
$summaryLines += "- Max signal pairs: $signalBudgetDisplay"
$summaryLines += "- Noise policy: $noisePolicyEffective"

$aggregate = [ordered]@{
  schema      = 'vi-compare/history-suite@v1'
  generatedAt = (Get-Date).ToString('o')
  targetPath  = $targetRel
  requestedStartRef = $requestedStartRef
  startRef    = $startRef
  endRef      = $endRef
  maxPairs    = if ($maxPairsRequested) { $MaxPairs } else { $null }
  maxSignalPairs = $maxSignalBudget
  noisePolicy = $noisePolicyEffective
  failFast    = [bool]$FailFast.IsPresent
  failOnDiff  = [bool]$FailOnDiff.IsPresent
  reportFormat = $reportFormatEffective
  resultsDir  = $resultsRootResolved
  requestedModes = @($modeNames)
  executedModes  = @()
  modes       = @()
  stats       = [ordered]@{
    modes     = $modeSpecs.Count
    processed = 0
    diffs     = 0
    signalDiffs = 0
    noiseCollapsed = 0
    errors    = 0
    missing   = 0
    categoryCounts = [ordered]@{}
    bucketCounts   = [ordered]@{}
  }
  status      = 'pending'
}
if ($sourceBranchBudget) {
  $aggregate.branchBudget = [ordered]@{
    sourceBranchRef = [string]$sourceBranchBudget.sourceBranchRef
    baselineRef = if ([string]::IsNullOrWhiteSpace([string]$sourceBranchBudget.baselineRef)) { $null } else { [string]$sourceBranchBudget.baselineRef }
    maxCommitCount = [int]$sourceBranchBudget.maxCommitCount
    commitCount = if ($null -eq $sourceBranchBudget.commitCount) { $null } else { [int]$sourceBranchBudget.commitCount }
    status = [string]$sourceBranchBudget.status
    reason = [string]$sourceBranchBudget.reason
  }
}

$totalProcessed = 0
$totalDiffs = 0
$totalSignalDiffs = 0
$totalNoiseCollapsed = 0
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
  $modeAdjustments = if ($modeSpec.PSObject.Properties['Adjustments']) { $modeSpec.Adjustments } else { @{} }
  if ($modeAdjustments.ContainsKey('ForceNoBd'))    { $modeForceNoBd    = [bool]$modeAdjustments['ForceNoBd'] }
  if ($modeAdjustments.ContainsKey('FlagNoAttr'))   { $modeFlagNoAttr   = [bool]$modeAdjustments['FlagNoAttr'] }
  if ($modeAdjustments.ContainsKey('FlagNoFp'))     { $modeFlagNoFp     = [bool]$modeAdjustments['FlagNoFp'] }
  if ($modeAdjustments.ContainsKey('FlagNoFpPos'))  { $modeFlagNoFpPos  = [bool]$modeAdjustments['FlagNoFpPos'] }
  if ($modeAdjustments.ContainsKey('FlagNoBdCosm')) { $modeFlagNoBdCosm = [bool]$modeAdjustments['FlagNoBdCosm'] }

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
    maxPairs    = if ($maxPairsRequested) { $MaxPairs } else { $null }
    maxSignalPairs = $maxSignalBudget
    noisePolicy = $noisePolicyEffective
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
      signalDiffs    = 0
      noiseCollapsed = 0
      lastDiffIndex  = $null
      lastDiffCommit = $null
      stopReason     = $null
      errors         = 0
      missing        = 0
      categoryCounts = [ordered]@{}
      bucketCounts   = [ordered]@{}
      collapsedNoise = [ordered]@{
        count        = 0
        indices      = @()
        commits      = @()
        categoryCounts = [ordered]@{}
        bucketCounts   = [ordered]@{}
      }
    }
    status      = 'pending'
  }

  $modeCategoryCounts = $modeManifest.stats.categoryCounts
  $modeBucketCounts = $modeManifest.stats.bucketCounts

  $processed = 0
  $diffCount = 0
  $signalDiffCount = 0
  $missingCount = 0
  $errorCount = 0
  $lastDiffIndex = $null
  $lastDiffCommit = $null
  $stopReason = $null
  $noiseCollapsedCount = 0
  $collapsedNoiseStats = $modeManifest.stats.collapsedNoise
  $collapsedCategoryCounts = $collapsedNoiseStats.categoryCounts
  $collapsedBucketCounts = $collapsedNoiseStats.bucketCounts
  $collapsedIndices = New-Object System.Collections.Generic.List[int]
  $collapsedCommits = New-Object System.Collections.Generic.List[string]

  foreach ($planEntry in $planEntries) {
    if (-not $planEntry) { continue }

    $headCommit = $null
    if ($planEntry.PSObject.Properties['Head'] -and $planEntry.Head) {
      $headCommit = [string]$planEntry.Head
    }
    $baseCommit = $null
    if ($planEntry.PSObject.Properties['Base'] -and $planEntry.Base) {
      $baseCommit = [string]$planEntry.Base
    }

    if ([string]::IsNullOrWhiteSpace($headCommit) -or [string]::IsNullOrWhiteSpace($baseCommit)) { continue }
    $headCommit = $headCommit.Trim()
    $baseCommit = $baseCommit.Trim()
    if (-not $headCommit -or -not $baseCommit) { continue }

    $lineageNode = $null
    if ($planEntry.PSObject.Properties['Lineage'] -and $planEntry.Lineage) {
      $lineageNode = $planEntry.Lineage
    }
    $lineageType = if ($lineageNode -and $lineageNode.PSObject.Properties['type']) { [string]$lineageNode.type } else { 'mainline' }

    $planStopAfter = $false
    if ($planEntry.PSObject.Properties['StopAfter']) {
      $planStopAfter = [bool]$planEntry.StopAfter
    }
    $planStopReason = $null
    if ($planEntry.PSObject.Properties['StopAfterReason'] -and $planEntry.StopAfterReason) {
      $planStopReason = [string]$planEntry.StopAfterReason
    }

    $index = $processed + 1
    if ($maxPairsRequested -and $index -gt $MaxPairs) {
      $stopReason = 'max-pairs'
      break
    }

    Write-Verbose ("[{0}] Comparing {1} -> {2} (mode: {3}, lineage: {4})" -f $index, (Get-ShortSha -Value $baseCommit -Length 7), (Get-ShortSha -Value $headCommit -Length 7), $modeName, $lineageType)

    $comparisonRecord = [ordered]@{
      index   = $index
      head    = @{
        ref   = $headCommit
        short = Get-ShortSha -Value $headCommit -Length 12
      }
      base    = @{
        ref   = $baseCommit
        short = Get-ShortSha -Value $baseCommit -Length 12
      }
      outName      = "{0}-{1}" -f $outPrefixToken, $index.ToString('D3')
      mode         = $modeName
      slug         = $modeSlug
      reportFormat = $reportFormatEffective
    }
    if ($lineageNode) {
      $comparisonRecord.lineage = [pscustomobject]$lineageNode
    }

    $summaryPath = Join-Path $modeResultsResolved ("{0}-summary.json" -f $comparisonRecord.outName)
    $execPath    = Join-Path $modeResultsResolved ("{0}-exec.json" -f $comparisonRecord.outName)
    $artifactsPath = Join-Path $modeResultsResolved ("{0}-artifacts" -f $comparisonRecord.outName)
    $summaryJson = $null
    $summaryPreExisting = $false
    # Determinism guard: self-hosted workspaces may retain prior run outputs.
    # Always clear per-pair artifacts so each compare is executed fresh.
    foreach ($stalePath in @($summaryPath, $execPath, $artifactsPath)) {
      if (Test-Path -LiteralPath $stalePath) {
        try {
          Remove-Item -LiteralPath $stalePath -Recurse -Force -ErrorAction Stop
        } catch {
          Write-Warning ("Failed to remove stale comparison output '{0}': {1}" -f $stalePath, $_.Exception.Message)
        }
      }
    }

    $comparisonRecordObject = $null
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

      $baseExists = Test-FileExistsAtRef -Ref $baseCommit -Path $targetRel
      if (-not $baseExists) {
        $missingCount++
        $comparisonRecord.result = [ordered]@{
          status  = 'missing-base'
          message = ("Target '{0}' not present at {1}" -f $targetRel, $baseCommit)
        }
        $processed++
        $modeManifest.comparisons += [pscustomobject]$comparisonRecord
        if ($planStopAfter) {
          $stopReason = if ($planStopReason) { $planStopReason } else { 'reached-end-ref' }
          break
        }
        continue
      }

      if (-not $summaryPreExisting) {
        $modeProcessEnvironment = @{
          COMPAREVI_HISTORY_MODE = $modeName
          COMPAREVI_HISTORY_MODE_SLUG = $modeSlug
          COMPAREVI_HISTORY_MODE_FLAGS = if ($modeFlags -and $modeFlags.Count -gt 0) { $modeFlags -join "`n" } else { '' }
          COMPAREVI_HISTORY_REPORT_FORMAT = $reportFormatEffective
        }
        $compareArgs = @("-NoLogo","-NoProfile","-File", $compareScript,
          "-Path", $targetRel,
          "-RefA", $baseCommit,
          "-RefB", $headCommit,
          "-ResultsDir", $modeResultsResolved,
          "-OutName", $comparisonRecord.outName,
          "-ReportFormat", $reportFormatEffective,
          "-Quiet"
        )
        $compareArgs += "-ReplaceFlags"
        if ($Detailed.IsPresent) { $compareArgs += "-Detailed" }
        if ($RenderReport.IsPresent -or $reportFormatEffective -eq 'html') { $compareArgs += "-RenderReport" }
        if ($FailOnDiff.IsPresent) { $compareArgs += "-FailOnDiff" }
        if ($modeFlags -and $modeFlags.Count -gt 0) {
          $compareArgs += "-LvCompareArgs"
          $compareArgs += ($modeFlags -join ' ')
        }
        if ($PSBoundParameters.ContainsKey('CompareTimeoutSeconds') -and $CompareTimeoutSeconds -gt 0) {
          $compareArgs += "-TimeoutSeconds"
          $compareArgs += [string][int]$CompareTimeoutSeconds
        }
        if (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
          $compareArgs += "-InvokeScriptPath"
          $compareArgs += $InvokeScriptPath
        }
        if ($KeepArtifactsOnNoDiff.IsPresent) {
          $compareArgs += "-KeepArtifactsOnNoDiff"
        }
        $compareArgsOriginal = @($compareArgs)
        $pwshResult = Invoke-Pwsh -Arguments $compareArgs -Environment $modeProcessEnvironment
        if ($pwshResult.ExitCode -ne 0) {
          if ($pwshResult.ExitCode -eq 1) {
            $hasSummary = Test-Path -LiteralPath $summaryPath -PathType Leaf
            $hasDiffEvidence = $hasSummary -or (Get-ExecDiffEvidence -ExecPath $execPath)
            if ($hasDiffEvidence) {
              Write-Verbose 'Compare-RefsToTemp reported exit code 1 with diff evidence; continuing.'
            } else {
              $msg = "Compare-RefsToTemp.ps1 exited with code 1 without diff evidence."
              if ($pwshResult.StdErr) { $msg = "$msg`n$($pwshResult.StdErr.Trim())" }
              if ($pwshResult.StdOut) { $msg = "$msg`n$($pwshResult.StdOut.Trim())" }
              throw $msg
            }
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
          Write-Warning ("Summary not found at {0}; retrying compare with detailed capture." -f $summaryPath)
          $retryArgsList = New-Object System.Collections.Generic.List[string]
          foreach ($arg in $compareArgsOriginal) { $retryArgsList.Add($arg) | Out-Null }
          if (-not ($retryArgsList.Contains("-Detailed"))) { $retryArgsList.Add("-Detailed") | Out-Null }
          if (-not ($retryArgsList.Contains("-RenderReport"))) { $retryArgsList.Add("-RenderReport") | Out-Null }
          [void]$retryArgsList.Remove("-Quiet")
          $retryArgs = $retryArgsList.ToArray()
          $retryResult = Invoke-Pwsh -Arguments $retryArgs -Environment $modeProcessEnvironment
          if ($retryResult.ExitCode -ne 0) {
            if ($retryResult.ExitCode -eq 1) {
              $hasSummary = Test-Path -LiteralPath $summaryPath -PathType Leaf
              $hasDiffEvidence = $hasSummary -or (Get-ExecDiffEvidence -ExecPath $execPath)
              if ($hasDiffEvidence) {
                Write-Verbose 'Retry Compare-RefsToTemp reported exit code 1 with diff evidence; continuing.'
              } else {
                $msg = "Retry Compare-RefsToTemp.ps1 exited with code 1 without diff evidence."
                if ($retryResult.StdErr) { $msg = "$msg`n$($retryResult.StdErr.Trim())" }
                if ($retryResult.StdOut) { $msg = "$msg`n$($retryResult.StdOut.Trim())" }
                throw $msg
              }
            } else {
              $msg = "Retry Compare-RefsToTemp.ps1 exited with code {0}" -f $retryResult.ExitCode
              if ($retryResult.StdErr) { $msg = "$msg`n$($retryResult.StdErr.Trim())" }
              if ($retryResult.StdOut) { $msg = "$msg`n$($retryResult.StdOut.Trim())" }
              throw $msg
            }
          }
        }
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
          Write-Warning ("Summary not found at {0}; generating fallback summary from exec data." -f $summaryPath)
          $fallbackOut = [ordered]@{
            execJson = if (Test-Path -LiteralPath $execPath -PathType Leaf) { (Resolve-Path -LiteralPath $execPath).Path } else { $null }
          }
          $fallbackCli = [ordered]@{
            exitCode    = $null
            diff        = $null
            duration_s  = $null
            command     = $null
            cliPath     = $null
            reportFormat = $reportFormatEffective
          }
          if (Test-Path -LiteralPath $execPath -PathType Leaf) {
            try {
              $execData = Get-Content -LiteralPath $execPath -Raw | ConvertFrom-Json -Depth 6
              if ($execData) {
                if ($execData.PSObject.Properties['exitCode']) { $fallbackCli.exitCode = [int]$execData.exitCode }
                if ($execData.PSObject.Properties['diff']) { $fallbackCli.diff = [bool]$execData.diff }
                if ($execData.PSObject.Properties['duration_s']) { $fallbackCli.duration_s = [double]$execData.duration_s }
                if ($execData.PSObject.Properties['command']) { $fallbackCli.command = [string]$execData.command }
                if ($execData.PSObject.Properties['cliPath']) { $fallbackCli.cliPath = [string]$execData.cliPath }
                if ($execData.PSObject.Properties['args'] -and $execData.args) { $fallbackCli.args = @($execData.args) }
              }
            } catch {}
          }
          $fallback = [ordered]@{
            schema       = 'ref-compare-summary/v1'
            generatedAt  = (Get-Date).ToString('o')
            name         = $targetLeaf
            path         = $targetRel
            refA         = $baseCommit
            refB         = $headCommit
            temp         = $null
            reportFormat = $reportFormatEffective
            out          = [pscustomobject]$fallbackOut
            computed     = [ordered]@{
              baseBytes  = $null
              headBytes  = $null
              baseSha    = $null
              headSha    = $null
              expectDiff = $null
            }
            cli          = [pscustomobject]$fallbackCli
          }
          $fallback | ConvertTo-Json -Depth 8 | Out-File -FilePath $summaryPath -Encoding utf8
          $summaryJson = [pscustomobject]$fallback
        } else {
          $summaryJson = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 8
        }
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
      $cliCategories = @()
      $cliCategoryDetails = @()
      $cliCategoryBuckets = @()
      $cliCategoryBucketDetails = @()
      if ($summaryJson.cli -and $summaryJson.cli.PSObject.Properties['highlights'] -and $summaryJson.cli.highlights) {
        $highlights += @($summaryJson.cli.highlights | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
      if ($summaryJson.cli -and $summaryJson.cli.PSObject.Properties['categories'] -and $summaryJson.cli.categories) {
        $cliCategories += @($summaryJson.cli.categories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
      if ($summaryJson.cli -and $summaryJson.cli.PSObject.Properties['categoryDetails'] -and $summaryJson.cli.categoryDetails) {
        $cliCategoryDetails += @($summaryJson.cli.categoryDetails)
      }
      if ($summaryJson.cli -and $summaryJson.cli.PSObject.Properties['categoryBuckets'] -and $summaryJson.cli.categoryBuckets) {
        $cliCategoryBuckets += @($summaryJson.cli.categoryBuckets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
      if ($summaryJson.cli -and $summaryJson.cli.PSObject.Properties['categoryBucketDetails'] -and $summaryJson.cli.categoryBucketDetails) {
        $cliCategoryBucketDetails += @($summaryJson.cli.categoryBucketDetails)
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

      $outNode = $summaryJson.out
      if ((@($cliCategories).Count -eq 0 -or @($cliCategoryDetails).Count -eq 0) -and $outNode) {
        $reportCandidate = $null
        if ($outNode.PSObject.Properties['reportHtml'] -and $outNode.reportHtml) {
          $reportCandidate = [string]$outNode.reportHtml
        } elseif ($outNode.PSObject.Properties['reportPath'] -and $outNode.reportPath) {
          $reportCandidate = [string]$outNode.reportPath
        }

        if (-not [string]::IsNullOrWhiteSpace($reportCandidate)) {
          $reportCategoryMetadata = Get-ComparisonCategoriesFromReport -ReportPath $reportCandidate
          if ($reportCategoryMetadata) {
            if (@($cliCategories).Count -eq 0 -and @($reportCategoryMetadata.categories).Count -gt 0) {
              $cliCategories += @($reportCategoryMetadata.categories)
            }
            if (@($cliCategoryDetails).Count -eq 0 -and @($reportCategoryMetadata.categoryDetails).Count -gt 0) {
              $cliCategoryDetails += @($reportCategoryMetadata.categoryDetails)
            }
            if (@($cliCategoryBuckets).Count -eq 0 -and @($reportCategoryMetadata.categoryBuckets).Count -gt 0) {
              $cliCategoryBuckets += @($reportCategoryMetadata.categoryBuckets)
            }
            if (@($cliCategoryBucketDetails).Count -eq 0 -and @($reportCategoryMetadata.categoryBucketDetails).Count -gt 0) {
              $cliCategoryBucketDetails += @($reportCategoryMetadata.categoryBucketDetails)
            }
            if (@($reportCategoryMetadata.headings).Count -gt 0) {
              $highlights += @($reportCategoryMetadata.headings)
            } elseif (@($reportCategoryMetadata.details).Count -gt 0) {
              $highlights += @($reportCategoryMetadata.details | Select-Object -First 10)
            }
          }
        }
      }

      if ($highlights.Count -gt 0) {
        $comparisonRecord.result.highlights = @($highlights | Select-Object -Unique)
      }

      $categories = @()
      if (@($cliCategories).Count -gt 0) {
        $categories = @($cliCategories | Select-Object -Unique)
      } else {
        $categories = @(
          Get-ComparisonCategories -Highlights $highlights -HasDiff:$diff |
            Select-Object -Unique
        )
      }

      $categoryInfo = $null
      if (@($categories).Count -gt 0) {
        $categoryInfo = Get-VICategoryBuckets -Names $categories
      }
      $resolvedCategoryDetails = if (@($cliCategoryDetails).Count -gt 0) {
        @($cliCategoryDetails)
      } elseif ($categoryInfo -and $categoryInfo.Details) {
        @($categoryInfo.Details)
      } else {
        @()
      }
      $resolvedCategoryBuckets = if (@($cliCategoryBuckets).Count -gt 0) {
        @($cliCategoryBuckets | Select-Object -Unique)
      } elseif ($categoryInfo -and $categoryInfo.BucketSlugs) {
        @($categoryInfo.BucketSlugs)
      } else {
        @()
      }
      $resolvedCategoryBucketDetails = if (@($cliCategoryBucketDetails).Count -gt 0) {
        @($cliCategoryBucketDetails)
      } elseif ($categoryInfo -and $categoryInfo.BucketDetails) {
        @($categoryInfo.BucketDetails)
      } else {
        @()
      }

      if (@($categories).Count -gt 0) {
        $comparisonRecord.result.categories = $categories
        if (@($resolvedCategoryDetails).Count -gt 0) {
          $comparisonRecord.result.categoryDetails = $resolvedCategoryDetails
        }
        if (@($resolvedCategoryBuckets).Count -gt 0) {
          $comparisonRecord.result.categoryBuckets = $resolvedCategoryBuckets
        }
        if (@($resolvedCategoryBucketDetails).Count -gt 0) {
          $comparisonRecord.result.categoryBucketDetails = $resolvedCategoryBucketDetails
        }
        foreach ($category in $categories) {
          $categoryKey = [string]$category
          if ([string]::IsNullOrWhiteSpace($categoryKey)) { continue }
          if (-not $modeCategoryCounts.Contains($categoryKey)) {
            $modeCategoryCounts[$categoryKey] = 0
          }
          $modeCategoryCounts[$categoryKey]++
        }
        if (@($resolvedCategoryBuckets).Count -gt 0) {
          foreach ($bucketSlug in $resolvedCategoryBuckets) {
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
      $categoryDetails = $null
      if ($comparisonRecord.result.PSObject.Properties['categoryDetails']) {
        $categoryDetails = $comparisonRecord.result.categoryDetails
      } elseif (@($resolvedCategoryDetails).Count -gt 0) {
        $categoryDetails = $resolvedCategoryDetails
      }

      $classification = Get-ComparisonClassification -CategoryDetails $categoryDetails -HasDiff:$diff
      $comparisonRecord.result.classification = $classification

      $appendComparison = $true
      $collapsedThis = $false
      $isSignalDiff = $false
      if ($diff) {
        if ($classification -eq 'noise') {
          if ($noisePolicyEffective -ne 'include') {
            $appendComparison = $false
            $collapsedThis = $true
          }
        } else {
          # treat unknown/other as signal
          $isSignalDiff = $true
        }

        if ($isSignalDiff) {
          $signalDiffCount++
        }

        if ($collapsedThis) {
          $comparisonRecord.result.collapsed = $true
          $noiseCollapsedCount++
          [void]$collapsedIndices.Add($index)
          [void]$collapsedCommits.Add($headCommit)
          if ($categoryDetails) {
            Update-TallyFromDetails -Target $collapsedCategoryCounts -Details $categoryDetails
          }
          if (@($resolvedCategoryBucketDetails).Count -gt 0) {
            Update-TallyFromDetails -Target $collapsedBucketCounts -Details $resolvedCategoryBucketDetails
          }
        }
      }

      $comparisonRecordObject = [pscustomobject]$comparisonRecord
      $processed++
      if ($diff) {
        $diffCount++
        $lastDiffIndex = $index
        $lastDiffCommit = $headCommit
        if ($FailFast.IsPresent) {
          if ($appendComparison) {
            $modeManifest.comparisons += $comparisonRecordObject
          }
          $stopReason = 'fail-fast-diff'
          break
        }
      }

      if ($appendComparison) {
        $modeManifest.comparisons += $comparisonRecordObject
      }

      if (-not $stopReason -and $isSignalDiff -and $signalBudgetRequested -and $signalDiffCount -ge $maxSignalBudget) {
        $stopReason = 'max-signal'
        break
      }
    }
    catch {
      if (-not $comparisonRecordObject) {
        $comparisonRecordObject = [pscustomobject]$comparisonRecord
      }
      if ($comparisonRecordObject.PSObject.Properties['error']) {
        $comparisonRecordObject.error = $_.Exception.Message
      } else {
        $comparisonRecordObject | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force
      }
      $modeManifest.comparisons += $comparisonRecordObject
      $errorCount++
      $stopReason = if ($stopReason) { $stopReason } else { 'error' }
      $modeManifest.status = 'failed'
      $modeManifest.stats.errors = $errorCount
      throw
    }

    if ($stopReason -eq 'fail-fast-diff') { break }
    if (-not $stopReason -and $planStopAfter) {
      $stopReason = if ($planStopReason) { $planStopReason } else { 'reached-end-ref' }
      break
    }
  }
  if (-not $stopReason) {
    if ($processed -eq 0) {
      $stopReason = 'no-pairs'
    } elseif ($errorCount -gt 0) {
      $stopReason = 'error'
    } elseif ($planTerminalHint) {
      $stopReason = $planTerminalHint
    } else {
      $stopReason = 'complete'
    }
  }

  $modeManifest.stats.processed = $processed
  $modeManifest.stats.diffs = $diffCount
  $modeManifest.stats.signalDiffs = $signalDiffCount
  $modeManifest.stats.noiseCollapsed = $noiseCollapsedCount
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

  $sortedCollapsedCategories = [ordered]@{}
  foreach ($categoryName in ($collapsedCategoryCounts.Keys | Sort-Object)) {
    $sortedCollapsedCategories[$categoryName] = [int]$collapsedCategoryCounts[$categoryName]
  }
  $sortedCollapsedBuckets = [ordered]@{}
  foreach ($bucketName in ($collapsedBucketCounts.Keys | Sort-Object)) {
    $sortedCollapsedBuckets[$bucketName] = [int]$collapsedBucketCounts[$bucketName]
  }
  $collapsedNoiseStats.categoryCounts = $sortedCollapsedCategories
  $collapsedNoiseStats.bucketCounts = $sortedCollapsedBuckets
  $collapsedNoiseStats.indices = @($collapsedIndices.ToArray())
  $collapsedNoiseStats.commits = @($collapsedCommits.ToArray())
  $collapsedNoiseStats.count = $noiseCollapsedCount

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
    $summaryLines += "- Signal diffs: $signalDiffCount"
    $summaryLines += "- Missing pairs: $missingCount"
    $summaryLines += "- Stop reason: $stopReason"
    if ($noiseCollapsedCount -gt 0 -and $noisePolicyEffective -ne 'include') {
      $summaryLines += "- Collapsed noise diffs: $noiseCollapsedCount"
      if ($collapsedNoiseStats.categoryCounts.Count -gt 0) {
        $collapsedCategorySummary = ($collapsedNoiseStats.categoryCounts.Keys | ForEach-Object {
            $k = $_
            $v = $collapsedNoiseStats.categoryCounts[$k]
            if ($v -isnot [int]) { $v = [int]$v }
            "{0} ({1})" -f (Get-ComparisonCategoryDisplayName -Name $k), $v
        }) -join ', '
        if ($collapsedCategorySummary) {
          $summaryLines += "  - Collapsed categories: $collapsedCategorySummary"
        }
      }
    }
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
    SignalDiffs    = $signalDiffCount
    NoiseCollapsed = $noiseCollapsedCount
    Missing        = $missingCount
    LastDiffIndex  = $lastDiffIndex
    LastDiffCommit = $lastDiffCommit
    ManifestPath   = $modeManifestResolved
    ResultsDir     = $modeResultsResolved
    ResultsRelative= $modeResultsRelative
  })

  if ($signalDiffCount -gt 0) {
    $diffPlural = if ($signalDiffCount -eq 1) { '' } else { 's' }
    $highlight = "{0}: {1} signal diff{2}" -f $modeName, $signalDiffCount, $diffPlural
    if ($lastDiffIndex) {
      $highlight += (" (last #{0}" -f $lastDiffIndex)
      if ($lastDiffCommit) {
        $highlight += (" @{0}" -f (Get-ShortSha -Value $lastDiffCommit -Length 12))
      }
      $highlight += ')'
    }
    $diffHighlights.Add($highlight)
  } elseif ($diffCount -gt 0 -and $noisePolicyEffective -eq 'include') {
    $diffPlural = if ($diffCount -eq 1) { '' } else { 's' }
    $diffHighlights.Add(("{0}: {1} diff{2}" -f $modeName, $diffCount, $diffPlural))
  }
  if ($noiseCollapsedCount -gt 0 -and $noisePolicyEffective -ne 'include') {
    $noisePlural = if ($noiseCollapsedCount -eq 1) { '' } else { 's' }
    $action = if ($noisePolicyEffective -eq 'collapse') { 'collapsed' } else { 'skipped' }
    $categorySummary = $null
    if ($collapsedNoiseStats.categoryCounts.Count -gt 0) {
      $categorySummary = ($collapsedNoiseStats.categoryCounts.Keys | ForEach-Object {
        $slug = $_
        $countValue = $collapsedNoiseStats.categoryCounts[$slug]
        if ($countValue -isnot [int]) { $countValue = [int]$countValue }
        "{0} ({1})" -f (Get-ComparisonCategoryDisplayName -Name $slug), $countValue
      }) -join ', '
    }
    $noiseHighlight = "{0}: {1} noise diff{2} {3}" -f $modeName, $noiseCollapsedCount, $noisePlural, $action
    if ($categorySummary) {
      $noiseHighlight += (" [{0}]" -f $categorySummary)
    }
    $diffHighlights.Add($noiseHighlight)
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
  $totalSignalDiffs += $signalDiffCount
  $totalNoiseCollapsed += $noiseCollapsedCount
  $totalErrors += $errorCount
  $totalMissing += $missingCount
}

$summaryLines += ''
$summaryLines += "- Total processed pairs: $totalProcessed"
$summaryLines += "- Total diffs: $totalDiffs"
$summaryLines += "- Total signal diffs: $totalSignalDiffs"
$summaryLines += "- Total missing pairs: $totalMissing"
if ($totalNoiseCollapsed -gt 0 -and $noisePolicyEffective -ne 'include') {
  $summaryLines += "- Collapsed noise diffs: $totalNoiseCollapsed"
}

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
$aggregate.stats.signalDiffs = $totalSignalDiffs
$aggregate.stats.noiseCollapsed = $totalNoiseCollapsed
$aggregate.stats.errors = $totalErrors
$aggregate.stats.missing = $totalMissing
$executedModeNames = @($aggregate.modes | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$aggregate.executedModes = @($executedModeNames)
$aggregate.status = if ($aggregate.modes | Where-Object { $_.status -eq 'failed' }) { 'failed' } else { 'ok' }
if ($executedModeNames.Count -gt 0) {
  $summaryLines += "- Executed modes: $($executedModeNames -join ', ')"
}

$aggregate | ConvertTo-Json -Depth 8 | Out-File -FilePath $aggregateManifestPath -Encoding utf8
$aggregateManifestResolved = (Resolve-Path -LiteralPath $aggregateManifestPath).Path
Write-GitHubOutput -Key 'manifest-path' -Value $aggregateManifestResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'results-dir' -Value $resultsRootResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'mode-count' -Value $aggregate.modes.Count -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'total-processed' -Value $totalProcessed -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'total-diffs' -Value $totalDiffs -DestPath $GitHubOutputPath
$aggregateStopReason = if ($aggregate.status -eq 'ok') { 'complete' } else { 'failed' }
Write-GitHubOutput -Key 'stop-reason' -Value $aggregateStopReason -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'target-path' -Value $targetRel -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'requested-mode-list' -Value $requestedModeListValue -DestPath $GitHubOutputPath
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
    signalDiffs = $_.stats.signalDiffs
    noiseCollapsed = $_.stats.noiseCollapsed
    errors    = $_.stats.errors
    missing   = $_.stats.missing
    categoryCounts = $_.stats.categoryCounts
    bucketCounts = $_.stats.bucketCounts
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
if ($executedModeNames.Count -gt 0) {
  $executedModeListValue = $executedModeNames -join ', '
  Write-GitHubOutput -Key 'executed-mode-list' -Value $executedModeListValue -DestPath $GitHubOutputPath
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
  Write-StepSummary -Lines $summaryLines -DestPath $StepSummaryPath
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
