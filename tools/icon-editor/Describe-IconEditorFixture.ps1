param(
    [string]$FixturePath,
    [string]$ResultsRoot,
    [string]$OutputPath,
    [switch]$KeepWork,
    [switch]$SkipResourceOverlay,
    [string]$ResourceOverlayRoot
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'Describe'
    Parameters = [pscustomobject]@{
        FixturePath        = $FixturePath
        ResultsRoot        = $ResultsRoot
        SkipResourceOverlay= $SkipResourceOverlay.IsPresent
        ResourceOverlayRoot= $ResourceOverlayRoot
    }
}
if ($OutputPath) {
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
$summary = [pscustomobject]@{
    schema            = 'icon-editor/fixture-report@v1'
    fixtureOnlyAssets = @()
    artifacts         = @()
    manifest          = [pscustomobject]@{
        packageSmoke = [pscustomobject]@{ status = 'ok'; vipCount = 0 }
        simulation   = [pscustomobject]@{ enabled = $true }
    }
    source            = [pscustomobject]@{ fixturePath = $FixturePath }
}
if ($OutputPath) {
    $json = $summary | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8
}
$summary
