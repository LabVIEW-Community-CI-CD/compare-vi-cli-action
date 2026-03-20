# {{ cookiecutter.pack_slug }}

This scaffold is a reviewable starter for a pre-push known-flag scenario pack.

Generated files:

- `scenario-pack.json`
- `docs/{{ cookiecutter.pack_slug }}.md`
- `tests/{{ cookiecutter.pack_slug }}.Tests.ps1`
- `cookiecutter-replay.json`

Promotion path:

1. Refine the scenario content.
2. Merge the final pack into `tools/policy/prepush-known-flag-scenarios.json`.
3. Add or adapt focused tests in `tests/PrePushKnownFlagScenarioReport.Tests.ps1`.
4. Update the knowledgebase if the new pack changes certification policy.
