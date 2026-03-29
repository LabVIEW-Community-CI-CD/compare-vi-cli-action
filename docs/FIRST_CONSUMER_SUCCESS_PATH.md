<!-- markdownlint-disable-next-line MD041 -->
# First Consumer Success Path

Use this guide when a downstream team wants the shortest supported path to a
successful adoption of `compare-vi-cli-action` without inheriting the full
maintainer platform.

Start with these checked-in surfaces only:

1. [`README.md`](../README.md)
2. [`USAGE_GUIDE.md`](./USAGE_GUIDE.md)
3. [`MINIMAL_ADOPTER_CONTRACT.md`](./MINIMAL_ADOPTER_CONTRACT.md)

If you need release-train proving, hardening backlog generation, or downstream
promotion automation, move to
[`DOWNSTREAM_RELEASE_TRAIN_ONBOARDING.md`](./DOWNSTREAM_RELEASE_TRAIN_ONBOARDING.md)
after this first-success path is complete.

## Prerequisites

Before starting, confirm:

- the downstream repository can run GitHub Actions
- a self-hosted Windows runner is available for compare execution
- LabVIEW is installed and healthy on that runner
- LVCompare is installed at the maintained canonical path
- the downstream team knows which released compare-vi version it intends to pin

## Five-step success path

### 1. Pin a supported release

Adopt a supported `v0.6.x` release tag or another explicitly supported release
identifier from the active support line. Do not start from an unpublished branch
head or from maintainer-only workflow internals.

### 2. Prove the runtime

Confirm the downstream runner can satisfy the maintained compare prerequisites
described in [`CONTRIBUTING.md`](../CONTRIBUTING.md):

- self-hosted Windows execution
- LabVIEW available and healthy
- LVCompare available at the canonical path

Hosted Linux/macOS checks can support the repo, but they do not replace this
runtime proof.

### 3. Run one supported entrypoint

Choose one supported consumer-facing entrypoint:

- the composite action contract in [`action.yml`](../action.yml)
- the manual compare workflow path described in [`README.md`](../README.md)

Do not use the full maintainer workflow estate as the starting point for a new
consumer.

### 4. Verify the result and artifacts

A first run is only successful when the downstream team can confirm:

- the workflow completed without infrastructure ambiguity
- the compare result was readable as diff or no-diff
- the expected artifacts or workflow summary were available
- the pinned release identity is visible in the downstream configuration

### 5. Record the support path

Before calling the adoption stable, the downstream team must know:

- where support and security issues are reported:
  [`SECURITY.md`](../SECURITY.md)
- where the product boundary is defined:
  [`SUPPORTED_PRODUCT_BOUNDARY.md`](./SUPPORTED_PRODUCT_BOUNDARY.md)
- when to escalate into deeper downstream proving:
  [`DOWNSTREAM_RELEASE_TRAIN_ONBOARDING.md`](./DOWNSTREAM_RELEASE_TRAIN_ONBOARDING.md)

## Exit criteria

Treat the consumer as successfully onboarded only when all five are true:

| Check | Evidence |
| --- | --- |
| Supported release pin is explicit | Downstream workflow/action reference points to a supported release identifier. |
| Runtime is real, not assumed | Self-hosted Windows + LabVIEW + LVCompare proof exists. |
| Supported entrypoint runs | Consumer can invoke the action or documented manual workflow path. |
| Result is inspectable | Compare summary and artifacts are readable without maintainer-only context. |
| Support path is known | Team knows the product boundary and security/support reporting route. |

If any of these checks fail, the consumer is still in onboarding.

## When to escalate to the full onboarding runbook

Use the deeper downstream onboarding flow when you need any of the following:

- pilot stabilization across repeated remediation cycles
- protected-environment or branch-check evaluation
- downstream hardening issue creation
- promotion scorecards or downstream/develop proving rails
- wake adjudication, monitoring injection, or investment accounting
