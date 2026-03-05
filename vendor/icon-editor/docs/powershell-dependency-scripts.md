# PowerShell Dependency Scripts

This document lists the PowerShell scripts used to build, test, and distribute the LabVIEW Icon Editor. Each script is a dependency in the tooling chain and can be called directly or by other scripts.

## Table of Contents

- [AddTokenToLabVIEW.ps1](#addtokentolabviewps1)
- [ApplyVIPC.ps1](#applyvipcps1)
- [Build.ps1](#buildps1)
- [Build_lvlibp.ps1](#build_lvlibpps1)
- [build_vip.ps1](#build_vipps1)
- [Close_LabVIEW.ps1](#close_labviewps1)
- [ModifyVIPBDisplayInfo.ps1](#modifyvipbdisplayinfops1)
- [Prepare_LabVIEW_source.ps1](#prepare_labview_sourceps1)
- [Rename-file.ps1](#rename-fileps1)
- [RestoreSetupLVSource.ps1](#restoresetuplvsourceps1)
- [Set_Development_Mode.ps1](#set_development_modeps1)
- [RevertDevelopmentMode.ps1](#revertdevelopmentmodeps1)
- [RunUnitTests.ps1](#rununittestsps1)

---

## AddTokenToLabVIEW.ps1
Adds a custom `LocalHost.LibraryPaths` token to the LabVIEW INI file so LabVIEW can find project libraries during development or builds. Used by `Set_Development_Mode.ps1`.

## ApplyVIPC.ps1
Applies a `.vipc` container to a specific LabVIEW version and bitness using g-cli. Ensures that all required LabVIEW dependencies are installed before building.

## Build.ps1
Top-level script that orchestrates the full build. Cleans previous outputs, builds packed libraries for 32-bit and 64-bit, updates metadata, and produces the final `.vip` package. Depends on many of the other scripts listed here.

## Build_lvlibp.ps1
Invokes the "Editor Packed Library" build specification and embeds version information and commit identifiers into the resulting `.lvlibp`.

## build_vip.ps1
Modifies a `.vipb` file and builds the final VI Package with g-cli, using version data and display information provided by `Build.ps1`.

## Close_LabVIEW.ps1
Gracefully shuts down a running LabVIEW instance using g-cli's `QuitLabVIEW` command. Called throughout the pipeline to ensure LabVIEW exits cleanly.

## ModifyVIPBDisplayInfo.ps1
Updates the display information inside a `.vipb` file and merges version and branding metadata. Typically called by `Build.ps1` before packaging.

## Prepare_LabVIEW_source.ps1
Unzips LabVIEW sources and updates configuration so the project is ready for development or building. Called by `Set_Development_Mode.ps1`.

## Rename-file.ps1
Renames the built packed libraries to the expected `lv_icon_x86.lvlibp` or `lv_icon_x64.lvlibp` names.

## RestoreSetupLVSource.ps1
Reverses `Prepare_LabVIEW_source.ps1` by restoring the packaged state of the LabVIEW sources and removing custom INI tokens. Used by `RevertDevelopmentMode.ps1`.

## Set_Development_Mode.ps1
Configures the repository for development. Removes existing packed libraries, adds INI tokens, prepares LabVIEW sources, and closes LabVIEW for both bitnesses.

## RevertDevelopmentMode.ps1
Undoes development mode by restoring packaged sources and closing LabVIEW. Helpful when leaving development or before distributing a build.

## RunUnitTests.ps1
Locates the `.lvproj`, runs unit tests through g-cli, and outputs a table of results. Used in CI workflows.

