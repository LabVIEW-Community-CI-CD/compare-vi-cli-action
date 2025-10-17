<!-- markdownlint-disable-next-line MD041 -->
# N-CLI Companion (Local Dev Extension)

The N-CLI companion hosts CompareVI and future CLI providers in one panel so you can swap tooling without reinstalling
new extensions. The default CompareVI provider keeps all of the manual compare conveniences (flag presets, commit
compare, artifact summaries) and now layers in health checks, telemetry breadcrumbs, and a provider switcher. A stub
g-cli provider is included to exercise the multi-provider plumbing and warn when the executable is missing.

## Providers

- **CompareVI** – full-featured provider used by existing workflows. Presents the VI Compare panel, LabVIEW health
  checks, CLI previews, and profile runner.
- **G CLI (stub)** – exercises provider switching and g-cli detection. When the configured executable cannot be found
  the panel disables CompareVI actions and surfaces the missing-path warning so you can install/configure the tool
  before expanding the provider.

Switch providers from the top of the VI Compare panel. Provider metadata (docs URL, health status, disabled reason)
renders in the panel header and controls the enabled/disabled state of compare actions.

## Commands

- CompareVI: Run Manual Compare (`comparevi.runManualCompare`)
  - Prompts for LabVIEW year and bitness
  - Calls `tools/Invoke-LVCompare.ps1` with the resolved LabVIEW path
  - Uses workspace defaults for Base/Head VIs and output folder
  - Offers an optional multi-select picker for LVCompare flags (configurable)

- CompareVI: Run Profile (`comparevi.runProfile`)
  - Reads profiles from `tools/comparevi.profiles.json` (configurable via `comparevi.profilesPath`)
  - Lets you pick a named profile and runs it

- CompareVI: Compare Active VI with Previous Commit (`comparevi.compareActiveWithPrevious`)
  - Compares the currently open `.vi` against `HEAD~1` for the same path
  - Extracts both revisions to temporary files and runs LVCompare
  - Reuses the same output directory and summary/flag behavior as other commands

- CompareVI: Open/Create Profiles (`comparevi.openProfiles`)
  - Opens the profiles file; creates a sample if missing

## Settings

- `comparevi.labview.year` (default `2025`)
- `comparevi.labview.bits` (default `64`)
- `comparevi.paths.baseVi` (default `${workspaceFolder}/VI2.vi`)
- `comparevi.paths.headVi` (default `${workspaceFolder}/tmp-commit-236ffab/VI2.vi`)
- `comparevi.output.dir` (default `tests/results/manual-vi2-compare`)
- `comparevi.profilesPath` (default `tools/comparevi.profiles.json`)
- `comparevi.passFlags` (default `false`) — pass profile/default flags without prompting
- `comparevi.showFlagPicker` (default `true`) — prompt for flags with a multi-select picker before each run
- `comparevi.knownFlags` — list of LVCompare flags shown in the picker
- `comparevi.showSourcePicker` (default `true`) — prompt for base/head commit sources when profiles define commit refs
- `comparevi.keepTempVi` (default `false`) — retain extracted temporary VIs after each run (handy for debugging)
- `comparevi.providers.gcli.path` (default empty) — optional override for the g-cli executable path used by the stub
  provider
- `comparevi.telemetryEnabled` (default `true`) — when enabled, write NDJSON telemetry events for each compare run under
  `tests/results/telemetry/`

## Commit-Based Sources

Profiles can describe comparisons entirely in terms of Git commits. Example:

```json
{
  "name": "Compare VI2",
  "year": "2025",
  "bits": "64",
  "vis": [
    { "id": "root", "ref": "HEAD", "path": "VI2.vi" },
    { "id": "previous", "ref": "HEAD~1", "path": "VI2.vi" }
  ],
  "defaultBase": "previous",
  "defaultHead": "root"
}
```

On each run the extension extracts the selected commits to a temporary directory (`base.vi` / `head.vi`), renames them
to avoid collisions, and feeds them to `Invoke-LVCompare.ps1`. QuickPick prompts show commit hashes and subjects, and
the post-run summary lists the chosen refs and VI paths.

The CompareVI Manual side bar (Activity Bar → CompareVI Manual) lists profiles and their current selections. Right-click
a profile to run it, choose new base/head commits, or open the latest capture/report.

- Paths in `vis` entries are relative to the repository. If omitted, the extension will list `.vi` files in the commit
  and prompt you to choose one.
- Temporary files are cleaned up automatically unless `comparevi.keepTempVi` is enabled.
- Tree view vignettes display the current commit selections; context menus still provide “Run”, “Open Report”, etc.
- Each compare run snapshots `LabVIEW.ini` (when present) alongside CLI artifacts so you can audit LabVIEW configuration
  changes over time.

## Telemetry

When `comparevi.telemetryEnabled` is true the extension appends NDJSON events to `tests/results/telemetry/n-cli-
companion.ndjson`. Entries include the provider id, run type (manual/profile/commit/active), exit codes, and whether a
LabVIEW.ini snapshot was captured. Disable the setting to opt out locally.

## Run locally

1. Open this repository in VS Code.
2. Press F5 (or run the “Run Extension” launch config) to start an Extension Development Host.
3. Open the Command Palette and run “CompareVI: Run Manual Compare”.

The command opens an Integrated Terminal and executes the PowerShell script.

## Tasks (TaskProvider)

The extension registers a `comparevi` task type that surfaces one VS Code task per profile.

- Open the Task Runner (Terminal → Run Task) and look for tasks named `CompareVI: <profile name>`.
- Running a task executes `pwsh -File tools/Invoke-LVCompare.ps1` populated from the profile.

## Package the extension (VSIX)

From the repository root:

```bash
npm install --prefix vscode/comparevi-helper
npm run package --prefix vscode/comparevi-helper
```

The VSIX (`comparevi-helper-<version>.vsix`) is emitted in `vscode/comparevi-helper/` and can be installed via `code
--install-extension <path-to-vsix>`.

## Testing

- Unit tests (Vitest): `npm run test:unit`
- Integration tests (VS Code host): `npm run test:ext`
- Full test suite: `npm test`
