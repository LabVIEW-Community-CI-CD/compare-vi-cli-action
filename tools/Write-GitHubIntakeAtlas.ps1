#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$ResultsRoot = 'tests/results/_agent/intake',
  [string]$JsonPath,
  [string]$MarkdownPath,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GitHubIntake.psm1') -Force

if ([string]::IsNullOrWhiteSpace($JsonPath)) {
  $JsonPath = Join-Path $ResultsRoot 'github-intake-atlas.json'
}

if ([string]::IsNullOrWhiteSpace($MarkdownPath)) {
  $MarkdownPath = Join-Path $ResultsRoot 'github-intake-atlas.md'
}

$jsonParent = Split-Path -Parent $JsonPath
if ($jsonParent -and -not (Test-Path -LiteralPath $jsonParent -PathType Container)) {
  New-Item -ItemType Directory -Path $jsonParent -Force | Out-Null
}

$markdownParent = Split-Path -Parent $MarkdownPath
if ($markdownParent -and -not (Test-Path -LiteralPath $markdownParent -PathType Container)) {
  New-Item -ItemType Directory -Path $markdownParent -Force | Out-Null
}

$catalog = Get-GitHubIntakeCatalog
$report = New-GitHubIntakeAtlasReport -Catalog $catalog

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonPath -Encoding utf8
$markdown = ConvertTo-GitHubIntakeAtlasMarkdown -Report $report
$markdown | Set-Content -LiteralPath $MarkdownPath -Encoding utf8

if ($PassThru.IsPresent) {
  $report
}
