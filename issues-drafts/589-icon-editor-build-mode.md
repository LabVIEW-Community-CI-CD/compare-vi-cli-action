# Issue Draft – Enable full icon-editor build coverage via composites

## Summary
- Extend the new icon-editor composites so they can execute real VI Package builds in CI.
- Keep simulate mode as the default, but provide guardrails (toggle/option) to run `Invoke-IconEditorBuild.ps1` end-to-end.

## Motivation
- The new composites already cover simulation, staging, and compare flows. Building a real VIP locally first and then baking that path into CI gives us higher confidence and faster feedback.
- Real builds ensure staging, artifact uploads, and downstream checks operate on production-ready outputs.

## Implementation plan
1. Draft CI toggles & doc updates
   - Introduce a documented toggle (env var or workflow input) for `ICON_EDITOR_BUILD_MODE=build`.
   - Update README/docs to explain simulation vs build mode and how to run locally.
2. Local validation loop
   - Run `tools/icon-editor/Invoke-IconEditorBuild.ps1` locally to validate the composites’ build path.
   - Confirm staging helper (`stage-artifacts` composite) preserves fixture reports and metadata.
3. CI integration
   - Update `.github/workflows/validate.yml` to support the build toggle (likely manual trigger first).
   - Capture and publish artifacts from the build path; ensure hook parity remains green.
4. Testing
   - Expand Node tests or add Pester coverage around build-mode outputs (manifest, staging summary).
   - Run both simulate and build modes in Validate before closing.

## Open questions
- Should the build toggle be a workflow input, repo variable, or both?
- Do we gate real builds behind manual approval until they are stable?

## Acceptance checklist
- [ ] Documented build-mode flow (local + CI).
- [ ] Validate workflow supports running in build mode.
- [ ] Tests cover composite metadata for build mode.
- [ ] Simulate and build Validate runs green.
