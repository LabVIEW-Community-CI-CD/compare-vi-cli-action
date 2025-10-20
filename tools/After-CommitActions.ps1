#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$Push = $true,
  [switch]$CreatePR = $true,
  [string]$RepositoryRoot,
  [string]$Remote = 'origin',
  [string]$BaseBranch = 'develop',
  [string]$PushTarget = 'standing',
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [Alias('Args')]
    [string[]]$GitArgs
  )
  $output = & git @GitArgs 2>&1
  $exit = $LASTEXITCODE
  [pscustomobject]@{
    ExitCode = $exit
    Output   = if ($output -is [System.Array]) { @($output) } elseif ($null -eq $output) { @() } else { @($output) }
  }
}

function Get-GitSingleLine {
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [Alias('Args')]
    [string[]]$GitArgs
  )
  $result = Invoke-Git @GitArgs
  if ($result.ExitCode -ne 0) { return $null }
  ($result.Output -join "`n").Trim()
}

function Should-SkipPath {
  param([string]$Path)
  $patterns = @(
    '^\.agent_priority_cache\.json$',
    '^tests/results/',
    '^tests\\results\\',
    '^tests/$',
    '^tests\\$',
    '^tmp/',
    '^tmp\\',
    '^\.tmp/'
  )
  foreach ($pattern in $patterns) {
    if ($Path -match $pattern) { return $true }
  }
  return $false
}

$repoRoot = $null
$popLocation = $false
if ($RepositoryRoot) {
  $repoRoot = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
  Push-Location $repoRoot
  $popLocation = $true
} else {
  $repoRoot = Get-GitSingleLine @('rev-parse','--show-toplevel')
  if (-not $repoRoot) { throw 'Not inside a git repository.' }
  Push-Location $repoRoot
  $popLocation = $true
}

$summaryPath = Join-Path $repoRoot 'tests/results/_agent/post-commit.json'
$summaryDir = Split-Path -Parent $summaryPath
if (-not (Test-Path -LiteralPath $summaryDir)) {
  New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
}

$pushResult = $null
$prResult = $null
$commitMessage = $null
$branch = $null
$issueNumber = $null

try {
  $status = Invoke-Git @('status','--porcelain')
  $rawEntries = @()
  if ($status.ExitCode -eq 0) {
    foreach ($line in ($status.Output | Where-Object { $_ })) {
      if (-not $line) { continue }
      $path = $line.Substring(3)
      $rawEntries += [pscustomobject]@{
        Raw  = $line
        Path = $path
      }
    }
  } else {
    $rawEntries = @([pscustomobject]@{ Raw = 'unknown'; Path = 'unknown' })
  }
  $dirtyEntries = @($rawEntries | Where-Object { -not (Should-SkipPath -Path $_.Path) })
  $folderEntries = @($dirtyEntries | Where-Object { $_.Path -eq 'tests/' })
  if ($folderEntries) {
    $otherTests = @($dirtyEntries | Where-Object { $_.Path -like 'tests/*' -and $_.Path -notmatch '^tests/results/_agent/' })
    if ($otherTests.Count -eq 0) {
      $dirtyEntries = @($dirtyEntries | Where-Object { $_.Path -ne 'tests/' })
    }
  }
  if ($dirtyEntries.Count -gt 0 -and -not $Force) {
    $paths = $dirtyEntries | ForEach-Object { $_.Path }
    throw ("Working tree is dirty; aborting post-commit automation. Offending paths: {0}. Use -Force to override." -f ($paths -join ', '))
  }

  $branch = Get-GitSingleLine @('rev-parse','--abbrev-ref','HEAD')
  if (-not $branch -or $branch -eq 'HEAD') { throw 'Cannot determine branch (detached HEAD).' }

  $commitMessage = Get-GitSingleLine @('log','-1','--pretty=%s')
  $planPath = Join-Path $repoRoot 'tests/results/_agent/commit-plan.json'
  if (Test-Path -LiteralPath $planPath) {
    try {
      $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($plan.issue) { $issueNumber = [int]$plan.issue }
      if ($plan.target) { $PushTarget = $plan.target }
    } catch {}
  }
  if (-not $issueNumber) {
    $cachePath = Join-Path $repoRoot '.agent_priority_cache.json'
    if (Test-Path -LiteralPath $cachePath) {
      try {
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($cache.number) { $issueNumber = [int]$cache.number }
      } catch {}
    }
  }

  if ($Push) {
    $ensureArgs = @(
      '-NoLogo','-NoProfile',
      '-File', (Join-Path $repoRoot 'tools' 'Ensure-AgentPushTarget.ps1'),
      '-RepositoryRoot', $repoRoot,
      '-SkipTrackingCheck',
      '-SkipCleanCheck'
    )
    if ($PushTarget) { $ensureArgs += @('-Target',$PushTarget) }
    & pwsh @ensureArgs
    if ($LASTEXITCODE -ne 0) { throw 'Push target contract failed (pre-push).' }

    $upstreamResult = Invoke-Git @('rev-parse','--abbrev-ref','--symbolic-full-name','@{u}')
    $hasUpstream = $upstreamResult.ExitCode -eq 0

    if ($hasUpstream) {
      $pushResult = Invoke-Git @('push',$Remote)
    } else {
      $pushResult = Invoke-Git @('push','--set-upstream',$Remote,$branch)
    }
    if ($pushResult.ExitCode -ne 0) {
      throw ("git push failed:`n{0}" -f ($pushResult.Output -join "`n"))
    }

    & pwsh @ensureArgs
    if ($LASTEXITCODE -ne 0) { throw 'Push target contract failed (post-push).' }
  }

  if ($CreatePR) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
      & $gh.Source 'auth' 'status' 2>$null
      if ($LASTEXITCODE -eq 0) {
        $existing = & $gh.Source 'pr' 'view' '--json' 'number' '--head' $branch 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $existing) {
          $title = if ($commitMessage) { $commitMessage } else { "Standing priority update #$issueNumber" }
          $args = @('pr','create','--base',$BaseBranch,'--head',$branch,'--title',$title,'--fill')
          if ($issueNumber) { $args += @('--body',("Automated updates for #{0}." -f $issueNumber)) }
          $prOutput = & $gh.Source @args
          if ($LASTEXITCODE -eq 0) {
            $prResult = @{
              created = $true
              output = $prOutput
            }
          } else {
            $prResult = @{
              created = $false
              error = $LASTEXITCODE
            }
          }
        } else {
          $data = $existing | ConvertFrom-Json
          $prResult = @{
            created = $false
            existing = $data.number
          }
        }
      } else {
        $prResult = @{
          created = $false
          reason = 'gh-auth-failed'
        }
      }
    } else {
      $prResult = @{
        created = $false
        reason = 'gh-missing'
      }
    }
  }
} finally {
  if ($popLocation) { Pop-Location }
  $summary = [ordered]@{
    schema        = 'post-commit/actions@v1'
    generatedAt   = (Get-Date).ToString('o')
    repoRoot      = $repoRoot
    branch        = $branch
    commitMessage = $commitMessage
    pushExecuted  = [bool]$Push
    pushResult    = if ($pushResult) { $pushResult } else { $null }
    createPR      = [bool]$CreatePR
    prResult      = $prResult
    issue         = $issueNumber
  }
  $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $summaryPath -Encoding utf8
}


