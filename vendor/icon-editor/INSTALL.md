# LabVIEW Icon Editor – Installation Guide

This guide explains how to install the LabVIEW Icon Editor VI Package on your system.

## Prerequisites

- **LabVIEW 2023 or Newer** – The Icon Editor package requires **LabVIEW 2023 SP1 or later**. *(Note: The package is not compatible with LabVIEW 2022 or earlier.)*
- **VI Package Manager (VIPM)** – You’ll use VIPM to install the `.vip` file. Ensure you have VIPM installed (the free Community Edition is fine).

> *Why LabVIEW 2023+?* The Icon Editor has evolved with new features that depend on improvements in LabVIEW. As of this release, the VI Package is built to support LabVIEW 2023 and onward.
>
> *Development note:* The source code is saved in **LabVIEW 2021 SP1** for building and maintenance. Contributors can develop with LabVIEW 2021, but the packaged editor only runs on LabVIEW 2023 SP1 or newer.

## Installation Steps

1. **Download the Package:** Go to the [latest release page](https://github.com/ni/labview-icon-editor/releases/latest) on GitHub and download the latest **LabVIEW Icon Editor `.vip` file**.
2. **Launch VIPM (as Admin):** Close LabVIEW if it’s open. Start VIPM with administrator privileges (on Windows, right-click VIPM and choose “Run as administrator” – this is required to install into LabVIEW’s directories).
3. **Install the `.vip`:** In VIPM, either double-click the downloaded `.vip` file or in VIPM go to **File → Open Package** and select the file. VIPM will display information about the LabVIEW Icon Editor package. Click **Install** and follow any prompts. VIPM will install the Icon Editor into the appropriate LabVIEW folders.
4. **Restart LabVIEW:** After installation, launch LabVIEW (2023 or newer). Create a new VI and open the Icon Editor (for example, right-click the VI’s icon and choose “Edit Icon”). 
5. **Verify Installation:** The Icon Editor should open and reflect the new version. You can check the **About** or **Help** in the Icon Editor for version info. If it opens without errors and you see new features (as described in the release notes), the installation was successful.

## Troubleshooting Installation

- **Installation Failed / VIPM errors:** Make sure you closed LabVIEW and ran VIPM as administrator. If VIPM reports dependency issues, ensure you have the required LabVIEW version installed. The package will not install in older versions of LabVIEW.
- **Multiple LabVIEW Versions:** If you have multiple LabVIEW versions on your machine, VIPM will ask which version to install to. Choose a LabVIEW 2023 (or newer) installation. The Icon Editor will only be available in the LabVIEW version you install it to.
- **Reverting to Default Icon Editor:** If you need to revert to the original NI Icon Editor, you can uninstall the package via VIPM. Alternatively, find the installed `lv_icon.lvlibp` file in `<LabVIEW>\resource\plugins` and the `LabVIEW Icon API` folder in `<LabVIEW>\vi.lib\` and remove or rename them (e.g., add `.backup`). Then repair LabVIEW or copy back the original files if you have them backed up.

For any installation issues, feel free to [open an issue](https://github.com/ni/labview-icon-editor/issues) on GitHub or ask for help on the [NI Community forums](https://forums.ni.com) or Discord. Enjoy the enhanced Icon Editor!
