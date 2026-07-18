@echo off
setlocal
set "INSTALLER=%~dp0Install-NetworkRescueHelper.ps1"
if not exist "%INSTALLER%" set "INSTALLER=%LOCALAPPDATA%\KerryNetworkRescue\Install-NetworkRescueHelper.ps1"
if not exist "%INSTALLER%" (
  echo ERROR: Install-NetworkRescueHelper.ps1 was not found.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%" -Mode Uninstall -AutoElevate
if errorlevel 1 echo ERROR: Privileged Helper uninstall failed.
echo.
pause
endlocal
