param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ProcessCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter()][string[]]$Arguments = @()
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err }
}

function Get-AgentRunContext {
    [CmdletBinding()]
    param()
    $wf   = $env:GITHUB_WORKFLOW
    $job  = $env:GITHUB_JOB
    $sha  = $env:GITHUB_SHA
    $ref  = $env:GITHUB_REF
    $actor= $env:GITHUB_ACTOR

    # Fallbacks for local/non-GitHub contexts
    if (-not $sha) {
        try {
            $r = Invoke-ProcessCapture -FileName 'git' -Arguments @('rev-parse','--verify','HEAD')
            if ($r.Code -eq 0 -and $r.Out) { $sha = ($r.Out.Trim()) }
        } catch {}
    }
    if (-not $ref) {
        try {
            $r = Invoke-ProcessCapture -FileName 'git' -Arguments @('rev-parse','--abbrev-ref','HEAD')
            if ($r.Code -eq 0 -and $r.Out) {
                $branch = $r.Out.Trim()
                if ($branch -and $branch -ne 'HEAD') { $ref = "refs/heads/$branch" }
            }
        } catch {}
    }
    if (-not $wf) { $wf = 'local-session' }
    if (-not $job) { $job = 'manual' }
    if (-not $actor) {
        $actor = $env:USERNAME
        if (-not $actor -and $env:USER) { $actor = $env:USER }
        if (-not $actor) { $actor = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    }

    return [ordered]@{ sha = $sha; ref = $ref; workflow = $wf; job = $job; actor = $actor }
}

function Start-AgentWait {
    [CmdletBinding()] param(
        [Parameter(Position=0)][string]$Reason = 'unspecified',
        [Parameter(Position=1)][int]$ExpectedSeconds = 90,
        [Parameter()][string]$ResultsDir = 'tests/results',
        [Parameter()][int]$ToleranceSeconds = 5,
        [Parameter()][string]$Id = 'default'
    )
    $root = Resolve-Path . | Select-Object -ExpandProperty Path
    $outDir = Join-Path $ResultsDir '_agent'
    $sessionDir = Join-Path $outDir (Join-Path 'sessions' $Id)
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $markerPath = Join-Path $sessionDir 'wait-marker.json'
    $now = [DateTimeOffset]::UtcNow
    $sketch = 'brief-' + [string]$ExpectedSeconds
    $o = [ordered]@{
        schema = 'agent-wait/v1'
        id = $Id
        reason = $Reason
        expectedSeconds = $ExpectedSeconds
        toleranceSeconds = $ToleranceSeconds
        startedUtc = $now.ToString('o')
        startedUnixSeconds = [int][Math]::Floor($now.ToUnixTimeSeconds())
        workspace = $root
        sketch = $sketch
        runContext = Get-AgentRunContext
    }
    $o | ConvertTo-Json -Depth 5 | Out-File -FilePath $markerPath -Encoding utf8
    $msg = "Agent wait started: reason='$Reason', expected=${ExpectedSeconds}s"
    Write-Host $msg
    if ($env:GITHUB_STEP_SUMMARY) {
        $lines = @(
            '### Agent Wait Start',
            "- Reason: $Reason",
            "- Expected: ${ExpectedSeconds}s",
            "- Marker: $markerPath"
        ) -join "`n"
        $lines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    return $markerPath
}

function End-AgentWait {
    [CmdletBinding()] param(
        [Parameter(Position=0)][string]$ResultsDir = 'tests/results',
        [Parameter()][int]$ToleranceSeconds = 5,
        [Parameter()][string]$Id = 'default'
    )
    $outDir = Join-Path $ResultsDir '_agent'
    $sessionDir = Join-Path $outDir (Join-Path 'sessions' $Id)
    $markerPath = Join-Path $sessionDir 'wait-marker.json'
    if (-not (Test-Path $markerPath)) {
        Write-Host '::notice::No wait marker found.'
        return $null
    }
    $start = Get-Content $markerPath -Raw | ConvertFrom-Json
    $started = [DateTimeOffset]::Parse($start.startedUtc)
    $now = [DateTimeOffset]::UtcNow
    # Use ceiling to treat any non-zero elapsed time as at least 1s for strict zero-tolerance checks
    $elapsedSec = [int][Math]::Ceiling(($now - $started).TotalSeconds)
    # derive tolerance: prefer explicit param, fallback to marker
    $tol = if ($PSBoundParameters.ContainsKey('ToleranceSeconds')) { $ToleranceSeconds } elseif ($start.PSObject.Properties['toleranceSeconds']) { [int]$start.toleranceSeconds } else { 5 }
    $diff = [int][Math]::Abs($elapsedSec - [int]$start.expectedSeconds)
    $withinMargin = ($diff -le $tol)
    $sketch = 'brief-' + [string]$start.expectedSeconds
    $result = [ordered]@{
        schema = 'agent-wait-result/v1'
        id = $start.id
        reason = $start.reason
        expectedSeconds = $start.expectedSeconds
        startedUtc = $start.startedUtc
        endedUtc = $now.ToString('o')
        elapsedSeconds = $elapsedSec
        toleranceSeconds = $tol
        differenceSeconds = $diff
        withinMargin = $withinMargin
        markerPath = $markerPath
        sketch = $sketch
        runContext = Get-AgentRunContext
    }
    $lastPath = Join-Path $sessionDir 'wait-last.json'
    $logPath = Join-Path $sessionDir 'wait-log.ndjson'
    $result | ConvertTo-Json -Depth 5 | Out-File -FilePath $lastPath -Encoding utf8
    ($result | ConvertTo-Json -Depth 5) | Out-File -FilePath $logPath -Append -Encoding utf8
    # Keep marker for chainable waits; caller may remove if desired
    $summary = @(
        '### Agent Wait Result',
        "- Reason: $($result.reason)",
        "- Elapsed: ${elapsedSec}s",
        "- Expected: $($result.expectedSeconds)s",
        "- Tolerance: ${tol}s",
        "- Difference: ${diff}s",
        "- Within Margin: $withinMargin"
    ) -join "`n"
    Write-Host $summary
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    return $result
}

# Export only when running inside a module context
try {
    if ($PSVersionTable -and $ExecutionContext -and $ExecutionContext.SessionState.Module) {
        Export-ModuleMember -Function Start-AgentWait, End-AgentWait
    }
} catch {
    # Ignore when not in a module context
}
