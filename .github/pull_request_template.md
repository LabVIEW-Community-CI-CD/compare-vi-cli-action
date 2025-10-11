# Summary

Briefly describe the changes.

## Changes

- [ ] Updated action.yml logic
- [ ] Updated README/docs
- [ ] Updated workflows

## Testing

- [ ] Unit tests passed (Pester tests workflow)
- [ ] Ran Test (mock) on windows-latest and it passed
- [ ] Ran Smoke on self-hosted Windows and recorded exit codes
- [ ] Verified outputs (`diff`, `exitCode`, `cliPath`, `command`) and step summary
- [ ] Checked toggle manifest digest (`session-index.v2.json` / dashboard) matches expected profiles

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
