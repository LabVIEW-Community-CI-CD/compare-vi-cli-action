<!-- markdownlint-disable-next-line MD041 -->
# Supported Product Boundary

This repository is a platform repo that publishes a reusable compare surface.
Consumers should not assume every checked-in workflow, runbook, or proving lane
is part of the supported public product.

## Public supported surface

Treat these as the primary supported consumer-facing contract:

- the composite action contract in [`action.yml`](../action.yml)
- the core usage and invocation guidance in [`README.md`](../README.md)
- the consumer-focused options and examples in [`USAGE_GUIDE.md`](./USAGE_GUIDE.md)
- the public security reporting path in [`SECURITY.md`](../SECURITY.md)
- tagged and released versions that match the active supported release line

For most adopters, this is the product.

## Maintainer and operator platform surface

The repository also carries extensive internal operating machinery. These
surfaces are maintained for platform stewardship and release governance, not as
stable external APIs:

- release operations and release conductor flows
- downstream onboarding, promotion, and proving rails
- standing-priority, queue, and policy automation
- internal runbooks, handoff artifacts, and operator feedback loops
- validation orchestration that exists to maintain the platform itself

These surfaces may change faster than the public action contract and should be
treated as maintainer/operator internals unless a document explicitly says
otherwise.

## Experimental and proving surfaces

Some checked-in content exists to prove, redesign, or evaluate future operating
models rather than define the current public contract. Examples include:

- redesign plans
- proving manifests and scorecards
- diagnostics harnesses
- pilot or downstream evaluation lanes

These are valuable engineering assets, but downstream consumers should not read
them as a promise of stable supported behavior.

## How to read the repo

If you are adopting the product, start here and stay narrow:

1. [`README.md`](../README.md)
2. [`USAGE_GUIDE.md`](./USAGE_GUIDE.md)
3. [`SECURITY.md`](../SECURITY.md)
4. [`CONTRIBUTING.md`](../CONTRIBUTING.md) when you need the maintained runtime prerequisites

Only move into the broader docs and workflow estate when you are maintaining or
extending the platform itself.
