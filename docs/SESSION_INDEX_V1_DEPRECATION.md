<!-- markdownlint-disable-next-line MD041 -->
# Session Index v1 Deprecation Policy

## Announcement

As of **2026-03-04**, Session Index v1 enters deprecation mode.

- v1 is frozen: no new fields or semantic expansions.
- v2 is the primary contract for all critical consumers.
- v1 remains temporary compatibility only during the deprecation window.

## Deprecation window

The window remains open until all of the following are true:

1. `session-index-v2-contract` promotion gate is ready (`burnIn.promotionReady = true`).
2. Critical consumer migration matrix is complete and verified:
   - see `docs/SESSION_INDEX_V2_CONSUMER_MATRIX.md`.
3. No consumer regression for 5 consecutive upstream runs.
4. Maintainers approve v1 removal in a standing-priority PR.

## Freeze rules (effective immediately)

- Do not add new fields to `docs/schemas/session-index-v1.schema.json`.
- Do not add new workflow consumers that require `session-index.json`.
- New telemetry fields must target v2 schema and v2 readers.

## Removal checklist (v1 cutover)

- [ ] Remove v1 generation from producer paths/workflows.
- [ ] Remove v1 fallback from critical consumers.
- [ ] Remove v1 schema validation from CI jobs.
- [ ] Update branch-protection required checks if names/behavior changed.
- [ ] Update docs and release notes to state v2-only status.
- [ ] Publish final cutover report with evidence links.

## Evidence package required for cutover

- Final consumer readiness matrix snapshot.
- `session-index-v2-contract` artifact evidence (`consecutiveSuccess`, `promotionReady`).
- 5-run no-regression evidence for critical consumers.
- CI evidence showing no required path depends on `session-index.json`.

## Temporary compatibility note

During deprecation, references to `session-index.json` are allowed only where required
for controlled fallback or migration bookkeeping. Any new fallback usage must include a
justification and removal target in the same PR.
