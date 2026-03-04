# Release VI History Stable Enforcement Monitoring

This tracker captures long-tail evidence that stable tags continue to enforce migration policy in `hard` mode.

## Purpose

- provide a repeatable checklist for post-Phase-8 monitoring,
- keep stable-tag enforcement evidence auditable from PR comments and artifacts,
- surface drift quickly before promotion policy changes.

## Monitoring Cadence

- record evidence for each stable release cycle,
- include at least one comparable RC proof near the same window when possible,
- update this file and link evidence in PR/issue discussion.

## Quickstart (3 Commands)

1) Run zero-arg auto monitoring (harvest + tracker update + PR comment when branch PR is detected):

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Invoke-ReleaseVIHistoryStableMonitoringAuto.ps1
```

2) Inspect tracker changes locally:

```powershell
git diff -- docs/RELEASE_VI_HISTORY_STABLE_ENFORCEMENT_MONITORING.md
```

3) Commit and push tracker update (if you want to persist this cycle evidence):

```powershell
git add docs/RELEASE_VI_HISTORY_STABLE_ENFORCEMENT_MONITORING.md; git commit -m "docs: update stable monitoring evidence (#216)"; git push
```

Expected output sanity-check (example):

```text
trackerPath       : docs/RELEASE_VI_HISTORY_STABLE_ENFORCEMENT_MONITORING.md
action            : replaced-placeholder | updated-existing-tag | appended
tag               : v0.6.x
runId             : <run-id>
runUrl            : https://github.com/<owner>/<repo>/actions/runs/<run-id>
indexJobUrl       : https://github.com/<owner>/<repo>/actions/runs/<run-id>/job/<job-id>
row               : | <date> | <tag> | stable | <runUrl> | <indexJobUrl> | migration.tagClassEnforcement.stable | hard | <rawOutcome> | <outcome> | auto-harvested from run <run-id> |
commentBodyPath   : tests/results/_agent/release-proof/monitoring-auto/pr-comment.md
```

## Evidence Template

| Date (UTC) | Tag | Tag Class | Run URL | Index Job URL | enforcementSource | enforcementMode | rawOutcome | outcome | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-03-03 | next-stable-tag | stable | pending-next-stable-run-url | pending-next-stable-index-job-url | migration.tagClassEnforcement.stable | expected-hard | pending | pending | prefilled row for next stable release capture |

## Acceptance Checks Per Entry

For stable tags:

- `tagClass = stable`
- `enforcementSource` resolves to the expected stable source (or explicit fallback path)
- `enforcementMode = hard` unless an approved exception exists
- if `rawOutcome = fail`, workflow should fail under hard enforcement

## Quick Field Extraction

Use this PowerShell snippet after downloading `release-vi-history-review-index` artifacts:

```powershell
$policyPath = Get-ChildItem -Path tests/results/_agent/release-proof -Filter release-vi-history-policy.json -Recurse -File |
	Sort-Object LastWriteTimeUtc -Descending |
	Select-Object -First 1 -ExpandProperty FullName

$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -Depth 20

[pscustomobject]@{
	tagClass = $policy.tagClass
	enforcementSource = $policy.enforcementSource
	enforcementMode = $policy.enforcementMode
	rawOutcome = $policy.rawOutcome
	outcome = $policy.outcome
	policyPath = $policyPath
} | Format-List
```

Helper script equivalent:

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Get-ReleaseVIHistoryPolicyFields.ps1
```

One-line step-summary variant (for CI/manual notes):

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Get-ReleaseVIHistoryPolicyFields.ps1 -AppendStepSummary
```

## One-Command Tracker Update

Auto-harvest latest successful stable `Release on tag` run and upsert tracker row:

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Update-ReleaseVIHistoryStableMonitoring.ps1
```

Use a specific run id:

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Update-ReleaseVIHistoryStableMonitoring.ps1 -RunId <run-id>
```

Generate a PR-comment body file from the harvested row:

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Update-ReleaseVIHistoryStableMonitoring.ps1 -EmitPrCommentBody
```

Generate and post directly to a PR:

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Update-ReleaseVIHistoryStableMonitoring.ps1 -EmitPrCommentBody -PostPrComment -PrRepoSlug LabVIEW-Community-CI-CD/compare-vi-cli-action -PrNumber 646
```

Zero-arg auto mode (resolve repo + branch PR context automatically):

```powershell
pwsh -NoLogo -NoProfile -File ./tools/Invoke-ReleaseVIHistoryStableMonitoringAuto.ps1
```

NPM wrapper:

```powershell
npm run release:vi-history:monitor:auto
```

VS Code task:

- `Release VI History: Stable monitoring auto`

## Exception Handling

If stable mode deviates from `hard`:

1. open/update incident record using `docs/RELEASE_VI_HISTORY_MIGRATION_INCIDENT_PLAYBOOK.md`,
2. post mitigation rationale and owner in PR comment,
3. define expiry/revert condition for the exception.

## Current Baseline

- RC evidence is tracked via recent Phase 8 disposable proof comments on PR #646.
- First stable-tag entry should be added on the next stable release run.
