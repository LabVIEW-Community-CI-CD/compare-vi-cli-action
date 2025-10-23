<!-- markdownlint-disable-next-line MD041 -->
# Markdown Lint Backlog Plan (relates to #88)

This plan documents how we will clear the existing Markdown lint backlog while keeping PRs green and
developer experience smooth.

## Policy

- Keep `node tools/npm/run-script.mjs lint:md:changed` as the only blocking check for PRs. Full sweeps remain
  notice-only.
- Treat `MD041` as a warning (already configured); do not block merges on it.
- Honor the 120-character guideline (`MD013`) for prose; allow exceptions for code blocks and tables (already
  configured).

## Priorities

- Hotspots: fix the highest-violation files first (e.g., `.copilot-instructions.md`, long-form design docs).
- Generated/long-history files (e.g., `CHANGELOG.md`) stay suppressed until the end.

## Workflow

1. Inventory
   - Run `node tools/npm/run-script.mjs lint:md` locally to capture the current error list.
   - Group by rule and file; select the top 5 offenders.
2. Quick wins (1-2 passes)
   - `MD012` (consecutive blank lines): normalize to a maximum of 2.
   - `MD013` (line length): reflow paragraphs to <=120 chars; skip tables/code blocks (already excluded).
   - Add an H1 to docs missing a top-level heading when appropriate instead of suppressing.
3. Suppress where justified
   - If a file is instructional metadata or has intentional formatting (e.g., `.copilot-instructions.md`), either:
     - Add a local disable comment for the specific rule(s), or
     - Add the path to `.markdownlintignore` with rationale in a comment.
4. Validate
   - Re-run `node tools/npm/run-script.mjs lint:md` and ensure the error count steadily declines.
   - Land fixes in small, focused commits referencing `#88`.

## Acceptance

- Backlog reduced to zero `MD012` across the repo.
- All actively maintained docs free of `MD013`; remaining violations limited to justified exceptions.
- CI continues to use `lint:md:changed` as a required check; full sweeps report but do not block.

