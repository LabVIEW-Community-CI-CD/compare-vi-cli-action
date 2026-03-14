# Human Go/No-Go Decision Contract

Issue [#981](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/981)
defines the contract slice for epic
[#964](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/964).
Issue [#982](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/982)
implements the manual workflow, and issue
[#980](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/980)
adds the deterministic discovery helper that future agents use before starting
new work.

## Intended Workflow Surface

- Workflow name: `Human Go/No-Go Feedback`
- Workflow path: `.github/workflows/human-go-no-go-feedback.yml`
- Trigger: `workflow_dispatch`

## Dispatch Inputs

Required inputs:

- `target_context`
  Short identifier for the work area under review.
- `decision`
  Exact choice: `go` or `nogo`.
- `feedback`
  Free-form human feedback that future agents can cite directly.
- `recommended_action`
  Exact choice: `continue`, `revise`, or `pause`.

Optional inputs:

- `target_issue_url`
  Related issue URL when the decision is tied to a specific issue.
- `target_pull_request_url`
  Related pull request URL when the decision is tied to a specific PR head.
- `target_run_id`
  Workflow run id when the decision is tied to a specific run.
- `evidence_url`
  Supporting artifact, run, or comment URL.
- `transcribed_for`
  Human identity when an agent is transcribing another operator's decision.
- `next_iteration_seed`
  Optional seed text for the next iteration.

Implementation note:

- `recordedBy` is derived from `github.actor` so the workflow stays within
  GitHub's `workflow_dispatch` 10-input limit.
- `target.ref` defaults to `target_context` when no separate ref is supplied.

## Output Contract

The workflow emits a machine-readable JSON payload that conforms to
[../schemas/human-go-no-go-decision-v1.schema.json](../schemas/human-go-no-go-decision-v1.schema.json)
with:

- schema id `human-go-no-go-decision@v1`
- artifact name `human-go-no-go-decision`
- primary report path `tests/results/_agent/handoff/human-go-no-go-decision.json`
- optional event stream path
  `tests/results/_agent/handoff/human-go-no-go-events.ndjson`

The payload must capture:

- workflow identity
- target repository, context, ref, and optional run id
- decision value `go` or `nogo`
- feedback text
- recorder/transcription identity
- linked run/evidence URLs
- next-iteration recommendation and seed text

## Discovery Rule

Future agents should resolve the latest human disposition through:

- `node tools/npm/run-script.mjs priority:human-go-no-go:latest`

The helper writes:

- `tests/results/_agent/handoff/human-go-no-go-latest.json`

Invoke it with `--fail-on-nogo` at startup/handoff boundaries when a fresh
human `go` is required before more implementation work can proceed.
