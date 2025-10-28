#Requires -Version 7.0
<#
.SYNOPSIS
  Captures LVCompare metadata (status, categories, headings) for a VI pair.

.DESCRIPTION
  Invokes the existing Invoke-LVCompare.ps1 helper (or an injected scriptblock)
  to generate compare artifacts, then parses the HTML report to extract the
  diff categories, headings, and included attribute toggles.  Results are
  written to the requested output path as JSON and returned to the caller.

.PARAMETER BaseVi
  Path to the base VI.

.PARAMETER HeadVi
  Path to the head VI.

.PARAMETER OutputPath
  Destination path for the JSON metadata file.

.PARAMETER Flags
  Additional LVCompare flags.  Defaults to none (caller can supply `-ReplaceFlags`).

.PARAMETER ReplaceFlags
  Replace the default Invoke-LVCompare flags entirely with the provided Flags array.

.PARAMETER InvokeLVCompare
  Optional scriptblock used to invoke LVCompare (primarily for tests).  When omitted,
  the helper shell-outs to tools/Invoke-LVCompare.ps1.

.OUTPUTS
  PSCustomObject representing the compare metadata.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BaseVi,

    [Parameter(Mandatory)]
    [string]$HeadVi,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string[]]$Flags,
    [switch]$ReplaceFlags,

    [scriptblock]$InvokeLVCompare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExistingFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
    } catch { return $null }
    return $null
}

function Parse-InclusionList {
    param([string]$Html)
    $map = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Html)) { return $map }
    $pattern = '<li\s+class="(?<class>checked|unchecked)">(?<label>[^<]+)</li>'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
        $label = $match.Groups['label'].Value.Trim()
        if (-not $label) { continue }
        $decoded = [System.Net.WebUtility]::HtmlDecode($label)
        $map[$decoded] = ($match.Groups['class'].Value.Trim().ToLowerInvariant() -eq 'checked')
    }
    return $map
}

function Parse-DiffHeadings {
    param([string]$Html)
    $headings = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Html)) { return $headings }
    $pattern = '<summary\s+class="difference-heading">\s*(?<text>.*?)\s*</summary>'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
        $raw = $match.Groups['text'].Value
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $decoded = [System.Net.WebUtility]::HtmlDecode($raw.Trim())
        $decoded = ($decoded -replace '^\s*\d+\.\s*', '')
        if (-not $decoded) { continue }
        $headings.Add($decoded)
    }
    return $headings
}

function Parse-DiffDetails {
    param([string]$Html)
    $details = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Html)) { return $details }
    $pattern = '<li\s+class="diff-detail">\s*(?<text>.*?)\s*</li>'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
        $raw = $match.Groups['text'].Value
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $decoded = [System.Net.WebUtility]::HtmlDecode($raw.Trim())
        if ($decoded) { $details.Add($decoded) }
    }
    return $details
}

$resolvedBase = Resolve-ExistingFile -Path $BaseVi
if (-not $resolvedBase) { throw "Base VI not found: $BaseVi" }
$resolvedHead = Resolve-ExistingFile -Path $HeadVi
if (-not $resolvedHead) { throw "Head VI not found: $HeadVi" }

New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
$compareDir = Join-Path ([System.IO.Path]::GetDirectoryName($OutputPath)) ("vi-metadata-{0}" -f [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetRandomFileName()))
New-Item -ItemType Directory -Path $compareDir -Force | Out-Null

if (-not $InvokeLVCompare) {
    $repoRoot = (& git rev-parse --show-toplevel).Trim()
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'Unable to determine git repository root.'
    }
    $invokeScript = Join-Path $repoRoot 'tools' 'Invoke-LVCompare.ps1'
    if (-not (Test-Path -LiteralPath $invokeScript -PathType Leaf)) {
        throw "Invoke-LVCompare.ps1 not found at $invokeScript"
    }
    $InvokeLVCompare = {
        param(
            [string]$BaseVi,
            [string]$HeadVi,
            [string]$OutputDir,
            [string[]]$Flags,
            [switch]$ReplaceFlags
        )
        $args = @('-NoLogo','-NoProfile','-File',$invokeScript,'-BaseVi',$BaseVi,'-HeadVi',$HeadVi,'-OutputDir',$OutputDir,'-RenderReport','-Summary')
        if ($ReplaceFlags.IsPresent) { $args += '-ReplaceFlags' }
        if ($Flags) { $args += @('-Flags') + $Flags }
        & pwsh @args | Out-String | Out-Null
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE }
    }.GetNewClosure()
}

$invokeResult = & $InvokeLVCompare -BaseVi $resolvedBase -HeadVi $resolvedHead -OutputDir $compareDir -Flags $Flags -ReplaceFlags:$ReplaceFlags.IsPresent
$exitCode = 0
if ($invokeResult -is [int]) {
    $exitCode = [int]$invokeResult
} elseif ($invokeResult -and $invokeResult.PSObject.Properties['ExitCode']) {
    try { $exitCode = [int]$invokeResult.ExitCode } catch { $exitCode = $LASTEXITCODE }
} else {
    $exitCode = $LASTEXITCODE
}

$reportPath = Resolve-ExistingFile -Path (Join-Path $compareDir 'compare-report.html')
$capturePath = Resolve-ExistingFile -Path (Join-Path $compareDir 'lvcompare-capture.json')

if (-not $reportPath) {
    throw "Compare report not found in $compareDir"
}

$htmlContent = Get-Content -LiteralPath $reportPath -Raw
$included = Parse-InclusionList -Html $htmlContent
$headings = Parse-DiffHeadings -Html $htmlContent
$details  = Parse-DiffDetails -Html $htmlContent

$categories = New-Object System.Collections.Generic.List[string]
foreach ($heading in $headings) {
    if (-not $heading) { continue }
    $primary = $heading
    $splitIdx = $heading.IndexOf(' - ')
    if ($splitIdx -gt 0) { $primary = $heading.Substring(0, $splitIdx) }
    $primary = $primary.Trim()
    if (-not $primary) { continue }
    if (-not $categories.Contains($primary)) { $categories.Add($primary) }
}

$includedList = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($key in $included.Keys) {
    $includedList.Add([pscustomobject]@{
        name  = $key
        value = [bool]$included[$key]
    })
}

$status = switch ($exitCode) {
    0 { 'match' }
    1 { 'diff' }
    default { 'error' }
}

$result = [pscustomobject]@{
    basePath          = $resolvedBase
    headPath          = $resolvedHead
    outputDir         = $compareDir
    status            = $status
    exitCode          = $exitCode
    reportPath        = $reportPath
    capturePath       = $capturePath
    diffCategories    = $categories
    diffHeadings      = $headings
    diffDetails       = $details
    includedAttributes= $includedList
}

$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
return $result
