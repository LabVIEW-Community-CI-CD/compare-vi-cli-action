#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Target,
  [string]$ConfigPath,
  [string]$RepositoryRoot,
  [switch]$SkipTrackingCheck,
  [switch]$SkipCleanCheck,
  [switch]$SkipBranchPatternCheck,
  [switch]$Quiet,
  [switch]$NoTelemetry,
  [switch]$NoStepSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param([Parameter(Mandatory = $true)][string[]]$Args)
  $output = & git @Args 2>&1
  $exit = $LASTEXITCODE
  return [pscustomobject]@{
    ExitCode = $exit
    Output   = if ($output -is [System.Array]) { @($output) } elseif ($null -eq $output) { @() } else { @($output) }
  }
}

function Get-GitSingleLine {
  param([Parameter(Mandatory = $true)][string[]]$Args)
  $result = Invoke-Git -Args $Args
  if ($result.ExitCode -ne 0) { return $null }
  return ($result.Output -join "`n").Trim()
}

function Get-StandingIssueNumber {
  param([string]$RepoRoot)
  $cachePath = Join-Path $RepoRoot '.agent_priority_cache.json'
  if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { return $null }
  try {
    $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($cache.number) {
      return [string]$cache.number
    }
  } catch {}
  return $null
}

function Get-Property {
  param(
    [Parameter(Mandatory = $false)]$Primary,
    [Parameter(Mandatory = $false)]$Fallback,
    [Parameter(Mandatory = $false)]$Default
  )
  if ($null -ne $Primary) { return $Primary }
  if ($null -ne $Fallback) { return $Fallback }
  return $Default
}

function Get-JsonPropertyValue {
  param(
    [Parameter(Mandatory = $false)]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    $dict = [System.Collections.IDictionary]$Object
    foreach ($key in $dict.Keys) {
      if ($key -is [string] -and $key.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $dict[$key]
      }
    }
    return $null
  }
  $prop = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name }
  if ($prop) { return $prop.Value }
  return $null
}

$popLocation = $false
try {
  if ($RepositoryRoot) {
    $resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    Push-Location $resolvedRoot
    $popLocation = $true
    $top = Get-GitSingleLine -Args @('rev-parse','--show-toplevel')
    if (-not $top) { throw "Path '$RepositoryRoot' is not inside a git repository." }
    $repoRoot = $top
    if (-not $repoRoot) { $repoRoot = $resolvedRoot }
    Set-Location $repoRoot
  } else {
    $top = Get-GitSingleLine -Args @('rev-parse','--show-toplevel')
    if (-not $top) { throw 'Unable to determine repository root (run inside a git repository or specify -RepositoryRoot).' }
    Push-Location $top
    $popLocation = $true
    $repoRoot = $top
  }

  $configFile = if ($ConfigPath) {
    if ([IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $repoRoot $ConfigPath }
  } else {
    Join-Path $repoRoot '.agent_push_config.json'
  }
  if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    throw "Push target contract not found: $configFile"
  }

  $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json -ErrorAction Stop

  if (-not $Target) {
    $Target = $config.defaultTarget
  }
  if (-not $Target) {
    throw "Push target not specified and 'defaultTarget' missing in $configFile."
  }
  if (-not $config.targets) { throw "No targets declared in $configFile." }
  $targetProperty = $config.targets.PSObject.Properties | Where-Object { $_.Name -ieq $Target }
  if (-not $targetProperty) { throw "Target '$Target' not defined in $configFile." }
  $targetConfig = $targetProperty.Value

  $remoteName = Get-Property -Primary (Get-JsonPropertyValue -Object $targetConfig -Name 'remote') -Fallback (Get-JsonPropertyValue -Object $config -Name 'remote') -Default 'origin'
  $branchPatternRaw = Get-Property -Primary (Get-JsonPropertyValue -Object $targetConfig -Name 'branchPattern') -Fallback (Get-JsonPropertyValue -Object $config -Name 'branchPattern') -Default $null
  $requireTracking = if ($SkipTrackingCheck) {
    $false
  } else {
    [bool](Get-Property -Primary (Get-JsonPropertyValue -Object $targetConfig -Name 'requireTracking') -Fallback (Get-JsonPropertyValue -Object $config -Name 'requireTracking') -Default $true)
  }
  $requireClean = if ($SkipCleanCheck) {
    $false
  } else {
    [bool](Get-Property -Primary (Get-JsonPropertyValue -Object $targetConfig -Name 'requireClean') -Fallback (Get-JsonPropertyValue -Object $config -Name 'requireClean') -Default $true)
  }
  $performBranchCheck = if ($SkipBranchPatternCheck) {
    $false
  } else {
    if ($null -eq $branchPatternRaw) { $false } else { $true }
  }

  $standingNumber = $null
  $branchPatternEvaluated = $branchPatternRaw
  if ($performBranchCheck -and $branchPatternRaw -match '\{number\}') {
    $standingNumber = Get-StandingIssueNumber -RepoRoot $repoRoot
    if (-not $standingNumber) {
      throw "Standing priority cache missing (required to resolve branch pattern). Run 'node tools/npm/run-script.mjs priority:sync' first."
    }
    $branchPatternEvaluated = $branchPatternRaw.Replace('{number}', [Regex]::Escape($standingNumber))
  }

  $violations = New-Object System.Collections.Generic.List[string]

  $currentBranch = Get-GitSingleLine -Args @('rev-parse','--abbrev-ref','HEAD')
  if (-not $currentBranch) {
    $violations.Add('Failed to resolve current branch.')
    $currentBranch = 'unknown'
  }
  $isDetached = $currentBranch -eq 'HEAD'
  if ($isDetached) {
    $violations.Add('HEAD is detached; checkout a branch before pushing.')
  }

  $remoteUrlResult = Invoke-Git -Args @('remote','get-url',$remoteName)
  $remoteUrl = $null
  if ($remoteUrlResult.ExitCode -ne 0) {
    $violations.Add(("Remote '{0}' is not configured (see {1})." -f $remoteName, $configFile))
  } else {
    $remoteUrl = ($remoteUrlResult.Output -join "`n").Trim()
  }

  $upstream = $null
  $upstreamRemote = $null
  $upstreamBranch = $null
  if (-not $isDetached) {
    $upstreamLine = Get-GitSingleLine -Args @('rev-parse','--abbrev-ref','--symbolic-full-name','@{u}')
    if ($upstreamLine) {
      $upstream = $upstreamLine
      if ($upstream -match '^(?<remote>[^/]+)/(?<branch>.+)$') {
        $upstreamRemote = $Matches.remote
        $upstreamBranch = $Matches.branch
      } elseif ($upstream -match '^(?<remote>[^/]+)$') {
        $upstreamRemote = $Matches.remote
        $upstreamBranch = ''
      }
    } elseif ($requireTracking) {
      $violations.Add(("Current branch '{0}' is not tracking a remote branch. Push with 'git push --set-upstream {1} {0}' before proceeding." -f $currentBranch, $remoteName))
    }
  }

  if ($requireTracking -and $upstreamRemote -and $upstreamRemote -ne $remoteName) {
    $violations.Add(("Upstream remote '{0}' does not match contract remote '{1}' (see {2})." -f $upstreamRemote, $remoteName, $configFile))
  }

  if ($performBranchCheck -and -not $isDetached -and $branchPatternEvaluated) {
    try {
      if (-not [Regex]::IsMatch($currentBranch, $branchPatternEvaluated, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $targetDescription = Get-JsonPropertyValue -Object $targetConfig -Name 'description'
        $describe = if ($targetDescription) { $targetDescription } else { "target '$Target'" }
        $violations.Add(("Branch '{0}' does not match pattern '{1}' ({2})." -f $currentBranch, $branchPatternRaw, $describe))
      }
    } catch {
      $violations.Add(("Branch pattern '{0}' is invalid: {1}" -f $branchPatternRaw, $_.Exception.Message))
    }
  }

  $porcelainOutput = Invoke-Git -Args @('status','--porcelain')
  $workspaceDirty = $false
  if ($porcelainOutput.ExitCode -eq 0) {
    $porcelainLines = @($porcelainOutput.Output)
    $workspaceDirty = $porcelainLines.Count -gt 0
  } else {
    $violations.Add('Failed to evaluate working tree status.')
  }
  if ($requireClean -and $workspaceDirty) {
    $violations.Add('Working tree is dirty; commit, stash, or clean changes before pushing.')
  }

  $telemetryConfig = Get-JsonPropertyValue -Object $config -Name 'telemetry'
  $telemetryTargetConfig = Get-JsonPropertyValue -Object $targetConfig -Name 'telemetry'

  $telemetry = [ordered]@{
    schema               = 'agent-push-target/check@v1'
    generatedAt          = (Get-Date).ToString('o')
    configPath           = $configFile
    target               = $Target
    targetDescription    = (Get-JsonPropertyValue -Object $targetConfig -Name 'description')
    remote               = $remoteName
    remoteUrl            = $remoteUrl
    branch               = $currentBranch
    branchPattern        = $branchPatternRaw
    branchPatternApplied = $branchPatternEvaluated
    standingIssueNumber  = $standingNumber
    requireTracking      = $requireTracking
    requireClean         = $requireClean
    skipBranchCheck      = -not $performBranchCheck
    upstream             = $upstream
    upstreamRemote       = $upstreamRemote
    upstreamBranch       = $upstreamBranch
    dirty                = $workspaceDirty
    violations           = @($violations)
    status               = if ($violations.Count -eq 0) { 'ok' } else { 'fail' }
  }

  if (-not $NoTelemetry) {
    $resultsPathRaw = Get-Property -Primary (Get-JsonPropertyValue -Object $targetConfig -Name 'resultsPath') -Fallback (Get-JsonPropertyValue -Object $telemetryTargetConfig -Name 'resultsPath') -Default (Get-Property -Primary (Get-JsonPropertyValue -Object $telemetryConfig -Name 'resultsPath') -Fallback $null -Default 'tests/results/_agent/push-target.json')
    $resultsPath = if ([IO.Path]::IsPathRooted($resultsPathRaw)) { $resultsPathRaw } else { Join-Path $repoRoot $resultsPathRaw }
    $resultsDir = Split-Path -Parent $resultsPath
    if ($resultsDir -and -not (Test-Path -LiteralPath $resultsDir)) {
      New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    }
    $telemetry | ConvertTo-Json -Depth 6 | Out-File -FilePath $resultsPath -Encoding utf8
  }

  if (-not $NoStepSummary) {
    $summaryHeader = Get-Property -Primary (Get-JsonPropertyValue -Object $targetConfig -Name 'stepSummaryHeader') -Fallback (Get-JsonPropertyValue -Object $telemetryTargetConfig -Name 'stepSummaryHeader') -Default (Get-Property -Primary (Get-JsonPropertyValue -Object $telemetryConfig -Name 'stepSummaryHeader') -Fallback $null -Default 'Agent Push Target')
    $summaryPath = $env:GITHUB_STEP_SUMMARY
    if ($summaryPath) {
      $lines = @("### $summaryHeader")
      $lines += ("- Target: {0}" -f $Target)
      $lines += ("- Remote: {0}" -f $remoteName)
      if ($remoteUrl) { $lines += ("- Remote URL: {0}" -f $remoteUrl) }
      $lines += ("- Branch: {0}" -f $currentBranch)
      if ($upstream) { $lines += ("- Upstream: {0}" -f $upstream) }
      $lines += ("- Status: {0}" -f $telemetry.status)
      if ($violations.Count -gt 0) {
        foreach ($item in $violations) { $lines += ("  - {0}" -f $item) }
      }
      Add-Content -LiteralPath $summaryPath -Value ($lines -join "`n") -Encoding utf8
    }
  }

  if (-not $Quiet) {
    Write-Host "[push-target] Target: $Target" -ForegroundColor Cyan
    Write-Host ("[push-target] Remote: {0}{1}" -f $remoteName, $(if ($remoteUrl) { " ($remoteUrl)" } else { '' })) -ForegroundColor Gray
    Write-Host ("[push-target] Branch: {0}" -f $currentBranch) -ForegroundColor Gray
    if ($upstream) { Write-Host ("[push-target] Upstream: {0}" -f $upstream) -ForegroundColor Gray }
    if ($violations.Count -eq 0) {
      Write-Host '[push-target] Contract satisfied.' -ForegroundColor Green
    } else {
      Write-Host '[push-target] Contract violations detected:' -ForegroundColor Yellow
      foreach ($v in $violations) { Write-Host (" - {0}" -f $v) -ForegroundColor Yellow }
    }
  }

  if ($violations.Count -gt 0) {
    $message = "Push target contract violations:`n - " + ($violations -join "`n - ") + "`nSee $configFile for allowed remotes/branches."
    throw [System.InvalidOperationException]$message
  }

  return [pscustomobject]$telemetry
}
finally {
  if ($popLocation) {
    Pop-Location
  }
}
