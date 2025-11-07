param(
    [string]$RequestsPath,
    [string]$CapturesRoot,
    [string]$SummaryPath,
    [switch]$DryRun,
    [int]$TimeoutSeconds
)
if (-not $Global:InvokeValidateLocalStubLog) { $Global:InvokeValidateLocalStubLog = @() }
$Global:InvokeValidateLocalStubLog += [pscustomobject]@{
    Command = 'InvokeDiffs'
    Parameters = [pscustomobject]@{
        RequestsPath = $RequestsPath
        CapturesRoot = $CapturesRoot
        SummaryPath  = $SummaryPath
        DryRun       = $DryRun.IsPresent
    }
}
if (-not (Test-Path -LiteralPath $CapturesRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $CapturesRoot -Force | Out-Null
}
$summaryDir = Split-Path -Parent $SummaryPath
if ($summaryDir -and -not (Test-Path -LiteralPath $summaryDir -PathType Container)) {
    New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
}
'{"counts":{"total":1}}' | Set-Content -LiteralPath $SummaryPath -Encoding utf8
