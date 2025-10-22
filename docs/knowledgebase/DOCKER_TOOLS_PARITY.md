<!-- markdownlint-disable-next-line MD041 -->
# Docker Tools Parity Checklist

This note captures the current state of the containerized validation helpers and how to confirm they match the Windows
tooling. It supports standing priority #127 (Phase 1a: Docker image alignment).

## Environment prerequisites

- Docker Desktop (or Engine) must be available. On Windows, confirm with `docker version`; the client/server details
  should show `Docker Desktop` with the expected engine revision.
- Ensure `GH_TOKEN`/`GITHUB_TOKEN` are available (the helper forwards them into containers when defined).

## Quick parity run

```powershell
pwsh -File tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage
```

- The `dotnet-cli-build (sdk)` container publishes the CompareVI CLI into `dist/comparevi-cli/`. Expect artifacts:
  - `comparevi-cli.dll`, `CompareVi.Shared.dll`, matching `.deps.json` and `.runtimeconfig.json` files.
- `actionlint` runs inside the tools image (or `rhysd/actionlint` if `-UseToolsImage` isn't specified). Successful runs
  print `[docker] actionlint OK`.
- Optional flags (`-SkipDocs`, `-SkipWorkflow`, `-SkipMarkdown`) remain available when you want a quicker loop while
  iterating locally.

## Cleanup expectations

- After parity validation, remove `dist/comparevi-cli/`:

  ```powershell
  Remove-Item -LiteralPath dist/comparevi-cli -Recurse -Force
  ```

- Verify `git status` returns clean output (aside from intentional working-tree changes).

## Troubleshooting

- **Docker daemon missing** – `open //./pipe/dockerDesktopLinuxEngine` (Windows) means Docker Desktop isn’t running.
  Start Docker, re-run `docker version`, and retry the helper.
- **Permission issues** – ensure your user is authorized to run Docker commands; add to the `docker-users` group when
  needed.
- **Token forwarding** - if `GH_TOKEN` / `GITHUB_TOKEN` are required, set them before running the helper. Without a
  token, `priority:sync` inside the container may fail.

## Automation support

- GitHub workflow `Tools Parity (Linux)` (`.github/workflows/tools-parity.yml`) runs the helper on `ubuntu-latest`.
  Trigger it via `workflow_dispatch` to capture fresh parity logs and a `docker version` snapshot. Artifacts are uploaded
  as `docker-parity-linux` (example run: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/18703466772).
- Adjust the workflow inputs to re-enable docs, workflow drift, or markdown checks when validating broader coverage.

## macOS coverage (help wanted)

- The tools image cannot run on macOS-hosted GitHub runners (Docker Desktop is not available), so parity needs to be
  captured on a physical/virtual Mac with Docker running.
- Contributions welcome: run the parity helper locally on macOS, record `docker version` + script logs, and update this
  guide (and the validation matrix) with findings.

## Status (2025-10-22)

- Parity check completed on Windows with Docker Desktop 4.47.0 (Engine 28.4.0). CLI build succeeded; cleanup confirmed.
- Full helper sweep (docs, workflow drift, markdown) now runs cleanly after lint fixes logged in develop (Oct 22).
- Documentation updated (validation matrix) to remind contributors to remove `dist/comparevi-cli/` after runs.
- Linux automation added via `Tools Parity (Linux)` workflow; macOS parity remains open for contribution.
