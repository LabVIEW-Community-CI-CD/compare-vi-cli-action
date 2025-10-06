# Reassess default for discovery failure strictness

**Labels:** testing, stability

## Background

Discovery failure detection currently uses a softened classification (errors only promoted when no other failures) plus nested suppression to avoid false positives.

## Goal

Decide whether to enable strict mode by default (treat any discovery failure pattern as error) in v0.5.0.

## Data Needed

- Count of discovery failure occurrences across recent v0.4.x runs.
- Instances confirmed as false positives (if any) post instrumentation.
- Time cost impact of strict runs vs soft mode (should be negligible).

## Acceptance Criteria

- [ ] Evidence collected & summarized (table or bullet stats) in PR description.
- [ ] Decision recorded (flip default or retain) with justification.
- [ ] README & dispatcher help updated to reflect new default if flipped.
- [ ] Env escape hatch preserved (e.g., `DISCOVERY_FAILURES_STRICT=0`).

## Implementation (If Flipped)

- Change default internal flag to strict.
- Update tests expecting soft classification.
- Add release notes: rationale + rollback env variable.

## Risks

- Rare but still possible nested edge false positives if suppression logic changes; mitigate with regression test capturing nested scenario output.
