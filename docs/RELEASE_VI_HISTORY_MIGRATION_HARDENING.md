# Release VI History Migration Hardening

This document defines the Phase 8 migration controls for release VI history review.

## Goals

- provide backward compatibility for older `scenario-summary.json` payload shapes,
- support rollout control for policy enforcement (`observe` → `soft` → `hard`),
- keep migration behavior deterministic and auditable.

## Compatibility Normalization

Script: `tools/Normalize-ReleaseVIHistorySummaries.ps1`

Usage in workflow:

- scan downloaded `scenario-summary.json` files,
- map legacy aliases to canonical contract fields,
- write normalized payloads in-place before index/policy steps.

Canonical fields restored from aliases:

- `os` (`osLabel`, `platform`)
- `scenario` (`scenarioId`)
- `flags` (`compareFlags`)
- `status` (`captureStatus`)
- `gateOutcome` (`gate`, `policyOutcome`)
- `resultClass` (`result`, `classification`)
- `compareExit` (`compareExitCode`, `exitCode`)
- `reportExists` (`hasReport`)

## Rollout Gate Modes

Config file: `configs/release-vi-history-migration.json`

- `observe`: do not fail release index on policy `fail`; record warning and continue.
- `soft`: same fail behavior as `observe` with stronger warning semantics for adoption.
- `hard`: enforce policy `fail` as job failure (current strict behavior).

Default for initial Phase 8 rollout is `hard` to preserve current release behavior.

## Tag-Class Adoption Rules (Phase 8 Slice)

The migration config supports tag-class-specific enforcement overrides:

- `tagClassEnforcement.rc`: effective mode for prerelease tags (for example `v0.6.0-rc.*`).
- `tagClassEnforcement.stable`: effective mode for stable release tags.

Current defaults:

- RC tags use `soft` enforcement.
- Stable tags use `hard` enforcement.

Evaluation order in workflow:

1. Start from `policyEnforcementMode` (fallback/default).
2. Determine tag class from `github.ref_name` (`rc` if tag contains `-`, otherwise `stable`).
3. If `tagClassEnforcement.<tagClass>` exists, it overrides the fallback.

The generated policy summary includes `tagClass`, `enforcementMode`, and `enforcementSource` for auditability.

## Validation

- schema: `docs/schemas/release-vi-history-migration-v1.schema.json`
- npm script: `release:vi-history:migration:schema`
- local gate: `tools/PrePush-Checks.ps1`