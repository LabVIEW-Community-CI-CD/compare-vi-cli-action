# GitHub Wiki Portal

This repository uses the GitHub wiki as a curated public portal into the checked-in documentation.

## Role split

- The wiki is for summaries, navigation, and audience-focused entry points.
- Checked-in repo docs remain the source of truth for runbooks, policy, technical contracts, and maintenance details.
- Published wiki page content lives in GitHub's dedicated wiki backing repo,
  `LabVIEW-Community-CI-CD/compare-vi-cli-action.wiki.git`.
- No critical operational rule should exist only in the wiki.

## Audience

- operators looking for the right runbook quickly
- contributors looking for the right entry point into the repo
- future agents discovering the repository surface for the first time

## Page contract

Every wiki page should follow the same basic shape:

1. A short summary that says who the page is for.
2. A small `Start here` link list.
3. An `Authoritative repo docs` section linking back to checked-in docs.
4. A maintenance note explaining that the repo docs are authoritative.

## Initial portal pages

The first wiki rollout should keep a compact, stable structure:

- `Home`
  - overall repository orientation and the top-level navigation hub
- `Getting-Started`
  - repository overview, primary workflows, and first-stop docs
- `Operations-and-Runbooks`
  - operator-facing runbook entry points
- `Contribution-and-Agent-Guidance`
  - contributor workflow, intake guidance, and agent rules

## Repo touchpoints

These repo surfaces should point readers at the wiki when discoverability matters:

- `README.md`
- `.github/ISSUE_TEMPLATE/config.yml`
- `docs/knowledgebase/GitHub-Intake-Layer.md`
- `AGENTS.md`

## Non-goals

- Do not mirror the entire `docs/knowledgebase/` tree into the wiki.
- Do not make the wiki the primary authoring location.
- Do not add sync automation or parity enforcement in the initial rollout.

## Deferred automation

Automation evaluation is tracked in
[`docs/knowledgebase/GitHub-Wiki-Portal-Automation-Evaluation.md`](./GitHub-Wiki-Portal-Automation-Evaluation.md).
The current recommendation is to keep manual curation and only consider narrow helpers such as read-only route/link
reporting or navigation export if repeated maintenance toil justifies them.

## Maintenance note

When a wiki page needs a detail-heavy update, prefer improving the checked-in repo doc first, then refresh the wiki
page to point at the right authoritative section instead of duplicating the full content.
