# Release VI History Profile Manifest

This document defines the manifest used by release-time VI history review profile selection.

## Files

- Manifest: `configs/release-vi-history-profiles.json`
- Schema: `docs/schemas/release-vi-history-profiles-v1.schema.json`

## Selection Rules

- Requested profile comes from repository variable `RELEASE_VI_HISTORY_PROFILE`.
- If the variable is empty, the workflow uses `defaultProfile` from the manifest.
- If the variable references an unknown profile, the workflow falls back to `defaultProfile`.

## Profile Expansion

The workflow expands a selected profile by forming a matrix cross-product:

- each `osTarget` item (`id`, `runner`, `image`)
- each selected profile `scenario` (`id`, `flags`)

Each generated matrix row includes:

- `os` (runner label)
- `os_label` (`linux` or `windows`)
- `image`
- `scenario`
- `flags`

## Built-in Profiles

- `smoke`: baseline only
- `history-core`: baseline + noattr + layout-and-position (default)
- `full`: history-core plus front-panel-only and block-diagram-only
