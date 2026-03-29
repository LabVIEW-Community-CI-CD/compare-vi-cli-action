<!-- markdownlint-disable-next-line MD041 -->
# v0.6.6 Release Evidence

This document records the immutable release and certified-consumer evidence for
`v0.6.6`.

## Release identity

- release: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/releases/tag/v0.6.6`
- published at: `2026-03-29T22:32:09Z`
- target commit: `24ddb012d897fb8c17e63a9f5973dcc71a68147b`
- annotated tag object: `1b160fb279d5e5aaa8f2b0801d99cc0567f19b98`
- release status:
  - `draft=false`
  - `immutable=true`

## Authoritative release workflow evidence

- release conductor:
  - run: `23720581794`
  - url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23720581794`
- initial publish:
  - run: `23720604131`
  - url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23720604131`
- downstream proving repair for the shipped source SHA:
  - run: `23720719499`
  - url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23720719499`
- protected `verify-existing-release` replay:
  - run: `23720737438`
  - url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23720737438`
  - result: `completed/success`

## Published assets

The immutable release currently carries:

- `comparevi-cli-v0.6.6-win-x64-fxdependent.zip`
- `comparevi-cli-v0.6.6-win-x64-selfcontained.zip`
- `comparevi-cli-v0.6.6-linux-x64-fxdependent.tar.gz`
- `comparevi-cli-v0.6.6-linux-x64-selfcontained.tar.gz`
- `comparevi-cli-v0.6.6-osx-x64-fxdependent.tar.gz`
- `comparevi-cli-v0.6.6-osx-x64-selfcontained.tar.gz`
- `CompareVI.Tools-v0.6.6.zip`
- `SHA256SUMS.txt`
- `sbom.spdx.json`
- `provenance.json`

## Certified consumer ring

Current certified downstream consumer baseline:

- repository: `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`
- branch: `develop`
- certified action pin: `LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.6.6`

Rollout evidence:

- consumer repin PR:
  - PR: `#51`
  - url: `https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/pull/51`
  - merged at: `2026-03-29T22:51:06Z`
  - merge commit: `34949deeca6db7d887e1c5b425dc7173b1de6b5b`
- consumer smoke/governance proof:
  - template smoke run: `23720949271`
  - url: `https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/actions/runs/23720949271`
  - result: required compare-consumer smoke and render matrix all `success`
  - policy guard run: `23720949290`
  - promotion contract run: `23720949261`
- upstream hosted drift proof:
  - run: `23721023554`
  - url: `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23721023554`
  - result: `completed/success`

Local operator replay on 2026-03-29 also produced:

- onboarding report `status=pass`
- `requiredFailCount=0`
- `warningCount=0`
- onboarding success summary `repositoriesPassing=1`, `totalWarnings=0`

## Ongoing drift visibility

`v0.6.6` is the supported stable consumer baseline until a later stable `v0.6.x`
release supersedes it.

The standing drift detector for the certified consumer ring is:

- workflow: `.github/workflows/downstream-onboarding-feedback.yml`
- cadence: manual plus weekly schedule
- repo topology source: `tools/policy/downstream-repo-graph.json`
- target consumer policy source:
  `tools/priority/delivery-agent.policy.json`

If the certified consumer ring moves or expands, update this document, the repo
graph policy, and the consumer rollout evidence in the same change.
