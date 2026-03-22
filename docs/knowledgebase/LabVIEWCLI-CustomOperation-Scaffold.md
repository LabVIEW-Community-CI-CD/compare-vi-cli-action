<!-- markdownlint-disable-next-line MD041 -->
# LabVIEW CLI Custom Operation Scaffold

This note defines the disposable workspace scaffold used to bootstrap
repo-owned LabVIEW CLI custom operation authoring from either:

- NI's installed `AddTwoNumbers` example
- installed official LabVIEW CLI operation directories

without vendoring NI-owned files into git.

## Purpose

Use the scaffold helper when an agent or human needs a repeatable starting point
for a future repo-owned custom operation payload such as
`PrintToSingleFileHtml`.

This helper does not promote the NI example into the repository.

- It copies from an installed NI source tree on the host.
- It defaults the destination into `tests/results/_agent/`.
- It emits a machine-readable receipt that records the source kind, source path,
  and LabVIEW path/version hint used for the scaffold.

## Entry points

- Helper: `tools/New-LabVIEWCLICustomOperationWorkspace.ps1`
- Dedicated `PrintToSingleFileHtml` wrapper:
  `tools/New-PrintToSingleFileHtmlAuthoringWorkspace.ps1`
- Native-authoring packet wrapper:
  `tools/New-PrintToSingleFileHtmlAuthoringPacket.ps1`
- Payload finalization helper:
  `tools/Finalize-OperationPayloadSourceBundle.ps1`
- Receipt schema:
  `docs/schemas/labview-cli-custom-operation-scaffold-v1.schema.json`
- Dedicated wrapper receipt schema:
  `docs/schemas/print-to-single-file-html-authoring-workspace-v1.schema.json`
- Native-authoring packet receipt schema:
  `docs/schemas/print-to-single-file-html-authoring-packet-v1.schema.json`
- Payload finalization receipt schema:
  `docs/schemas/operation-payload-authoring-finalization-v1.schema.json`
- Focused test:
  `tests/New-LabVIEWCLICustomOperationWorkspace.Tests.ps1`
- Dedicated wrapper test:
  `tests/New-PrintToSingleFileHtmlAuthoringWorkspace.Tests.ps1`
- Native-authoring packet test:
  `tests/New-PrintToSingleFileHtmlAuthoringPacket.Tests.ps1`

## Source kinds and default destinations

### `ni-example`

- Default source:
  `C:\Users\Public\Documents\National Instruments\LabVIEW CLI\Examples\AddTwoNumbers`

### `installed-cli-operation`

- Default source:
  `C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\Operations\CreateComparisonReport`

### Destination

- Default destination root:
  `tests/results/_agent/custom-operation-scaffolds/`

If the destination is inside the repository, the helper only allows child paths
under `tests/results/_agent/custom-operation-scaffolds/`.

The shared scaffold root itself is not a valid destination. This keeps `-Force`
from wiping the entire disposable scaffold area in one call.

## Usage

Scaffold into the default disposable results root:

```powershell
node tools/npm/run-script.mjs history:custom-operation:scaffold
```

Scaffold into an explicit disposable path:

```powershell
pwsh -NoLogo -NoProfile -File tools/New-LabVIEWCLICustomOperationWorkspace.ps1 `
  -DestinationPath tests/results/_agent/custom-operation-scaffolds/manual-authoring `
  -Force
```

Scaffold from an installed LabVIEW CLI operation directory instead of the
`AddTwoNumbers` example:

```powershell
pwsh -NoLogo -NoProfile -File tools/New-LabVIEWCLICustomOperationWorkspace.ps1 `
  -SourceKind installed-cli-operation `
  -DestinationPath tests/results/_agent/custom-operation-scaffolds/print-html-authoring `
  -Force
```

Scaffold the dedicated disposable authoring workspace for the repo-owned
`PrintToSingleFileHtml` payload:

```powershell
node tools/npm/run-script.mjs history:custom-operation:scaffold:print-single-file
```

Build the native-authoring packet for the repo-owned `PrintToSingleFileHtml`
payload. This layers the disposable workspace scaffold with the installed
`Operations.lvproj`, `Toolkit-Operations.lvproj`, the preferred LabVIEW 2026
x86 path, an authoring checklist, and a convenience launch script:

```powershell
node tools/npm/run-script.mjs history:custom-operation:authoring-packet:print-single-file
```

Finalize the repo-owned payload metadata after native authoring has copied real
LabVIEW binary files into the payload bundle:

```powershell
node tools/npm/run-script.mjs history:custom-operation:finalize:print-single-file
```

## Receipt

Successful runs emit `labview-cli-custom-operation-scaffold@v1` with:

- source kind (`ni-example` or `installed-cli-operation`)
- source example path
- destination path
- destination policy (`repo-results-root` or `outside-repo`)
- receipt path
- LabVIEW path hint
- LabVIEW version hint
- copied file inventory

## Boundary

This scaffold is bootstrap only.

- It does not prove that the custom operation executes correctly.
- It does not resolve the host hang tracked in `#1472`.
- It does not make the eventual payload promotable on its own.

It exists so payload-authoring lanes such as `#1619` have a deterministic,
repeatable workspace bootstrap instead of manual copying from the NI install
tree. The dedicated `PrintToSingleFileHtml` wrappers from `#1621` build on that
generic scaffold without changing the underlying bootstrap contract: the
workspace wrapper bootstraps disposable files, and the native-authoring packet
turns the remaining gap into an explicit LabVIEW authoring handoff instead of a
hidden assumption. The finalization helper then closes the bookkeeping gap after
that native authoring step by updating the payload bundle metadata only when the
checked-in files inspect as real LabVIEW binaries.
That handoff remains the concrete prerequisite for the standing public proof
lanes in `#1617`, `#1726`, and `#1467`.
