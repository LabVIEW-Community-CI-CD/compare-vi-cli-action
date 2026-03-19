<!-- markdownlint-disable-next-line MD041 -->
# Cross-Repo VI History Capture

This note records the supported steps for exercising the Compare-VIHistory
tooling against an external repository. The canonical local-first downstream
adoption proof uses `LabVIEW-Community-CI-CD/labview-icon-editor-demo` on
`develop`, while the legacy one-off module sample below still uses
`svelderrainruiz/labview-icon-editor`, which is the active downstream icon
editor repository.

## Prerequisites

- Git history with the target VI available locally.
- LVCompare/LabVIEW installed (the same requirements as the action repo).
- Access to the Compare-VI tooling (`Compare-VIHistory.ps1`,
  `Compare-RefsToTemp.ps1`, and supporting modules).
- Hosted GitHub runner flows that use the bundle-backed NI Linux adapter also
  rely on `Run-NILinuxContainerCompare.ps1` plus its adjacent runtime support
  scripts from the same bundle.

## Preferred release-asset path

The release pipeline publishes an immutable `CompareVI.Tools` zip bundle on
each tagged release. For cross-repo usage, prefer downloading that asset
instead of checking out this repository.

Treat the backend release tag as the authoritative pin. The bundle's embedded
PowerShell manifest version is informative, but the supported consumer contract
is the reviewed release tag plus its published checksum/provenance.

1. **Download the pinned release asset**

   ```powershell
   $tag = 'v1.0.0'
   $asset = 'CompareVI.Tools-v<release-version>.zip'
   $uri = "https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/releases/download/$tag/$asset"
   Invoke-WebRequest -Uri $uri -OutFile $asset
   ```

2. **Verify the archive**

   Download the matching `SHA256SUMS.txt` from the same release and confirm the
   hash for the zip before extracting it.

3. **Extract and inspect metadata**

   ```powershell
   Expand-Archive -Path .\CompareVI.Tools-v<release-version>.zip -DestinationPath .\comparevi-tools
   Get-Content .\comparevi-tools\CompareVI.Tools-v<release-version>\comparevi-tools-release.json
   ```

   The embedded metadata records the module version, repository source,
   source ref/tag, source SHA, the file closure for the bundle, and the
   supported downstream consumer contracts under
   `consumerContract.historyFacade` and
   `consumerContract.hostedNiLinuxRunner`.

4. **Import the module from the extracted bundle**

   ```powershell
   Import-Module .\comparevi-tools\CompareVI.Tools-v<release-version>\tools\CompareVI.Tools\CompareVI.Tools.psd1 -Force
   ```

5. **Run the facade helper**

   ```powershell
   Set-Location labview-icon-editor
   $history = Invoke-CompareVIHistoryFacade `
     -TargetPath "resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi" `
     -Mode attributes,front-panel,block-diagram `
     -RenderReport `
     -FailOnDiff:$false `
     -InvokeScriptPath ..\comparevi-tools\CompareVI.Tools-v<release-version>\tools\Invoke-LVCompare.ps1

   $history.observedInterpretation.coverageClass
   $history.execution.requestedModes
   $history.execution.executedModes
   $history.reports.markdownPath
   ```

This path replaces whole-repository acquisition for module consumers while
keeping the integration pinned to a reviewed release tag. The returned facade
object is the supported downstream summary surface: requested/executed modes,
coverage and outcome interpretation, report paths, and per-mode tallies without
the raw backend comparison payloads.

For hosted GitHub runner diagnostics, use the same extracted bundle root as
`COMPAREVI_SCRIPTS_ROOT` and resolve the NI Linux runner from
`tools/Run-NILinuxContainerCompare.ps1`. Keep its adjacent support scripts
(`Assert-DockerRuntimeDeterminism.ps1` and
`Compare-ExitCodeClassifier.ps1`) in the extracted bundle; do not copy the
runner by itself.

### Single-container smoke bootstrap

When a hosted or local smoke lane needs extra dependencies or config inside the
NI Linux image, prefer runtime injection over starting multiple short-lived
containers. `Run-NILinuxContainerCompare.ps1` now accepts either the low-level
runtime injection switches or an explicit bootstrap contract
(`-RuntimeBootstrapContractPath`):

- `-RuntimeInjectionScriptPath` for a bash fragment that is sourced inside the
  running container before LabVIEW CLI/Xvfb discovery.
- `-RuntimeInjectionEnv` for additional `KEY=VALUE` pairs passed into that same
  container execution.
- `-RuntimeInjectionMount` for extra `hostPath::/container/path` mounts that
  carry config or dependency payloads.
- `branchRef` and `maxCommitCount` inside the bootstrap contract so consumers
  can bind the VI-history smoke run to a specific source branch and fail early
  when that branch drifts past the agreed history window.
- `viHistory` inside the bootstrap contract when the container should derive the
  compare pair from a mounted git repo instead of relying on host-supplied
  `-BaseVi` / `-HeadVi`. The explicit block accepts:
  - `repoPath`
  - `targetPath`
  - `resultsPath`
  - optional `baselineRef`
  - optional `maxPairs`

Because the injection script is sourced in the same bash session that later
invokes the LabVIEW CLI, sequential bootstrap steps such as exporting config,
amending `PATH`, unpacking sidecar tools, or verifying mounted payloads all run
inside one container start before the compare operation executes.

When the explicit `viHistory` block is present, the bootstrap script now:

- resolves the requested branch inside the mounted repo
- enforces the branch budget against divergence from `develop` (when present)
- materializes a bounded first-parent pair plan inside the container work root
- emits `suite-manifest.json`, `history-context.json`, and
  `vi-history-bootstrap-receipt.json` under the mounted results directory
- hands that plan to the same in-container compare command, so one container
  session can walk multiple sequential VI-history pairs and still emit a single
  bounded suite bundle

For VI-history consumers, the host-side fast loop enforces the commit cap before
starting Docker, using divergence from `develop` as the budget when that
baseline exists. The bootstrap script enforces the same cap again inside the
container when `COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT` is provided. That
keeps oversized feature branches from silently turning the smoke lane into a
full-history replay while leaving the baseline `develop` lane usable.

```powershell
pwsh -NoLogo -NoProfile -File tools/Run-NILinuxContainerCompare.ps1 `
  -RuntimeBootstrapContractPath .\runtime-bootstrap.json
```

```json
{
  "schema": "ni-linux-runtime-bootstrap/v1",
  "mode": "vi-history-suite-smoke",
  "branchRef": "consumer/feature-history",
  "maxCommitCount": 64,
  "scriptPath": "tools/NILinux-VIHistorySuiteBootstrap.sh",
  "viHistory": {
    "repoPath": ".",
    "targetPath": "fixtures/vi-attr/Head.vi",
    "resultsPath": "tests/results/local-parity/linux-smoke/vi-history-suite/results",
    "baselineRef": "develop",
    "maxPairs": 2
  }
}
```

## Canonical downstream demo adoption

Treat `LabVIEW-Community-CI-CD/labview-icon-editor-demo` as the first
documented downstream consumer for the local-first VI history loop.

- Backend pin: reviewed `compare-vi-cli-action` release tag plus
  `comparevi-tools-release.json`
- Facade pin: immutable `comparevi-history` release used by the consumer
  workflows and local-review scripts
- Downstream repo: `LabVIEW-Community-CI-CD/labview-icon-editor-demo`
- PR workflow target branch: `develop`
- Downstream maintainer doc:
  `docs/comparevi-history-diagnostics.md`
- Representative VI:
  `Tooling/deployment/VIP_Post-Install Custom Action.vi`

For that repo, the supported local maintainer loop is:

1. refine locally with `dev-fast`
2. repeat locally with `warm-dev` when iteration is high-frequency
3. run `proof` before opening the PR
4. use GitHub CI only for publication and trust-boundary proof

Example local review from a `comparevi-history` checkout:

```powershell
pwsh -NoLogo -NoProfile -File <comparevi-history-root>\scripts\Invoke-CompareVIHistoryLocalReview.ps1 `
  -ConsumerRepositoryRoot <labview-icon-editor-demo-root> `
  -ViPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi'
```

Example repeated-turn warm runtime:

```powershell
pwsh -NoLogo -NoProfile -File <comparevi-history-root>\scripts\Invoke-CompareVIHistoryLocalReview.ps1 `
  -ConsumerRepositoryRoot <labview-icon-editor-demo-root> `
  -ViPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' `
  -Profile warm-dev `
  -WarmRuntimeDir tests/results/local-review/runtime `
  -BaseRef develop `
  -HeadRef HEAD
```

Example local proof before opening the PR:

```powershell
pwsh -NoLogo -NoProfile -File <comparevi-history-root>\scripts\Invoke-CompareVIHistoryLocalReview.ps1 `
  -ConsumerRepositoryRoot <labview-icon-editor-demo-root> `
  -ViPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' `
  -Profile proof `
  -BaseRef develop `
  -HeadRef HEAD
```

Keep the checked-in GitHub workflows in the downstream repo as the publication
surface. The local-first loop is for reviewer/runtime refinement before the PR
exists, not a replacement for the published PR diagnostics.

## Legacy module sample flow

Use this exact sample when you need a documented cross-repo consumer reference:

- Backend pin: reviewed `compare-vi-cli-action` release tag plus
  `comparevi-tools-release.json`
- Downstream repo: `svelderrainruiz/labview-icon-editor`
- Target VI:
  `resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi`
- Recommended modes: `attributes,front-panel,block-diagram`
- Supported module entry point: `Invoke-CompareVIHistoryFacade`
- Runtime summary artifact: `history-summary.json`

For reviewer-facing diagnostics surfaces, prefer explicit scoped modes instead
of aggregate lanes such as `default` or `full`. The embedded bundle metadata
also advertises
`consumerContract.diagnosticsCommentRenderer.entryScriptPath = tools/New-CompareVIHistoryDiagnosticsBody.ps1`,
which comparevi-history consumers can resolve from the extracted tooling root
or workflow `tooling-path` output instead of copying inline PowerShell comment
renderers.

## Local-first acceleration planes

Cross-repo maintainers should now separate local refinement speed from canonical
proof:

- `proof`
  - image: `nationalinstruments/labview:2026q1-linux`
  - purpose: release parity and CI truth
- `dev-fast`
  - image: `comparevi-vi-history-dev:local`
  - purpose: faster cold local refinement with a mounted working tree and
    prewarmed dependencies
- `warm-dev`
  - same local dev image
  - purpose: repeated local turns against one long-lived Docker runtime

This split is deliberate:

- `comparevi-tools` stays the non-LV/tools image only
- the local dev image is not published in the first slice
- CI and release workflows keep advertising only the canonical NI image

### Backend local entrypoints

Use the backend runtime substrate from this repo:

```powershell
node tools/npm/run-script.mjs history:local:build-dev-image
node tools/npm/run-script.mjs history:local:refine -- `
  -BaseVi fixtures/vi-attr/Base.vi `
  -HeadVi fixtures/vi-attr/Head.vi `
  -HistoryTargetPath fixtures/vi-attr/Head.vi
node tools/npm/run-script.mjs history:local:proof -- `
  -BaseVi fixtures/vi-attr/Base.vi `
  -HeadVi fixtures/vi-attr/Head.vi `
  -HistoryTargetPath fixtures/vi-attr/Head.vi
node tools/npm/run-script.mjs history:local:warm-runtime -- `
  -RepoRoot . `
  -ResultsRoot tests/results/local-vi-history/warm-dev `
  -RuntimeDir tests/results/local-vi-history/runtime/warm-dev
```

Direct PowerShell entrypoints are:

- `tools/Build-VIHistoryDevImage.ps1`
- `tools/Invoke-VIHistoryLocalRefinement.ps1`
- `tools/Invoke-VIHistoryLocalOperatorSession.ps1`
- `tools/Manage-VIHistoryRuntimeInDocker.ps1`

The local receipts are:

- `comparevi/local-refinement@v1`
- `comparevi/local-runtime-state@v1`
- `comparevi/local-runtime-health@v1`
- `comparevi/local-refinement-benchmark@v1`
- `comparevi/local-operator-session@v1`

Those receipts are the contract `comparevi-history` should consume when it adds
profile-aware `local-review` and `local-proof` surfaces on top of the backend
runtime planes.

Use the operator-session contract when one local command needs to compose the
runtime plane with a downstream review hook. The session manifest records:

- the underlying local-refinement receipt
- benchmark selection and warm-runtime artifacts
- optional downstream review output paths such as a review bundle, workspace,
  preview manifest, or review receipt
- the final composed session status

The session wrapper sets stable environment variables for downstream review
hooks, including:

- `COMPAREVI_LOCAL_REFINEMENT_RECEIPT_PATH`
- `COMPAREVI_LOCAL_REFINEMENT_BENCHMARK_PATH`
- `COMPAREVI_LOCAL_REFINEMENT_RESULTS_ROOT`
- `COMPAREVI_LOCAL_OPERATOR_SESSION_PATH`
- `COMPAREVI_REVIEW_RECEIPT_PATH`
- `COMPAREVI_REVIEW_BUNDLE_PATH`
- `COMPAREVI_REVIEW_WORKSPACE_HTML_PATH`
- `COMPAREVI_REVIEW_WORKSPACE_MARKDOWN_PATH`
- `COMPAREVI_REVIEW_PREVIEW_MANIFEST_PATH`
- `COMPAREVI_REVIEW_RUN_PATH`

For extracted tooling bundles, prefer the module-level stable surface instead
of hard-coding backend script paths:

- `Invoke-CompareVIHistoryLocalRefinementFacade`
- `Invoke-CompareVIHistoryLocalOperatorSessionFacade`
- consumer contract:
  `comparevi-tools/local-refinement-facade@v1`
  and `comparevi-tools/local-operator-session-facade@v1`

### Recommended downstream workflow

For a downstream maintainer, the intended loop is now:

1. refine a VI-history change locally with `dev-fast`
2. repeat locally with `warm-dev` when the turn frequency is high
3. run `proof` before opening the PR
4. use GitHub CI only for publication and trust-boundary proof

That keeps sticky comment, preview publication, and trust-split validation in
GitHub while moving parser/renderer/runtime iteration off the PR churn path.

## One-off local run from a source checkout (legacy / maintainer path)

1. **Clone the target repo**

   ```powershell
   git clone https://github.com/svelderrainruiz/labview-icon-editor.git
   ```

2. **Import the module**

   From the cloned `compare-vi-cli-action` repository run:

   ```powershell
   Import-Module (Join-Path $PWD 'tools/CompareVI.Tools/CompareVI.Tools.psd1') -Force
   ```

   The module exposes both `Invoke-CompareVIHistory` and
   `Invoke-CompareVIHistoryFacade`, and redirects all helper lookups back to
   this repository.

3. **Run the history helper**

   ```powershell
   Set-Location labview-icon-editor
Invoke-CompareVIHistory `
  -TargetPath "resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi" `
  -SourceBranchRef "feature/history-source" `
  -MaxBranchCommits 64 `
  -RenderReport `
  -FailOnDiff:$false `
  -InvokeScriptPath ..\compare-vi-cli-action\tools\Invoke-LVCompare.ps1
```
Add `-MaxPairs <n>` when you need to cap the number of commit pairs in the cross-repo run.
Add `-SourceBranchRef` plus `-MaxBranchCommits` when the consumer needs an
explicit budget against branch sprawl before the history suite runs.

   - Outputs land in `tests/results/ref-compare/history/` inside the cloned
     repo (`history-report.md`, `history-report.html`, manifest JSON, etc.).
   - Works for any VI path with commit history; use `-StartRef` if you need to
     anchor to an older commit.
   - When LabVIEW is not available locally, point `-InvokeScriptPath` at a
     testing stub so the pipeline still emits manifests and reports.

### Reference fixtures

The repository ships a synthetic snapshot under
`fixtures/cross-repo/labview-icon-editor/settings-init/` (Markdown, HTML, and
JSON manifests). `tests/CompareVI.CrossRepo.Fixtures.Tests.ps1` validates that
the recorded metadata bucket counts (2 entries in the `metadata` bucket) stay
in sync with the documentation. Use the fixture as a template when capturing
new cross-repo runs.

## Offline corpus harness

For the seeded offline real-history corpus path added under issue `#894`, use
[`Offline-RealHistory-Corpus.md`](./Offline-RealHistory-Corpus.md). That flow
wraps `Compare-VIHistory` with the NI Windows container bridge and writes
generated evidence under `tests/results/offline-real-history/` instead of
committing bulky raw reports. Issue `#895` adds the deterministic committed
subset at `fixtures/real-history/offline-corpus.normalized.json`, which is
rebuilt from the checked-in seed fixture and tiny capture summaries instead of
from local run artifacts.

## Observations / gaps

- With `CompareVI.Tools` we can reuse `Compare-VIHistory` and
  `Compare-RefsToTemp` without copying scripts into the target repository.
- The published `CompareVI.Tools` zip bundle now covers the module acquisition
  path without cloning this repository.
- The bundle now also carries the hosted NI Linux runner surface needed by
  comparevi-history consumers that stage `nationalinstruments/labview:2026q1-linux`
  on hosted runners.
- A reusable workflow/facade is still useful for the cleanest `uses:` UX.

## Packaging decision (2025-10-31)

For issue #527 we will proceed with the **PowerShell module** approach:

- Create a module (working name `CompareVI.Tools`) that exports
  `Compare-VIHistory`, `Compare-RefsToTemp`, bucket metadata helpers, and the
  vendor resolver.
- Publish the module as part of the compare-vi-cli-action release process as a
  pinned zip bundle.
- Provide a simple wrapper script so GitHub workflows can import the module and
  invoke `Compare-VIHistory` without copying files.
- Generate a zip bundle from the release pipeline for consumers that prefer
  fixed artifacts.

## Next steps (tracked by issue #527)

- **Packaging options**  
  - *PowerShell module bundle*: publish `Compare-VIHistory`,
    `Compare-RefsToTemp`, bucket metadata, vendor resolvers, and compare
    engine dependencies as a self-contained `CompareVI.Tools` zip asset on each
    release. External repos download/unpack the bundle and import the module
    directly.  
  - *Reusable workflow/composite action*: wrap the helper in a GitHub Action
    that accepts repo+VI inputs and runs the history capture on a trusted
    runner.

- **Automation gaps to close**
  - Keep the release bundle metadata and verification guidance aligned with the
    published asset names.
  - Provide a sample workflow (e.g., `vi-history-cross-repo.yml`) that
    downloads the helper and runs it against a supplied repo/ref.
  - Clarify access requirements (SAML, LFS, large history impacts) in the docs.
  - Add validation that warns when the target VI has no history (e.g., history
    report shows only `_missing-base_` rows).
