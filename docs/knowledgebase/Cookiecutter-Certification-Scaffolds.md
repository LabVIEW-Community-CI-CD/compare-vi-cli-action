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

## Hosted Bootstrap Proof

`#1494` promotes the local wrapper into a hosted proof surface instead of
copying cookiecutter install logic into ad hoc workflows.

Local proof entrypoint:

```powershell
node tools/npm/run-script.mjs priority:scaffold:cookiecutter:proof
```

Hosted proof workflow:

- `.github/workflows/cookiecutter-bootstrap.yml`
- runner matrix:
  - `ubuntu-latest`
  - `windows-latest`
- pinned runtime bootstrap:
  - `actions/setup-node@v6` + `npm ci`
  - `actions/setup-python@v6` with `python-version: '3.12'`

The hosted proof runs `tools/Test-CompareVICookiecutterBootstrap.ps1`, which:

- exercises the shared scaffold wrapper on both hosted OS planes
- validates the pinned `cookiecutter==2.7.1` runtime through the wrapper
- emits a proof receipt at
  `tests/results/_agent/cookiecutter-bootstrap/<platform>/comparevi-cookiecutter-bootstrap-proof.json`
- uploads both proof receipts and generated scaffold outputs for review

The hosted conveyor now has a second, template-consumer proof lane:

- pinned template dependency:
  - `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate@v0.1.0`
- checked-in deterministic context:
  - `tests/fixtures/cookiecutter/template-context.json`
- hosted Ubuntu execution plane:
  - `ghcr.io/labview-community-ci-cd/comparevi-tools:latest`
- helper entrypoint:
  - `node tools/npm/run-script.mjs priority:template:render:container`
- deterministic render mode:
  - `priority:template:render:container` reads `tools/policy/template-dependency.json`
  - the helper uses the pinned template dependency, pinned `cookiecutter==2.7.1`,
    and the checked-in deterministic template context
- generated consumer output root:
  - `tests/results/_agent/cookiecutter-bootstrap/<platform>/pinned-template-render`
- dependency receipt:
  - `tests/results/_agent/cookiecutter-bootstrap/<platform>/pinned-template-dependency.json`
- verification report:
  - `tests/results/_agent/promotion/template-agent-verification-report.json`

Hosted Ubuntu renders the pinned template dependency inside the tools image.
Hosted Windows verifies the same pinned release host-native so the conveyor belt
has both a container-backed render plane and a mirrored verification plane. A
follow-on hosted verification job then emits the machine-readable template-agent
verification report so downstream proving and the template pivot gate consume
the same pinned dependency provenance.

## Natural Follow-Ons

- mirror the template family into `svelderrainruiz/cookiecutter`
- carry the same scaffold surface into `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate@v0.1.0`
- use the hosted bootstrap proof as the consumer-proving install contract for
  Linux and Windows lanes
