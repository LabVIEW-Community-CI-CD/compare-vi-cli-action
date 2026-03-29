<!-- markdownlint-disable-next-line MD041 -->
# Minimal Adopter Contract

This document defines the minimum contract for a downstream team adopting
`compare-vi-cli-action`.

## Supported use cases

- compare two LabVIEW `.vi` files through the published composite action
- run the maintained manual compare workflows described in [`README.md`](../README.md)
- consume released versions from the active supported release line

## Required infrastructure

- GitHub Actions repository context
- self-hosted Windows runner for full compare execution
- maintained LabVIEW installation
- maintained LVCompare installation at the canonical path described in [`CONTRIBUTING.md`](../CONTRIBUTING.md)

Hosted Linux/macOS and non-LabVIEW checks are useful support lanes, but they do
not replace the maintained compare runtime.

## Supported consumer entrypoints

- [`action.yml`](../action.yml)
- [`README.md`](../README.md)
- [`USAGE_GUIDE.md`](./USAGE_GUIDE.md)

Use these as the authoritative adoption surface before consulting deeper
operator docs.

## Unsupported assumptions

Do not assume:

- every workflow in `.github/workflows/` is part of the public product contract
- internal release conductor, downstream promotion, or standing-priority
  automation is stable for external reuse
- hosted-only execution is sufficient for full compare support
- undocumented workflow lanes are supported consumer APIs

## First successful adoption

A downstream adoption should be considered successful only when:

1. the downstream repo can invoke the supported action or workflow entrypoint
2. the required Windows + LabVIEW + LVCompare runtime is available and healthy
3. a compare run completes and produces the expected diff/no-diff artifacts
4. the downstream team can identify which released version they are pinned to
5. the downstream team knows where to report security or support issues

If those five conditions are not met, the consumer is still in onboarding, not
in stable adoption.
