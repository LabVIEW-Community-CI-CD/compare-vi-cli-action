# Build VI Package 📦

Runs **`build_vip.ps1`** to update a `.vipb` file's display info and build the VI Package via the VIPM CLI.

## Inputs
| Name | Required | Example | Description |
|------|----------|---------|-------------|
| `supported_bitness` | **Yes** | `64` | Target LabVIEW bitness. |
| `minimum_supported_lv_version` | **Yes** | `2026` | LabVIEW major version used for packaging. |
| `labview_minor_revision` | No (defaults to `3`) | `3` | LabVIEW minor revision. |
| `major` | **Yes** | `1` | Major version component. |
| `minor` | **Yes** | `0` | Minor version component. |
| `patch` | **Yes** | `0` | Patch version component. |
| `build` | **Yes** | `1` | Build number component. |
| `commit` | **Yes** | `abcdef` | Commit identifier. |
| `release_notes_file` | **Yes** | `Tooling/deployment/release_notes.md` | Release notes file. |
| `display_information_json` | **Yes** | `'{}'` | JSON for VIPB display information. |

> **Note:** The action automatically uses the first `.vipb` file located in this directory.

## Outputs

| Name | Description |
|------|-------------|
| `vipm_build_log` | Relative path to the VIPM CLI stdout/stderr log for the build. |
| `vipm_build_metadata` | Relative path to the structured JSON metadata captured from the VIPM build invocation. |

## Quick-start
```yaml
- uses: ./.github/actions/build-vi-package
  with:
    supported_bitness: 64
    minimum_supported_lv_version: 2026
    major: 1
    minor: 0
    patch: 0
    build: 1
    commit: ${{ github.sha }}
    release_notes_file: Tooling/deployment/release_notes.md
    display_information_json: '{}'
  # outputs available via steps.<id>.outputs.vipm_build_log, etc.
```

## License
This directory inherits the root repository’s license (MIT, unless otherwise noted).
