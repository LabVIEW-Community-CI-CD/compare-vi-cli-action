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

## Validation

- schema: `docs/schemas/release-vi-history-migration-v1.schema.json`
- npm script: `release:vi-history:migration:schema`
- local gate: `tools/PrePush-Checks.ps1`