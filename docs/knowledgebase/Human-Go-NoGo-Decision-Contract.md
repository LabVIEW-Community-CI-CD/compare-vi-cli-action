# Human Go-NoGo Decision Contract

Issue [#981](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/981)
defines the contract slice for epic
[#964](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/964).
This page pins the future manual workflow inputs and the machine-readable output
shape before the workflow itself is implemented.

## Intended Workflow Surface

- Workflow name: `Human Go/No-Go Feedback`
- Workflow path: `.github/workflows/human-go-no-go-feedback.yml`
- Trigger: `workflow_dispatch`

## Dispatch Inputs

Required inputs:

- `target_context`
  Short identifier for the work area under review.
- `target_ref`
  Branch, ref, or comparable execution target.
- `decision`
  Exact choice: `go` or `nogo`.
- `feedback`
  Free-form human feedback that future agents can cite directly.

Optional inputs:

- `related_issue_url`
  Related issue URL when the decision is tied to a specific issue.
- `related_pull_request_url`
  Related pull request URL when the decision is tied to a specific PR head.
- `target_run_id`
  Workflow run id when the decision is tied to a specific run.
- `evidence_url`
  Supporting artifact, run, or comment URL.
- `recorded_by`
  Human or agent identity that triggered the workflow.
- `transcribed_for`
  Human identity when an agent is transcribing another operator's decision.

## Output Contract

The workflow will later emit a machine-readable JSON payload that conforms to
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

## Consumer Rule

Future-agent discovery and startup wiring is tracked separately by issue
[#980](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/980).
This contract only fixes the input/output shape and the durable report paths
that later helpers must honor.
