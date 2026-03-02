Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-VIHistoryPolicyDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter(Mandatory)]
        [bool]$RequireDiff,

        [int]$MinDiffs = 0,

        [AllowNull()]
        [int]$Comparisons,

        [AllowNull()]
        [int]$Diffs,

        [AllowNull()]
        [string]$Status,

        [switch]$Missing
    )

    $policyClass = if ($RequireDiff) { 'strict' } else { 'smoke' }
    $requiredDiffs = [Math]::Max(0, [int]$MinDiffs)
    $normalStatus = if ([string]::IsNullOrWhiteSpace($Status)) { 'unknown' } else { $Status.Trim().ToLowerInvariant() }

    $outcome = 'pass'
    $reasonCode = 'ok'
    $reasonMessage = 'policy checks passed'

    if ($Missing) {
        $reasonCode = 'missing-summary-row'
        $reasonMessage = ("No summary row was produced for target '{0}'." -f $TargetPath)
        if ($RequireDiff) {
            $outcome = 'fail'
        } else {
            $outcome = 'warn'
        }
    } elseif ($null -eq $Comparisons -or $Comparisons -lt 1) {
        $reasonCode = 'zero-comparisons'
        $reasonMessage = ("Target '{0}' reported zero comparisons." -f $TargetPath)
        if ($RequireDiff) {
            $outcome = 'fail'
        } else {
            $outcome = 'warn'
        }
    } elseif ($RequireDiff -and ($null -eq $Diffs -or $Diffs -lt $requiredDiffs)) {
        $outcome = 'fail'
        $reasonCode = 'insufficient-diffs'
        $reasonMessage = ("Target '{0}' expected at least {1} diff(s) but reported {2}." -f $TargetPath, $requiredDiffs, [int]$Diffs)
    } elseif ($RequireDiff -and $normalStatus -notmatch 'diff') {
        $outcome = 'fail'
        $reasonCode = 'strict-status-mismatch'
        $reasonMessage = ("Target '{0}' expected diff status but saw '{1}'." -f $TargetPath, $normalStatus)
    } elseif ((-not $RequireDiff) -and $requiredDiffs -gt 0 -and ($null -eq $Diffs -or $Diffs -lt $requiredDiffs)) {
        $outcome = 'warn'
        $reasonCode = 'insufficient-diffs'
        $reasonMessage = ("Target '{0}' expected at least {1} diff(s) but reported {2}." -f $TargetPath, $requiredDiffs, [int]$Diffs)
    }

    [pscustomobject]@{
        policyClass     = $policyClass
        outcome         = $outcome
        gateOutcome     = if ($outcome -eq 'fail') { 'fail' } else { 'pass' }
        hardFail        = ($outcome -eq 'fail')
        warning         = ($outcome -eq 'warn')
        reasonCode      = $reasonCode
        reasonMessage   = $reasonMessage
        requireDiff     = $RequireDiff
        minDiffs        = $requiredDiffs
        comparisons     = if ($null -eq $Comparisons) { 0 } else { [int]$Comparisons }
        diffs           = if ($null -eq $Diffs) { 0 } else { [int]$Diffs }
        status          = $normalStatus
        targetPath      = $TargetPath
    }
}

