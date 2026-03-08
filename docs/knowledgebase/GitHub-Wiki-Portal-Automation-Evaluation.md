# GitHub Wiki Portal Automation Evaluation

This document records the deferred automation evaluation for the compare-vi wiki portal tracked under `#904`.

## Decision

Keep manual curation for now.

- Do not add wiki sync or export automation as part of the initial portal rollout.
- If automation becomes justified later, start with the smallest read-only or narrowly bounded helper.
- Do not treat the wiki as a second source of truth.

## Context

- The authoritative docs live in this repository under `docs/`.
- The published wiki pages live in the separate GitHub wiki backing repo,
  `LabVIEW-Community-CI-CD/compare-vi-cli-action.wiki.git`.
- The wiki exists to help humans and future agents find the right checked-in doc quickly.
- The March 8, 2026 portal rollout established the wiki information architecture and repo touchpoints, but it did not
  produce repeated maintenance evidence yet.

The separate wiki repo matters. Any write automation that updates published pages increases cross-repo coupling,
credential scope, rollback surface, and drift risk.

## Evaluation criteria

Any future automation proposal should be judged against these criteria:

1. Preserve `docs/` as the source of truth.
2. Minimize cross-repo write coupling with the wiki backing repo.
3. Keep manual editorial control over curated summaries.
4. Reduce repeated toil instead of moving one-off setup work into code.
5. Be easy to validate and easy to roll back.

## Option matrix

| Option | Value | Risks | Recommendation |
| --- | --- | --- | --- |
| Keep manual curation | Zero new tooling; preserves editorial control | Ongoing manual updates | Keep as the default now |
| Read-only route/link report | Detects stale authoritative-doc links and missing portal routes without changing content | May need explicit wiki snapshot input because published pages live in a separate repo | First candidate if drift evidence appears |
| Navigation manifest export | Reduces repeated edits to `Home` and `_Sidebar` structure | Couples a checked-in manifest to wiki repo writes; may flatten intentional page curation | Consider only after repeated navigation churn |
| Page skeleton generator | Speeds creation of stable page sections like `Start here` and `Authoritative repo docs` | Limited value once the initial portal pages already exist | Only if future page creation becomes frequent |
| Summary snippet export | Reuses checked-in summaries | Higher drift and formatting risk across repos; encourages duplication | Not recommended as an early step |
| Full sync or parity enforcement | Strongest consistency signal | Recreates the wiki as a mirrored docs system and raises rollback complexity | Reject |

## Concrete triggers

Automation should only be reconsidered if there is measured evidence such as:

- three or more stale-link fixes across wiki pages within a short maintenance window
- two or more standing-priority cycles that require the same `Home` or `_Sidebar` edits
- repeated missed wiki follow-up after checked-in docs change
- operator or agent confusion that persists even after the current portal contract is in place

## Recommended progression

If the triggers are met, use this order:

1. Add a read-only helper that reports broken authoritative-doc links or missing required portal sections.
2. If navigation churn remains high, evaluate a checked-in manifest that can export `Home` and `_Sidebar` skeletons.
3. Reevaluate before introducing any cross-repo write automation.

Do not start with snippet export or full wiki sync.

## Current conclusion

As of March 8, 2026, the repository does not have enough repeated maintenance evidence to justify wiki automation.
Manual curation remains the correct operating mode, and `#904` should stay focused on decision quality rather than
premature implementation.
