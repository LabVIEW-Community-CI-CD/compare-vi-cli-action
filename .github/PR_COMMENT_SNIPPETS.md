# GitHub Intake Snippets

Use these snippets to bootstrap issues, PR bodies, and PR comments with deterministic structure. Replace placeholders in
angle brackets.

## Open An Issue With The CLI Intake Helpers

- Feature or program intake:

```text
pwsh -File tools/New-IssueBody.ps1 -Template feature-program -StandingPriority -OutputPath issue-body.md
gh issue create --title "<title>" --body-file issue-body.md
```

- Workflow, policy, or template work:

```text
pwsh -File tools/New-IssueBody.ps1 -Template workflow-policy-agent-ux -OutputPath issue-body.md
gh issue create --title "<title>" --body-file issue-body.md
```

## Open A PR With The Template Helpers

- Default agent-maintenance flow:

```text
pwsh -File tools/Branch-Orchestrator.ps1 -Issue <number> -Execute
```

- Workflow or policy change flow:

```text
pwsh -File tools/Branch-Orchestrator.ps1 -Issue <number> -Execute -PRTemplate workflow-policy
```

- Manual body generation without opening the PR yet:

```text
pwsh -File tools/New-PullRequestBody.ps1 -Template human-change -Issue <number> -OutputPath pr-body.md
gh pr create --title "<title>" --body-file pr-body.md
```

## Re-run Orchestrated With Same Inputs

- Copy `strategy`, `include_integration`, and `sample_id` from the previous run's "Run Provenance" block (or choose new
  values).
- Paste this as a new PR comment:

```text
/run orchestrated strategy=<single|matrix> include_integration=<true|false> sample_id=<same-or-new-id>
```

Notes:

- Prefer `strategy=single` under typical load; use `matrix` when runners are idle.
- Re-using the same `sample_id` links runs for easier comparison and can help idempotency.
- If you omit `sample_id`, the dispatcher will generate one automatically.

## Quick Variants

- Single (deterministic chain):

```text
/run orchestrated strategy=single include_integration=true sample_id=<id>
```

- Matrix (parallel categories):

```text
/run orchestrated strategy=matrix include_integration=true sample_id=<id>
```
