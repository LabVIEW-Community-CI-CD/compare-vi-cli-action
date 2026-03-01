#Requires -Version 7.0
<#
.SYNOPSIS
  Extracts images from a VI history HTML report into deterministic files.

.DESCRIPTION
  Parses `<img>` tags from a `history-report.html` payload and exports each
  image to a deterministic file name (`history-image-###.<ext>`). Embedded
  base64 data URIs are decoded, local file references are copied, and an
  index JSON contract is emitted for downstream PR-comment/report tooling.

.PARAMETER ReportPath
  Path to the source history-report HTML file.

.PARAMETER OutputDir
  Directory where extracted images should be written. Defaults to
  `<ReportPath directory>/previews`.

.PARAMETER IndexPath
  Path to the JSON index output. Defaults to
  `<OutputDir>/vi-history-image-index.json`.

.PARAMETER GitHubOutputPath
  Optional path to write GitHub Actions step outputs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ReportPath,

    [string]$OutputDir,

    [string]$IndexPath,

    [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw ("{0} path not provided." -f $Description)
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("{0} not found: {1}" -f $Description, $Path)
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-OutputPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$BaseDir
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return Resolve-FullPath -Path $Path
    }

    return Resolve-FullPath -Path (Join-Path $BaseDir $Path)
}

function Write-GitHubOutput {
    param(
        [Parameter(Mandatory)]
        [string]$Key,
        [AllowNull()]
        [string]$Value,
        [string]$DestPath
    )

    $target = $DestPath
    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = $env:GITHUB_OUTPUT
    }
    if ([string]::IsNullOrWhiteSpace($target)) {
        return
    }

    Add-Content -LiteralPath $target -Value ("{0}={1}" -f $Key, $Value)
}

function Get-ImageExtensionFromMimeType {
    param([string]$MimeType)
    if ([string]::IsNullOrWhiteSpace($MimeType)) { return 'bin' }
    switch -Regex ($MimeType.ToLowerInvariant()) {
        '^image/png$' { return 'png' }
        '^image/jpeg$' { return 'jpg' }
        '^image/gif$' { return 'gif' }
        '^image/bmp$' { return 'bmp' }
        '^image/webp$' { return 'webp' }
        '^image/svg\+xml$' { return 'svg' }
        default { return 'bin' }
    }
}

function Get-ImageExtensionFromPath {
    param([string]$PathOrUri)
    if ([string]::IsNullOrWhiteSpace($PathOrUri)) { return $null }
    try {
        $ext = [System.IO.Path]::GetExtension($PathOrUri)
        if ([string]::IsNullOrWhiteSpace($ext)) { return $null }
        return $ext.TrimStart('.').ToLowerInvariant()
    } catch {
        return $null
    }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hash = [System.Security.Cryptography.SHA256]::Create()
        try {
            return [System.BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $hash.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Resolve-LocalImageSource {
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$ReportDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return [pscustomobject]@{ type = 'invalid'; path = $null; message = 'Image source is empty.' }
    }

    $uri = $null
    if ([System.Uri]::TryCreate($Source, [System.UriKind]::Absolute, [ref]$uri)) {
        if ($uri.IsFile) {
            return [pscustomobject]@{ type = 'file'; path = $uri.LocalPath; message = $null }
        }
        return [pscustomobject]@{ type = 'external'; path = $null; message = ('External URI scheme is not copied: {0}' -f $uri.Scheme) }
    }

    if ([System.IO.Path]::IsPathRooted($Source)) {
        return [pscustomobject]@{ type = 'file'; path = $Source; message = $null }
    }

    $candidate = Join-Path $ReportDirectory $Source
    return [pscustomobject]@{ type = 'file'; path = $candidate; message = $null }
}

$resolvedReportPath = Resolve-ExistingFile -Path $ReportPath -Description 'History report HTML'
$reportDirectory = Split-Path -Parent $resolvedReportPath

$effectiveOutputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    Join-Path $reportDirectory 'previews'
} else {
    Resolve-OutputPath -Path $OutputDir -BaseDir $reportDirectory
}

New-Item -ItemType Directory -Path $effectiveOutputDir -Force | Out-Null
$resolvedOutputDir = (Resolve-Path -LiteralPath $effectiveOutputDir).Path

$effectiveIndexPath = if ([string]::IsNullOrWhiteSpace($IndexPath)) {
    Join-Path $resolvedOutputDir 'vi-history-image-index.json'
} else {
    Resolve-OutputPath -Path $IndexPath -BaseDir $resolvedOutputDir
}

$html = Get-Content -LiteralPath $resolvedReportPath -Raw -ErrorAction Stop

$imageTagPattern = '<img\b[^>]*?\bsrc\s*=\s*(["''])(?<src>.*?)\1[^>]*>'
$attributePattern = '\b{0}\s*=\s*(["''])(?<value>.*?)\1'
$regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
$imageMatches = [System.Text.RegularExpressions.Regex]::Matches($html, $imageTagPattern, $regexOptions)

$images = New-Object System.Collections.Generic.List[object]
$exportedCount = 0

for ($idx = 0; $idx -lt $imageMatches.Count; $idx++) {
    $imageMatch = $imageMatches[$idx]
    $tag = $imageMatch.Value
    $src = [System.Net.WebUtility]::HtmlDecode($imageMatch.Groups['src'].Value.Trim())

    $alt = $null
    $altMatch = [System.Text.RegularExpressions.Regex]::Match($tag, ($attributePattern -f 'alt'), $regexOptions)
    if ($altMatch.Success) {
        $alt = [System.Net.WebUtility]::HtmlDecode($altMatch.Groups['value'].Value)
    }

    $entry = [ordered]@{
        index      = $idx
        source     = $src
        sourceType = $null
        alt        = $alt
        status     = 'pending'
    }

    $dataUriMatch = [System.Text.RegularExpressions.Regex]::Match(
        $src,
        '^data:(?<mime>[^;,]+)(?:;[^,]*)?;base64,(?<data>.+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($dataUriMatch.Success) {
        $entry.sourceType = 'embedded'
        $mimeType = $dataUriMatch.Groups['mime'].Value.Trim().ToLowerInvariant()
        $entry.mimeType = $mimeType

        try {
            $rawData = $dataUriMatch.Groups['data'].Value -replace '\s', ''
            $bytes = [System.Convert]::FromBase64String($rawData)
            $extension = Get-ImageExtensionFromMimeType -MimeType $mimeType
            $fileName = 'history-image-{0:D3}.{1}' -f $idx, $extension
            $destinationPath = Join-Path $resolvedOutputDir $fileName
            [System.IO.File]::WriteAllBytes($destinationPath, $bytes)

            $resolvedSavedPath = (Resolve-Path -LiteralPath $destinationPath).Path
            $entry.fileName = $fileName
            $entry.savedPath = $resolvedSavedPath
            $entry.byteLength = $bytes.Length
            $entry.sha256 = Get-FileSha256Hex -Path $resolvedSavedPath
            $entry.status = 'saved'
            $exportedCount++
        } catch {
            $entry.status = 'decode-error'
            $entry.error = $_.Exception.Message
        }
    } else {
        $sourceResolution = Resolve-LocalImageSource -Source $src -ReportDirectory $reportDirectory
        $entry.sourceType = $sourceResolution.type

        if ($sourceResolution.type -eq 'external') {
            $entry.status = 'external-source'
            $entry.error = $sourceResolution.message
        } elseif ($sourceResolution.type -eq 'invalid') {
            $entry.status = 'invalid-source'
            $entry.error = $sourceResolution.message
        } else {
            $candidatePath = $sourceResolution.path
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                $entry.status = 'missing-source'
                $entry.error = ('Image source not found: {0}' -f $candidatePath)
            } else {
                $resolvedCandidate = (Resolve-Path -LiteralPath $candidatePath).Path
                $extension = Get-ImageExtensionFromPath -PathOrUri $resolvedCandidate
                if ([string]::IsNullOrWhiteSpace($extension)) {
                    $extension = 'bin'
                }
                $fileName = 'history-image-{0:D3}.{1}' -f $idx, $extension
                $destinationPath = Join-Path $resolvedOutputDir $fileName
                Copy-Item -LiteralPath $resolvedCandidate -Destination $destinationPath -Force

                $resolvedSavedPath = (Resolve-Path -LiteralPath $destinationPath).Path
                $item = Get-Item -LiteralPath $resolvedSavedPath
                $entry.fileName = $fileName
                $entry.savedPath = $resolvedSavedPath
                $entry.resolvedSource = $resolvedCandidate
                $entry.byteLength = [int64]$item.Length
                $entry.sha256 = Get-FileSha256Hex -Path $resolvedSavedPath
                $entry.status = 'saved'
                $exportedCount++
            }
        }
    }

    $images.Add([pscustomobject]$entry) | Out-Null
}

$index = [pscustomobject]@{
    schema             = 'pr-vi-history-image-index@v1'
    generatedAt        = (Get-Date).ToString('o')
    reportPath         = $resolvedReportPath
    outputDir          = $resolvedOutputDir
    sourceImageCount   = $imageMatches.Count
    exportedImageCount = $exportedCount
    images             = $images
}

New-Item -ItemType Directory -Path (Split-Path -Parent $effectiveIndexPath) -Force | Out-Null
$index | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $effectiveIndexPath -Encoding utf8

Write-GitHubOutput -Key 'history-image-index-path' -Value $effectiveIndexPath -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'history-image-output-dir' -Value $resolvedOutputDir -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'history-image-count' -Value ([string]$exportedCount) -DestPath $GitHubOutputPath

return $index
