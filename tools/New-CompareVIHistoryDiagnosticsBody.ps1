[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('comment-gated', 'manual')]
  [string]$Variant,

  [Parameter(Mandatory = $true)]
  [string]$ActionRef,

  [string]$IssueNumber,
  [string]$PullRequestNumber,
  [string]$TargetPath,
  [string]$ContainerImage,
  [string]$RequestedModes,
  [string]$ExecutedModes,
  [string]$TotalProcessed,
  [string]$TotalDiffs,
  [string]$ResultsDir,
  [string]$StepConclusion,
  [string]$IsFork,
  [string]$RunUrl,
  [string]$ModeSummaryMarkdown,
  [string]$OpeningSentence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ValueOrDefault {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value,
    [Parameter(Mandatory = $true)]
    [string]$DefaultValue
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $DefaultValue
  }

  return $Value
}

$prNumber = if ($Variant -eq 'comment-gated') {
  Get-ValueOrDefault -Value $IssueNumber -DefaultValue 'n/a'
} else {
  Get-ValueOrDefault -Value $PullRequestNumber -DefaultValue 'n/a'
}

$defaultOpeningSentence = if ($Variant -eq 'comment-gated') {
  "comparevi-history diagnostics finished for PR #$prNumber."
} else {
  "comparevi-history manual diagnostics finished for PR #$prNumber."
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add((Get-ValueOrDefault -Value $OpeningSentence -DefaultValue $defaultOpeningSentence)) | Out-Null
$lines.Add('') | Out-Null
$lines.Add(('- Action ref: `{0}`' -f (Get-ValueOrDefault -Value $ActionRef -DefaultValue 'n/a'))) | Out-Null
$lines.Add(('- Target path: `{0}`' -f (Get-ValueOrDefault -Value $TargetPath -DefaultValue 'n/a'))) | Out-Null
$lines.Add(('- Container image: `{0}`' -f (Get-ValueOrDefault -Value $ContainerImage -DefaultValue 'n/a'))) | Out-Null
$lines.Add(('- Requested modes: `{0}`' -f (Get-ValueOrDefault -Value $RequestedModes -DefaultValue 'n/a'))) | Out-Null
$lines.Add(('- Executed modes: `{0}`' -f (Get-ValueOrDefault -Value $ExecutedModes -DefaultValue 'n/a'))) | Out-Null
$lines.Add(('- Total processed: `{0}`' -f (Get-ValueOrDefault -Value $TotalProcessed -DefaultValue 'n/a'))) | Out-Null
$lines.Add(('- Total diffs: `{0}`' -f (Get-ValueOrDefault -Value $TotalDiffs -DefaultValue 'n/a'))) | Out-Null

if ($Variant -eq 'comment-gated') {
  $lines.Add(('- Step conclusion: `{0}`' -f (Get-ValueOrDefault -Value $StepConclusion -DefaultValue 'n/a'))) | Out-Null
  $lines.Add(('- PR head is fork: `{0}`' -f (Get-ValueOrDefault -Value $IsFork -DefaultValue 'n/a'))) | Out-Null
} else {
  $lines.Add(('- Results dir: `{0}`' -f (Get-ValueOrDefault -Value $ResultsDir -DefaultValue 'n/a'))) | Out-Null
  $lines.Add(('- PR head is fork: `{0}`' -f (Get-ValueOrDefault -Value $IsFork -DefaultValue 'n/a'))) | Out-Null
}

$lines.Add('') | Out-Null
$lines.Add('### Mode coverage') | Out-Null
$lines.Add('') | Out-Null
$lines.Add((Get-ValueOrDefault -Value $ModeSummaryMarkdown -DefaultValue '_mode summary unavailable_')) | Out-Null
$lines.Add('') | Out-Null
$lines.Add(('- Run: {0}' -f (Get-ValueOrDefault -Value $RunUrl -DefaultValue 'n/a'))) | Out-Null

return ($lines -join "`n")
