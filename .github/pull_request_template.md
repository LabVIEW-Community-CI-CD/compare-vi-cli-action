# Summary

Briefly describe the changes.

## Agent Metadata (required for automation-authored PRs)

- Agent ID: `agent/copilot-codex-a`
- Operator: `@svelderrainruiz`
- Reviewer-Required: `@svelderrainruiz`
- Emergency-Bypass-Label: `AllowCIBypass`

> For automation-authored PRs, keep this block populated. Policy checks use it to route reviewer requests and enforce approval. Human-authored PRs may delete this section.

## Changes

- [ ] Updated action.yml logic
- [ ] Updated README/docs
- [ ] Updated workflows

## Testing

- [ ] Unit tests passed (Pester tests workflow)
- [ ] Ran Test (mock) on windows-latest and it passed
- [ ] Ran Smoke on self-hosted Windows and recorded exit codes
- [ ] Verified outputs (`diff`, `exitCode`, `cliPath`, `command`) and step summary

## Documentation

- [ ] README updated (usage, args, troubleshooting)
- [ ] CHANGELOG updated (user-facing changes)
- [ ] Copilot instructions updated if behavior changed

## Checklist

- [ ] CI green (Validate, Pester tests, Test (mock))
- [ ] Tag plan prepared (if releasing)

## Smoke test (optional guidance)

- If you have access to the self-hosted runner with LabVIEW, run `.github/workflows/smoke.yml`.
- Provide inputs, or ensure repo variables exist:
  - `LV_BASE_VI` (no-diff), `LV_HEAD_VI` (diff), `LVCOMPARE_PATH`
