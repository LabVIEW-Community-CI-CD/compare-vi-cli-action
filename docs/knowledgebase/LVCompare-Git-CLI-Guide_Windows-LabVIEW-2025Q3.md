# LVCompare.exe + Git CLI — Windows (LabVIEW 2025 Q3)
**Version:** 2025-10-01

This is a complete, copy‑pasteable setup guide to use **LVCompare.exe** with the **Git CLI** on **Windows** for **LabVIEW 2025 Q3**. It includes ready‑to‑run commands, optional scripts, and troubleshooting notes suitable for automation (e.g., a Copilot agent).

---

## 0) Prerequisites
- Windows 10/11
- Git CLI installed and on PATH (`git --version`)
- LabVIEW 2025 Q3 installed
- **LVCompare.exe** present (installed with LabVIEW)
- (Optional) **LabVIEW CLI** if you want to generate HTML comparison reports

> Default install paths (adjust if installed elsewhere):
>
> - LVCompare.exe: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`  
> - LabVIEW.exe (64‑bit): `C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe`  
> - LabVIEW.exe (32‑bit): `C:\Program Files (x86)\National Instruments\LabVIEW 2025\LabVIEW.exe`

---

## 1) Quick sanity check (one‑off compare)
Open **Command Prompt** and run (edit the two VI paths first):
```bat
"C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe" ^
  "C:\path\to\old.vi" "C:\path\to\new.vi" ^
  -lvpath "C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe" ^
  -nobdcosm -nofppos -noattr
```
If LVCompare launches and shows the diff, you’re good.

**What the flags do (noise filters):**
- `-nobdcosm` — ignore cosmetic changes on the block diagram (position/size/appearance)
- `-nofppos` — ignore object position/size changes on the front panel
- `-noattr` — ignore VI attribute changes

---

## 2) Configure Git difftool (global)
Run **one** of the following blocks depending on your shell.

### 2.1 Command Prompt / .cmd
```bat
git config --global difftool.lvcompare.cmd ^
 ""C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe" ^
  "$LOCAL" "$REMOTE" ^
  -lvpath "C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe" ^
  -nobdcosm -nofppos -noattr"
git config --global diff.tool lvcompare
git config --global difftool.prompt false
git config --global difftool.trustExitCode true
```

### 2.2 PowerShell
```powershell
git config --global difftool.lvcompare.cmd `
 '"C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe" `
  "$LOCAL" "$REMOTE" `
  -lvpath "C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe" `
  -nobdcosm -nofppos -noattr'
git config --global diff.tool lvcompare
git config --global difftool.prompt false
git config --global difftool.trustExitCode true
```

### 2.3 Git Bash
```bash
git config --global difftool.lvcompare.cmd ""/c/Program Files/National Instruments/Shared/LabVIEW Compare/LVCompare.exe" "$LOCAL" "$REMOTE" -lvpath "/c/Program Files/National Instruments/LabVIEW 2025/LabVIEW.exe" -nobdcosm -nofppos -noattr"
git config --global diff.tool lvcompare
git config --global difftool.prompt false
git config --global difftool.trustExitCode true
```

> Note: `$LOCAL` is the “old/left” side and `$REMOTE` is the “new/right” side when `git difftool` runs.

---

## 3) Use it
From any repo that contains LabVIEW files:
```bat
git difftool               # interactive selection
git difftool -y            # open diffs without prompting
git difftool HEAD~1 HEAD   # compare a range
git difftool -- path\to\ControlLoop.vi  # limit to a file or folder
```
- You’ll see “Binary files differ” in `git diff`; use `git difftool` for a visual VI diff.
- For folder diffs: `git difftool -d` (dir‑diff) opens pairs one after another.

---

## 4) (Optional) Treat VIs as binary in Git
Add the following to your repo’s **.gitattributes** (a sample file is included in this package):
```gitattributes
*.vi   binary
*.vim  binary
*.vit  binary
*.ctl  binary
*.ctt  binary
```
This prevents Git from attempting text diffs/merges on LabVIEW binary artifacts.

---

## 5) (Optional) Add LVCompare to PATH
So you can type `lvcompare` anywhere:
```powershell
[Environment]::SetEnvironmentVariable(
  "Path",
  $env:Path + ";C:\Program Files\National Instruments\Shared\LabVIEW Compare",
  "User"
)
```
Open a new terminal afterwards.

---

## 6) (Optional) HTML comparison report via LabVIEW CLI
If you have **LabVIEWCLI** installed, you can generate a single‑file HTML report (great for CI/code reviews):
```bat
LabVIEWCLI -OperationName CreateComparisonReport ^
  -vi1 "C:\path\to\old.vi" -vi2 "C:\path\to\new.vi" ^
  -reportType HTMLSingleFile -reportPath "C:\path\to\CompareReport.html" ^
  -nobdcosm -nofppos -noattr
```

---

## 7) Troubleshooting
- **Two VIs with the same name in memory**: Rename one, or rely on your SCM’s temporary filenames (most tools do this automatically).
- **Wrong LabVIEW version opens**: Add/adjust `-lvpath` to point at the exact LabVIEW 2025 executable.
- **Too much churn in diffs**: Keep `-nobdcosm`, `-nofppos`, and consider enabling “Separate compiled code from source” on your project to reduce recompile noise.
- **32‑bit installs**: Replace `C:\Program Files\...` with `C:\Program Files (x86)\...` in the examples.

---

## 8) Uninstall / revert the Git config
```bat
git config --global --unset diff.tool
git config --global --unset difftool.lvcompare.cmd
git config --global --unset difftool.prompt
git config --global --unset difftool.trustExitCode
```

---

## 9) Appendix: Ready‑made scripts in this package
- `setup-lvcompare-git-difftool.cmd` — idempotent installer that sets the Git config for LVCompare (auto‑detects 64/32‑bit paths).
- `lvcompare-wrapper.cmd` — helper you can place on PATH to launch LVCompare with recommended flags.
- `sample.gitattributes` — marks common LabVIEW binary file types as binary.

*End of guide.*
