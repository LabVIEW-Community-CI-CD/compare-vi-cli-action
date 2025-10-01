@echo off
:: setup-lvcompare-git-difftool.cmd
:: Idempotently configure Git to use LVCompare.exe as difftool for LabVIEW artifacts.
:: Tested on Windows with Git for Windows.

setlocal ENABLEDELAYEDEXPANSION

:: Default paths (64-bit first, fall back to 32-bit)
set "LV_COMPARE_64=C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe"
set "LV_COMPARE_32=C:\Program Files (x86)\National Instruments\Shared\LabVIEW Compare\LVCompare.exe"
set "LV_EXE_64=C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe"
set "LV_EXE_32=C:\Program Files (x86)\National Instruments\LabVIEW 2025\LabVIEW.exe"

set "LV_COMPARE="
if exist "%LV_COMPARE_64%" set "LV_COMPARE=%LV_COMPARE_64%"
if not defined LV_COMPARE if exist "%LV_COMPARE_32%" set "LV_COMPARE=%LV_COMPARE_32%"

set "LV_EXE="
if exist "%LV_EXE_64%" set "LV_EXE=%LV_EXE_64%"
if not defined LV_EXE if exist "%LV_EXE_32%" set "LV_EXE=%LV_EXE_32%"

if not exist "%LV_COMPARE%" (
  echo [ERROR] LVCompare.exe not found.
  echo Looked for:
  echo   %LV_COMPARE_64%
  echo   %LV_COMPARE_32%
  echo Please edit this script and set LV_COMPARE to your install path.
  exit /b 1
)

if not exist "%LV_EXE%" (
  echo [WARN] LabVIEW.exe (2025) not found at default locations.
  echo        Proceeding without -lvpath (registered LabVIEW will be used).
  set "LV_ARG="
) else (
  set "LV_ARG=-lvpath \"%LV_EXE%\""
)

echo [INFO] Using LVCompare: "%LV_COMPARE%"
if defined LV_ARG echo [INFO] Using LabVIEW:  "%LV_EXE%"

:: Build the difftool command string with proper escaping
set "CMD=\"%LV_COMPARE%\" \"$LOCAL\" \"$REMOTE\" %LV_ARG% -nobdcosm -nofppos -noattr"

echo.
echo [INFO] Configuring Git difftool "lvcompare"...
git config --global difftool.lvcompare.cmd "%CMD%"
git config --global diff.tool lvcompare
git config --global difftool.prompt false
git config --global difftool.trustExitCode true

if errorlevel 1 (
  echo [ERROR] One or more git config commands failed.
  exit /b 2
)

echo.
echo [OK] Git configured. Try:  git difftool -y
exit /b 0
