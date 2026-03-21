<!-- markdownlint-disable-next-line MD041 -->
# Unattended Delivery Daemon Debt Register

This register only keeps daemon debt that still threatens one of these
outcomes on current `develop`:

- RC determinism
- standing reconciliation
- four-lane utilization
- consumer-proving reliability

If a seam no longer needs an active follow-up issue, keep it here only when it
still explains a compatibility read or older receipt family.

## Active Debt

### Standing reconciliation

- Risk: merge finalization can complete while automatic standing reconciliation
  falls back to a warning or deterministic retry.
- Current seam: bootstrap warns that the router backstop is skipped when
  `tests/results/_agent/issue/router.json` cannot be parsed, so a completed
  standing lane can stay visible until the next reconciliation pass.
- Concrete evidence surfaces:
  - code: `tools/priority/delivery-agent.mjs`,
    `tools/priority/reconcile-standing-after-merge.mjs`,
    `tools/priority/bootstrap.ps1`
  - receipts: `tests/results/_agent/runtime/delivery-agent-state.json`,
    `tests/results/_agent/issue/router.json`,
    `tests/results/_agent/issue/no-standing-priority.json`
  - tests: `tools/priority/__tests__/runtime-supervisor.test.mjs`
- Follow-up issue: #1643

No other open daemon debt on current `develop` crossed the follow-up threshold
for RC determinism, four-lane utilization, or consumer-proving reliability.

## Retired But Explicit Compatibility Debt

### Runtime-state naming compatibility

- Why it stays documented: readers may still encounter `runtime-state.json` as
  a legacy fallback, but primary daemon/runtime reads and writes are being
  normalized onto `delivery-agent-state.json`.
- Concrete evidence surfaces:
  - code: `packages/runtime-harness/index.mjs`,
    `tools/priority/queue-supervisor.mjs`,
    `tools/priority/throughput-scorecard.mjs`,
    `tools/priority/lib/delivery-agent-common.ts`
  - receipts: `tests/results/_agent/runtime/delivery-agent-state.json`,
    `tests/results/_agent/runtime/runtime-state.json`
  - tests: `tools/priority/__tests__/delivery-agent-manager-contract.test.mjs`,
    `tools/priority/__tests__/throughput-scorecard.test.mjs`
- Retirement issue: #1634
