@echo off
:: lvcompare-wrapper.cmd
:: Launch LVCompare with recommended flags. Usage:
::   lvcompare-wrapper.cmd old.vi new.vi [extra LVCompare flags]
:: Place this script somewhere on PATH or call it directly.

setlocal ENABLEDELAYEDEXPANSION

:: Default paths (adjust if needed)
set "LV_COMPARE=C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe"
set "LV_EXE=C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe"

if not exist "%LV_COMPARE%" (
  set "LV_COMPARE=C:\Program Files (x86)\National Instruments\Shared\LabVIEW Compare\LVCompare.exe"
)

if not exist "%LV_EXE%" (
  set "LV_EXE=C:\Program Files (x86)\National Instruments\LabVIEW 2025\LabVIEW.exe"
)

if "%~2"=="" (
  echo Usage: %~nx0 path\to\old.vi path\to\new.vi [extra LVCompare flags]
  exit /b 64
)

set "VI1=%~f1"
set "VI2=%~f2"
shift
shift

if not exist "%LV_COMPARE%" (
  echo [ERROR] LVCompare.exe not found. Edit this script to point to the correct path.
  exit /b 1
)

if exist "%LV_EXE%" (
  "%LV_COMPARE%" "%VI1%" "%VI2%" -lvpath "%LV_EXE%" -nobdcosm -nofppos -noattr %*
) else (
  echo [WARN] LabVIEW.exe not found at the default location; using registered LabVIEW.
  "%LV_COMPARE%" "%VI1%" "%VI2%" -nobdcosm -nofppos -noattr %*
)
