# Compare VI (composite) GitHub Action

<!-- ci: bootstrap status checks -->

[![Validate](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/validate.yml/badge.svg)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/validate.yml)
[![Smoke test](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/smoke.yml/badge.svg)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/smoke.yml)
[![Test (mock)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/test-mock.yml/badge.svg)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/test-mock.yml)
[![Marketplace](https://img.shields.io/badge/GitHub%20Marketplace-Action-blue?logo=github)](https://github.com/marketplace/actions/compare-vi-cli-action)

Diff two LabVIEW `.vi` files using NI LVCompare CLI. Validated with LabVIEW 2025 Q3 on self-hosted Windows runners.

See also: [`CHANGELOG.md`](./CHANGELOG.md) and the release workflow at `.github/workflows/release.yml`.

Requirements

- Self-hosted Windows runner with LabVIEW 2025 Q3 installed and licensed
- `LVCompare.exe` either on `PATH`, provided via `lvComparePath`, or set as `LVCOMPARE_PATH` environment variable

Inputs

- `base` (required): Path to base `.vi`
- `head` (required): Path to head `.vi`
- `lvComparePath` (optional): Full path to `LVCompare.exe` if not on `PATH`
- `lvCompareArgs` (optional): Extra CLI flags for `LVCompare.exe` (space-delimited; quotes supported)
- `fail-on-diff` (optional, default `true`): Fail the job if differences are found
- `working-directory` (optional): Directory to run the command from; relative `base`/`head` are resolved from here

Outputs

- `diff`: `true|false` whether differences were detected (based on exit code mapping 0=no diff, 1=diff)
- `exitCode`: Raw exit code from the CLI
- `cliPath`: Resolved path to the executable
- `command`: The exact command line executed (quoted) for auditing

Exit codes and step summary

- Exit code mapping: 0 = no diff, 1 = diff detected, any other code = failure.
- Outputs (`diff`, `exitCode`, `cliPath`, `command`) are always emitted even when the step fails, to support branching and diagnostics.
- A structured run report is appended to `$GITHUB_STEP_SUMMARY` with working directory, resolved paths, CLI path, command, exit code, and diff result.

Usage (self-hosted Windows)

```yaml
jobs:
  compare:
    runs-on: [self-hosted, Windows]
    steps:
      - uses: actions/checkout@v5
      - name: Compare VIs
        id: compare
        uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.1.0
        with:
          working-directory: subfolder/with/vis
          base: relative/path/to/base.vi   # resolved from working-directory if set
          head: relative/path/to/head.vi   # resolved from working-directory if set
          # Preferred: LVCOMPARE_PATH on runner, or provide full path
          lvComparePath: C:\\Program Files\\NI\\LabVIEW 2025\\LVCompare.exe
          # Optional extra flags (space-delimited, quotes supported)
          lvCompareArgs: "--some-flag --value \"C:\\Temp\\My Folder\\file.txt\""
          # Built-in policy: fail on diff by default
          fail-on-diff: "true"

      - name: Act on result
        if: steps.compare.outputs.diff == 'true'
        shell: pwsh
        run: |
          Write-Host 'Differences detected.'
```

UNC/long path guidance

- The action resolves `base`/`head` to absolute paths before invoking LVCompare.
- If you encounter long-path or UNC issues, consider:
  - Using shorter workspace-relative paths via `working-directory`.
  - Mapping a drive on self-hosted runners for long UNC prefixes.
  - Ensuring your LabVIEW/Windows environment supports long paths.

Common lvCompareArgs recipes (patterns)

- Pass a path with spaces:
  - `lvCompareArgs: "--flag \"C:\\Path With Spaces\\out.txt\""`
- Multiple flags:
  - `lvCompareArgs: "--flag1 value1 --flag2 value2"`
- Environment-driven values:
  - `lvCompareArgs: "--flag \"${{ runner.temp }}\\out.txt\""`

Troubleshooting unknown exit codes

- The action treats 0 as no diff and 1 as diff. Any other exit code fails fast.
- Outputs are still set for diagnostics: `exitCode`, `cliPath`, `command`, and `diff=false`.
- Check $GITHUB_STEP_SUMMARY for a concise run report.

Smoke test workflow

- A manual workflow is provided at `.github/workflows/smoke.yml`.
- Trigger it with “Run workflow” and supply `base`, `head`, and optional `lvComparePath`/`lvCompareArgs`.
- It runs the local action (`uses: ./`) on a self-hosted Windows runner and prints outputs.

Marketplace

- Listing: [GitHub Marketplace listing](https://github.com/marketplace/actions/compare-vi-cli-action)
- After publication, keep the badge/link updated to the final marketplace URL and ensure the README usage references the latest tag.

Notes

- This action maps `LVCompare.exe` exit codes to a boolean `diff` (0 = no diff, 1 = diff). Any other exit code fails the step.
- Typical locations to try for 2025 Q3 include:
  - `C:\\Program Files\\NI\\LabVIEW 2025\\LVCompare.exe`
  - `C:\\Program Files\\National Instruments\\LabVIEW 2025\\LVCompare.exe`

Troubleshooting

- Ensure the runner user has the necessary LabVIEW licensing.
- Verify `LVCompare.exe` is reachable (PATH, `LVCOMPARE_PATH`, or `lvComparePath`).
- Check composite action outputs (`diff`, `exitCode`, `cliPath`, `command`) and the CLI exit code for diagnostics.

Tests

Run unit tests locally (excludes Integration-tagged tests, works cross-platform):
```powershell
pwsh -File ./tools/Run-Pester.ps1
```

Include Integration tests:
```powershell
pwsh -File ./tools/Run-Pester.ps1 -IncludeIntegration
```

- Produces artifacts under `tests/results/` (NUnit XML and summary)
- Uses Pester v5 (falls back to system Pester if PSGallery is unavailable)
- CI workflow: `.github/workflows/test-pester.yml` runs unit tests by default and uploads artifacts
- Use the "Run workflow" input in GitHub Actions to include integration tests
