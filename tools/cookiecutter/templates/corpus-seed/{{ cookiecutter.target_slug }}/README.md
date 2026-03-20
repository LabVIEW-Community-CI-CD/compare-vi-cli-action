# {{ cookiecutter.target_slug }}

This scaffold is a reviewable starter for a headless certification corpus seed.

Generated files:

- `sample-target.json`
- `docs/{{ cookiecutter.target_slug }}.md`
- `tests/{{ cookiecutter.target_slug }}.Tests.ps1`
- `cookiecutter-replay.json`

Promotion path:

1. Refine the public evidence and local notes.
2. Merge the final target into `fixtures/headless-corpus/sample-vi-corpus.targets.json`.
3. Extend `tests/Invoke-HeadlessSampleVICorpusEvaluation.Tests.ps1` if the new
   seed changes admission expectations.
