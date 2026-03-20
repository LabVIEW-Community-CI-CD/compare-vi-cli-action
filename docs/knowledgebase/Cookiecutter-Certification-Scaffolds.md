# Cookiecutter Certification Scaffolds

`compare-vi-cli-action` now carries a small cookiecutter catalog for the
deterministic asset classes that keep showing up in certification work:

- pre-push known-flag scenario packs
- headless certification corpus seeds

The goal is not to generate checked-in contract files automatically. The goal is
to generate a reviewable scaffold that already matches repo naming, layout, and
schema expectations closely enough that only scenario content needs editing.

## Entry Point

Use the wrapper instead of calling cookiecutter directly:

```powershell
pwsh -NoLogo -NoProfile -File tools/New-CompareVICookiecutterScaffold.ps1 -ListTemplates
```

Generate a scenario-pack scaffold:

```powershell
pwsh -NoLogo -NoProfile -File tools/New-CompareVICookiecutterScaffold.ps1 `
  -TemplateId scenario-pack `
  -ContextPath .\scenario-pack.context.json `
  -NoInput
```

Generate a corpus-seed scaffold:

```powershell
pwsh -NoLogo -NoProfile -File tools/New-CompareVICookiecutterScaffold.ps1 `
  -TemplateId corpus-seed `
  -ContextPath .\corpus-seed.context.json `
  -NoInput
```

The wrapper:

- resolves Python 3
- bootstraps a pinned local cookiecutter runtime under
  `tests/results/_agent/cookiecutter-runtime`
- invokes the multi-template catalog via `--directory`
- keeps repo-local output under `tests/results/_agent/cookiecutter-scaffolds`
- writes a receipt at `comparevi-cookiecutter-scaffold.json`

## Template Families

### `scenario-pack`

Emits a starter scaffold for a pre-push known-flag scenario pack:

- `scenario-pack.json`
- `README.md`
- `docs/<slug>.md`
- `tests/<slug>.Tests.ps1`
- `cookiecutter-replay.json`

The JSON is schema-pinned and shaped like the repo's checked-in
`prepush-known-flag-scenario-packs/v1` contract, but it is emitted as a
standalone scaffold for review instead of editing the live contract in place.

### `corpus-seed`

Emits a starter scaffold for a headless certification corpus seed:

- `sample-target.json`
- `README.md`
- `docs/<slug>.md`
- `tests/<slug>.Tests.ps1`
- `cookiecutter-replay.json`

The template uses change kind to pick the coherent rendering strategy:

- `modified` -> `CreateComparisonReport`
- `added` / `deleted` -> `PrintToSingleFileHtml`

## Why Cookiecutter Here

The catalog intentionally uses the cookiecutter features that help agents and
maintainers the most:

- hooks for pre/post generation validation
- `--directory` so one template root can host multiple comparevi templates
- deterministic replay files for regeneration
- human-readable `__prompts__`
- `--no-input` compatibility for unattended agent generation

## Boundaries

- Generated scaffolds are not authoritative by themselves.
- Promotion into checked-in contracts still happens through normal review.
- Repo-local output is constrained to the dedicated scaffold results root to
  avoid accidental pollution of git-tracked source trees.

## Natural Follow-Ons

- mirror the template family into `svelderrainruiz/cookiecutter`
- carry the same scaffold surface into `LabviewGitHubCiTemplate`
- install the pinned cookiecutter runtime in hosted Linux and hosted Windows
  consumer-proving lanes once the local contract settles
