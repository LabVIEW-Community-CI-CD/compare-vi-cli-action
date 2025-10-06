# Remove Base.vi/Head.vi fallback & expand guard scope

**Labels:** migration, breaking-change-warning, v0.5.0

## Summary

Finalize the artifact naming migration by removing legacy `Base.vi` / `Head.vi` fallback logic and expanding guard tests to scripts and documentation (currently only module scope guarded). Enforce exclusive usage of `VI1.vi` / `VI2.vi` starting in v0.5.0.

## Rationale

- Prevent silent regression to deprecated names.
- Reduce branching logic and test complexity.
- Clarify public guidance (one canonical naming convention).

## Scope

- Remove fallback resolution blocks (`@('VI1.vi','Base.vi')` etc.) in scripts and tests.
- Extend existing naming guard test or add new guard to scan scripts + docs (allowlist historical CHANGELOG sections).
- Emit clear failure message if legacy names supplied.
- Update README & runbook: remove transitional migration note; add “Removal Completed” note.

## Non-Goals

- Renaming schema fields (`basePath`, `headPath`).
- Backporting removal to v0.4.x.

## Acceptance Criteria

- [ ] No occurrences of `Base.vi` / `Head.vi` outside CHANGELOG historical entries.
- [ ] Guard test fails if legacy names reintroduced (docs or scripts) excluding allowlist.
- [ ] Fallback code deleted; tests updated accordingly.
- [ ] Release notes draft for v0.5.0 documents removal + upgrade path.
- [ ] CI green (unit + integration) with new guard coverage.

## Migration Guidance (for release notes)

1. Rename legacy artifacts to `VI1.vi` / `VI2.vi`.
2. Update workflows referencing those filenames.
3. Confirm no environment variables rely on old names (env variable keys unchanged).

## Risk Mitigation

- Provide pre-release (rc) tag with warning elevated to error to validate ecosystem readiness.
- Include GitHub search snippet in release notes for downstream repo auditing.

## Follow-Up

- After removal, consider introducing optional `artifactLabelBase` / `artifactLabelHead` outputs if human-friendly aliasing needed (separate issue if pursued).
