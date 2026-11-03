@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title PANICORE - Generate Diagnostic Report

echo.
echo ==================================================
echo PANICORE - GENERATE ONE DIAGNOSTIC ZIP
echo ==================================================
echo.
if not exist "%~dp0App\Portable_Controller.ps1" (
 echo [STOPPED] Extract this ZIP fully before running the report command.
 goto HOLD
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
 echo [STOPPED] Windows PowerShell is unavailable.
 goto HOLD
)
if not exist "%~dp0Reports\Current" mkdir "%~dp0Reports\Current"
echo Collecting locally saved setup, UE4SS, radar and crash evidence...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0App\Portable_Controller.ps1" -Action Diagnostics
if errorlevel 1 (
 echo [STOPPED] Report collection encountered an error. The window will stay open.
) else (
 echo [OK] Review and upload the latest PHC_Diagnostics_*.zip in Reports.
 echo No information is uploaded automatically.
)
:HOLD
echo.
pause
endlocal
