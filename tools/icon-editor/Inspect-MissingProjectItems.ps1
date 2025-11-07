#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$OutputPath,
    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
}

if (-not $ProjectPath) {
    $ProjectPath = Join-Path $RepoRoot 'vendor\icon-editor\lv_icon_editor.lvproj'
}

$resolvedProject = Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop
$projectDir = Split-Path -Parent $resolvedProject.ProviderPath

if (-not $OutputPath) {
    $outputDirectory = Join-Path $RepoRoot 'tests\results\_agent\icon-editor'
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $OutputPath = Join-Path $outputDirectory 'missing-items.json'
}

[xml]$projectXml = Get-Content -LiteralPath $resolvedProject.ProviderPath -Raw
$nodes = $projectXml.SelectNodes('//Item[@URL]')

$missingItems = New-Object System.Collections.Generic.List[object]

function Resolve-ProjectUrl {
    param(
        [string]$Url,
        [string]$ProjectDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    if ($Url -match '^\s*/<resource>') { return $null }
    if ($Url -match '^labview\.exe') { return $null }

    $normalized = $Url -replace '/', [System.IO.Path]::DirectorySeparatorChar
    if ([System.IO.Path]::IsPathRooted($normalized)) {
        return $normalized
    }

    return [System.IO.Path]::GetFullPath((Join-Path $ProjectDirectory $normalized))
}

foreach ($node in $nodes) {
    $urlAttribute = $node.Attributes['URL']
    if (-not $urlAttribute) { continue }
    $urlValue = $urlAttribute.Value
    $candidate = Resolve-ProjectUrl -Url $urlValue -ProjectDirectory $projectDir
    if (-not $candidate) { continue }

    if (-not (Test-Path -LiteralPath $candidate)) {
        $missingItems.Add([ordered]@{
            name         = $node.Attributes['Name']?.Value
            url          = $urlValue
            resolvedPath = $candidate
        }) | Out-Null
    }
}

$result = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    projectPath = $resolvedProject.ProviderPath
    missing     = $missingItems
}

$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host ("Captured {0} missing project item(s) -> {1}" -f $missingItems.Count, $OutputPath)

return $result
