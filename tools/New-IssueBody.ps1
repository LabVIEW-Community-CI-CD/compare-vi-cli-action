#Requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('bug-report', 'feature-program', 'workflow-policy-agent-ux', 'investigation-anomaly')]
  [string]$Template = 'feature-program',
  [switch]$StandingPriority,
  [string]$RelatedIssues,
  [string]$RepositoryContext = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TemplateBody {
  param([string]$TemplateName)

  switch ($TemplateName) {
    'bug-report' {
      return @'
## Summary

Describe the failure in one short paragraph.

## Reproduction

- Minimal commands or workflow inputs:
- Repository state or branch:
- Runner plane / OS / Docker or LabVIEW details:

## Expected behavior

Describe the expected outcome.

## Actual behavior

Describe the actual outcome, including exit codes, check names, or artifact paths when relevant.

## Evidence

- Commands run:
- Artifact paths or workflow URLs:
- Screenshots or logs:
'@
    }
    'feature-program' {
      return @'
## Problem

Explain what hurts today and why it is worth changing now.

## Goal

State the desired end condition in one short paragraph.

## Scope

- In scope:
- Out of scope:
- Cross-repo or downstream dependencies:

## Acceptance criteria

- ...
- ...

## Evidence expectations

- Commands that should pass:
- Artifacts or workflow runs that should be attached:
- Rollback or follow-up expectations:
'@
    }
    'workflow-policy-agent-ux' {
      return @'
## Problem

Describe the workflow, policy, merge-queue, reviewer-routing, or agent UX gap.

## Desired behavior

Describe the deterministic outcome we want after the change.

## Affected contracts

- Workflows, jobs, or required checks:
- Labels, rulesets, reviewer routing, or approvals:
- Templates, helper scripts, or docs:

## Validation and rollback

- Validation commands:
- Dry-run or live workflow evidence:
- Rollback path:

## Reviewer focus

- Policy assumptions to verify:
- Subtle behavior or edge cases:
'@
    }
    'investigation-anomaly' {
      return @'
## Summary

Describe the anomaly and why it matters.

## Impact

- What is blocked, quarantined, or risky:
- Which workflows, tests, or operators are affected:

## Observed symptoms

- ...
- ...

## Mitigations attempted

- ...
- ...

## Working hypotheses and next steps

1. ...
2. ...

## Exit criteria

- Root cause identified or bounded:
- Durable mitigation or resolution path documented:
- Evidence captured for follow-up:
'@
    }
    default {
      throw "Unsupported issue template '$TemplateName'."
    }
  }
}

$relatedIssuesText = if ([string]::IsNullOrWhiteSpace($RelatedIssues)) { '(none supplied)' } else { $RelatedIssues }
$standingText = if ($StandingPriority.IsPresent) { 'Yes' } else { 'No' }
$preamble = @(
  '## Intake Context',
  '',
  "- Repository context: ``$RepositoryContext``",
  "- Standing priority at draft time: $standingText",
  "- Related issues or repos: $relatedIssuesText",
  ''
)

$body = (
  (($preamble -join [Environment]::NewLine) + [Environment]::NewLine + (Get-TemplateBody -TemplateName $Template)).
    Trim()
) + [Environment]::NewLine

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Write-Output $body
  return
}

$outputParent = Split-Path -Parent $OutputPath
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $body -NoNewline
