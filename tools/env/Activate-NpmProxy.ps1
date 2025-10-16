param()
$wrapperDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'npm' 'bin'
$pathSeparator = [System.IO.Path]::PathSeparator
$pathParts = $env:PATH -split [System.Text.RegularExpressions.Regex]::Escape($pathSeparator)
if (-not ($pathParts -contains $wrapperDir)) {
    $env:PATH = "$wrapperDir$pathSeparator$env:PATH"
}
