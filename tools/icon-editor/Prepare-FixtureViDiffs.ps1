param(
    [string]$ReportPath,
    [string]$BaselineManifestPath,
    [string]$BaselineFixturePath,
    [string]$OutputDir,
    [string]$ResourceOverlayRoot
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'Prepare'
    Parameters = [pscustomobject]@{
        OutputDir = $OutputDir
    }
}
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
'{"schema":"icon-editor/vi-diff-requests@v1","count":1,"requests":[{"category":"test","relPath":"tests\\StubTest.vi","base":null,"head":"head.vi"}]}' | Set-Content -LiteralPath (Join-Path $OutputDir 'vi-diff-requests.json') -Encoding utf8
