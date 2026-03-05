# Issue Draft – Decouple Icon Editor Build Steps into Composite Actions

## Summary
- Convert the icon editor build and artifact staging steps into reusable composite actions so the Validate workflow and any follow-on automation can share the same logic without inline scripts.
- Ensure the composite wraps the existing PowerShell entry points (`Simulate-IconEditorBuild.ps1`, `Stage-BuildArtifacts.ps1`) and exposes parameters for future Linux/self-hosted lanes.

## Motivation
- Current jobs embed multiple script invocations inline (`pwsh -File tools/icon-editor/...`), which makes reuse across workflows and repositories cumbersome.
- Composite actions simplify CI maintenance, reduce boilerplate in `.github/workflows/validate.yml`, and allow consumers to call the staging/build logic with consistent inputs.
- Aligns with recent work on splitting stage/upload steps for better artifact handling and hook parity.

## Proposed scope
1. Add a composite action (e.g., `.github/actions/icon-editor/build`) that runs the simulate/build step and captures outputs (manifest path, artifact list, etc.).
2. Add a second composite (e.g., `.github/actions/icon-editor/stage-artifacts`) responsible for invoking `Stage-BuildArtifacts.ps1` and emitting metadata for downstream jobs.
3. Update `validate.yml` to call these composites, preserving existing environment guards, tokens, and result paths.
4. Refresh documentation in `docs/ICON_EDITOR_PACKAGE.md` (or a dedicated CI guide) to note the new composites and their parameters.
5. Extend tests:
   - Node tests to verify action metadata (inputs/outputs).
   - Pester coverage to ensure composites still preserve fixture reports and manifest data.

## Out of scope
- Switching Validate to real builds or enabling Linux lanes (tracked separately).
- Changing tool outputs beyond wrapping them in composites.

## Open questions
- Do we need a composite for the compare step as well, or should that remain scripted until Linux support is ready?
- Should the composite expose a flag to skip resource overlay for non-default fixtures?

## Acceptance checklist
- [ ] Composite actions checked into `.github/actions/icon-editor/*` with README snippets.
- [ ] Validate workflow uses the composites without duplicating script logic.
- [ ] Fixture reports/artifacts still surface for hook parity (`tools/PrePush-Checks.ps1` passes).
- [ ] Tests updated (Node + Pester) and passing locally + CI.
- [ ] Docs updated to explain new composite usage.
