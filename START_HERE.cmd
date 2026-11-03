@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title PANICORE - Install and Start v0.11.6.2
echo.
echo =================================================
echo  PANICORE Controller 0.11.6.2 - START HERE
echo =================================================
echo.
if not exist "%~dp0App\Portable_Controller.ps1" (
  echo [STOPPED] Extract the entire ZIP using "Extract All" first.
  goto HOLD
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo [STOPPED] Windows PowerShell is unavailable.
  goto HOLD
)
echo [1/2] Checking source files and script syntax...
if not exist "%~dp0Reports\Current" mkdir "%~dp0Reports\Current"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0App\Verify_PowerShell.ps1" > "%~dp0Reports\Current\preflight-last.txt" 2>&1
set "PHC_PREFLIGHT_EXIT=%errorlevel%"
type "%~dp0Reports\Current\preflight-last.txt"
if not "%PHC_PREFLIGHT_EXIT%"=="0" (
  echo [STOPPED] Preflight failed. No game files changed.
  goto HOLD
)
echo.
echo [2/2] Preparing UE4SS, launching PANICORE and radar...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0App\Portable_Controller.ps1" -Action Launch -StartupLog "%~dp0Reports\Current\startup-last.txt"
if errorlevel 1 (
  echo [STOPPED] See the error above; session report should be in Reports.
) else (
  echo [OK] The session ended; look in Reports for ONE ZIP.
)
:HOLD
echo.
echo Window stays open for your review.
pause
endlocal
