param(
    [string]$SummaryPath,
    [string]$OutputPath
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'RenderReport'
    Parameters = [pscustomobject]@{
        SummaryPath = $SummaryPath
        OutputPath  = $OutputPath
    }
}
if ($OutputPath) {
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    'report' | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
