@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title PANICORE - Cleanup and Uninstall
echo.
echo =================================================
echo  PANICORE Controller - UNINSTALL
 echo =================================================
echo.
if not exist "%~dp0App\Portable_Controller.ps1" (
  echo [STOPPED] Required internal script is missing; extract the full package.
  goto HOLD
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0App\Portable_Controller.ps1" -Action Cleanup -StartupLog "%~dp0Reports\Current\cleanup-last.txt"
if errorlevel 1 (
  echo [STOPPED] The cleanup could not verify an existing loader.
  echo Unknown files were deliberately preserved.
) else (
  echo [OK] Checked and cleaned any verified PANICORE controller loader.
  echo You may delete this portable folder yourself if you no longer need it.
)
:HOLD
echo.
pause
endlocal
