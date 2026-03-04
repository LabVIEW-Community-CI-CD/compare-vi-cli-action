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

## Evidence Template

| Date (UTC) | Tag | Tag Class | Run URL | Index Job URL | enforcementSource | enforcementMode | rawOutcome | outcome | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| yyyy-mm-dd | v0.x.y | stable | <url> | <url> | migration.tagClassEnforcement.stable | hard | pass/warn/fail | pass/warn/fail | baseline entry |

## Acceptance Checks Per Entry

For stable tags:

- `tagClass = stable`
- `enforcementSource` resolves to the expected stable source (or explicit fallback path)
- `enforcementMode = hard` unless an approved exception exists
- if `rawOutcome = fail`, workflow should fail under hard enforcement

## Exception Handling

If stable mode deviates from `hard`:

1. open/update incident record using `docs/RELEASE_VI_HISTORY_MIGRATION_INCIDENT_PLAYBOOK.md`,
2. post mitigation rationale and owner in PR comment,
3. define expiry/revert condition for the exception.

## Current Baseline

- RC evidence is tracked via recent Phase 8 disposable proof comments on PR #646.
- First stable-tag entry should be added on the next stable release run.