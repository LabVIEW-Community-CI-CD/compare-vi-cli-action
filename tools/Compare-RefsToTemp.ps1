param(
  [Parameter(ParameterSetName='ByPath', Mandatory=$true)][string]$Path,
  [Parameter(ParameterSetName='ByName', Mandatory=$true)][string]$ViName,
  [Parameter(ParameterSetName='ByPath', Mandatory=$true)][Parameter(ParameterSetName='ByName', Mandatory=$true)][string]$RefA,
  [Parameter(ParameterSetName='ByPath', Mandatory=$true)][Parameter(ParameterSetName='ByName', Mandatory=$true)][string]$RefB,
  [string]$ResultsDir = 'tests/results/ref-compare',
  [string]$OutName,
  [switch]$Quiet,
  [switch]$Detailed,
  [switch]$RenderReport,
  [ValidateSet('html','xml','text')]
  [string]$ReportFormat = 'html',
  [string]$LvCompareArgs,
  [switch]$ReplaceFlags,
  [string]$LvComparePath,
  [string]$LabVIEWExePath,
  [string]$InvokeScriptPath,
  [switch]$LeakCheck,
  [double]$LeakGraceSeconds = 1.5,
  [string]$LeakJsonPath,
  [Nullable[int]]$TimeoutSeconds,
  [switch]$FailOnDiff
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { git --version | Out-Null } catch { throw 'git is required on PATH to fetch file content at refs.' }

$repoRoot = (Get-Location).Path

function Convert-ToNativeFileSystemPath {
  param([AllowNull()][string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return $PathValue }

  $candidate = [string]$PathValue
  $lastProviderSeparator = $candidate.LastIndexOf('::', [System.StringComparison]::Ordinal)
  if ($lastProviderSeparator -ge 0) {
    $candidate = $candidate.Substring($lastProviderSeparator + 2)
  }
  $candidate = ($candidate -replace '^[A-Za-z][A-Za-z0-9.+-]*::', '')
  if ($candidate -match '^[\\/](wsl\.localhost|wsl\$)[\\/]') {
    $candidate = [System.IO.Path]::DirectorySeparatorChar + $candidate
  }
  try {
    $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction Stop | Select-Object -First 1
    $providerPath = [string]$resolved.ProviderPath
    if (-not [string]::IsNullOrWhiteSpace($providerPath)) {
      return [System.IO.Path]::GetFullPath($providerPath)
    }
  } catch {}

  try {
    return [System.IO.Path]::GetFullPath($candidate)
  } catch {
    return $candidate
  }
}

$repoRoot = Convert-ToNativeFileSystemPath -PathValue $repoRoot

function Resolve-CompareVIScriptsRoot {
  param([string]$PrimaryRoot)

  $candidateRoots = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($PrimaryRoot)) {
    $candidateRoots.Add($PrimaryRoot) | Out-Null
  }
  $scriptsOverride = [System.Environment]::GetEnvironmentVariable('COMPAREVI_SCRIPTS_ROOT','Process')
  if (-not [string]::IsNullOrWhiteSpace($scriptsOverride)) {
    $candidateRoots.Add($scriptsOverride) | Out-Null
  }
  foreach ($root in $candidateRoots) {
    $moduleCandidate = Join-Path (Join-Path $root 'scripts') 'CompareVI.psm1'
    if (Test-Path -LiteralPath $moduleCandidate -PathType Leaf) {
      return $root
    }
  }
  return $PrimaryRoot
}

try {
  $categoryModuleCandidates = New-Object System.Collections.Generic.List[string]
  $categoryModuleCandidates.Add((Join-Path $repoRoot 'tools' 'VICategoryBuckets.psm1')) | Out-Null
  $resolvedScriptsRoot = Resolve-CompareVIScriptsRoot -PrimaryRoot $repoRoot
  if (-not [string]::IsNullOrWhiteSpace($resolvedScriptsRoot)) {
    $categoryModuleCandidates.Add((Join-Path $resolvedScriptsRoot 'tools' 'VICategoryBuckets.psm1')) | Out-Null
  }
  foreach ($candidate in @($categoryModuleCandidates | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      Import-Module $candidate -Force
      break
    }
  }
} catch {}

function Split-ArgString {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  $errors = $null
  $tokens = [System.Management.Automation.PSParser]::Tokenize($Value, [ref]$errors)
  $accepted = @('CommandArgument','String','Number','CommandParameter')
  $list = @()
  foreach ($token in $tokens) {
    if ($accepted -contains $token.Type) { $list += $token.Content }
  }
  return @($list | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Normalize-ExistingPath {
  param([string]$Candidate)
  if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
  try { return Convert-ToNativeFileSystemPath -PathValue $Candidate } catch { return $Candidate }
}

function Resolve-NativeExistingPath {
  param([string]$Candidate)
  if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
  try { return Convert-ToNativeFileSystemPath -PathValue $Candidate } catch { return $Candidate }
}

function Resolve-TempRoot {
  $candidates = @(
    $env:COMPAREVI_COMPARE_TEMP_ROOT,
    $env:COMPAREVI_TEMP_ROOT,
    $env:TEMP,
    $env:TMP,
    $env:TMPDIR,
    $env:RUNNER_TEMP
  )

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try {
      $resolved = [System.IO.Path]::GetFullPath($candidate)
      if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
      }
      return $resolved
    } catch {}
  }

  $fallback = [System.IO.Path]::GetTempPath()
  if ([string]::IsNullOrWhiteSpace($fallback)) {
    throw 'Unable to resolve a temporary directory for Compare-RefsToTemp.'
  }
  if (-not (Test-Path -LiteralPath $fallback -PathType Container)) {
    New-Item -ItemType Directory -Path $fallback -Force | Out-Null
  }
  return $fallback
}

function Get-PositiveIntFromEnv {
  param([string[]]$Names)
  foreach ($name in @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $raw = [System.Environment]::GetEnvironmentVariable($name, 'Process')
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $parsed = 0
    if ([int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -gt 0) {
      return [int]$parsed
    }
  }
  return $null
}

function Get-IncludedAttributesFromReport {
  param([string]$ReportPath)
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { return @() }
  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { return @() }
  try {
    $html = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop
  } catch {
    return @()
  }
  $matches = [regex]::Matches($html, '<li\s+class="(?<state>checked|unchecked)">(?<text>[^<]*)</li>', 'IgnoreCase')
  $results = @()
  foreach ($match in $matches) {
    $state = $match.Groups['state'].Value
    $text = $match.Groups['text'].Value
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $name = [System.Net.WebUtility]::HtmlDecode($text.Trim())
    $results += [pscustomobject]@{
      name     = $name
      included = ($state -eq 'checked')
    }
  }
  return $results
}

function Parse-DiffHeadings {
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

      $decoded = Normalize-ComparisonReportText -Value $raw
      $decoded = ($decoded -replace '^\s*\d+[\.\)]\s*', '')
      if ([string]::IsNullOrWhiteSpace($decoded)) { continue }
      if (Test-IsComparisonIdentityLabel -Value $decoded) { continue }
      if (-not $headings.Contains($decoded)) {
        $headings.Add($decoded) | Out-Null
      }
    }
  }

  return @($headings.ToArray())
}

function Normalize-ComparisonReportText {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

  $decoded = [System.Net.WebUtility]::HtmlDecode($Value)
  $withoutTags = [regex]::Replace($decoded, '<[^>]+>', ' ')
  return ([regex]::Replace($withoutTags, '\s+', ' ')).Trim()
}

function Test-IsComparisonIdentityLabel {
  param([string]$Value)

  $normalized = Normalize-ComparisonReportText -Value $Value
  if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }

  return ($normalized -match '^\s*First\s+VI:\s*.+?\s+Second\s+VI:\s*.+?\s*$')
}

function Parse-DiffDetails {
  param([string]$Html)

  $details = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrWhiteSpace($Html)) { return @() }

  $pattern = '<li\s+class="[^"]*\bdiff-detail(?:-cosmetic)?\b[^"]*">\s*(?<text>.*?)\s*</li>'
  foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
    $raw = $match.Groups['text'].Value
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $decoded = Normalize-ComparisonReportText -Value $raw
    if (Test-IsComparisonIdentityLabel -Value $decoded) { continue }
    if ($decoded) {
      $details.Add($decoded) | Out-Null
    }
  }

  return @($details.ToArray())
}

function Infer-DiffCategoriesFromDetails {
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

function Normalize-ReportCategories {
  param([System.Collections.IEnumerable]$Categories)

  if (-not $Categories -or -not (Get-Command -Name Get-VICategoryBuckets -ErrorAction SilentlyContinue)) {
    return @(
      $Categories |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique
    )
  }

  $categoryInfo = Get-VICategoryBuckets -Names @($Categories)
  if ($null -eq $categoryInfo -or -not $categoryInfo.Details) {
    return @(
      $Categories |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique
    )
  }

  $details = @($categoryInfo.Details)
  if ($details.Count -gt 1) {
    $specificDetails = @($details | Where-Object { [string]$_.slug -ne 'cosmetic' })
    if ($specificDetails.Count -gt 0) {
      $details = $specificDetails
    }
  }

  return @(
    $details |
      ForEach-Object {
        switch ([string]$_.slug) {
          'block-diagram' { 'Block Diagram' }
          'block-diagram-functional' { 'Block Diagram Functional' }
          'block-diagram-cosmetic' { 'Block Diagram Cosmetic' }
          'connector-pane' { 'Connector Pane' }
          'front-panel' { 'Front Panel' }
          'front-panel-position-size' { 'Front Panel Position/Size' }
          'control-changes' { 'Front Panel Controls' }
          'window' { 'Window Properties' }
          'attributes' { 'VI Attribute' }
          'vi-attribute' { 'VI Attribute' }
          'documentation' { 'Documentation' }
          'execution' { 'Execution Settings' }
          'icon' { 'Icon' }
          'unspecified' { 'Unspecified' }
          'cosmetic' { 'Cosmetic' }
          default { if ([string]::IsNullOrWhiteSpace([string]$_.label)) { [string]$_.slug } else { [string]$_.label } }
        }
      } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
}

function Get-ReportCategoryMetadata {
  param([string]$ReportPath)

  $empty = [pscustomobject]@{
    categories           = @()
    headings             = @()
    details              = @()
    categoryDetails      = @()
    categoryBuckets      = @()
    categoryBucketDetails= @()
  }

  if ([string]::IsNullOrWhiteSpace($ReportPath)) { return $empty }
  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { return $empty }

  try {
    $html = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop
  } catch {
    return $empty
  }

  $headings = @(Parse-DiffHeadings -Html $html)
  $details = @(Parse-DiffDetails -Html $html)
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
    foreach ($name in @(Infer-DiffCategoriesFromDetails -Details $details)) {
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      if (-not $categories.Contains($name)) {
        $categories.Add($name) | Out-Null
      }
    }
  }

  $normalizedCategories = @(Normalize-ReportCategories -Categories @($categories.ToArray()))
  $categories = New-Object System.Collections.Generic.List[string]
  foreach ($name in $normalizedCategories) {
    $categories.Add([string]$name) | Out-Null
  }

  $categoryDetails = @()
  $categoryBuckets = @()
  $categoryBucketDetails = @()
  if ($categories.Count -gt 0 -and (Get-Command -Name Get-VICategoryBuckets -ErrorAction SilentlyContinue)) {
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

function Resolve-ViRelativePath {
  param(
    [Parameter(Mandatory=$true)][string]$ViName,
    [Parameter(Mandatory=$true)][string[]]$Refs
  )

  $viLeaf = $ViName.Trim()
  if ([string]::IsNullOrWhiteSpace($viLeaf)) { throw "VI name cannot be empty." }
  $viLeafLower = $viLeaf.ToLowerInvariant()
  $refMatches = [ordered]@{}
  $pathLookup = @{}
  foreach ($ref in $Refs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
    $pathsForRef = @()
    $ls = & git ls-tree -r --name-only $ref 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ls) { continue }
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
    Write-Verbose ("[Compare-RefsToTemp] Multiple candidates for '{0}'; selected '{1}'" -f $ViName, $chosen)
  }
  return $chosen
}

function Get-FileAtRef([string]$ref,[string]$relPath,[string]$dest){
  $dir = Split-Path -Parent $dest
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $ls = & git ls-tree -r $ref -- $relPath 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $ls) { throw "git ls-tree failed to find $relPath at $ref" }
  $blob = $null
  foreach ($line in $ls) {
    $m = [regex]::Match($line, '^[0-9]+\s+blob\s+([0-9a-fA-F]{40})\s+\t')
    if ($m.Success) { $blob = $m.Groups[1].Value; break }
    $parts = $line -split '\s+'
    if ($parts.Count -ge 3 -and $parts[1] -eq 'blob') { $blob = $parts[2]; break }
  }
  if (-not $blob) { throw "Could not parse blob id for $relPath at $ref" }
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'git'
  foreach($a in @('cat-file','-p', $blob)) { [void]$psi.ArgumentList.Add($a) }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $fs = [System.IO.File]::Open($dest, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { throw "git cat-file failed for $blob (code=$($p.ExitCode))" }
}

function Invoke-PwshProcess {
  param(
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [switch]$QuietOutput
  )

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'pwsh'
  foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
  $psi.WorkingDirectory = $repoRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $processTempRoot = Resolve-TempRoot
  foreach ($tempVar in @('TEMP','TMP','TMPDIR','RUNNER_TEMP')) {
    if ([string]::IsNullOrWhiteSpace($psi.Environment[$tempVar])) {
      $psi.Environment[$tempVar] = $processTempRoot
    }
  }
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  if (-not $QuietOutput) {
    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Host $stderr }
  } elseif ($proc.ExitCode -ne 0) {
    if ($stdout) { Write-Host $stdout }
    if ($stderr) { Write-Host $stderr }
  }
  [pscustomobject]@{
    ExitCode = $proc.ExitCode
    StdOut   = $stdout
    StdErr   = $stderr
  }
}

$candidateRefs = @($RefA, $RefB)
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
  $resolvedFromRefs = Resolve-ViRelativePath -ViName $ViName -Refs $candidateRefs
  $Path = $resolvedFromRefs
}

$Path = ($Path -replace '\\','/').Trim('/')
if ([string]::IsNullOrWhiteSpace($Path)) { throw "Unable to resolve VI path for comparison." }
if (-not $ViName) { $ViName = (Split-Path $Path -Leaf) }

if (-not $OutName) {
  $nameToken = if ($ViName) { $ViName } else { $Path }
  $OutName = $nameToken -replace '[^A-Za-z0-9._-]+','_'
  if ([string]::IsNullOrWhiteSpace($OutName)) { $OutName = 'vi-compare' }
}

$reportFormatEffective = if ($ReportFormat) { $ReportFormat.ToLowerInvariant() } else { 'html' }
if ($RenderReport.IsPresent -and $reportFormatEffective -ne 'html') {
  $reportFormatEffective = 'html'
}
$renderReportRequested = ($reportFormatEffective -eq 'html')
$detailRequested = $Detailed.IsPresent -or $renderReportRequested -or ($reportFormatEffective -ne 'html')
$timeoutSecondsEffective = $null
if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -gt 0) {
  $timeoutSecondsEffective = [int]$TimeoutSeconds
} else {
  $timeoutSecondsEffective = Get-PositiveIntFromEnv -Names @(
    'PR_VI_HISTORY_COMPARE_TIMEOUT_SECONDS',
    'VI_HISTORY_COMPARE_TIMEOUT_SECONDS',
    'COMPAREVI_TIMEOUT_SECONDS'
  )
}
if (($timeoutSecondsEffective -eq $null -or $timeoutSecondsEffective -le 0) -and $detailRequested) {
  # Report generation can exceed the default 300s under real fixture load.
  $timeoutSecondsEffective = 900
}
Write-Host ("[Debug] detailRequested={0} renderReportRequested={1} reportFormat={2} timeoutSeconds={3}" -f $detailRequested, $renderReportRequested, $reportFormatEffective, ($timeoutSecondsEffective ?? 'default'))
$scriptsRoot = Resolve-CompareVIScriptsRoot -PrimaryRoot $repoRoot
$flagTokens = Split-ArgString -Value $LvCompareArgs
$customInvokeProvided = -not [string]::IsNullOrWhiteSpace($InvokeScriptPath)
$lvComparePathResolved = Normalize-ExistingPath $LvComparePath
$labviewExeResolved    = Normalize-ExistingPath $LabVIEWExePath
$invokeScriptResolved  = $null
if ($detailRequested -or $InvokeScriptPath) {
  if (-not $InvokeScriptPath) {
    $invokeCandidates = @(
      Join-Path (Join-Path $repoRoot 'tools') 'Invoke-LVCompare.ps1'
    )
    if ($scriptsRoot -and $scriptsRoot -ne $repoRoot) {
      $invokeCandidates += Join-Path (Join-Path $scriptsRoot 'tools') 'Invoke-LVCompare.ps1'
    }
    foreach ($candidate in $invokeCandidates) {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $InvokeScriptPath = $candidate
        break
      }
    }
  }
  $invokeScriptResolved = Normalize-ExistingPath $InvokeScriptPath
  if (-not (Test-Path -LiteralPath $invokeScriptResolved -PathType Leaf)) {
    throw "Invoke-LVCompare script not found: $invokeScriptResolved"
  }
}
$tmpRoot = Resolve-TempRoot
$tmp = Join-Path $tmpRoot ("refcmp-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$base = Join-Path $tmp 'Base.vi'
$head = Join-Path $tmp 'Head.vi'

Get-FileAtRef -ref $RefA -relPath $Path -dest $base
Get-FileAtRef -ref $RefB -relPath $Path -dest $head

$rd = if ([System.IO.Path]::IsPathRooted($ResultsDir)) { $ResultsDir } else { Join-Path $repoRoot $ResultsDir }
$rd = Convert-ToNativeFileSystemPath -PathValue $rd
New-Item -ItemType Directory -Path $rd -Force | Out-Null
$execPath = Join-Path $rd ("$OutName-exec.json")
$sumPath  = Join-Path $rd ("$OutName-summary.json")
$artifactDir = $null
if ($detailRequested) {
  $artifactDir = Join-Path $rd ("$OutName-artifacts")
  New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
}
$reportFile = $null
switch ($reportFormatEffective) {
  'xml'  { if ($artifactDir) { $reportFile = Join-Path $artifactDir 'compare-report.xml' } }
  'text' { if ($artifactDir) { $reportFile = Join-Path $artifactDir 'compare-report.txt' } }
  default { if ($artifactDir) { $reportFile = Join-Path $artifactDir 'compare-report.html' } }
}

$invokeFlagTokens = if ($flagTokens) { @($flagTokens) } else { @() }

$bytesBase = (Get-Item -LiteralPath $base).Length
$bytesHead = (Get-Item -LiteralPath $head).Length
$shaBase = (Get-FileHash -Algorithm SHA256 -LiteralPath $base).Hash.ToUpperInvariant()
$shaHead = (Get-FileHash -Algorithm SHA256 -LiteralPath $head).Hash.ToUpperInvariant()
$expectDiff = ($bytesBase -ne $bytesHead) -or ($shaBase -ne $shaHead)

$compareModuleRoot = Resolve-CompareVIScriptsRoot -PrimaryRoot $repoRoot
$compareModulePath = Join-Path (Join-Path $compareModuleRoot 'scripts') 'CompareVI.psm1'
if (-not (Test-Path -LiteralPath $compareModulePath -PathType Leaf)) {
  throw "CompareVI module not found. Checked: $compareModulePath"
}
Import-Module $compareModulePath -Force

$cliExit = $null
$cliDiff = $false
$cliCommand = $null
$cliPath = $null
$cliDurationSeconds = $null
$cliDurationNanoseconds = $null
$cliArtifactImageCount = 0
$cliArtifactReportSizeBytes = 0
$cliArgsRecorded = @()
$cliArtifacts = $null
$cliHighlights = @()
$cliStdoutPreview = @()
$detailPaths = [ordered]@{}
$includedAttributes = @()
$reportMetadata = $null

if ($detailRequested) {
  $invokeArgs = @('-NoLogo','-NoProfile','-File', $invokeScriptResolved, '-BaseVi', $base, '-HeadVi', $head, '-OutputDir', $artifactDir, '-NoiseProfile', 'full', '-Quiet')
  if ($renderReportRequested) { $invokeArgs += '-RenderReport' }
  if ($timeoutSecondsEffective -and $timeoutSecondsEffective -gt 0) {
    $invokeArgs += '-TimeoutSeconds'
    $invokeArgs += [string]$timeoutSecondsEffective
  }
  if ($lvComparePathResolved) { $invokeArgs += '-LVComparePath'; $invokeArgs += $lvComparePathResolved }
  if ($labviewExeResolved) { $invokeArgs += '-LabVIEWExePath'; $invokeArgs += $labviewExeResolved }
  if ($customInvokeProvided -and $invokeFlagTokens -and $invokeFlagTokens.Length -gt 0) {
    $invokeArgs += '-Flags'
    foreach ($token in $invokeFlagTokens) { $invokeArgs += $token }
  }
  if ($ReplaceFlags) { $invokeArgs += '-ReplaceFlags' }
  if ($LeakCheck.IsPresent) {
    $invokeArgs += '-LeakCheck'
    $invokeArgs += '-LeakGraceSeconds'; $invokeArgs += $LeakGraceSeconds
    if (-not [string]::IsNullOrWhiteSpace($LeakJsonPath)) {
      $invokeArgs += '-LeakJsonPath'; $invokeArgs += $LeakJsonPath
    }
  }

  $previousReportFormat = [System.Environment]::GetEnvironmentVariable('COMPAREVI_REPORT_FORMAT','Process')
  $previousFlags = [System.Environment]::GetEnvironmentVariable('COMPAREVI_LVCOMPARE_FLAGS','Process')
  try {
    if ($reportFormatEffective) {
      [System.Environment]::SetEnvironmentVariable('COMPAREVI_REPORT_FORMAT', $reportFormatEffective, 'Process')
    } else {
      [System.Environment]::SetEnvironmentVariable('COMPAREVI_REPORT_FORMAT', $null, 'Process')
    }
    if ($invokeFlagTokens -and $invokeFlagTokens.Length -gt 0) {
      [System.Environment]::SetEnvironmentVariable('COMPAREVI_LVCOMPARE_FLAGS', ($invokeFlagTokens -join "`n"), 'Process')
    } else {
      [System.Environment]::SetEnvironmentVariable('COMPAREVI_LVCOMPARE_FLAGS', $null, 'Process')
    }
    $invokeResult = Invoke-PwshProcess -Arguments $invokeArgs -QuietOutput:$Quiet
  }
  finally {
    [System.Environment]::SetEnvironmentVariable('COMPAREVI_REPORT_FORMAT', $previousReportFormat, 'Process')
    [System.Environment]::SetEnvironmentVariable('COMPAREVI_LVCOMPARE_FLAGS', $previousFlags, 'Process')
  }
  $capturePath = Join-Path $artifactDir 'lvcompare-capture.json'
  $stdoutPath  = Join-Path $artifactDir 'lvcompare-stdout.txt'
  $stderrPath  = Join-Path $artifactDir 'lvcompare-stderr.txt'
  $reportPath  = $reportFile
  $imagesDir   = Join-Path $artifactDir 'cli-images'

  $capture = $null
  if (Test-Path -LiteralPath $capturePath) {
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 8
  }
  if (-not $capture) {
    throw "lvcompare-capture.json not produced (exit code $($invokeResult.ExitCode)). Inspect $artifactDir for details."
  }

  $cliExit = if ($capture.exitCode -ne $null) { [int]$capture.exitCode } else { [int]$invokeResult.ExitCode }
  $cliDiff = ($cliExit -eq 1)
  if (-not $cliDiff -and $capture.PSObject.Properties['diff']) {
    try { $cliDiff = [bool]$capture.diff } catch {}
  }
  $cliCommand = if ($capture.command) { [string]$capture.command } else { $null }
  $cliPath = if ($capture.cliPath) { [string]$capture.cliPath } else { $lvComparePathResolved }
  if ($capture.seconds -ne $null) {
    $cliDurationSeconds = [double]$capture.seconds
    $cliDurationNanoseconds = [long]([Math]::Round($cliDurationSeconds * 1e9))
  }
  if ($capture.args) { $cliArgsRecorded = @($capture.args | ForEach-Object { [string]$_ }) }

  if ($cliExit -notin @(0,1)) {
    throw "LVCompare failed with exit code $cliExit. See $capturePath for details."
  }

  if ($capture.PSObject.Properties['environment'] -and $capture.environment -and $capture.environment.PSObject.Properties['cli']) {
    $cliNode = $capture.environment.cli
    if ($cliNode.PSObject.Properties['artifacts'] -and $cliNode.artifacts) {
      $artifactSummary = [ordered]@{}
      foreach ($prop in $cliNode.artifacts.PSObject.Properties) {
        if ($prop.Name -eq 'imageCount' -and $prop.Value -ne $null) {
          try { $cliArtifactImageCount = [Math]::Max([int]$prop.Value, 0) } catch {}
        } elseif ($prop.Name -eq 'reportSizeBytes' -and $prop.Value -ne $null) {
          try { $cliArtifactReportSizeBytes = [Math]::Max([int64]$prop.Value, 0) } catch {}
        }
        if ($prop.Name -eq 'images' -and $prop.Value) {
          $images = @()
          foreach ($img in @($prop.Value)) {
            if (-not $img) { continue }
            $imgIndex = $null
            $imgMimeType = $null
            $imgByteLength = $null
            $imgSavedPath = $null
            if ($img -is [string]) {
              $imgSavedPath = [string]$img
            } elseif ($img.PSObject) {
              if ($img.PSObject.Properties['index']) { $imgIndex = $img.index }
              if ($img.PSObject.Properties['mimeType']) { $imgMimeType = $img.mimeType }
              elseif ($img.PSObject.Properties['mime']) { $imgMimeType = $img.mime }
              if ($img.PSObject.Properties['byteLength']) { $imgByteLength = $img.byteLength }
              elseif ($img.PSObject.Properties['bytes']) { $imgByteLength = $img.bytes }
              if ($img.PSObject.Properties['savedPath']) { $imgSavedPath = $img.savedPath }
              elseif ($img.PSObject.Properties['path']) { $imgSavedPath = $img.path }
            }
            $images += [ordered]@{
              index      = $imgIndex
              mimeType   = $imgMimeType
              byteLength = $imgByteLength
              savedPath  = $imgSavedPath
            }
          }
          if ($images.Count -gt $cliArtifactImageCount) {
            $cliArtifactImageCount = $images.Count
          }
          if ($images.Count -gt 0) { $artifactSummary.images = $images }
        } else {
          $artifactSummary[$prop.Name] = $prop.Value
        }
      }
      if ($artifactSummary.Count -gt 0) { $cliArtifacts = [pscustomobject]$artifactSummary }
    }
  }

  if (-not $cliDiff -and $expectDiff) {
    if ($cliArtifactImageCount -gt 0) {
      $cliDiff = $true
      Write-Verbose ("Treating compare as diff based on artifact image evidence (imageCount={0})." -f $cliArtifactImageCount)
    } elseif ($cliArtifactReportSizeBytes -gt 0) {
      $cliDiff = $true
      Write-Verbose ("Treating compare as diff based on non-empty report artifact (reportSizeBytes={0})." -f $cliArtifactReportSizeBytes)
    }
  }

  if (Test-Path -LiteralPath $stdoutPath) {
    $stdoutLines = Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue
    if ($stdoutLines) {
      $cliStdoutPreview = @($stdoutLines | Select-Object -First 10)
      foreach ($line in $stdoutLines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '(?i)(block\s+diagram|front\s+panel|vi\s+attribute|connector\s+pane|terminal)') {
          $cliHighlights += $trimmed
        }
      }
      $cliHighlights = @($cliHighlights | Select-Object -Unique | Select-Object -First 20)
    }
  }

  $leakResolvedPath = $null
  if ($LeakCheck.IsPresent) {
    $candidateLeakPaths = @()
    if (-not [string]::IsNullOrWhiteSpace($LeakJsonPath)) {
      $candidateLeakPaths += $LeakJsonPath
    }
    $candidateLeakPaths += (Join-Path $artifactDir 'lvcompare-leak.json')
    foreach ($candidatePath in $candidateLeakPaths) {
      if (-not $candidatePath) { continue }
      if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        try {
          $leakResolvedPath = Resolve-NativeExistingPath -Candidate $candidatePath
        } catch {
          $leakResolvedPath = $candidatePath
        }
        break
      }
    }
    if ($leakResolvedPath) {
      $detailPaths.leakJson = $leakResolvedPath
      try {
        $leakInfo = Get-Content -LiteralPath $leakResolvedPath -Raw | ConvertFrom-Json -Depth 6
      } catch {
        $leakInfo = $null
      }
      if ($leakInfo) {
        if ($cliArtifacts) {
          $cliArtifacts | Add-Member -NotePropertyName 'leakDetected' -NotePropertyValue ([bool]$leakInfo.leakDetected) -Force
        } else {
          $cliArtifacts = [pscustomobject]@{
            leakDetected = [bool]$leakInfo.leakDetected
          }
        }
        if ($cliArtifacts) {
          if ($leakInfo.PSObject.Properties['graceSeconds']) {
            $cliArtifacts | Add-Member -NotePropertyName 'graceSeconds' -NotePropertyValue ([double]$leakInfo.graceSeconds) -Force
          }
          if ($leakInfo.PSObject.Properties['processes']) {
            $cliArtifacts | Add-Member -NotePropertyName 'processes' -NotePropertyValue $leakInfo.processes -Force
          }
          if ($leakInfo.PSObject.Properties['schema']) {
            $cliArtifacts | Add-Member -NotePropertyName 'leakSchema' -NotePropertyValue $leakInfo.schema -Force
          }
        }
      }
    }
  }

  if (Test-Path -LiteralPath $capturePath) { $detailPaths.captureJson = Resolve-NativeExistingPath -Candidate $capturePath }
  if (Test-Path -LiteralPath $stdoutPath)  { $detailPaths.stdout       = Resolve-NativeExistingPath -Candidate $stdoutPath }
  if (Test-Path -LiteralPath $stderrPath)  { $detailPaths.stderr       = Resolve-NativeExistingPath -Candidate $stderrPath }
  $reportResolved = $null
  if ($reportFile -and (Test-Path -LiteralPath $reportFile)) {
    $reportResolved = Resolve-NativeExistingPath -Candidate $reportFile
    $detailPaths.reportPath = $reportResolved
    if ($reportFormatEffective -eq 'html') {
      $detailPaths.reportHtml = $reportResolved
    }
  }
  if (Test-Path -LiteralPath $imagesDir)   { $detailPaths.imagesDir    = Resolve-NativeExistingPath -Candidate $imagesDir }
  if ($reportFormatEffective -eq 'html' -and $reportResolved) {
    $includedAttributes = Get-IncludedAttributesFromReport -ReportPath $reportResolved
    $reportMetadata = Get-ReportCategoryMetadata -ReportPath $reportResolved
    if ($reportMetadata) {
      if ($reportMetadata.headings -and $reportMetadata.headings.Count -gt 0) {
        $cliHighlights += @($reportMetadata.headings)
      } elseif ($reportMetadata.details -and $reportMetadata.details.Count -gt 0) {
        $cliHighlights += @($reportMetadata.details | Select-Object -First 10)
      }
      $cliHighlights = @($cliHighlights | Select-Object -Unique | Select-Object -First 20)
    }
  }

  $execObject = [ordered]@{
    schema      = 'compare-exec/v1'
    generatedAt = (Get-Date).ToString('o')
    cliPath     = $cliPath
    command     = $cliCommand
    args        = $cliArgsRecorded
    exitCode    = $cliExit
    diff        = $cliDiff
    cwd         = $repoRoot
    duration_s  = $cliDurationSeconds
    duration_ns = $cliDurationNanoseconds
    timeoutSeconds = $timeoutSecondsEffective
    base        = $capture.base
    head        = $capture.head
  }
  $execObject | ConvertTo-Json -Depth 6 | Out-File -FilePath $execPath -Encoding utf8
}
else {
  $argsString = if ($invokeFlagTokens -and $invokeFlagTokens.Length -gt 0) { ($invokeFlagTokens -join ' ') } else { '' }
  $result = Invoke-CompareVI -Base $base -Head $head -LvComparePath $lvComparePathResolved -LvCompareArgs $argsString -CompareExecJsonPath $execPath -FailOnDiff:$false
  $cliExit = [int]$result.ExitCode
  $cliDiff = [bool]$result.Diff
  $cliCommand = $result.Command
  $cliPath = $result.CliPath
  $cliDurationSeconds = $result.CompareDurationSeconds
  $cliDurationNanoseconds = $result.CompareDurationNanoseconds
  if ($invokeFlagTokens -and $invokeFlagTokens.Length -gt 0) { $cliArgsRecorded = $invokeFlagTokens }
}

if (-not $cliDiff -and $cliExit -eq $null) { $cliExit = 0 }

$exec = Get-Content -LiteralPath $execPath -Raw | ConvertFrom-Json -Depth 6

$outPaths = [ordered]@{ execJson = (Resolve-NativeExistingPath -Candidate $execPath) }
foreach ($k in @('captureJson','stdout','stderr','reportHtml','reportPath','imagesDir')) {
  if ($detailPaths.Contains($k) -and $detailPaths[$k]) { $outPaths[$k] = $detailPaths[$k] }
}
if ($detailPaths.Contains('leakJson') -and $detailPaths['leakJson']) {
  $outPaths.leakJson = $detailPaths['leakJson']
}
if ($artifactDir) { $outPaths.artifactDir = Resolve-NativeExistingPath -Candidate $artifactDir }

$cliSummary = [ordered]@{
  exitCode    = $cliExit
  diff        = [bool]$cliDiff
  duration_s  = $cliDurationSeconds
  command     = $cliCommand
  cliPath     = $cliPath
  reportFormat = $reportFormatEffective
}
if ($cliDurationNanoseconds -ne $null) { $cliSummary.duration_ns = $cliDurationNanoseconds }
if ($cliArgsRecorded -and $cliArgsRecorded.Length -gt 0) { $cliSummary.args = $cliArgsRecorded }
if ($cliHighlights -and $cliHighlights.Length -gt 0) { $cliSummary.highlights = $cliHighlights }
if ($cliStdoutPreview -and $cliStdoutPreview.Length -gt 0) { $cliSummary.stdoutPreview = $cliStdoutPreview }
if ($cliArtifacts) { $cliSummary.artifacts = $cliArtifacts }
if ($includedAttributes -and $includedAttributes.Count -gt 0) { $cliSummary.includedAttributes = $includedAttributes }
if ($reportMetadata) {
  if ($reportMetadata.categories -and $reportMetadata.categories.Count -gt 0) {
    $cliSummary.categories = @($reportMetadata.categories)
  }
  if ($reportMetadata.categoryDetails -and $reportMetadata.categoryDetails.Count -gt 0) {
    $cliSummary.categoryDetails = @($reportMetadata.categoryDetails)
  }
  if ($reportMetadata.categoryBuckets -and $reportMetadata.categoryBuckets.Count -gt 0) {
    $cliSummary.categoryBuckets = @($reportMetadata.categoryBuckets)
  }
  if ($reportMetadata.categoryBucketDetails -and $reportMetadata.categoryBucketDetails.Count -gt 0) {
    $cliSummary.categoryBucketDetails = @($reportMetadata.categoryBucketDetails)
  }
}

$sum = [ordered]@{
  schema = 'ref-compare-summary/v1'
  generatedAt = (Get-Date).ToString('o')
  name = $ViName
  path = $Path
  refA = $RefA
  refB = $RefB
  temp = $tmp
  reportFormat = $reportFormatEffective
  out = [pscustomobject]$outPaths
  computed = [ordered]@{
    baseBytes = $bytesBase
    headBytes = $bytesHead
    baseSha   = $shaBase
    headSha   = $shaHead
    expectDiff= $expectDiff
  }
  cli = [pscustomobject]$cliSummary
}
$sum | ConvertTo-Json -Depth 8 | Out-File -FilePath $sumPath -Encoding utf8

if (-not $Quiet) {
  $displayId = if ($ViName) { "$ViName ($Path)" } else { $Path }
  Write-Host "Ref compare complete: $displayId ($RefA vs $RefB)"
  Write-Host "- Exec: $execPath"
  Write-Host "- Summary: $sumPath"
  if ($artifactDir) { Write-Host "- Artifacts: $artifactDir" }
  Write-Host ("- ExpectDiff={0} | cli.diff={1} | exitCode={2}" -f $expectDiff,([bool]$cliDiff),$cliExit)
  if ($includedAttributes -and $includedAttributes.Count -gt 0) {
    Write-Host "- Included attributes:"
    foreach ($attr in $includedAttributes) {
      $mark = if ($attr.included) { '[x]' } else { '[ ]' }
      Write-Host ("  {0} {1}" -f $mark, $attr.name)
    }
  }
}

if ($FailOnDiff -and $cliDiff) {
  throw "LVCompare reported differences between refs: $RefA vs $RefB"
}

exit 0
