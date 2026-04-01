# Release Notes v0.6.12

`v0.6.12` is a maintenance release that carries the published `v0.6.11` stable
line forward and fixes the Windows preflight process-capture deadlock exposed
when Docker returns large manifest output.

## Highlights

- The released backend no longer deadlocks while collecting large Docker
  manifest payloads during Windows preflight and runtime-manager checks.
- A shared timeout helper now owns bounded process execution and concurrent
  stdout/stderr draining for the Windows preflight seam.
- The stable release keeps the `v0.6.11` Windows NI proof authority and
  VI-history native-path repair instead of regressing to an older integration
  surface.

## Included maintenance slice

- `#2091` fix: Windows preflight process capture deadlock
- carry forward the published `v0.6.11` release-line policy and proof surfaces

## Validation highlights

- Focused Pester coverage proves large-manifest replay no longer blocks either
  `tools/Invoke-DockerRuntimeManager.ps1` or
  `tools/Test-WindowsNI2026q1HostPreflight.ps1`.
- The release branch is prepared from the published `v0.6.11` line and merged
  with the post-`#2091` `develop` tip, preserving the already-published stable
  fixes while adding the Windows preflight deadlock repair.
- Release helper docs, changelog, and version surfaces align on `0.6.12`.

## Consumer impact

- Stable consumers should move from `@v0.6.11` to `@v0.6.12` to pick up the
  Windows preflight/runtime-manager deadlock repair.
- `comparevi-history` should repin `comparevi-backend-ref.txt` to `v0.6.12`
  before rerunning the clone-backed `ni/labview-icon-editor` proof on the
  released backend.
